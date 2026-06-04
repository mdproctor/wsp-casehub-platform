# HANDOFF — casehub-platform

**Date:** 2026-06-04
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

ACL authorization model research. Discovered `CaseInstance` has no actor identity and `PropagationContext.inheritedAttributes` is always empty in production despite being designed for `userId` propagation. Corrected the worker authorization model: IAM/RBAC style (case definitions declare, authorization service approves, engine enforces) — not the original "creator grants" model. Scope expanded to cross-module enforcement and external token delegation (quarkus-flow token-as-data pattern and secrets DSL researched). Filed platform#68. ACL spec updated exhaustively with all findings, open decisions, and file references.

## Immediate Next Step

Fix the claudony tenancyId null-guard protocol violation — still unresolved:
`casehub/src/main/java/io/casehub/claudony/casehub/ClaudonyLedgerEventCapture.java` line 67:
```java
entry.tenancyId = Objects.requireNonNull(event.tenancyId(), "tenancyId missing from CaseLifecycleEvent");
```
Then begin claudony#121 (full tenancy foundation).

## Cross-Module

*Unchanged — `git show HEAD~2:HANDOFF.md`*

## What's Left

- **claudony**: `ClaudonyLedgerEventCapture` null-guard protocol violation · XS · Low
- **qhorus**: local main diverged from casehubio upstream · S · Med
- Hook install pending: `casehub/aml`, `casehub/clinical`, `hortora/garden` · XS · Low
- platform#58 — AgentSession multi-turn (v2, deferred) · L · Med
- platform#68 — ACL/authorization model: 6 open decisions before design can start (see spec §6.9) · L · High
- Workspace epic branches past deletion dates — kept by user choice

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #68 | Authorization model design — resolve 6 open decisions, then implement | L | High | Read spec §6.9 first; flat vs role-based is the gate |
| — | ACL SPI + `acl-jpa/` module | L | Med | Blocked on #68 decisions |
| #49 | CDI emission investigation — Options A/B/C + storeAll batch | M | Med | Needs devtown/clinical/aml feedback first |
| #39 | CDI priority revisit (memory-mem0/ shipped, unblocked) | S | Med | |
| #34 | Graphiti adapter (`memory-graphiti/`) | L | Med | |

## References

- ACL spec (updated with all 2026-06-04 research): `docs/specs/2026-06-01-acl-design.md`
- Agent spec: `docs/superpowers/specs/2026-06-02-agent-module-design.md`
- Blog: `blog/2026-06-04-mdp02-the-authorization-gap-beneath-the-spec.md`
