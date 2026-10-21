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
subagent_pre() { pre "$@" | jq '.transcript_path="/h/.claude/projects/p/s1/subagents/agent-a1.jsonl"'; }  # a Workflow agent: no agent_id
patch_pre() { # sid cwd patch [string|command]
  jq -n --arg s "$1" --arg c "$2" --arg p "$3" --arg shape "${4:-command}" \
    '{hook_event_name:"PreToolUse",session_id:$s,cwd:$c,tool_name:"apply_patch",tool_input:(if $shape=="string" then $p else {command:$p} end)}'
}
post_bash() { json PostToolUse "$1" "" "$2" | jq '.tool_name="Bash"'; }
stop() { json Stop "$1" "" "$2" | jq --argjson a "${3:-false}" '.stop_hook_active=$a'; }

run() { # JSON  (extra env via the caller's environment)
  ERR=$(printf %s "$1" | "$GATE" 2>&1 >/dev/null); RC=$?
}

run_manifest() { # JSON event plugin_root
  local command
  command=$(jq -r --arg event "$2" '.hooks[$event][0].hooks[0].command' "$HERE/../hooks/hooks.json")
  ERR=$(printf %s "$1" | CLAUDE_PLUGIN_ROOT="$3" bash -c "$command" 2>&1 >/dev/null); RC=$?
}

check() { # description expected_rc [stderr-substring...]
  local d=$1 want=$2 s; shift 2
  N=$((N + 1)); local ok=1
  [ "$RC" = "$want" ] || ok=0
  if [ "$want" = 0 ] && [ -n "$ERR" ]; then ok=0; fi
  for s in "$@"; do case "$ERR" in *"$s"*) ;; *) ok=0 ;; esac; done
  if [ $ok = 1 ]; then PASS=$((PASS + 1)); echo "ok   $N $d"
  else FAIL=$((FAIL + 1)); echo "FAIL $N $d (rc=$RC want $want; stderr: $ERR)"; fi
}

lacks() { # description substring: the last stderr must not contain it
  N=$((N + 1))
  case "$ERR" in *"$2"*) FAIL=$((FAIL + 1)); echo "FAIL $N $1 (stderr: $ERR)" ;; *) PASS=$((PASS + 1)); echo "ok   $N $1" ;; esac
}

fresh_state() { export CLAUDE_PLUGIN_DATA="$T/data-$CASE"; rm -rf "$CLAUDE_PLUGIN_DATA"; }

# ---- tests -----------------------------------------------------------------
t_manifest_nonexecutable_cache() {
  local r plugin memory; r=$(new_repo a 0)
  mkdir -p "$r/docs/memories"
  plugin="$T/$CASE/plugin with spaces"
  mkdir -p "$plugin/hooks"
  cp "$GATE" "$plugin/hooks/memory-gate.sh"
  chmod 644 "$plugin/hooks/memory-gate.sh"
  run_manifest "$(pre s1 "$r/src/a.c" "$r")" PreToolUse "$plugin"
  check "manifest gates edits from a non-executable cache without a live memory" 2 "$r"
  add_mem "$r" in_progress 2026-10-15-task
  run_manifest "$(pre s1 "$r/src/a.c" "$r")" PreToolUse "$plugin"
  check "manifest permits edits from a non-executable cache with a live memory" 0
  add_mem "$r" completed 2026-10-15-task
  run_manifest "$(pre s1 "$r/src/a.c" "$r")" PreToolUse "$plugin"
  check "manifest blocks edits from a non-executable cache after memory completion" 2 "$r"
  memory="$r/docs/memories/2026-10-15-task.md"
  stamp "$memory" 202001010000
  echo n >"$r/src/from-shell.c"
  run_manifest "$(post_bash s2 "$r")" PostToolUse "$plugin"
  check "manifest launches PostToolUse from a non-executable cache" 0
  run_manifest "$(stop s2 "$T")" Stop "$plugin"
  check "manifest launches Stop and checks the recorded shell root" 2 "$r" "src/from-shell.c"
}

