# Obsidian note conventions

Obsidian (`~/Documents/zettelkasten`) is Dylan's **second brain**: it holds what he knows and is learning. He versions it himself, outside git.

- Read, search and create notes with the `obsidian:obsidian-cli` skill; use the Obsidian skills for syntax (wikilinks, callouts, embeds).
- Attachments go in `800-files/<kebab-filename>`.

## Notes by Claude

Claude writes three kinds of note, each in its own folder and in the shape of its template in `900-templates/`. Permanent notes are Dylan's own writing, which he builds from these.

| Kind | Folder | Template | Tags |
| --- | --- | --- | --- |
| Troubleshooting | `110-literature-notes/` | `Literature Notes` | `zettelkasten/literature`, `troubleshooting`, topic tags |
| Lesson recap | `110-literature-notes/` | `Literature Notes` | `zettelkasten/literature`, `lesson`, topic tags |
| Idea capture | `100-fleeting-notes/` | `Fleeting Notes` | `zettelkasten/fleeting`, `todo`, topic tags |

### Format

The CLI skips Templater, so write the note out in full with the template's frontmatter and real values. A troubleshooting note:

```markdown
---
Created: YYYY-MM-DD HH:mm
Modified: YYYY-MM-DD HH:mm
Tags:
  - zettelkasten/literature
  - troubleshooting
  - <topic tags, e.g. talos, kubernetes>
Related:
  - "[[<related note>]]"
---
# <Title>
<body>

---
# References
- <commit, PR or issue URL from this session>
- <docs the note relied on>
```

An idea capture has the fleeting frontmatter (`Created`, `Modified`, `Tags`), then the H1 and the body. It has no `Related` and no References.

- Filename: the H1 title plus `.md`, spaces kept.
- Timestamps come from `date '+%Y-%m-%d %H:%M'`. Bump `Modified` on every edit.
- Literature notes: at most 600 words.

### Troubleshooting

Write one the moment a fix is confirmed. The title is the symptom as Dylan would search for it. The body has these headings:

- `## Symptom`: the error, copied exactly, in a code block.
- `## Root cause`: one sentence.
- `## Fix`: what changed, and why it works.
- `## Prevention`: the issue, check or ADR this led to.
- `## Dead ends`: each approach tried, and why it failed.

It is complete as written. Done when a search for the error text finds it.

### Lesson recap

Write one when a `/teach` lesson ends, which is when its learning record is written. Title: `lesson <NNNN> <lesson title>`. The body has these headings:

- `## What we learned`: one sentence per insight, in the project glossary's terms, linking the troubleshooting notes the lesson produced.
- `## Still shaky`: what the quiz, the checks or the review showed isn't solid yet.
- `## Next`: the next lesson, or the step it unlocks.

References: the lesson file, its learning records, and the commits or PRs it touched.

### Idea capture

Write these when a lesson or session ends: an insight worth turning into a permanent note, one idea per note, phrased as the question Dylan should answer. Keep only the insights that cost real effort or keep coming back, at most 3 per session. Link the troubleshooting note it came from, if any. Dylan processes a capture by writing his own permanent note from it, or by deleting it.

### Search first

Before diagnosing an error, search the vault for its most distinctive part (`obsidian search query="<error text>"`). Bring any matching troubleshooting note into the diagnosis.
