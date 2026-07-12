# HANDOFF — casehub-platform

**Date:** 2026-07-12
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Implemented #138 — DataSource deregistration lifecycle. Rete-style self-pruning: AlphaDataSource reference counting (markForRemoval + share count), idempotent register (first-descriptor-wins, replacing silent upsert), lifecycle-aware deregister with DataSourceDeregistered CDI event. DataSourceRouter convergent wiring handles CDI event ordering. SubscriptionEngine observes deregistration. Design review (7 rounds, 16 issues, all resolved) caught re-registration race during drain, CDI event ordering, conditional removal gating. Also filed engine#688 (DataSourceTrigger moved to casehub-engine), closed platform #140 as misfiled. Logged idea: shared situation awareness — notification inbox as agent cognition surface.

## Immediate Next Step

Pick from What's Next — #146 notification center frontend or #139 Marshaller configuration model. Domain notification bridges (casehub-work, casehub-engine) still need filing as cross-repo issues.

## Cross-Module

**We're blocking:**
- `casehub-work` — `WorkEventTypeTest` needs updating for new notification/subscription event types · XS · Low

## What's Left

**Epic #137 — DataSource SPI follow-up:**
- #139 Marshaller configuration model · S · Med
- #141 MVEL3 real evaluator · S · Low (blocked on Maven Central publish)
- #171 JPA-backed DataSourceRegistry · M · Med
- #172 DataSource descriptor update mechanism · S · Med

**Epic #147 — Notification deferred:**
- #164 Validate BUFFER_FOR_DIGEST requires digested channel · S · Low
- #165 Secondary index for pendingKeysForUser · XS · Low (profile first)
- #167 Digest buffer orphan cleanup/retention · S · Low
- #168 UUIDv7 relocation from notification package · XS · Low
- #169 InMemoryDeliveryChannelRegistry extraction · S · Low
- #170 Open/engagement tracking · M · Med

**Other:**
- casehubio/neocortex#101 — bridge-only reactive implementations · M · Med
- Domain notification bridges (casehub-work, casehub-engine, casehub-iot) — not yet filed · S · Low each

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #146 | Notification center frontend | L | Med | Remaining: blocks-ui#33, blocks-ui#34 |
| #139 | Marshaller configuration model | S | Med | Wiring mechanism for Marshaller<I,O> |
| #171 | JPA-backed DataSourceRegistry | M | Med | Persistent DataSource storage |
| #170 | Open/engagement tracking | M | Med | Email opens, push taps — deferred from #154 |

## References

| Type | Path |
|------|------|
| Spec | `docs/specs/2026-07-10-datasource-deregistration-design.md` |
| Plan | `docs/plans/2026-07-11-datasource-deregistration.md` |
| Review | `~/adr/casehub-platform/datasource-deregistration-light-20260711-152550/` |
| Garden | `GE-20260711-265dfc` — convergent CDI @ObservesAsync handlers |
| Idea | `IDEAS.md` — shared situation awareness: notification inbox as agent cognition surface |
