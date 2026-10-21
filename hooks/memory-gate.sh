#!/usr/bin/env bash
# Enforces the memory-system skill's timing (exit 2 = block + message to Claude).
#   PreToolUse (Edit|Write|MultiEdit|NotebookEdit|apply_patch): an edit outside docs/memories/ needs a LIVE task memory
#     in the edited file's own repo or worktree. Live = state: in_progress AND either
#       (a) untracked/modified/staged in that working tree, or added/changed on this branch since the merge-base
#           with the default branch (origin/HEAD, else main, else master), or
#       (b) written by this session (recorded in a per-session state file).
#     Paths git ignores are not gated. An agent's edit (agent_id in the input, or a /subagents/ transcript path)
#     marks its root busy for AGENT_WINDOW_MIN minutes.
#   PostToolUse (Bash): records the root of the hook's cwd, so Bash-written files are checked at Stop.
#   Stop: for every root this session touched (plus the root of Stop's cwd) except a busy one, files changed after
#     that root's newest memory -> update the memory before finishing (on the default branch with no live memory:
#     commit, revert or delete them instead). The project's main checkout (CLAUDE_PROJECT_DIR's root, else Stop's
#     cwd root) is never skipped. Stop also drops roots that no longer exist from the session's list, and names
#     at most 8 files.
# Opt-in per repo: a repo without docs/memories/ is never gated. MEMORY_GATE=off disables every event.
# Portable to bash 3.2 (macOS): no associative arrays, no mapfile, no ${var,,}. Never touches the network.
set -u
[ "${MEMORY_GATE:-}" = off ] && exit 0
command -v jq >/dev/null || exit 0
command -v git >/dev/null || exit 0
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

IN_PROGRESS_RE='^[[:space:]]*-?[[:space:]]*state:[[:space:]]*in_progress[[:space:]]*$'

