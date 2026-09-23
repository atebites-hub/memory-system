#!/usr/bin/env bash
# Enforces the memory-system skill's timing (exit 2 = block + message to Claude):
#   PreToolUse: no repo edits outside docs/memories/ without an in_progress task memory.
#   Stop: files changed after the newest memory was written -> update the memory before finishing.
# Opt-in per repo: does nothing unless the repo has a docs/memories/ directory.
# ponytail: Bash-tool file writes (sed, heredocs) are not gated; add a Bash matcher if that becomes a gap.
set -u
command -v jq >/dev/null || exit 0
# CLAUDE_PROJECT_DIR, not git's toplevel: git resolves symlinks, the tool's file_path does not.
root=${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}
mem="$root/docs/memories"
[ -n "$root" ] && [ -d "$mem" ] || exit 0
input=$(cat)

case "$(jq -r .hook_event_name <<<"$input")" in
PreToolUse)
  f=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
  case "$f" in "$mem"/*) exit 0 ;; "$root"/*) ;; *) exit 0 ;; esac
  grep -qsE '^[[:space:]]*-?[[:space:]]*state:[[:space:]]*in_progress[[:space:]]*$' "$mem"/[0-9]*.md && exit 0
  echo "No in_progress task memory. Before editing, create docs/memories/YYYY-MM-DD-<slug>.md from the memory-system skill's template with 'state: in_progress'." >&2
  exit 2
  ;;
Stop)
  [ "$(jq -r .stop_hook_active <<<"$input")" = true ] && exit 0
  newest=$(ls -t "$mem"/[0-9]*.md 2>/dev/null | head -1)
  stale=$(git -C "$root" status --porcelain --untracked-files=all | cut -c4- | sed 's/.* -> //' | grep -v '^docs/memories/' |
    while read -r p; do [ -e "$root/$p" ] && { [ -z "$newest" ] || [ "$root/$p" -nt "$newest" ]; } && echo "$p"; done)
  [ -z "$stale" ] && exit 0
  echo "Files changed after the last task-memory update: $(echo $stale | head -c 300). Update the task memory in docs/memories/ (Status, Lessons, timestamps; state: completed if the task is done) before finishing." >&2
  exit 2
  ;;
esac
exit 0
