# HANDOFF — casehub-platform

**Date:** 2026-06-03
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Shipped platform#55: `casehub-platform-agent-api` and `casehub-platform-agent-claude`. Five rounds of spec review converged on: `AgentProvider` SPI + `NoOpAgentProvider @DefaultBean`, `ClaudeAgentClient @Startup`, scheduled subprocess closure for wall-clock timeout, `JdkFlowAdapter` for Flux→Multi bridge. All deployed to casehubio/platform main, mdproctor fork, and mdproctor.github.io (4 blog entries). Branch closed and stamped.

## Immediate Next Step

Fix the claudony tenancyId null-guard protocol violation — still unresolved from the previous handover:
`casehub/src/main/java/io/casehub/claudony/casehub/ClaudonyLedgerEventCapture.java` line 67:
```java
entry.tenancyId = Objects.requireNonNull(event.tenancyId(), "tenancyId missing from CaseLifecycleEvent");
```
Then begin claudony#121 (full tenancy foundation).

## Cross-Module

**We're blocking:**
- Unknown repo — `WorkBroker` and `ExclusionPolicy` call `membersOf()` expecting `Set<String>`. Identify correct repo and file issue. · S · Low

**Blocked by:**
- quarkus-flow and drools worker use cases still pending — gates ACL SPI work. Read spec §6.5 in `docs/specs/2026-06-01-acl-design.md` before any ACL code.

## What's Left

- **claudony**: `ClaudonyLedgerEventCapture` null-guard protocol violation — fix before any other claudony work · XS · Low
- **qhorus**: local main diverged from casehubio upstream — devtown/life dispatch fix stranded locally; needs branch reconciliation · S · Med
- **engine#411**: NOT NULL enforcement for tenancy_id in V2002/V2003 — Hibernate validate strategy will fail at startup on affected consumers · S · Low
- Hook install pending on: `casehub/aml`, `casehub/clinical`, `hortora/garden` · XS · Low
- platform#57 — openclaw: assess ClaudeAgentProvider vs tmux WorkerProvisioner · S · Med
- platform#58 — AgentSession multi-turn (v2, deferred) · L · Med
- platform#59 — PLATFORM.md + CLAUDE.md update for agent-api/agent-claude modules · XS · Low
- platform#60 — `Thread.sleep` in cancellation test → deterministic sync · XS · Low
- platform#61 — spec BOM groupId typo fix · XS · Low
- Workspace epic branches past deletion dates: `epic-platform-api`, `epic-platform-testing`, `epic-quarkus-alignment`, `epic-platform-config` — kept by user choice

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| — | ACL SPI + acl-jpa/ module | L | Med | Blocked on worker use cases — read spec §6.5 first |
| #49 | CDI emission investigation — Options A/B/C + storeAll batch | M | Med | Needs devtown/clinical/aml app feedback first |
| #39 | CDI priority revisit when `memory-mem0/` arrives | S | Med | Blocks on #33 |
| #33 | Mem0 adapter | L | Med | |
| #34 | Graphiti adapter | L | Med | |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Parked |

## References

- Downstream migration: platform#55 comments — drafthouse, eidos, engine, devtown, aml, clinical each need `-claude/` module
- ACL spec: `docs/specs/2026-06-01-acl-design.md`
- Agent spec: `docs/superpowers/specs/2026-06-02-agent-module-design.md`
- Blog: `blog/2026-06-03-mdp01-shipping-platform-agent.md`
