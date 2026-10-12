#!/usr/bin/env bash
# Self-contained tests for hooks/memory-gate.sh. Builds throwaway git repos under mktemp -d,
# feeds hook JSON on stdin and asserts the exit code and the stderr text. Runs on bash 3.2.
#   bash tests/run.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
GATE="$HERE/../hooks/memory-gate.sh"
T=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$T"' EXIT
command -v jq >/dev/null || { echo "tests need jq" >&2; exit 1; }
unset MEMORY_GATE CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

PASS=0 FAIL=0 N=0 CASE=""
RC=0 ERR=""

# ---- helpers ---------------------------------------------------------------
mem_body() { printf -- '---\nstate: %s\n---\n# task\n' "$1"; }

# new_repo NAME [with_mem]: repo on main with one commit; with_mem=1 adds a committed stale in_progress memory.
new_repo() {
  local r="$T/$CASE-$1"
  mkdir -p "$r/src" && git init -q -b main "$r" && echo x >"$r/README" && echo y >"$r/src/a.c"
  if [ "${2:-1}" = 1 ]; then
    mkdir -p "$r/docs/memories" && mem_body in_progress >"$r/docs/memories/2020-01-01-old.md"
  fi
  git -C "$r" add -A && git -C "$r" commit -q -m init
  printf %s "$r"
}
add_mem() { mem_body "$2" >"$1/docs/memories/$3.md"; }   # root state name (untracked)
stamp() { touch -t "$2" "$1"; }                            # file YYYYMMDDhhmm

json() { # event sid file cwd [extra jq args]
  jq -n --arg e "$1" --arg s "$2" --arg f "$3" --arg c "$4" \
    '{hook_event_name:$e,session_id:$s,cwd:$c,tool_name:"Edit",tool_input:(if $f=="" then {} else {file_path:$f} end)}'
}
pre() { json PreToolUse "$1" "$2" "${3:-/}" ; }
agent_pre() { pre "$@" | jq '.agent_id="a1" | .agent_type="general-purpose"'; }
post_bash() { json PostToolUse "$1" "" "$2" | jq '.tool_name="Bash"'; }
stop() { json Stop "$1" "" "$2" | jq --argjson a "${3:-false}" '.stop_hook_active=$a'; }

run() { # JSON  (extra env via the caller's environment)
  ERR=$(printf %s "$1" | "$GATE" 2>&1 >/dev/null); RC=$?
}

check() { # description expected_rc [stderr-substring...]
  local d=$1 want=$2 s; shift 2
  N=$((N + 1)); local ok=1
  [ "$RC" = "$want" ] || ok=0
  for s in "$@"; do case "$ERR" in *"$s"*) ;; *) ok=0 ;; esac; done
  if [ $ok = 1 ]; then PASS=$((PASS + 1)); echo "ok   $N $d"
  else FAIL=$((FAIL + 1)); echo "FAIL $N $d (rc=$RC want $want; stderr: $ERR)"; fi
}

fresh_state() { export CLAUDE_PLUGIN_DATA="$T/data-$CASE"; rm -rf "$CLAUDE_PLUGIN_DATA"; }

