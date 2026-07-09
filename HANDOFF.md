# HANDOFF — casehub-platform

**Date:** 2026-07-09
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Implemented #154 — guaranteed delivery tracking and retry. Universal delivery tracking (every channel delivery recorded as `DeliveryAttempt`), per-channel retry via `guaranteedMinSeverity` on `DeliveryChannelDescriptor`, exponential backoff with jitter in `DeliveryRetryProcessor`. Design review (20 issues, all resolved) caught concurrent claim semantics, exception-path infinite retry, and digest pre-persist timing race. Two new modules: `delivery-tracking-inmem/`, `delivery-tracking-jpa/` (Flyway V3000).

## Immediate Next Step

Pick from What's Next — #146 notification center frontend or #138 DataSource deregistration lifecycle. Domain notification bridges (casehub-work, casehub-engine) still need filing as cross-repo issues.

## Cross-Module

**We're blocking:**
- `casehub-work` — `WorkEventTypeTest` needs updating for new notification/subscription event types · XS · Low

## What's Left

**Epic #137 — DataSource SPI follow-up:**
- #138 Deregistration lifecycle · M · Med
- #139 Marshaller configuration model · S · Med
- #140 Engine DataSourceTrigger · M · Med
- #141 MVEL3 real evaluator · S · Low (blocked on Maven Central publish)

**Epic #147 — Notification deferred:**
- #164 Validate BUFFER_FOR_DIGEST requires digested channel · S · Low
- #165 Secondary index for pendingKeysForUser · XS · Low (profile first)
- #167 Digest buffer orphan cleanup/retention · S · Low
- #168 UUIDv7 relocation from notification package · XS · Low
- #169 InMemoryDeliveryChannelRegistry extraction · S · Low
- #170 Open/engagement tracking (email open, push tap callbacks) · M · Med

**Other:**
- casehubio/neocortex#101 — bridge-only reactive implementations · M · Med
- Domain notification bridges (casehub-work, casehub-engine, casehub-iot) — not yet filed · S · Low each

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #146 | Notification center frontend | L | Med | Remaining: blocks-ui#33, blocks-ui#34 |
| #138 | DataSource deregistration lifecycle | M | Med | CDI event, router cleanup |
| #140 | Engine DataSourceTrigger | M | Med | Cross-module engine integration |
| #170 | Open/engagement tracking | M | Med | Email opens, push taps — deferred from #154 |

## References

| Type | Path |
|------|------|
| Spec | `docs/specs/2026-07-08-delivery-tracking-retry-design.md` |
| Plan | `docs/plans/2026-07-09-delivery-tracking-retry.md` |
| Review | `~/adr/casehub-platform/delivery-tracking-retry-20260709-094746/` |
