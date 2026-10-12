#!/usr/bin/env bash
# Enforces the memory-system skill's timing (exit 2 = block + message to Claude).
#   PreToolUse (Edit|Write|MultiEdit|NotebookEdit): an edit outside docs/memories/ needs a LIVE task memory
#     in the edited file's own repo or worktree. Live = state: in_progress AND either
#       (a) untracked/modified/staged in that working tree, or added/changed on this branch since the merge-base
#           with the default branch (origin/HEAD, else main, else master), or
#       (b) written by this session (recorded in a per-session state file).
#     Paths git ignores are not gated. A subagent's edit (agent_id in the input) marks its root busy.
#   PostToolUse (Bash): records the root of the hook's cwd, so Bash-written files are checked at Stop.
#   Stop: for every root this session touched (plus the root of Stop's cwd, always checked) that no subagent
#     edited in the last AGENT_WINDOW_MIN minutes, files changed after that root's newest memory -> update the
#     memory before finishing (on the default branch with no live memory: commit, revert or delete them instead).
# Opt-in per repo: a repo without docs/memories/ is never gated. MEMORY_GATE=off disables every event.
# Portable to bash 3.2 (macOS): no associative arrays, no mapfile, no ${var,,}. Never touches the network.
set -u
[ "${MEMORY_GATE:-}" = off ] && exit 0
command -v jq >/dev/null || exit 0
command -v git >/dev/null || exit 0
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

IN_PROGRESS_RE='^[[:space:]]*-?[[:space:]]*state:[[:space:]]*in_progress[[:space:]]*$'

# ---- paths ------------------------------------------------------------------
# Physical path of a (possibly not yet existing) file: resolve the nearest existing directory, keep the rest.
phys_path() {
  local p=$1 rest=""
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ ! -d "$p" ]; do rest="/$(basename "$p")$rest"; p=$(dirname "$p"); done
  printf '%s%s' "$(cd "$p" && pwd -P)" "$rest"
}

# Physical toplevel of the repo/worktree containing directory $1 (nearest existing ancestor); empty if none.
repo_root() {
  local d=$1 top
  [ -n "$d" ] || return 0
  while [ ! -d "$d" ]; do d=$(dirname "$d"); done
  top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] && (cd "$top" && pwd -P)
}

# ---- per-session state ------------------------------------------------------
state_dir() { printf %s "${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/memory-system}/sessions"; }
state_file() { # kind(mem|roots)
  local dir sid
  dir=$(state_dir)
  sid=$(printf %s "$SESSION" | tr -c 'A-Za-z0-9_-' '_')
  mkdir -p "$dir" 2>/dev/null || return 1
  find "$dir" -type f -mtime +7 -exec rm -f {} + 2>/dev/null
  printf '%s/%s.%s' "$dir" "${sid:-nosession}" "$1"
}
record() { # kind line
  local f; f=$(state_file "$1") || return 0
  grep -qxF -- "$2" "$f" 2>/dev/null || printf '%s\n' "$2" >>"$f"
  touch "$f" 2>/dev/null  # activity keeps the file clear of the 7-day prune
}
recorded() { # kind line
  local f; f=$(state_file "$1") || return 1
  grep -qxF -- "$2" "$f" 2>/dev/null
}

# ---- subagents --------------------------------------------------------------
# A subagent's edit marks the root busy, and the lead's Stop skips a busy root other than its own cwd root: the
# agent's unfinished work there is not the lead's to record (nor, until the mark lapses, the lead's own edits there).
# Keyed by root, not session, so it holds whatever session_id a subagent carries.
# shortcut: only Edit/Write-family edits mark a root (an agent's Bash cwd is the project dir, not its worktree),
#   so an agent that changes files only through Bash goes unseen; track SubagentStart/SubagentStop if that matters.
AGENT_WINDOW_MIN=30  # agents run test gates of up to 10 min between edits
agent_marker() { # root
  local dir; dir=$(state_dir)
  mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s/agent-%s' "$dir" "$(printf %s "$1" | cksum | tr ' ' -)"
}
agent_busy() { # root
  local m; m=$(agent_marker "$1") || return 1
  [ -n "$(find "$m" -mmin -"$AGENT_WINDOW_MIN" 2>/dev/null)" ]
}

# ---- liveness of a memory ---------------------------------------------------
default_ref() { # root -> a ref naming the default branch
  local r=$1 ref
  ref=$(git -C "$r" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$ref" ] && git -C "$r" rev-parse --verify -q "$ref" >/dev/null; then printf %s "$ref"; return 0; fi
  for ref in main master; do
    git -C "$r" rev-parse --verify -q "refs/heads/$ref" >/dev/null && { printf %s "$ref"; return 0; }
  done
  for ref in origin/main origin/master; do
    git -C "$r" rev-parse --verify -q "refs/remotes/$ref" >/dev/null && { printf %s "$ref"; return 0; }
  done
  return 1
}

on_default_branch() { # root
  local def cur
  def=$(default_ref "$1") || return 1
  cur=$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null)
  [ "$cur" = "${def#origin/}" ]
}