# ---- tests -----------------------------------------------------------------
t_no_memdir_passes() {
  local r; r=$(new_repo a 0)
  run "$(pre s1 "$r/src/a.c")"; check "repo without docs/memories passes" 0
}
t_outside_repo_passes() {
  mkdir -p "$T/plain" && echo x >"$T/plain/f.txt"
  run "$(pre s1 "$T/plain/f.txt")"; check "file outside any repo passes" 0
  run "$(pre s1 "$T/plain/new/dir/f.txt")"; check "new file in a missing dir outside any repo passes" 0
}
t_gate_off() {
  local r; r=$(new_repo a)
  MEMORY_GATE=off run "$(pre s1 "$r/src/a.c")"; check "MEMORY_GATE=off passes PreToolUse" 0
  echo z >"$r/src/new.c"; stamp "$r/docs/memories/2020-01-01-old.md" 201901010000; stamp "$r/src/new.c" 202001020000
  run "$(stop s1 "$r")"; check "(control) Stop blocks the same state without the off switch" 2
  MEMORY_GATE=off run "$(stop s1 "$r")"; check "MEMORY_GATE=off passes Stop" 0
}
t_stale_blocked() {
  local r; r=$(new_repo a)
  run "$(pre s1 "$r/src/a.c")"
  check "edit blocked when the only in_progress memory is stale (committed on main)" 2 "$r" "docs/memories/YYYY-MM-DD-" "state: in_progress"
}
t_untracked_ok() {
  local r; r=$(new_repo a); add_mem "$r" in_progress 2026-10-11-task
  run "$(pre s1 "$r/src/a.c")"; check "edit passes with an untracked in_progress memory" 0
}
t_modified_ok() {
  local r; r=$(new_repo a)
  echo "more" >>"$r/docs/memories/2020-01-01-old.md"
  run "$(pre s1 "$r/src/a.c")"; check "edit passes when the in_progress memory is modified in the working tree" 0
}
t_staged_ok() {
  local r; r=$(new_repo a); add_mem "$r" in_progress 2026-10-11-task; git -C "$r" add docs/memories
  run "$(pre s1 "$r/src/a.c")"; check "edit passes with a staged in_progress memory" 0
}
t_feature_branch() {
  local r; r=$(new_repo a)
  git -C "$r" checkout -q -b feat
  run "$(pre s1 "$r/src/a.c")"; check "feature branch with only a stale memory from main is blocked" 2
  add_mem "$r" in_progress 2026-10-11-task; git -C "$r" add -A; git -C "$r" commit -q -m mem
  run "$(pre s1 "$r/src/a.c")"; check "feature branch passes with an in_progress memory committed on that branch" 0
}
t_default_branch_committed_not_live() {
  local r; r=$(new_repo a); add_mem "$r" in_progress 2026-10-11-task; git -C "$r" add -A; git -C "$r" commit -q -m mem
  run "$(pre s1 "$r/src/a.c")"; check "memory committed on the default branch is not live on the default branch" 2
}
t_master_default() {
  local r; r=$(new_repo a); git -C "$r" branch -m main master
  git -C "$r" checkout -q -b feat; add_mem "$r" in_progress 2026-10-11-task; git -C "$r" add -A; git -C "$r" commit -q -m mem
  run "$(pre s1 "$r/src/a.c")"; check "master is found as the default branch" 0
}
t_session_wrote() {
  local r; r=$(new_repo a)
  run "$(pre s1 "$r/docs/memories/2026-10-11-task.md")"; check "writing the memory itself is allowed" 0
  add_mem "$r" in_progress 2026-10-11-task; git -C "$r" add -A; git -C "$r" commit -q -m mem
  run "$(pre s1 "$r/src/a.c")"; check "edit passes after this session wrote the memory and committed it on main" 0
  run "$(pre s2 "$r/src/a.c")"; check "another session does not get the same pass" 2
  add_mem "$r" completed 2026-10-11-task
  run "$(pre s1 "$r/src/a.c")"; check "session-written memory stops counting once it is completed" 2
}
t_session_state_fallback() {
  local r; r=$(new_repo a); unset CLAUDE_PLUGIN_DATA; export TMPDIR="$T/tmp-$CASE"; mkdir -p "$TMPDIR"
  run "$(pre s1 "$r/docs/memories/2026-10-11-task.md")"
  add_mem "$r" in_progress 2026-10-11-task; git -C "$r" add -A; git -C "$r" commit -q -m mem
  run "$(pre s1 "$r/src/a.c")"; check "session state works without CLAUDE_PLUGIN_DATA" 0
  N=$((N + 1))
  if [ -d "$TMPDIR/memory-system/sessions" ]; then PASS=$((PASS + 1)); echo "ok   $N fallback state dir is under TMPDIR/memory-system/sessions"
  else FAIL=$((FAIL + 1)); echo "FAIL $N fallback state dir missing"; fi
  unset TMPDIR
}
t_completed_not_live() {
  local r; r=$(new_repo a 0); mkdir -p "$r/docs/memories"; add_mem "$r" completed 2026-10-11-task
  run "$(pre s1 "$r/src/a.c")"; check "a completed memory does not count" 2
}
t_worktree_gated_by_own_memories() {
  local r w; r=$(new_repo a); w="$T/$CASE-wt"
  git -C "$r" worktree add -q -b wtb "$w"
  add_mem "$r" in_progress 2026-10-11-main-task
  run "$(pre s1 "$w/src/a.c")"; check "worktree edit is blocked when only the main checkout has a live memory" 2 "$w"
  run "$(pre s1 "$r/src/a.c")"; check "main checkout edit passes with its own live memory" 0
  rm "$r/docs/memories/2026-10-11-main-task.md"; add_mem "$w" in_progress 2026-10-11-wt-task
  run "$(pre s1 "$w/src/a.c")"; check "worktree edit passes with the worktree's own live memory" 0
  run "$(pre s1 "$r/src/a.c")"; check "main checkout edit is blocked when only the worktree has a live memory" 2 "$r"
}
t_symlink_path() {
  local r; r=$(new_repo a); ln -s "$r" "$T/$CASE-link"
  run "$(pre s1 "$T/$CASE-link/src/a.c")"; check "symlinked path is treated as the repo (blocked without a live memory)" 2
  add_mem "$r" in_progress 2026-10-11-task
  run "$(pre s1 "$T/$CASE-link/src/a.c")"; check "symlinked path passes with a live memory" 0
  run "$(pre s1 "$T/$CASE-link/docs/memories/2026-10-11-x.md")"; check "memory written through a symlinked path is allowed" 0
}
t_stop_worktree_edit() {
  local r w; r=$(new_repo a); w="$T/$CASE-wt"
  git -C "$r" worktree add -q -b wtb "$w"; stamp "$r/docs/memories/2020-01-01-old.md" 201901010000; stamp "$w/docs/memories/2020-01-01-old.md" 201901010000
  add_mem "$w" in_progress 2026-10-11-wt-task; stamp "$w/docs/memories/2026-10-11-wt-task.md" 202001010000
  run "$(pre s1 "$w/src/new.c")"; check "worktree edit with live memory passes" 0
  echo n >"$w/src/new.c"; stamp "$w/src/new.c" 202001020000
  run "$(stop s1 "$r")"; check "Stop blocks for a changed file in an edited worktree, newer than its memory" 2 "$w" "src/new.c"
  stamp "$w/docs/memories/2026-10-11-wt-task.md" 202001030000
  run "$(stop s1 "$r")"; check "Stop passes when the worktree's memory is newer" 0
  run "$(stop s2 "$r")"; check "another session's Stop does not check that worktree" 0
}
t_stop_nested_worktree() {
  local r w; r=$(new_repo a); w="$r/.claude/worktrees/wt"
  git -C "$r" worktree add -q -b wtb "$w"
  stamp "$r/docs/memories/2020-01-01-old.md" 201901010000; stamp "$w/docs/memories/2020-01-01-old.md" 201901010000
  add_mem "$w" in_progress 2026-10-11-wt-task; stamp "$w/docs/memories/2026-10-11-wt-task.md" 202001010000
  run "$(pre s1 "$w/src/a.c")"; check "edit in a worktree nested in the main checkout passes with its own memory" 0
  run "$(stop s1 "$r")"; check "Stop does not report the nested worktree directory as a change in the main checkout" 0
  echo n >"$w/src/new.c"; stamp "$w/src/new.c" 202001020000
  run "$(stop s1 "$r")"; check "Stop names the nested worktree root, not the main root" 2 "in $w " "src/new.c"
}
t_session_state_kept_alive() {
  local r f; r=$(new_repo a)
  run "$(pre s1 "$r/docs/memories/2026-10-11-task.md")"
  f=$(ls "$CLAUDE_PLUGIN_DATA"/sessions/s1.mem)
  stamp "$f" "$(date -v-3d +%Y%m%d%H%M 2>/dev/null || date -d "3 days ago" +%Y%m%d%H%M)"
  run "$(pre s1 "$r/docs/memories/2026-10-11-task.md")"
  N=$((N + 1)); if [ -n "$(find "$f" -mtime -1)" ]; then PASS=$((PASS + 1)); echo "ok   $N re-recording refreshes the state file's mtime"
  else FAIL=$((FAIL + 1)); echo "FAIL $N state file mtime not refreshed (would be pruned mid-session)"; fi
}
t_stop_cwd_root() {
  local r; r=$(new_repo a); add_mem "$r" in_progress 2026-10-11-task
  stamp "$r/docs/memories/2020-01-01-old.md" 201901010000; stamp "$r/docs/memories/2026-10-11-task.md" 202001010000
  echo n >"$r/src/new.c"; stamp "$r/src/new.c" 202001020000
  run "$(stop s1 "$r/src")"; check "Stop checks the root of its cwd (a subdirectory)" 2 "$r"
}
t_stop_bash_root() {
  local r; r=$(new_repo a); add_mem "$r" in_progress 2026-10-11-task; mkdir -p "$T/$CASE-elsewhere"
  stamp "$r/docs/memories/2020-01-01-old.md" 201901010000; stamp "$r/docs/memories/2026-10-11-task.md" 202001010000
  echo n >"$r/src/viabash.c"; stamp "$r/src/viabash.c" 202001020000
  run "$(stop s1 "$T/$CASE-elsewhere")"; check "Stop does not see a Bash-written file in a root it never heard of" 0
  run "$(post_bash s1 "$r")"; check "PostToolUse Bash never blocks" 0
  run "$(stop s1 "$T/$CASE-elsewhere")"; check "Stop sees a file written by Bash in the session's recorded cwd root" 2 "$r" "src/viabash.c"
}
t_stop_hook_active() {
  local r; r=$(new_repo a); add_mem "$r" in_progress 2026-10-11-task
  stamp "$r/docs/memories/2020-01-01-old.md" 201901010000; stamp "$r/docs/memories/2026-10-11-task.md" 202001010000
  echo n >"$r/src/new.c"; stamp "$r/src/new.c" 202001020000
  run "$(stop s1 "$r" true)"; check "Stop passes when stop_hook_active is true" 0
}
t_stop_ignores_memories_and_no_memdir() {
  local r p; r=$(new_repo a); add_mem "$r" in_progress 2026-10-11-task
  stamp "$r/docs/memories/2020-01-01-old.md" 201901010000; stamp "$r/docs/memories/2026-10-11-task.md" 202001010000
  add_mem "$r" in_progress 2026-10-11-newer; stamp "$r/docs/memories/2026-10-11-newer.md" 202001050000
  run "$(stop s1 "$r")"; check "Stop ignores changes inside docs/memories" 0
  p=$(new_repo b 0); echo n >"$p/src/new.c"
  run "$(stop s1 "$p")"; check "Stop passes in a repo without docs/memories" 0
}