t_codex_payloads() {
  local r patch; r=$(new_repo a)
  patch=$(printf '*** Begin Patch\n*** Update File: src/a.c\n@@\n-y\n+z\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"; check "Codex command-object update is gated" 2 "$r"
  run "$(patch_pre s1 "$r" "$patch" string)"; check "Codex string update is gated" 2 "$r"
  run "$(patch_pre s1 "$r" "$(printf '%s\r\n' '*** Begin Patch' '*** Delete File: src/a.c' '*** End Patch')")"
  check "Codex CRLF headers are gated" 2 "$r"
  run "$(json PreToolUse s1 "" "$r")"; check "empty non-edit payload stays a no-op" 0
  run "$(pre s1 "$r/src/a.c" | jq '.tool_name="NotebookEdit" | .tool_input.notebook_path=.tool_input.file_path | del(.tool_input.file_path)')"
  check "Claude notebook_path remains gated" 2 "$r"
  add_mem "$r" in_progress 2026-10-11-task
  run "$(patch_pre s1 "$r" "$patch")"; check "Codex update passes with a live memory" 0
}
t_codex_operations() {
  local r patch; r=$(new_repo a)
  patch=$(printf '*** Begin Patch\n*** Add File: new/missing/file.c\n+x\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"; check "Codex added file in missing directories is gated" 2 "$r"
  patch=$(printf '*** Begin Patch\n*** Delete File: src/a.c\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"; check "Codex deletion is gated" 2 "$r"
  patch=$(printf '*** Begin Patch\n*** Update File: docs/memories/2020-01-01-old.md\n*** Move to: src/moved.md\n@@\n-# task\n+# moved\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"; check "Codex move destination outside memories is gated" 2 "$r"
  patch=$(printf '*** Begin Patch\n*** Update File: src/a.c\n*** Move to: docs/memories/2026-10-11-moved.md\n@@\n-y\n+z\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"; check "Codex move source outside memories is gated" 2 "$r"
}
t_codex_multi_file() {
  local r other patch; r=$(new_repo a); other=$(new_repo 'with space')
  add_mem "$r" in_progress 2026-10-11-task
  patch=$(printf '*** Begin Patch\n*** Update File: %s/src/a.c\n@@\n-y\n+z\n*** Add File: %s/src/a file.c\n+x\n*** End Patch\n' "$r" "$other")
  run "$(patch_pre s1 "$r" "$patch")"; check "all files and roots in one Codex patch must pass" 2 "$other"
  add_mem "$other" in_progress 2026-10-11-task
  run "$(patch_pre s1 "$r" "$patch")"; check "multi-repo patch passes when both roots have live memories" 0
}
t_codex_memory_recording() {
  local r patch; r=$(new_repo a)
  patch=$(printf '*** Begin Patch\n*** Update File: docs/memories/2020-01-01-old.md\n@@\n-# task\n+# revised\n*** Update File: src/a.c\n@@\n-y\n+z\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"; check "same-patch memory update cannot unlock code edits" 2 "$r"
  run "$(pre s1 "$r/src/a.c")"; check "blocked patch leaves no session memory authorization" 2 "$r"
  patch=$(printf '*** Begin Patch\n*** Add File: docs/memories/2026-10-11-task.md\n+state: in_progress\n+*** Update File: src/a.c\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch" string)"; check "memory patch ignores source-like text in added content" 0
  add_mem "$r" in_progress 2026-10-11-task; git -C "$r" add -A; git -C "$r" commit -q -m mem
  run "$(pre s1 "$r/src/a.c")"; check "successful Codex memory write is remembered by the session" 0
  run "$(pre s2 "$r/src/a.c")"; check "Codex memory authorization stays session-local" 2 "$r"
}
t_codex_path_safety() {
  local r patch; r=$(new_repo 'with space')
  patch=$(printf '*** Begin Patch\n*** Update File: docs/memories/../../src/a.c\n@@\n-y\n+z\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"; check "memory directory traversal does not exempt source edits" 2 "$r"
  ln -s "$r/src" "$r/docs/memories/source"
  patch=$(printf '*** Begin Patch\n*** Add File: docs/memories/source/new.c\n+x\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"; check "symlinked memory subdirectory does not exempt source edits" 2 "$r"
  patch=$(printf '*** Begin Patch\n*** Add File: a file with spaces.c\n+x\n*** End Patch\n')
  run "$(patch_pre s1 "$r/src" "$patch" string)"; check "relative paths use hook cwd and preserve spaces" 2 "$r"
}
t_codex_missing_parent_traversal() {
  local r patch; r=$(new_repo a)
  patch=$(printf '*** Begin Patch\n*** Add File: docs/memories/missing/../../../src/new.c\n+x\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "missing directories before .. do not exempt source edits" 2 "$r"
  add_mem "$r" in_progress 2026-10-11-task
  run "$(patch_pre s1 "$r" "$patch")"
  check "missing-parent traversal passes with a live memory" 0
}
t_codex_file_symlinks() {
  local r other patch; r=$(new_repo a); other=$(new_repo 'other repo')
  ln -s ../../src/a.c "$r/docs/memories/source.md"
  patch=$(printf '*** Begin Patch\n*** Add File: docs/memories/source.md\n+x\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "a final-file symlink in memories does not exempt its source target" 2 "$r"
  add_mem "$r" in_progress 2026-10-11-task
  run "$(patch_pre s1 "$r" "$patch")"
  check "a relative file symlink passes with its target repo memory" 0
  ln -s "$other/src/new.c" "$r/docs/memories/other.md"
  patch=$(printf '*** Begin Patch\n*** Add File: docs/memories/other.md\n+x\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "a dangling cross-repo symlink needs the target repo memory" 2 "$other"
  add_mem "$other" in_progress 2026-10-11-task
  rm "$r/docs/memories/2026-10-11-task.md"
  run "$(patch_pre s1 "$r" "$patch")"
  check "a cross-repo symlink uses the target repo live memory" 0
}
t_codex_symlink_cycles() {
  local r patch; r=$(new_repo a)
  ln -s loop.md "$r/docs/memories/loop.md"
  patch=$(printf '*** Begin Patch\n*** Add File: docs/memories/loop.md\n+x\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "a final-file symlink cycle fails with a diagnostic" 2 "cannot resolve" "too many symbolic links"
  ln -s loop-b "$r/docs/memories/loop-a"
  ln -s loop-a "$r/docs/memories/loop-b"
  patch=$(printf '*** Begin Patch\n*** Add File: docs/memories/loop-a/new.c\n+x\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "a parent-directory symlink cycle fails with a diagnostic" 2 "cannot resolve" "too many symbolic links"
}
t_codex_symlink_memory_recording() {
  local r other patch; r=$(new_repo a); other=$(new_repo b)
  ln -s "$other/docs/memories/2026-10-11-task.md" "$r/task.md"
  patch=$(printf '*** Begin Patch\n*** Add File: task.md\n+state: in_progress\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "writing a cross-repo symlink to a memory is allowed" 0
  add_mem "$other" in_progress 2026-10-11-task
  git -C "$other" add -A; git -C "$other" commit -q -m mem
  run "$(pre s1 "$other/src/a.c")"
  check "symlinked memory authorization records the resolved target" 0
  run "$(pre s2 "$other/src/a.c")"
  check "symlinked memory authorization remains session-local" 2 "$other"
}
t_codex_symlink_unlinks() {
  local r other gated patch deletion move; r=$(new_repo a); other=$(new_repo b 0); gated=$(new_repo c)
  ln -s "$other/src/a.c" "$r/src/link.c"
  deletion=$(printf '*** Begin Patch\n*** Delete File: src/link.c\n*** End Patch\n')
  move=$(printf '*** Begin Patch\n*** Update File: src/link.c\n*** Move to: docs/memories/2026-10-11-moved.md\n@@\n-y\n+z\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$deletion")"
  check "deleting a symlink needs its containing repo memory" 2 "$r"
  run "$(patch_pre s1 "$r" "$move")"
  check "moving a symlink needs its containing repo memory" 2 "$r"
  add_mem "$r" in_progress 2026-10-11-task
  run "$(patch_pre s1 "$r" "$deletion")"
  check "symlink deletion passes with its containing repo memory" 0
  run "$(patch_pre s1 "$r" "$move")"
  check "symlink move passes with its containing repo memory" 0
  rm "$r/src/link.c"; ln -s "$gated/src/a.c" "$r/src/link.c"
  run "$(patch_pre s1 "$r" "$deletion")"
  check "symlink deletion does not need its target repo memory" 0
  run "$(patch_pre s1 "$r" "$move")"
  check "symlink move source does not need its target repo memory" 0
  ln -s cycle.c "$r/src/cycle.c"
  patch=$(printf '*** Begin Patch\n*** Delete File: src/cycle.c\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "unlinking a final symlink cycle does not resolve its target" 0
  ln -s "$gated/src" "$r/docs/memories/directory"
  patch=$(printf '*** Begin Patch\n*** Delete File: docs/memories/directory/a.c\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "unlink operations still resolve parent-directory symlinks" 2 "$gated"
  patch=$(printf '*** Begin Patch\n*** Update File: src/link.c\n@@\n-y\n+z\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "an update without a move still needs the symlink target memory" 2 "$gated"
  ln -s "$gated/src/a.c" "$r/docs/memories/destination.md"
  patch=$(printf '*** Begin Patch\n*** Update File: src/link.c\n*** Move to: docs/memories/destination.md\n@@\n-y\n+z\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "move destinations still follow final symlinks" 2 "$gated"
  ln -s "$gated/docs/memories/2020-01-01-old.md" "$r/src/memory.md"
  patch=$(printf '*** Begin Patch\n*** Delete File: src/memory.md\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "deleting a memory alias is allowed with its containing repo memory" 0
  run "$(pre s1 "$gated/src/a.c")"
  check "unlinking a memory alias does not authorize its target memory" 2 "$gated"
  other=$(new_repo "$(printf ' \twith: spaces')")
  ln -s "$gated/src/a.c" "$other/src/link.c"
  patch=$(printf '*** Begin Patch\n*** Delete File: %s/src/link.c\n*** End Patch\n' "$other")
  run "$(patch_pre s1 "$r" "$patch")"
  check "operation prefixes preserve spaces, tabs, and colons in repo paths" 2 "$other"
}
t_codex_header_whitespace() {
  local r patch; r=$(new_repo a)
  patch=$(printf '*** Begin Patch\n  *** Add File: src/new.c\n+x\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "native indentation before the first Add header is gated" 2 "$r"
  ln -s ../../src/a.c "$r/docs/memories/source.md"
  patch=$(printf '*** Begin Patch\n*** Add File: docs/memories/source.md   \n+x\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "trailing header whitespace does not hide a source symlink" 2 "$r"
  patch=$(printf '*** Begin Patch\n*** Update File: docs/memories/2020-01-01-old.md\n@@\n *** Add File: src/context.c\n+text\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "header-like update context is not treated as another edited path" 0
}
t_codex_lexical_paths() {
  local r other patch; r=$(new_repo a); other=$(new_repo b 0)
  mkdir -p "$other/sub"; ln -s "$other/sub" "$r/src/link"
  patch=$(printf '*** Begin Patch\n*** Add File: src/link/../new.c\n+x\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "Codex normalizes .. before following a directory symlink" 2 "$r"
  run "$(pre s1 "$r/src/link/../new.c")"
  check "legacy file paths retain physical symlink and .. semantics" 0
  add_mem "$r" in_progress 2026-10-11-task
  run "$(patch_pre s1 "$r" "$patch")"
  check "a lexically normalized Codex edit passes with its repo memory" 0
  rm "$r/docs/memories/2026-10-11-task.md"
  ln -s "$other/sub" "$r/docs/memories/link"
  patch=$(printf '*** Begin Patch\n*** Add File: docs/memories/link/../2026-10-11-task.md\n+state: in_progress\n*** End Patch\n')
  run "$(patch_pre s1 "$r" "$patch")"
  check "a lexically normalized Codex memory path is allowed" 0
  add_mem "$r" in_progress 2026-10-11-task
  git -C "$r" add -A; git -C "$r" commit -q -m mem
  run "$(pre s1 "$r/src/a.c")"
  check "Codex records the lexically normalized memory target" 0
  run "$(pre s2 "$r/src/a.c")"
  check "normalized memory authorization remains session-local" 2 "$r"
}
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
t_ignored_memory_dir_recorded() {
  local r; r=$(new_repo a 0); mkdir -p "$r/docs/memories"
  printf 'docs/memories/\n' >"$r/.gitignore"; git -C "$r" add .gitignore; git -C "$r" commit -q -m ignore
  run "$(pre s1 "$r/docs/memories/2026-10-11-task.md")"; check "writing a memory in an ignored docs/memories passes" 0
  add_mem "$r" in_progress 2026-10-11-task
  run "$(pre s1 "$r/src/a.c")"; check "a session-written memory in an ignored docs/memories is live" 0
}
t_stop_default_branch_message() {
  local r; r=$(new_repo a); stamp "$r/docs/memories/2020-01-01-old.md" 201901010000
  echo n >"$r/junk.txt"; stamp "$r/junk.txt" 202001020000
  run "$(stop s1 "$r")"; check "Stop on the default branch with no live memory says commit, revert or delete" 2 "default branch" "revert" "junk.txt"
  lacks "default-branch message does not ask for a memory update" "Update the task memory"
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
# A worktree $w with a live memory and one changed file, newer than that memory.
agent_worktree() { # root w
  git -C "$1" worktree add -q -b wtb "$2"
  stamp "$1/docs/memories/2020-01-01-old.md" 201901010000; stamp "$2/docs/memories/2020-01-01-old.md" 201901010000
  add_mem "$2" in_progress 2026-10-11-wt-task; stamp "$2/docs/memories/2026-10-11-wt-task.md" 202001010000
}
t_stop_skips_agent_busy_root() {
  local r w; r=$(new_repo a); w="$T/$CASE-wt"; agent_worktree "$r" "$w"
  run "$(agent_pre s1 "$w/src/new.c")"; check "an agent's edit with a live memory passes" 0
  echo n >"$w/src/new.c"; stamp "$w/src/new.c" 202001020000
  run "$(stop s1 "$r")"; check "the lead's Stop skips a worktree an agent edited within the window" 0
  run "$(stop s2 "$r")"; check "the busy mark is per root, so another session's Stop skips it too" 0
  touch -t 202001010000 "$CLAUDE_PLUGIN_DATA"/sessions/agent-*
  run "$(stop s1 "$w")"; check "Stop checks the worktree again once the mark is past the window" 2 "$w" "src/new.c"
}
t_stop_skips_subagent_transcript_root() {
  local r w; r=$(new_repo a); w="$T/$CASE-wt"; agent_worktree "$r" "$w"
  run "$(subagent_pre s1 "$w/src/new.c")"; check "an edit from a /subagents/ transcript passes with a live memory" 0
  echo n >"$w/src/new.c"; stamp "$w/src/new.c" 202001020000
  run "$(stop s1 "$r")"; check "a /subagents/ transcript marks its root busy without an agent_id" 0
}
t_stop_busy_worktree_as_cwd() {
  local r w; r=$(new_repo a); w="$T/$CASE-wt"; agent_worktree "$r" "$w"
  run "$(agent_pre s1 "$w/src/new.c")"
  echo n >"$w/src/new.c"; stamp "$w/src/new.c" 202001020000
  CLAUDE_PROJECT_DIR=$r run "$(stop s1 "$w/src")"; check "a busy worktree is skipped even when it holds Stop's cwd, if the project is elsewhere" 0
  run "$(stop s1 "$w/src")"; check "(control) with no CLAUDE_PROJECT_DIR the cwd root is the one never skipped" 2 "$w" "src/new.c"
  mkdir -p "$T/$CASE-plain"
  CLAUDE_PROJECT_DIR=$T/$CASE-plain run "$(stop s1 "$w/src")"; check "a CLAUDE_PROJECT_DIR outside any repo falls back to the cwd root, never skipped" 2 "$w" "src/new.c"
}
t_stop_main_checkout_never_skipped() {
  local r w; r=$(new_repo a); w="$T/$CASE-0wt"; agent_worktree "$r" "$w"  # $w sorts before $r
  add_mem "$r" in_progress 2026-10-11-task; stamp "$r/docs/memories/2026-10-11-task.md" 202001010000
  run "$(agent_pre s1 "$w/src/new.c")"; run "$(agent_pre s1 "$r/src/b.c")"
  echo n >"$w/src/new.c"; echo n >"$r/src/lead.c"; stamp "$w/src/new.c" 202001020000; stamp "$r/src/lead.c" 202001020000
  CLAUDE_PROJECT_DIR=$r run "$(stop s1 "$w")"; check "Stop checks the main checkout even when an agent marked it busy" 2 "$r" "src/lead.c"
  lacks "the busy worktree holding Stop's cwd is skipped in the same Stop" "$w"
}
t_stop_cwd_root_never_skipped() {
  local r; r=$(new_repo a); add_mem "$r" in_progress 2026-10-11-task
  stamp "$r/docs/memories/2020-01-01-old.md" 201901010000; stamp "$r/docs/memories/2026-10-11-task.md" 202001010000
  run "$(agent_pre s1 "$r/src/b.c")"; check "an agent's edit in the main checkout passes" 0
  echo n >"$r/src/lead.c"; stamp "$r/src/lead.c" 202001020000
  run "$(stop s1 "$r")"; check "Stop still checks its own cwd root when an agent marked it busy" 2 "$r" "src/lead.c"
}
t_lead_edit_marks_nothing() {
  local r; r=$(new_repo a); add_mem "$r" in_progress 2026-10-11-task
  run "$(pre s1 "$r/src/a.c")"; check "lead edit passes" 0
  run "$(pre s1 "$r/src/a.c" | jq '.agent_type="main-agent"')"; check "an --agent session's edit (agent_type, no agent_id) passes" 0
  run "$(pre s1 "$r/src/a.c" | jq '.transcript_path="/h/.claude/projects/p/s1.jsonl"')"; check "an edit from the main transcript passes" 0
  N=$((N + 1)); if ls "$CLAUDE_PLUGIN_DATA"/sessions/agent-* >/dev/null 2>&1; then FAIL=$((FAIL + 1)); echo "FAIL $N a lead edit marked its root busy"
  else PASS=$((PASS + 1)); echo "ok   $N lead edits mark no root busy"; fi
}
t_stop_prunes_dead_roots() {
  local r w; r=$(new_repo a); w="$T/$CASE-wt"; agent_worktree "$r" "$w"
  run "$(pre s1 "$w/src/a.c")"; run "$(pre s1 "$r/docs/memories/2026-10-11-task.md")"
  rm -rf "$w"
  run "$(stop s1 "$r")"; check "Stop passes after a recorded worktree is deleted" 0
  N=$((N + 1)); if grep -qxF "$r" "$CLAUDE_PLUGIN_DATA/sessions/s1.roots" && ! grep -qF "$w" "$CLAUDE_PLUGIN_DATA/sessions/s1.roots"
  then PASS=$((PASS + 1)); echo "ok   $N Stop drops a deleted root from the session's list and keeps the live one"
  else FAIL=$((FAIL + 1)); echo "FAIL $N roots file: $(cat "$CLAUDE_PLUGIN_DATA/sessions/s1.roots")"; fi
}
t_stop_lists_eight_paths() {
  local r i; r=$(new_repo a); stamp "$r/docs/memories/2020-01-01-old.md" 201901010000
  git -C "$r" checkout -q -b feat
  for i in 01 02 03 04 05 06 07 08 09 10; do echo n >"$r/src/long-file-name-$i.c"; stamp "$r/src/long-file-name-$i.c" 202001020000; done
  run "$(stop s1 "$r")"; check "Stop names 8 whole paths and counts the rest" 2 "src/long-file-name-01.c" "src/long-file-name-08.c" "and 2 more"
  lacks "Stop does not name the ninth path" "long-file-name-09"
  rm "$r/src/long-file-name-09.c" "$r/src/long-file-name-10.c"
  run "$(stop s1 "$r")"; check "Stop names exactly 8 paths without a count" 2 "src/long-file-name-08.c"
  lacks "no 'more' when 8 paths fit" "more"
}

for t in $(declare -F | awk '{print $3}' | grep '^t_'); do
  CASE=$t; fresh_state; mkdir -p "$T/$CASE"; "$t"
done
echo "$PASS passed, $FAIL failed, $N total"
[ "$FAIL" = 0 ] && [ "$PASS" = "$N" ]
