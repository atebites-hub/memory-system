# memory-system

A Claude Code, Codex, and ZCode plugin for task memories: one Markdown file per task in `docs/memories/`, and hooks that make sure they get written at the right times.

- **Skill** `memory-system`: how to recall, create and update memories, with a template.
- **PreToolUse hook** (Edit/Write/MultiEdit/NotebookEdit, including Codex `apply_patch`): an edit outside `docs/memories/` is blocked unless the edited file's own repo (or git worktree) has a *live* task memory. Writing the memory itself is always allowed, and other paths git ignores are never gated.
- **PostToolUse hook** (Bash, including Codex `exec_command`): records the repo root of the hook's reported working directory (a lead's only; no blocking), so shell-written files are checked at Stop.
- **Stop hook**: for every repo/worktree the session edited or ran a shell command in (plus the one containing the Stop cwd), if files changed after that root's newest memory was written, the agent is asked once to update the memory before finishing. A root an agent is working in is skipped, except the project's main checkout.

The hooks only act in repos that have a `docs/memories/` directory, so installing at user scope does not affect other repos.

## Install

### Claude Code

```
/plugin marketplace add atebites-hub/memory-system
/plugin install memory-system@memory-system --scope project
mkdir -p docs/memories
```

`--scope project` records the plugin in the repo's `.claude/settings.json`, so it applies to that repo only.

### Codex desktop or CLI

```sh
codex plugin marketplace add atebites-hub/memory-system
codex plugin add memory-system@memory-system
```

Restart the desktop app or start a new CLI session after installation. Enable the gate in each repository by creating `docs/memories/`:

```sh
mkdir -p docs/memories
```

Codex uses the same hook definitions through its Edit/Write and Bash compatibility aliases. Both string and command-object `apply_patch` inputs are supported. Create or update the task memory in a separate tool call before patching other files: every affected path, including both ends of a move, must pass the gate before any memory write is recorded for the session.

### ZCode

Use ZCode's native plugin manager with the same marketplace:

```sh
zcode plugins marketplace add atebites-hub/memory-system
zcode plugins install memory-system@memory-system
```

To update an existing installation:

```sh
zcode plugins marketplace update memory-system
zcode plugins update memory-system@memory-system
```

Start a new chat after installing or updating. Create `docs/memories/` in each repository to enable the gate. Hooks launch through Bash so they also work when a plugin cache does not preserve executable file permissions.

Requires `git`, `jq`, and Bash 3.2 or newer (the hooks do nothing if `jq` is missing).

## Gate rules

- **Root.** The root is the repo or worktree that contains the edited file (`git rev-parse --show-toplevel` from the file's nearest existing directory). Paths are normalized even through missing directories. Writes through symlinks use the target's repository; Codex deletions and move sources use the directory containing the link because they remove the link itself. A file outside any repo, or in a repo without `docs/memories/`, is never gated. Each worktree is gated by its own `docs/memories/`, not the main checkout's.
- **Live memory.** A `docs/memories/[0-9]*.md` with `state: in_progress` counts only if it is also live:
  - it is untracked, modified or staged in that working tree, or was added or changed in a commit on the current branch since its merge-base with the default branch (`origin/HEAD`, else `main`, else `master`); on the default branch itself only the working-tree part counts; or
  - this session wrote it (every Edit/Write or Codex patch to a `docs/memories/*.md` is recorded per session id, under `$CLAUDE_PLUGIN_DATA/sessions/`, else `${TMPDIR:-/tmp}/memory-system/sessions/`) and it still reads `state: in_progress`.

  An old `in_progress` memory from a finished task no longer satisfies the gate, so mark finished tasks `completed` (or `cancelled`).
- **Ignored paths.** An edit to a path git ignores (`git check-ignore`) is not gated and does not add its root to Stop's list, because Stop's `git status` never lists it. A tracked file that matches an ignore pattern is still gated, and memory writes are recorded even when `docs/memories/` is ignored.
- **Stop.** For each root recorded this session, blocks when `git status --porcelain --untracked-files=all` lists a path outside `docs/memories/` that is newer than the root's newest memory. The message names at most 8 paths, then "and N more". A Stop that follows a block (`stop_hook_active`) is not blocked again. On the default branch with no live memory, the message asks to commit the changes through a branch and pull request, revert them, or delete them if untracked, instead of updating a memory. Stop also drops roots that no longer exist (deleted worktrees) from the session's list.
- **Agents.** An edit by an agent (hook input has `agent_id`, or its `transcript_path` contains `/subagents/`) marks its root busy for 30 minutes, keyed by root in the same state directory. Stop skips a busy root so the lead is not asked to record work an agent is still doing, except the project's main checkout (the root of `CLAUDE_PROJECT_DIR`, else of Stop's cwd), which is always checked. An agent's Bash command that starts with `cd <dir>` also marks that directory's root busy; an agent whose Bash commands do not start with `cd <its worktree>` is not seen. An agent's events never add a root to the session's list (its work is not the lead's to record), though its memory writes still count as live for its own later edits.
- **Bash.** Bash-written files are seen only at Stop (not gated at write time), in roots the session edited or ran Bash in.
- **Codex shell directory limitation.** Codex currently reports the session directory to shell hooks even when `exec_command` uses another `workdir`. Files written in that other repository are checked at Stop only if a file-edit hook also recorded its root. See [openai/codex#32360](https://github.com/openai/codex/issues/32360).
- **Off switch.** `MEMORY_GATE=off` in the environment makes every event exit 0.

The hook never uses the network and has a 10 s timeout. It needs bash 3.2 or newer (macOS default is fine).

## Tests

```
bash tests/run.sh
```

Builds throwaway git repos and worktrees, feeds hook JSON to `hooks/memory-gate.sh` and asserts exit codes and messages. It also executes the manifest commands against a non-executable script copied to a plugin path with spaces.

## License

MIT
