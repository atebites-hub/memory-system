# Launch hooks from non-executable plugin caches

## Description
- Make the existing hook launcher work when an installer does not preserve executable file modes, as observed in ZCode.
- Owned files: `hooks/hooks.json`, `tests/run.sh`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `README.md`, and this task memory.

## Related Memories
- [Codex hook compatibility](2026-10-15-codex-hook-compatibility.md)

## Task (TCREI)
- **Task**: Launch all three hook events through Bash and release compatible plugin metadata and installation guidance.
- **Scope**: inline
- **Context**: [Hook manifest](../../hooks/hooks.json), [regression harness](../../tests/run.sh), and ZCode's installed cache copied the executable script as mode 0644.
- **Rules**: Keep gate behavior unchanged; do not edit installed plugin caches or credentials. The parent agent owns review, commits, publishing, and native UI verification.
- **Evaluation**: verifiable. Gate: `bash tests/run.sh`. Add a manifest execution regression against a mode 0644 copied script and observe failure before changing the launcher; the parent independently reviews the diff and verifies the native host.
- **Iteration**: The parent will publish and reinstall the release through ZCode's native plugin manager, then verify the absent, in_progress, and completed memory lifecycle in the native app.
- **Plan**: Add the failing regression; switch manifest commands to Bash; bump both plugin metadata entries to 0.2.2; document ZCode installation and updates; run the full suite.

## Status
- state: completed
- started: 2026-10-15T18:06:22Z
- updated: 2026-10-15T18:08:02Z
- completed: 2026-10-15T18:08:02Z

## Lessons
### Background & Motivation
- ZCode's native Write reached the hook but failed to launch its mode 0644 script, so the expected memory denial did not occur.

### Key Challenges & Analysis
- Assumptions: Bash remains available, as already required by the hook.
- Alternatives: Changing installed file modes would repair one cache but would not survive reinstalling or updating.
- Risks: The shared manifest affects Claude Code, Codex, and compatible hosts; test the actual manifest commands, including quoting in plugin paths with spaces.

### Feedback & Assistance
- The parent supplied native host failure evidence and requested a durable source fix rather than a cache modification.
- Independent review found no actionable issues and independently reran all 101 tests successfully. Native installation verification remains owned by the parent; this entry records the completed implementation and local verification.

### Learnings
- Actual manifest execution matters: direct script tests missed the installer's removal of executable permissions.
- Before changing the launcher, all five new manifest checks failed with exit 126 (`Permission denied`), while the existing 96 tests passed. After the fix, all 101 tests passed on macOS Bash 3.2; JSON parsing, shell syntax, and `git diff --check` also passed.
- Each event uses `bash "${CLAUDE_PLUGIN_ROOT}/hooks/memory-gate.sh"`, preserving quoting for paths with spaces and making execution independent of the script's mode bits. The gate script and its policy remain unchanged.