t_ignored_path_passes() {
  local r p; r=$(new_repo a); mkdir -p "$T/$CASE-elsewhere"
  printf 'logs/\n' >"$r/.gitignore"; git -C "$r" add .gitignore; git -C "$r" commit -q -m ignore
  run "$(pre s1 "$r/logs/run/brief.md")"; check "edit of an ignored path in a missing dir passes without a live memory" 0
  run "$(pre s1 "$r/src/a.c")"; check "(control) edit of a tracked path is still blocked" 2
  p=$(new_repo b); printf 'logs/\n' >"$p/.gitignore"; git -C "$p" add .gitignore; git -C "$p" commit -q -m ignore
  run "$(pre s2 "$p/logs/x.md")"
  echo n >"$p/src/new.c"; stamp "$p/docs/memories/2020-01-01-old.md" 201901010000; stamp "$p/src/new.c" 202001020000
  run "$(stop s2 "$T/$CASE-elsewhere")"; check "an ignored edit does not add its root to Stop's list" 0
}
t_tracked_ignored_gated() {
  local r; r=$(new_repo a)
  mkdir -p "$r/build" && echo k >"$r/build/keep.txt" && git -C "$r" add build/keep.txt && git -C "$r" commit -q -m keep
  printf 'build/\n' >"$r/.gitignore"; git -C "$r" add .gitignore; git -C "$r" commit -q -m ignore
  run "$(pre s1 "$r/build/keep.txt")"; check "a tracked file that matches an ignore pattern stays gated" 2
}
t_stop_default_branch_message() {
  local r; r=$(new_repo a); stamp "$r/docs/memories/2020-01-01-old.md" 201901010000
  echo n >"$r/junk.txt"; stamp "$r/junk.txt" 202001020000
  run "$(stop s1 "$r")"; check "Stop on the default branch with no live memory says commit, revert or delete" 2 "default branch" "revert" "junk.txt"
  N=$((N + 1)); case "$ERR" in *"Update the task memory"*) FAIL=$((FAIL + 1)); echo "FAIL $N default-branch message also asks for a memory update" ;;
  *) PASS=$((PASS + 1)); echo "ok   $N default-branch message does not ask for a memory update" ;; esac
  git -C "$r" checkout -q -b feat
  run "$(stop s1 "$r")"; check "Stop on a feature branch asks for a memory update" 2 "Update the task memory" "junk.txt"
}
t_stop_default_branch_live_memory() {
  local r; r=$(new_repo a); stamp "$r/docs/memories/2020-01-01-old.md" 201901010000
  run "$(pre s1 "$r/docs/memories/2026-10-11-task.md")"
  add_mem "$r" in_progress 2026-10-11-task; git -C "$r" add -A; git -C "$r" commit -q -m mem
  stamp "$r/docs/memories/2026-10-11-task.md" 202001010000
  echo n >"$r/src/new.c"; stamp "$r/src/new.c" 202001020000
  run "$(stop s1 "$r")"; check "Stop on the default branch with a session-written live memory asks for a memory update" 2 "Update the task memory"
}
t_stop_skips_agent_busy_root() {
  local r w; r=$(new_repo a); w="$T/$CASE-wt"
  git -C "$r" worktree add -q -b wtb "$w"
  stamp "$r/docs/memories/2020-01-01-old.md" 201901010000; stamp "$w/docs/memories/2020-01-01-old.md" 201901010000
  run "$(pre s1 "$w/docs/memories/2026-10-11-wt-task.md")"
  add_mem "$w" in_progress 2026-10-11-wt-task; stamp "$w/docs/memories/2026-10-11-wt-task.md" 202001010000
  run "$(agent_pre s1 "$w/src/new.c")"; check "a subagent's edit with a live memory passes" 0
  echo n >"$w/src/new.c"; stamp "$w/src/new.c" 202001020000
  run "$(stop s1 "$r")"; check "the lead's Stop skips a worktree a subagent edited within the window" 0
  run "$(stop s2 "$w")"; check "the busy mark is per root, so another session's Stop skips it too" 0
  touch -t 202001010000 "$CLAUDE_PLUGIN_DATA"/sessions/agent-*
  run "$(stop s1 "$r")"; check "Stop checks the worktree again once the mark is past the window" 2 "$w" "src/new.c"
}
t_lead_edit_marks_nothing() {
  local r; r=$(new_repo a); add_mem "$r" in_progress 2026-10-11-task
  run "$(pre s1 "$r/src/a.c")"; check "lead edit passes" 0
  run "$(pre s1 "$r/src/a.c" | jq '.agent_type="main-agent"')"; check "an --agent session's edit (agent_type, no agent_id) passes" 0
  N=$((N + 1)); if ls "$CLAUDE_PLUGIN_DATA"/sessions/agent-* >/dev/null 2>&1; then FAIL=$((FAIL + 1)); echo "FAIL $N an edit without agent_id marked its root busy"
  else PASS=$((PASS + 1)); echo "ok   $N edits without agent_id mark no root busy"; fi
}

for t in $(declare -F | awk '{print $3}' | grep '^t_'); do
  CASE=$t; fresh_state; mkdir -p "$T/$CASE"; "$t"
done
echo "$PASS passed, $FAIL failed, $N total"
[ "$FAIL" = 0 ] && [ "$PASS" = "$N" ]
