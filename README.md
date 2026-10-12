# memory-system

A Claude Code plugin for task memories: one Markdown file per task in `docs/memories/`, and hooks that make sure they get written at the right times.

- **Skill** `memory-system`: how to recall, create and update memories, with a template.
- **PreToolUse hook** (Edit/Write/MultiEdit/NotebookEdit): an edit outside `docs/memories/` is blocked unless the edited file's own repo (or git worktree) has a *live* task memory. Writing the memory itself is always allowed, and paths git ignores are never gated.
- **PostToolUse hook** (Bash): records the repo root of the Bash tool's working directory (no blocking), so files written by Bash are checked at Stop.
- **Stop hook**: for every repo/worktree the session edited or ran Bash in (plus the one containing the Stop cwd), if files changed after that root's newest memory was written, Claude is asked once to update the memory before finishing. Roots a subagent is working in are skipped.

The hooks only act in repos that have a `docs/memories/` directory, so installing at user scope does not affect other repos.

## Install

```
/plugin marketplace add atebites-hub/memory-system
/plugin install memory-system@memory-system --scope project
mkdir -p docs/memories
```

`--scope project` records the plugin in the repo's `.claude/settings.json`, so it applies to that repo only.

Requires `git` and `jq` (the hooks do nothing if `jq` is missing).

## Gate rules

- **Root.** The root is the repo or worktree that contains the edited file (`git rev-parse --show-toplevel` from the file's nearest existing directory; symlinks are resolved on both sides). A file outside any repo, or in a repo without `docs/memories/`, is never gated. Each worktree is gated by its own `docs/memories/`, not the main checkout's.
- **Live memory.** A `docs/memories/[0-9]*.md` with `state: in_progress` counts only if it is also live:
  - it is untracked, modified or staged in that working tree, or was added or changed in a commit on the current branch since its merge-base with the default branch (`origin/HEAD`, else `main`, else `master`); on the default branch itself only the working-tree part counts; or
  - this session wrote it (every Edit/Write to a `docs/memories/*.md` is recorded per session id, under `$CLAUDE_PLUGIN_DATA/sessions/`, else `${TMPDIR:-/tmp}/memory-system/sessions/`) and it still reads `state: in_progress`.

  An old `in_progress` memory from a finished task no longer satisfies the gate, so mark finished tasks `completed` (or `cancelled`).
- **Ignored paths.** An edit to a path git ignores (`git check-ignore`) is not gated and does not add its root to Stop's list, because Stop's `git status` never lists it. A tracked file that matches an ignore pattern is still gated.
- **Stop.** For each root recorded this session, blocks when `git status --porcelain --untracked-files=all` lists a path outside `docs/memories/` that is newer than the root's newest memory. A Stop that follows a block (`stop_hook_active`) is not blocked again. On the default branch with no live memory, the message asks to commit the changes through a branch and pull request, revert them, or delete them if untracked, instead of updating a memory.
- **Subagents.** An edit whose hook input carries `agent_id` (a subagent or in-process teammate) marks its root busy for 30 minutes, keyed by root in the same state directory. Stop skips a busy root, so the main agent is not asked to record work an agent is still doing. Only Edit/Write-family edits mark a root, so an agent that changes files only through Bash is not seen.
- **Bash.** Bash-written files are seen only at Stop (not gated at write time), in roots the session edited or ran Bash in.
- **Off switch.** `MEMORY_GATE=off` in the environment makes every event exit 0.

The hook never uses the network and finishes well inside its 10 s timeout. It needs bash 3.2 or newer (macOS default is fine).

## Tests

```
bash tests/run.sh
```

Builds throwaway git repos and worktrees, feeds hook JSON to `hooks/memory-gate.sh` and asserts exit codes and messages. CI runs it on Linux and macOS.

## License

MIT
