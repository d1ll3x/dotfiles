# Dead-end registry logic, used by dead_end_registry.sh (`include "dead_end_registry";`).
# Pure functions over parsed JSON; the shell wrapper does file I/O and ids.

def USD_PER_MILLION: 9; # ~$9 / 1M tokens: a rough headline figure, never billing truth
def MAX_TRANSCRIPT_LINES: 6000;
def MAX_REGISTRY_ENTRIES: 500;
def MAX_CARD_ENTRIES: 3;
def MAX_AGE_DAYS: 60;
def MAX_CODE_LINES: 80;
def MAX_CODE_CHARS: 4000;
def CODE_LOOKBACK: 10;
def PROMPT_MATCH_THRESHOLD: 0.34;
def MIN_PROMPT_OVERLAP: 3;
def HUNK_MATCH_THRESHOLD: 0.6;
def MIN_HUNK_LINES: 3;

# id|weak|reason|regex (case-insensitive). Weak = a *symptom* rather than an explicit
# abandonment: only trusted on assistant messages ("the login page is broken" from the
# user is a bug report).
def REVERT_PATTERNS: [
  {id: "reverted", weak: false, reason: "reverted", re: "\\b(revert(?:ed|ing)?|rolled?\\s+back|roll\\s+back|backed\\s+out)\\b"},
  {id: "undo", weak: false, reason: "undone", re: "\\b(undo|undid|git\\s+revert|git\\s+reset\\s+--hard|restore\\s+the\\s+old)\\b"},
  {id: "didnt-work", weak: true, reason: "didn't work", re: "\\b(didn['’]?t\\s+work|does\\s+not\\s+work|doesn['’]?t\\s+work|not\\s+working|broke\\s+(?:the|everything)|broken)\\b"},
  {id: "abandon", weak: false, reason: "abandoned", re: "\\b(abandon(?:ed|ing)?|give\\s+up|giving\\s+up|gave\\s+up|scrap(?:ped)?\\s+that|drop\\s+(?:this|that)\\s+approach)\\b"},
  {id: "ruled-out", weak: false, reason: "ruled out", re: "\\b(ruled?\\s+out|dead\\s+end|won['’]?t\\s+work|that\\s+approach\\s+(?:failed|is\\s+wrong)|wrong\\s+approach|bad\\s+idea)\\b"},
  # Defect nouns alone are NOT a signal ("this mutex avoids a race condition").
  # Require a causal verb: the change *caused* the defect.
  {id: "race-cond", weak: true, reason: "caused a defect", re: "\\b(?:caused|causing|introduced|introducing|created|hit|ran\\s+into|led\\s+to|resulted?\\s+in|triggered)\\b[^.!?\\n]{0,120}?\\b(?:race\\s+condition|deadlock|infinite\\s+loop|memory\\s+leak|regression)\\b"}
];