# Repo-relative docs/memories paths that are dirty in the working tree or changed on this branch.
changed_memories() { # root
  local r=$1 def base
  git -C "$r" -c core.quotepath=off status --porcelain --untracked-files=all -- docs/memories 2>/dev/null |
    cut -c4- | sed 's/.* -> //'
  def=$(default_ref "$r") || return 0
  on_default_branch "$r" && return 0
  base=$(git -C "$r" merge-base "$def" HEAD 2>/dev/null) || return 0
  git -C "$r" -c core.quotepath=off diff --name-only "$base" HEAD -- docs/memories 2>/dev/null
}

live_memory_exists() { # root
  local r=$1 m changed
  changed=$(changed_memories "$r")
  for m in "$r"/docs/memories/[0-9]*.md; do
    [ -f "$m" ] && grep -qsE "$IN_PROGRESS_RE" "$m" || continue
    if printf '%s\n' "$changed" | grep -qxF -- "docs/memories/${m##*/}" || recorded mem "$m"; then return 0; fi
  done
  return 1
}

# ---- events -----------------------------------------------------------------
on_pre() {
  local f dir root pf mem m
  f=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$INPUT")
  [ -n "$f" ] || exit 0
  case "$f" in /*) ;; *) f="$CWD/$f" ;; esac
  dir=$(dirname "$f")
  root=$(repo_root "$dir") && [ -n "$root" ] || exit 0
  [ -d "$root/docs/memories" ] || exit 0
  pf=$(phys_path "$f"); mem="$root/docs/memories"
  case "$pf" in "$root"/*) ;; *) exit 0 ;; esac
  [ -n "$AGENT" ] && m=$(agent_marker "$root") && touch "$m" 2>/dev/null
  # Stop's git status never lists ignored paths; memory writes are still recorded, ignored or not.
  case "$pf" in "$mem"/*) ;; *) git -C "$root" check-ignore -q -- "${pf#"$root"/}" && exit 0 ;; esac
  record roots "$root"
  case "$pf" in
  "$mem"/*.md) record mem "$pf"; exit 0 ;;
  "$mem"/*) exit 0 ;;
  esac
  live_memory_exists "$root" && exit 0
  echo "memory-system: no live task memory in $root. Create $root/docs/memories/YYYY-MM-DD-<slug>.md from the skill's template with 'state: in_progress' before editing. An old in_progress memory from a finished task does not count: mark it completed." >&2
  exit 2
}

on_post() {
  local root
  root=$(repo_root "$CWD") && [ -n "$root" ] && [ -d "$root/docs/memories" ] && record roots "$root"
  exit 0
}

# Files git lists as changed (outside docs/memories) that are newer than the root's newest memory.
stale_files() { # root
  local r=$1 newest p
  newest=$(ls -t "$r"/docs/memories/[0-9]*.md 2>/dev/null | head -1)
  git -C "$r" -c core.quotepath=off status --porcelain --untracked-files=all 2>/dev/null |
    cut -c4- | sed 's/.* -> //' | grep -v -e '^docs/memories/' -e '/$' |  # a trailing "/" is a nested repo or worktree
    while IFS= read -r p; do
      [ -e "$r/$p" ] || continue
      if [ -z "$newest" ] || [ "$r/$p" -nt "$newest" ]; then printf '%s\n' "$p"; fi
    done
}

on_stop() {
  local roots root stale cwdroot rf
  [ "$(jq -r '.stop_hook_active // false' <<<"$INPUT")" = true ] && exit 0
  cwdroot=$(repo_root "$CWD")
  rf=$(state_file roots) || rf=/dev/null
  roots=$( { cat "$rf" 2>/dev/null; [ -n "$cwdroot" ] && printf '%s\n' "$cwdroot"; } | sort -u)
  while IFS= read -r root; do
    [ -n "$root" ] && [ -d "$root/docs/memories" ] || continue
    [ "$root" != "$cwdroot" ] && agent_busy "$root" && continue  # the main agent's own checkout is always checked
    stale=$(stale_files "$root" | tr '\n' ' ')
    [ -n "$stale" ] || continue
    stale=$(printf '%s' "$stale" | head -c 300)
    if on_default_branch "$root" && ! live_memory_exists "$root"; then
      echo "memory-system: changes on the default branch in $root with no task in progress: $stale. Commit them through a branch and pull request, revert them, or delete them if untracked, before finishing." >&2
    else
      echo "memory-system: files changed in $root after its last task-memory update: $stale. Update the task memory in $root/docs/memories/ (Status, Lessons, timestamps; state: completed if the task is done) before finishing." >&2
    fi
    exit 2
  done <<<"$roots"
  exit 0
}

INPUT=$(cat)
SESSION=$(jq -r '.session_id // empty' <<<"$INPUT")
AGENT=$(jq -r '.agent_id // empty' <<<"$INPUT")  # set only inside a subagent (agent_type alone also means --agent)
CWD=$(jq -r '.cwd // empty' <<<"$INPUT"); [ -n "$CWD" ] || CWD=$PWD
case "$(jq -r '.hook_event_name // empty' <<<"$INPUT")" in
PreToolUse) on_pre ;;
PostToolUse) on_post ;;
Stop) on_stop ;;
esac
exit 0
