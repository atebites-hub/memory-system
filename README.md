# memory-system

A Claude Code plugin for task memories: one Markdown file per task in `docs/memories/`, and hooks that make sure they get written at the right times.

- **Skill** `memory-system`: how to recall, create and update memories, with a template.
- **PreToolUse hook** (Edit/Write): edits outside `docs/memories/` are blocked until a memory with `state: in_progress` exists. Writing the memory itself is always allowed.
- **Stop hook**: if files changed after the newest memory was written, Claude is asked once to update the memory before finishing.

The hooks only act in repos that have a `docs/memories/` directory, so installing at user scope does not affect other repos.

## Install

```
/plugin marketplace add atebites-hub/memory-system
/plugin install memory-system@memory-system --scope project
mkdir -p docs/memories
```

`--scope project` records the plugin in the repo's `.claude/settings.json`, so it applies to that repo only.

Requires `git` and `jq` (the hooks do nothing if `jq` is missing).

## Limits

File writes made through the Bash tool (sed, heredocs) are not gated.

## License

MIT
