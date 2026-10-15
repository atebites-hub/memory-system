# Enforce task memories for Codex patch edits

## Description
- Fix Codex edits bypassing the memory gate and publish a reviewed plugin update.
- Preserve Claude Code behavior and the existing per-repository opt-in.

## Related Memories
- None; this is the first task memory in this repository.

## Task (TCREI)
- **Task**: Support Codex patch payloads in the memory hook, with regression tests and installation guidance.
- **Scope**: inline
- **Context**: [Hook](../../hooks/memory-gate.sh), [tests](../../tests/run.sh), and [README](../../README.md). Version 0.2.0 only reads Claude file-path payloads.
- **Rules**: Keep Bash 3.2 support, validate every affected repository before authorizing a memory write, and retain existing Claude inputs. Do not publish a release or merge the PR without user direction.
- **Evaluation**: verifiable; Gate: bash tests/run.sh. Independently review patch parsing and memory authorization, then run the existing Linux/macOS CI on the published PR.
- **Iteration**: Reconcile the installed local workaround with the upstream release after merge.
- **Plan**: Reproduce on upstream; port the fix and tests; fix confirmed path bypasses; document Codex installation and its shell-hook limit; bump the plugin version; commit, push, and open a PR.

## Status
- state: completed
- started: 2026-10-15
- updated: 2026-10-15
- completed: 2026-10-15

## Lessons
### Background & Motivation
Codex supplies apply_patch input as a string or a command object. Reading only file_path/notebook_path silently skips its edits.

### Key Challenges & Analysis
- Assumptions: Codex dispatches apply_patch through the Edit/Write hook aliases, verified in the desktop app before this task.
- Counterpoints: One patch can touch multiple files, move paths, or span repositories; checking the first path is insufficient.
- Alternatives: Keep one shared hook rather than introduce a separate Codex implementation.
- Risks: A denied patch must not record a memory authorization that permits a later edit.
- Confirmed bypasses: missing-directory traversal and final-file symlinks can disguise source edits as memory writes. Resolve the complete target before looking up its repository.
- Symlink operations differ: writes follow the final link, while Codex deletion and move-source operations unlink it. The resolver must use the corresponding path rather than apply one rule to every operation.
- Codex normalizes patch-header whitespace. Header scanning must follow those rules without mistaking update-context text for a file header.
- Codex joins and lexically normalizes dot segments before resolving filesystem symlinks. Normalize native patch paths in that order; keep Claude path handling physical.
- Host limit: native Codex shell hooks drop exec_command workdir. Do not add synthetic workdir handling that cannot fix the native behavior.

### Feedback & Assistance
- User requested a proper upstream fix as a first project and uses ~/github/<project-name> for checkouts.
- Independent review found two existing path bypasses; both now have fixes and regression cases.
- Native hook-contract review confirmed Edit/Write and Bash aliases, command-object patch payloads, and CLAUDE_PLUGIN_ROOT/DATA compatibility. Existing hook definitions remain valid.
- Final independent review caught the unlink distinction, accepted header whitespace, and native lexical normalization; all now have fixes and regression cases.
- Disposable native patch-tool checks confirmed that deleting a symlink leaves its target intact, and a symlink followed by .. is normalized lexically before a write.

### Learnings
- Original upstream suite: 43 passed. Expanded Codex suite against upstream: 49 passed, 14 failed, reproducing the compatibility defect.
- Final suite: 96 passed on macOS Bash 3.2.57; shell syntax and diff checks pass. Linux/macOS CI will verify the published PR.
- Match the host patch parser and filesystem operations separately: normalization order, header whitespace, and unlink semantics affect which repository must have a live memory.
