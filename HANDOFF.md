# HANDOFF — casehub-platform

**Date:** 2026-06-04
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

*Updated: #33 closed (Mem0 adapter shipped) — removed from What's Next. parent#160 closed — removed from What's Left.*

---

## Last Session

Cleared the S/XS backlog from platform#55: fixed spec BOM groupId typo (#61), updated PLATFORM.md + CLAUDE.md for agent modules (#59), replaced `Thread.sleep(300)` with Awaitility semaphore polling (#60), and assessed ClaudeAgentProvider vs tmux (#57 — complementary, not replaceable: tmux is load-bearing for Claudony dashboard persistence and ledger causal context). Protocol PP-20260603-a25235 filed; parent#160 opened for Capability Ownership gap.

## Immediate Next Step

Fix the claudony tenancyId null-guard protocol violation — still unresolved:
`casehub/src/main/java/io/casehub/claudony/casehub/ClaudonyLedgerEventCapture.java` line 67:
```java
entry.tenancyId = Objects.requireNonNull(event.tenancyId(), "tenancyId missing from CaseLifecycleEvent");
```
Then begin claudony#121 (full tenancy foundation).

## Cross-Module

**We're blocking:**
- Unknown repo — `WorkBroker` and `ExclusionPolicy` call `membersOf()` expecting `Set<String>`. File issue against correct repo. · S · Low

**Blocked by:**
- quarkus-flow and drools worker use cases — gates ACL SPI work. Read spec §6.5 in `docs/specs/2026-06-01-acl-design.md` first.

## What's Left

- **claudony**: `ClaudonyLedgerEventCapture` null-guard protocol violation · XS · Low
- **qhorus**: local main diverged from casehubio upstream · S · Med
- Hook install pending: `casehub/aml`, `casehub/clinical`, `hortora/garden` · XS · Low
- platform#58 — AgentSession multi-turn (v2, deferred) · L · Med
- Workspace epic branches past deletion dates — kept by user choice

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| — | ACL SPI + `acl-jpa/` module | L | Med | Blocked on worker use cases — read spec §6.5 first |
| #49 | CDI emission investigation — Options A/B/C + storeAll batch | M | Med | Needs devtown/clinical/aml feedback first |
| #39 | CDI priority revisit (memory-mem0/ shipped) | S | Med | |
| #34 | Graphiti adapter (`memory-graphiti/`) | L | Med | |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Parked |

## References

- ACL spec: `docs/specs/2026-06-01-acl-design.md`
- Agent spec: `docs/superpowers/specs/2026-06-02-agent-module-design.md`
- Blog: `blog/2026-06-03-mdp02-two-ways-to-launch-claude.md`
