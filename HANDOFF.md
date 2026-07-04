# HANDOFF — casehub-platform

**Date:** 2026-07-04
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Designed and implemented the DataSource SPI + alpha network event routing system (#136). Brainstormed with Drools vol2 as the reference architecture, ran adversarial design review (28 issues raised, all resolved), implemented via subagent-driven development (5 tasks), pushed to both remotes.

## Immediate Next Step

Pick from What's Next — #131 (base58btc encoding, M/Med) is the most actionable platform issue. The DataSource system is complete but has follow-up work: deregistration lifecycle, marshaller configuration, and engine DataSourceTrigger integration.

## What's Left

- Deregistration lifecycle for DataSource — no `DataSourceDeregistered` CDI event, router accumulates stale entries, orphaned subscriptions on upsert · M · Med
- Marshaller configuration model — `Marshaller<I,O>` interface exists but wiring mechanism (CDI lookup, descriptor property, registration API parameter) is open · S · Med
- Engine `DataSourceTrigger` — new `Trigger` impl referencing a DataSource for external event reactivity · M · Med
- MVEL3 real evaluator — replace mock with real transpiler when MVEL3 published to Maven · S · Low (blocked: MVEL3 not on Maven Central)
- casehubio/ledger#161 — update DIDResolver callers for actorId parameter · S · Low
- casehubio/ledger#165 — IdentityCacheInvalidator: use invalidate() instead of instanceof · XS · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #131 | did:key base58btc encoding (W3C spec compliance) | M | Med | no interop impact until external DIDs |
| #133 | secp256k1 did:key support | M | High | requires BouncyCastle or manual curve params |
| #134 | shared embedding similarity utility | S | Low | consolidate cosine similarity from engine and work |

## References

| Type | Path |
|------|------|
| Design spec | `docs/superpowers/specs/2026-07-03-datasource-alpha-network-architecture-design.md` |
| Implementation plan | `docs/superpowers/plans/2026-07-04-datasource-alpha-network.md` |
| Design review | `~/adr/casehub-platform/datasource-alpha-network-architecture-*/tracker.md` |
| ARC42STORIES | `ARC42STORIES.MD` |
