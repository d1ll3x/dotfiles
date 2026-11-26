---
name: handoff
description: Compact the current conversation into a handover document for another agent to pick up.
argument-hint: "What will the next session be used for?"
disable-model-invocation: true
---

Write a **handover**: a snapshot of where the work stands, so a fresh agent can continue it. Folder layout, frontmatter and snapshot rules are in `~/.agents/docs/notes.md`; read it first.

1. **Locate.** The project folder is `~/Documents/zettelkasten/200-projects/<project>/` (reuse the existing one; its name may differ from the repo's). Handovers go in its `handovers/` subfolder as `<project>-handover-YYYY-MM-DD.md`. Done when you have the path and the newest earlier handover, if any.
2. **Bring tasks current.** Every task touched this session has its `status` and `## Log` updated in `tasks/`. Done when no task's status contradicts what happened in the conversation.
3. **Check drift.** For each earlier snapshot (handover or milestone summary) the next agent is likely to read, apply the drift rule from `notes.md`. Done when every superseded decision in those snapshots has a `Revised` callout.
4. **Write.** Cover:
   - where the work stands, the next task (link the task file) and blockers
   - decisions made this session and where they're recorded
   - verified facts and environment gotchas found nowhere else
   - a **Suggested skills** section, naming which skills the next agent should call the Skill tool for
   - `Related:` links to the plan, the design and the previous handover

   Point to other artifacts (plan, design, ADRs, tasks, commits, diffs) by wikilink, path or URL rather than copying their content. Leave task status in `tasks/`. Redact secrets, tokens and personal data.

   If the user passed arguments, treat them as the focus of the next session and tailor the handover to it.