def word_set(s): s | [splits("\\s+") | select(length > 0) | {(.): true}] | add;
def STOPWORDS: word_set("
  the a an to of in on for and or but we it this that was is be been being i you he
  she they them as at by with from so if then not no yes do did does have has had will
  would can could should get got my our your its me us up out now just back try tried
  trying approach thing stuff work working worked again because after lets sure okay
  onto into when what how why where which there here some more very much want wants
  need needs going writing making really actually also like well about please");
# Keywords in nearly every coding prompt. A prompt/entry overlap of ONLY these must
# never fire a warning: at least one shared keyword must be outside this set.
def GENERIC_KEYWORDS: word_set("
  fix fixes fixed fixing bug bugs error errors issue issues problem problems fail
  fails failed failing failure failures test tests testing code file files folder line
  lines function functions method methods class update updates updated change changes
  changed changing add adds added adding remove removes removed removing refactor
  refactoring implement implementation implementing run runs running build builds
  building check checks checking write written create creates created creating delete
  deleted broken breaking breaks help still make makes");
# Lines in virtually every file that must not count toward hunk similarity:
# punctuation, comment-only lines, import boilerplate, bare control flow.
# (Input is already lowercased + trimmed by hunk_lines.)
def TRIVIAL_LINE: "\\A(?:[{}()\\[\\];,.:`]+|//.*|/\\*.*|\\*+/?.*|#(?:\\s|!).*|import\\s.*|from\\s.*|export\\s*\\{.*|(?:const|let|var)\\s+\\S+\\s*=\\s*require\\(.*|else\\s*\\{?|\\}?\\s*else\\s*\\{?|try\\s*\\{?|\\}?\\s*catch\\b.*|\\}?\\s*finally\\s*\\{?|return;?|break;?|continue;?|end)\\z";

# Python truthiness, for fields the transcript may leave empty.
def truthy: . != null and . != false and . != "" and . != [] and . != {} and . != 0;
# Math.round semantics (half up).
def js_round: . + 0.5 | floor;
# Number(x) || 0
def num: if type == "number" then . elif type == "boolean" then (if . then 1 else 0 end)
  elif type == "string" then (trim | tonumber? // 0) else 0 end;
# x.toFixed(2)
def money2: (. * 100 | js_round) as $c | "\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)";

# ── Text / fingerprint helpers ──
# gsub/splits slice strings by codepoint index (quadratic on big tool outputs), so the
# hot paths work on codepoints and split on a literal space instead.
def QUOTES: {"96": true, "39": true, "34": true, "8220": true, "8221": true, "8216": true, "8217": true};
def is_word_cp: (. >= 97 and . <= 122) or (. >= 48 and . <= 57) or . == 95 or . == 46 or . == 47 or . == 43 or . == 35 or . == 45;
# Python's str.isspace() set.
def is_space_cp: (. >= 9 and . <= 13) or (. >= 28 and . <= 32) or . == 133 or . == 160 or . == 5760
  or (. >= 8192 and . <= 8202) or . == 8232 or . == 8233 or . == 8239 or . == 8287 or . == 12288;
# gsub("\\s+"; " ") | trim
def squash_ws: explode | map(if is_space_cp then 32 end) | implode | split(" ") | map(select(length > 0)) | join(" ");
def tokenize($stop):
  if type == "string" and length > 0 then
    QUOTES as $q
    | ascii_downcase | explode | map(select($q[tostring] | not) | if is_word_cp then . else 32 end) | implode
    | split(" ") | map(select(length >= 3 and ($stop[.] | not)))
  else [] end;
# Distinct significant keywords in order of appearance, capped.
def keywords($stop; $limit):
  tokenize($stop) as $words
  | [limit($limit; foreach $words[] as $w ({}; .[$w] += 1; select(.[$w] == 1) | $w))];
# Strip diff markers, indentation, blank lines and fences; lowercase.
def hunk_lines:
  if type == "string" and length > 0 then
    split("\n") | map(sub("\\A[+\\- ]"; "") | trim | select(length > 0 and . != "```") | ascii_downcase)
  else [] end;
# Lines that could plausibly identify a specific change.
def substantive_lines:
  hunk_lines | map(select(length >= 4 and test("[a-z0-9]") and (test(TRIVIAL_LINE) | not)));

# ── Transcript parsing ──
def inner: if type == "object" and (.message | truthy) then .message else . end;
def message_text:
  inner | if type != "object" then ""
  else .content | if type == "string" then .
    elif type == "array" then map(if type == "string" then . elif type == "object" and (.text | type) == "string" then .text else "" end) | join("\n")
    else "" end
  end;
def message_role: (inner | if type == "object" then .role else null end) as $r
  | if ($r | truthy) then $r elif type == "object" then (.type // "") else "" end;
# Code payload of an Edit/Write tool_input.
def edit_code($name):
  if type != "object" then ""
  else (if $name == "Write" then .content else .new_string end)
    | if truthy then (if type == "string" then . else tojson end) else "" end
  end;
# Code payloads of every Edit/Write tool_use block in a transcript message.
def tool_use_code:
  inner | if type == "object" and (.content | type) == "array" then
    [.content[] | select(type == "object" and .type == "tool_use" and (.name == "Edit" or .name == "Write"))
     | .input as $in | .name as $n | $in | edit_code($n) | select(trim | length > 0)]
  else [] end;
# Sum of usage tokens across messages; ~4 chars/token if no usage at all.
def estimate_tokens:
  (map(inner | if type == "object" and (.usage | type) == "object" then
      .usage | [.input_tokens, .output_tokens, .cache_read_input_tokens, .cache_creation_input_tokens] | map(num) | add
    else 0 end) | add // 0) as $tokens
  | (map(message_text | length) | add // 0) as $chars
  | if $tokens == 0 and $chars > 0 then $chars / 4 | js_round else $tokens end | floor;
def usd_for: if . > 0 then . * USD_PER_MILLION / 1000000 * 100 | js_round | . / 100 else null end;

# ── Extraction: mine abandoned approaches from a transcript ──
# The most recent Edit/Write before the revert signal that best overlaps the dead-end
# keywords (recency breaks ties), or "".
def find_reverted_code($messages; $i; $kws; $stop):
  ($kws | map({(.): true}) | add // {}) as $kwset
  | reduce range($i; ([0, $i - CODE_LOOKBACK] | max) - 1; -1) as $j (null;
      reduce ($messages[$j] | tool_use_code[]) as $code (.;
        ($code | keywords($stop; 24)) as $ckw
        | if ($ckw | length) == 0 then .
          else ([$ckw[] | select($kwset[.])] | length * 1000 - ($i - $j)) as $score
          | if . == null or $score > .score then {score: $score, code: $code} else . end
          end))
  | .code // "";
def truncate_code: split("\n") | .[:MAX_CODE_LINES] | join("\n") | .[:MAX_CODE_CHARS];
# Short summary of what was tried: the sentence holding a revert cue, else the first.
def summarise($context; $signal):
  ((if ($signal | truthy) then $signal else $context end) | squash_ws) as $clean
  # split after [.!?] + whitespace; $clean has single spaces only
  | ($clean | split(" ") | reduce .[] as $w ([[]]; .[-1] += [$w] | if $w | test("[.!?]\\z") then . + [[]] else . end)
     | map(select(length > 0) | join(" ")) | if length == 0 then [""] else . end) as $sentences
  | ([$sentences[] | select(. as $s | any(REVERT_PATTERNS[]; .re as $re | $s | test($re; "i")))] | .[0]
     // (if ($sentences[0] | truthy) then $sentences[0] else $clean end)) | trim
  | if length > 160 then (.[:157] | rtrim) + "…" else . end;
# Dead-end candidates from revert/abandon signals, deduped by fingerprint.
def extract_dead_ends($stop):
  . as $messages
  | reduce range(0; length) as $i ({seen: {}, out: []};
      ($messages[$i] | message_text) as $text
      | if ($text | length) < 8 then .
        else ($messages[$i] | message_role | ascii_downcase | contains("assistant")) as $assistant
        | ([REVERT_PATTERNS[] | . as $p | select(($assistant or ($p.weak | not)) and ($text | test($p.re; "i")))] | .[0]) as $pat
        | if $pat == null then .
          else ($messages[[0, $i - 2] | max:$i + 1] | map(message_text) | join(" ") | squash_ws) as $context
          # Fewer than 3 keywords can never clear prompt matching's overlap bar.
          | ($context | keywords($stop; 12)) as $kws
          | ($kws[:6] | sort | join("|")) as $fp
          | if ($kws | length) < 3 or .seen[$fp] then .
            else .seen[$fp] = true
            | .out += [{
                summary: summarise($context; $text), reason: $pat.reason, signal: $pat.id,
                keywords: $kws, fingerprint: $fp,
                code: (find_reverted_code($messages; $i; $kws; $stop) | truncate_code),
                # The detour only, not the whole session.
                tokens: ($messages[[0, $i - CODE_LOOKBACK] | max:$i + 1] | estimate_tokens)}]
            end
          end
        end)
  | .out;

# ── Registry ──
# Epoch seconds of an ISO stamp, or null when unparseable.
def parse_ts:
  [capture("\\A(?<d>\\d{4}-\\d{2}-\\d{2})(?:[T ](?<t>\\d{2}:\\d{2}(?::\\d{2})?)(?<f>\\.\\d+)?(?<z>Z|[+-]\\d{2}:?\\d{2})?)?\\z")] | .[0]
  | if . == null then null
    else ((.t // "00:00:00") | if length == 5 then . + ":00" else . end) as $t
    | ((.z // "Z") | if . == "Z" then 0
        else capture("(?<s>[+-])(?<h>\\d{2}):?(?<m>\\d{2})") | (.h | tonumber) * 3600 + (.m | tonumber) * 60 | if .s == "-" then -. else . end
        end) as $off
    | ("\(.d)T\($t)Z" | fromdateiso8601) + ((.f // "0") | tonumber) - $off
    end;
def entry_stamp: (.ts // .date) | if type == "string" and length > 0 then parse_ts else null end;
# Age gate; undated or unparseable (legacy/hand-written) entries are kept.
def is_fresh($now): entry_stamp as $t | $t == null or $now - $t <= MAX_AGE_DAYS * 86400;
# Registry file text → entries (torn concurrent appends tolerated).
def parse_entries: split("\n") | map(select(trim | length > 0) | fromjson? | select(type == "object"));
def read_registry($now): parse_entries | map(select(is_fresh($now))) | .[-MAX_REGISTRY_ENTRIES:];

# ── Matching ──
# Registry entries whose keyword fingerprint overlaps the prompt, best first.
def match_prompt($registry; $stop):
  (keywords($stop; 16) | map({(.): true}) | add // {}) as $pset
  | GENERIC_KEYWORDS as $generic
  | if $pset == {} then []
    else [$registry[]
      | ((.keywords // []) | map({(.): true}) | add // {}) as $eset
      | ([$eset | keys[] | select($pset[.])]) as $shared
      | select(($shared | length) >= MIN_PROMPT_OVERLAP and any($shared[]; $generic[.] | not))
      | {entry: ., score: (($shared | length) / ($pset + $eset | length))}
      | select(.score >= PROMPT_MATCH_THRESHOLD)]
    | sort_by(-.score)
    end;
# Best registry entry whose reverted hunk this edit reintroduces, or null.
def match_edit($registry):
  substantive_lines as $edit
  # Tiny edits are too generic to match confidently.
  | if ($edit | length) < MIN_HUNK_LINES then null
    else ($edit | map({(.): true}) | add) as $eset
    | reduce $registry[] as $e (null;
        ($e.code | substantive_lines) as $lines
        | if ($lines | length) < MIN_HUNK_LINES then .
          else ($lines | map({(.): true}) | add) as $lset
          | ([$lset | keys[] | select($eset[.])] | length) as $shared
          # Ratio alone is not enough: MIN_HUNK_LINES literally shared lines too.
          | if $shared < MIN_HUNK_LINES then .
            else ($shared / ($eset + $lset | length)) as $sim
            | if $sim >= HUNK_MATCH_THRESHOLD and (. == null or $sim > .score) then {entry: $e, score: $sim} else . end
            end
          end)
    end;

# ── Rendering ──
def money: if .usd != null then "~$\(.usd | money2)" else null end;
def render_prompt_card:
  .[:MAX_CARD_ENTRIES] as $top
  | ($top | map(.entry.usd // 0) | add // 0) as $total
  | "Do NOT silently retry the same approach: confirm with the user, or explain why it will be different this time." as $advice
  | ["╔══════════════════════════════════════════════════════════════╗",
     "║  🪦  DEAD-END REGISTRY: you have been here before             ║",
     "╚══════════════════════════════════════════════════════════════╝"]
    + [$top[] | .score as $s | .entry
       | "⚠️  DEAD END [\($s * 100 | js_round)% match]: \(.summary)\n    → \((["tried on \(.date)", "outcome: \(.reason)"] + (money | if . then ["paid \(.) in tokens (est.)"] else [] end)) | join(" · "))"]
    + ["",
       if $total > 0 then "💸  These dead ends already cost an estimated ~$\($total | money2) in tokens the first time. \($advice)" else $advice end]
  | join("\n");
def render_edit_reason:
  .score as $s | .entry
  | (money | if . then " You have now paid for this dead end twice (an estimated \(.) in tokens the first time)." else "" end) as $paid
  | (if (.summary | truthy) then " What was tried: \"\(.summary)\"." else "" end) as $what
  | "🪦 DEAD END: this change closely matches (\($s * 100 | js_round)%) code you already tried on \(.date) and walked back (\(.reason)).\($what)\($paid) Reintroduce it only if you know why it will be different this time.";
# This repo's recorded dead ends as a human-readable card, newest first.
def render_registry:
  if length == 0 then
    "No dead ends recorded yet for this repo.\nKeep using Claude Code here: the Stop/PreCompact hooks mine tried-and-reverted approaches as you go: then run this again."
  else sort_by(-(entry_stamp // 0)) as $ordered
  | ($ordered | length) as $n
  | ($ordered | map(select(.usd != null) | .usd) | add // 0) as $total
  | ["╔══════════════════════════════════════════════════════════════╗",
     "║  🪦  DEAD-END REGISTRY: approaches already tried & walked back ║",
     "╚══════════════════════════════════════════════════════════════╝",
     "\($n) recorded dead end\(if $n == 1 then "" else "s" end) for this repo (newest first):", ""]
    + [range(0; $n) as $i | $ordered[$i]
       | "\($i + 1). \(if (.summary | truthy) then .summary else "(no summary recorded)" end)",
         "    → \((["tried \(if (.date | truthy) then .date else "unknown date" end)",
                   "walked back: \(if (.reason | truthy) then .reason else "ruled out" end)"]
                  + (money | if . then ["paid \(.) in tokens (est.)"] else [] end)) | join(" · "))"]
    + (if $total > 0 then ["", "💸  Estimated total already paid for these dead ends the first time: ~$\($total | money2) in tokens."] else [] end)
  | join("\n")
  end;
