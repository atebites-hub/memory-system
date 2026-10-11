#!/usr/bin/env bash
# Enforces the memory-system skill's timing (exit 2 = block + message to Claude).
#   PreToolUse (Edit|Write|MultiEdit|NotebookEdit): an edit outside docs/memories/ needs a LIVE task memory
#     in the edited file's own repo or worktree. Live = state: in_progress AND either
#       (a) untracked/modified/staged in that working tree, or added/changed on this branch since the merge-base
#           with the default branch (origin/HEAD, else main, else master), or
#       (b) written by this session (recorded in a per-session state file).
#   PostToolUse (Bash): records the root of the hook's cwd, so Bash-written files are checked at Stop.
#   Stop: for every root this session touched (plus the root of Stop's cwd), files changed after that root's
#     newest memory -> update the memory before finishing.
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
state_file() { # kind(mem|roots)
  local dir="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/memory-system}/sessions" sid
  sid=$(printf %s "$SESSION" | tr -c 'A-Za-z0-9_-' '_')
  mkdir -p "$dir" 2>/dev/null || return 1
  find "$dir" -type f -mtime +7 -exec rm -f {} + 2>/dev/null
  printf '%s/%s.%s' "$dir" "${sid:-nosession}" "$1"
}
record() { # kind line
  local f; f=$(state_file "$1") || return 0
  grep -qxF -- "$2" "$f" 2>/dev/null || printf '%s\n' "$2" >>"$f"
}
recorded() { # kind line
  local f; f=$(state_file "$1") || return 1
  grep -qxF -- "$2" "$f" 2>/dev/null
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

# Repo-relative docs/memories paths that are dirty in the working tree or changed on this branch.
changed_memories() { # root
  local r=$1 def cur base
  git -C "$r" -c core.quotepath=off status --porcelain --untracked-files=all -- docs/memories 2>/dev/null |
    cut -c4- | sed 's/.* -> //'
  def=$(default_ref "$r") || return 0
  cur=$(git -C "$r" symbolic-ref -q --short HEAD 2>/dev/null)
  [ "$cur" = "${def#origin/}" ] && return 0
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
  local f dir root pf mem
  f=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$INPUT")
  [ -n "$f" ] || exit 0
  case "$f" in /*) ;; *) f="$CWD/$f" ;; esac
  dir=$(dirname "$f")
  root=$(repo_root "$dir") && [ -n "$root" ] || exit 0
  [ -d "$root/docs/memories" ] || exit 0
  pf=$(phys_path "$f"); mem="$root/docs/memories"
  case "$pf" in "$root"/*) ;; *) exit 0 ;; esac
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
    cut -c4- | sed 's/.* -> //' | grep -v '^docs/memories/' |
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
    stale=$(stale_files "$root" | tr '\n' ' ')
    [ -n "$stale" ] || continue
    echo "memory-system: files changed in $root after its last task-memory update: $(printf '%s' "$stale" | head -c 300). Update the task memory in $root/docs/memories/ (Status, Lessons, timestamps; state: completed if the task is done) before finishing." >&2
    exit 2
  done <<<"$roots"
  exit 0
}

INPUT=$(cat)
SESSION=$(jq -r '.session_id // empty' <<<"$INPUT")
CWD=$(jq -r '.cwd // empty' <<<"$INPUT"); [ -n "$CWD" ] || CWD=$PWD
case "$(jq -r '.hook_event_name // empty' <<<"$INPUT")" in
PreToolUse) on_pre ;;
PostToolUse) on_post ;;
Stop) on_stop ;;
esac
exit 0
