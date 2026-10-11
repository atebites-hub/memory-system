---
name: memory-system
description: Read and write task memories in docs/memories/. Use when planning, starting work, after searches or user feedback, and when completing tasks.
---

# Memory System

Project task memories live in **`docs/memories/`** as Markdown files, one per task. This is separate from any host-level memory you may use.

This plugin's hooks enforce the timing in any repo that has a `docs/memories/` directory, per repo or git worktree (each worktree uses its own `docs/memories/`):

- An edit outside `docs/memories/` is blocked until a **live** memory exists: `state: in_progress` and either new or changed in this working tree or branch (untracked, modified, staged, or committed on the branch since it left the default branch), or written by this session. Writing the memory itself is always allowed.
- Finishing a turn after changing files (including files written through Bash) asks you to update the memory first.
- An old `in_progress` memory from a finished task no longer unlocks edits: mark finished tasks `completed` (or `cancelled`).
- `MEMORY_GATE=off` in the environment disables the hooks.

## When to use

- **Before a task**: Create or open the task's memory file; fill it from the template; set `state: in_progress`.
- **During work**: After searches or user input, update the same file (analysis, feedback, lessons as appropriate).
- **After a task**: Update that file: status, timestamps, lessons; `state: completed` (or `cancelled`).

## Recall (scan then read)

Survey all memories cheaply (everything through **Related Memories**, before **Task (TCREI)** or **Status**):

```bash
for f in docs/memories/[0-9]*.md; do
  [ -e "$f" ] || continue
  echo "=== $f ==="
  awk '/^## Task \(TCREI\)|^## Status/{exit} {print}' "$f"
  echo
done
```

Pick the most relevant paths from context (current task, links in **Related Memories**, descriptions). **Read the full file** only for those.

## Write

1. **Naming**: `YYYY-MM-DD-<short-task-slug>.md` (kebab-case slug).
2. **Template**: Copy [assets/memory_template.md](assets/memory_template.md). Task structure and fields are defined there; do not duplicate that spec in other repo docs.
3. **Before starting**: New file from template; complete **Description**, **Related Memories**, **Task (TCREI)** (including **Scope**), **Status** (`state: in_progress`, timestamps).
4. **After finishing**: Same file; set **Status** (`completed` / `cancelled`), **Lessons** / **Learnings**, final timestamps.

Prefer links to code/docs over long pasted content. One memory per task.
