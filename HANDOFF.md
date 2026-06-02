# HANDOFF — casehub-platform

**Date:** 2026-06-02
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Cross-repo CI/CD audit. Claudony was failing because engine-ledger SNAPSHOT on GitHub Packages predated the tenancyId commits. Root cause: engine's dispatch chain was missing claudony (and aml, devtown, life). Also found eidos was dispatching to devtown+claudony instead of engine — wrong repos entirely. Fixed 8 workflow files across platform/ledger/work/connectors/engine/eidos/qhorus/drafthouse. Filed exhaustive multi-tenancy state audit as parent#140. Claudony CI is now green.

## Immediate Next Step

Fix the protocol violation in `casehub/src/main/java/io/casehub/claudony/casehub/ClaudonyLedgerEventCapture.java` line 67:
```java
// Replace this:
entry.tenancyId = event.tenancyId() != null ? event.tenancyId() : "default";
// With:
entry.tenancyId = Objects.requireNonNull(event.tenancyId(), "tenancyId missing from CaseLifecycleEvent — upstream bug");
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
- parent#130 filed — `docs/PLATFORM.md` + `docs/repos/casehub-platform.md` need `memory-sqlite` added · XS · Low
- Workspace epic branches past deletion dates: `epic-platform-api`, `epic-platform-testing`, `epic-quarkus-alignment`, `epic-platform-config` — kept by user choice
- `worktree-agent-a9a47edb7a2ab6ca0` — orphaned agent worktree on project repo, worth cleaning up

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

- Multi-tenancy org audit: `casehubio/parent#140`
- ACL spec: `docs/specs/2026-06-01-acl-design.md`
- CI/CD dispatch audit: `blog/2026-06-02-mdp01-the-chain-that-wasnt-there.md`
- Prior blog: `blog/2026-06-01-mdp03-the-permission-layer.md`
- Platform module onboarding protocol: `PP-20260602-84e308` in casehub/garden (platform-module-progression.md)