# ---- paths ------------------------------------------------------------------
# Resolve .. and symlinks component by component; unlink keeps the final link path.
phys_path() {
  local p=$1 mode=${2:-write} pending resolved="" part target links=0
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  pending=${p#/}
  while [ -n "$pending" ]; do
    part=${pending%%/*}
    case "$pending" in */*) pending=${pending#*/} ;; *) pending="" ;; esac
    case "$part" in
    ""|.) ;;
    ..) resolved=${resolved%/*} ;;
    *)
      resolved="$resolved/$part"
      if [ -L "$resolved" ] && { [ "$mode" != unlink ] || [ -n "$pending" ]; }; then
        links=$((links + 1))
        if [ "$links" -gt 40 ]; then
          echo "memory-system: cannot resolve $p: too many symbolic links (possible cycle)." >&2
          return 1
        fi
        target=$(readlink "$resolved") || {
          echo "memory-system: cannot read symbolic link $resolved." >&2
          return 1
        }
        resolved=${resolved%/*}
        case "$target" in /*) resolved=""; target=${target#/} ;; esac
        pending="$target${pending:+/$pending}"
      fi
      ;;
    esac
  done
  printf '%s' "${resolved:-/}"
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

# ---- agents -----------------------------------------------------------------
# An agent's edit marks the root busy, and the lead's Stop skips a busy root other than the project's main checkout:
# the agent's unfinished work there is not the lead's to record. Keyed by root, not session, so it holds whatever
# session_id an agent carries.
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
# Delete and move sources unlink the final path; other edits write through final symlinks.
tool_paths() {
  jq -r --arg cwd "$CWD" '
    # Codex joins patch paths lexically before resolving filesystem symlinks.
    def path:
      sub("^\\*\\*\\* (Add File|Update File|Delete File|Move to): "; "") |
      (if startswith("/") then . else $cwd + "/" + . end) |
      reduce (split("/")[]) as $part
        ([]; if $part == "" or $part == "." then . elif $part == ".." then .[:-1] else . + [$part] end) |
      "/" + join("/");
    .tool_input |
    if type == "object" and (.file_path // .notebook_path) then "write:" + (.file_path // .notebook_path)
    else
      (if type == "string" then . elif type == "object" then .command // empty else empty end) |
      reduce (split("\n")[]) as $raw
        ({state:"start", move:false, paths:[]};
         .state as $state | .move as $move | .move=false |
         # In Update hunks leading whitespace denotes context, not header indentation.
         ($raw | if $state == "update" then sub("\\s+$"; "") else gsub("^\\s+|\\s+$"; "") end) as $line |
         if $line | startswith("*** Add File: ") then
           .state="add" | .paths += ["write:" + ($line | path)]
         elif $line | startswith("*** Delete File: ") then
           .state="delete" | .paths += ["unlink:" + ($line | path)]
         elif $line | startswith("*** Update File: ") then
           .state="update" | .move=true | .paths += ["write:" + ($line | path)]
         elif $state == "update" and $move and ($line | startswith("*** Move to: ")) then
           .paths[-1] |= sub("^write:"; "unlink:") |
           .paths += ["write:" + ($line | path)]
         else . end) | .paths[]
    end
  ' <<<"$INPUT"
}

check_path() {
  local mode=${1%%:*} f=${1#*:} dir root pf mem
  [ -n "$f" ] || return 0
  case "$f" in /*) ;; *) f="$CWD/$f" ;; esac
  pf=$(phys_path "$f" "$mode") || return 2
  dir=$(dirname "$pf")
  root=$(repo_root "$dir") && [ -n "$root" ] || return 0
  [ -d "$root/docs/memories" ] || return 0
  mem="$root/docs/memories"
  case "$pf" in "$root"/*) ;; *) return 0 ;; esac
  [ -n "$AGENT" ] && touch "$(agent_marker "$root")" 2>/dev/null
  case "$pf" in
  "$mem"/*) record roots "$root"; return 0 ;;
  esac
  # Stop's git status never lists ignored paths (memory writes above are recorded, ignored or not).
  git -C "$root" check-ignore -q -- "${pf#"$root"/}" && return 0
  record roots "$root"
  live_memory_exists "$root" && return 0
  echo "memory-system: no live task memory in $root. Create $root/docs/memories/YYYY-MM-DD-<slug>.md from the skill's template with 'state: in_progress' before editing. An old in_progress memory from a finished task does not count: mark it completed." >&2
  return 2
}

on_pre() {
  local paths entry mode f root pf
  paths=$(tool_paths)
  while IFS= read -r entry; do check_path "$entry" || exit 2; done <<<"$paths"
  # Record memory writes only after every path passes: blocked patches must not unlock stale memories.
  while IFS= read -r entry; do
    mode=${entry%%:*}; f=${entry#*:}
    [ -n "$f" ] || continue
    case "$f" in /*) ;; *) f="$CWD/$f" ;; esac
    pf=$(phys_path "$f" "$mode") || exit 2
    root=$(repo_root "$(dirname "$pf")") && [ -n "$root" ] || continue
    case "$pf" in "$root"/docs/memories/*.md) record mem "$pf" ;; esac
  done <<<"$paths"
  exit 0
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

# Whole paths for a message: at most 8, then "and N more".
path_list() { # newline-separated paths
  local n; n=$(printf '%s\n' "$1" | wc -l | tr -d ' ')
  printf '%s\n' "$1" | head -8 | tr '\n' ' ' | sed 's/ $//'
  [ "$n" -gt 8 ] && printf ' and %s more' $((n - 8))
}

on_stop() {
  local roots root stale cwdroot mainroot rf
  [ "$(jq -r '.stop_hook_active // false' <<<"$INPUT")" = true ] && exit 0
  cwdroot=$(repo_root "$CWD")
  mainroot=$(repo_root "${CLAUDE_PROJECT_DIR:-$CWD}")  # the lead's shell often sits in a worktree an agent builds in
  [ -n "$mainroot" ] || mainroot=$cwdroot  # CLAUDE_PROJECT_DIR outside any repo exempts nothing else
  rf=$(state_file roots) || rf=/dev/null
  if [ -f "$rf" ]; then  # every agent shares the session id, so the list grows with each deleted worktree
    while IFS= read -r root; do
      if [ -d "$root/docs/memories" ]; then printf '%s\n' "$root"; fi
    done <"$rf" >"$rf.new"
    # shortcut: a hook appending between the read and the mv is lost, so touch the file only when a root was dropped; the next edit re-records it
    cmp -s "$rf" "$rf.new" && rm -f "$rf.new" || mv "$rf.new" "$rf"
  fi
  roots=$( { cat "$rf" 2>/dev/null; [ -n "$cwdroot" ] && printf '%s\n' "$cwdroot"; } | sort -u)
  while IFS= read -r root; do
    [ -n "$root" ] && [ -d "$root/docs/memories" ] || continue
    [ "$root" != "$mainroot" ] && agent_busy "$root" && continue
    stale=$(stale_files "$root")
    [ -n "$stale" ] || continue
    stale=$(path_list "$stale")
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
# An agent: agent_id is set only inside a subagent (agent_type alone also means --agent); Workflow agents are not
# documented to carry it, so their transcript path (.../subagents/...) counts too.
AGENT=$(jq -r 'if (.agent_id // "") != "" or ((.transcript_path // "") | contains("/subagents/")) then 1 else empty end' <<<"$INPUT")
CWD=$(jq -r '.cwd // empty' <<<"$INPUT"); [ -n "$CWD" ] || CWD=$PWD
case "$(jq -r '.hook_event_name // empty' <<<"$INPUT")" in
PreToolUse) on_pre ;;
PostToolUse) on_post ;;
Stop) on_stop ;;
esac
exit 0
