# HANDOFF — casehub-platform

**Date:** 2026-06-04
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Cleared the S/XS backlog from platform#55: fixed spec BOM groupId typo (#61), updated PLATFORM.md + CLAUDE.md for agent modules (#59), replaced `Thread.sleep(300)` with Awaitility semaphore polling (#60), and assessed ClaudeAgentProvider vs tmux (#57 — complementary, not replaceable: tmux is load-bearing for Claudony dashboard persistence and ledger causal context). Protocol PP-20260603-a25235 filed; parent#160 opened for Capability Ownership gap.

## Immediate Next Step

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Left

- **claudony**: `ClaudonyLedgerEventCapture` null-guard protocol violation · XS · Low
- **qhorus**: local main diverged from casehubio upstream · S · Med
- Hook install pending: `casehub/aml`, `casehub/clinical`, `hortora/garden` · XS · Low
- **parent#160** — AgentProvider Capability Ownership entry + casehub-platform deep-dive update · S · Low
- platform#58 — AgentSession multi-turn (v2, deferred) · L · Med
- Workspace epic branches past deletion dates — kept by user choice

## What's Next

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## References

- ACL spec: `docs/specs/2026-06-01-acl-design.md`
- Agent spec: `docs/superpowers/specs/2026-06-02-agent-module-design.md`
- Blog: `blog/2026-06-03-mdp02-two-ways-to-launch-claude.md`
