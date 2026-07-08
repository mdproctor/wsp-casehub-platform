*Updated: #158 closed — removed from backlog.*

# HANDOFF — casehub-platform

**Date:** 2026-07-08
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Implemented #158 — persistent digest buffer. Extracted `InMemoryDigestBuffer` from `notification-dispatch/` to `digest-inmem/` (CDI protocol compliance), then created `digest-jpa/` with JPA-backed `DigestBuffer` (Flyway V2000, ID-scoped drain for READ COMMITTED safety). Design review caught a data-loss race condition in the drain pattern. Forage variant added to GE-20260414-62a6df.

## Immediate Next Step

Pick from What's Next — domain notification bridges (casehub-work, casehub-engine) need filing as cross-repo issues. Alternatively, #154 guaranteed delivery or #146 notification center frontend.

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
- #154 Guaranteed delivery + tracking · M · Med
- #164 Validate BUFFER_FOR_DIGEST requires digested channel · S · Low
- #165 Secondary index for pendingKeysForUser · XS · Low (profile first)
- #167 Digest buffer orphan cleanup/retention · S · Low
- #168 UUIDv7 relocation from notification package · XS · Low
- #169 InMemoryDeliveryChannelRegistry extraction · S · Low

**Other:**
- casehubio/neocortex#101 — bridge-only reactive implementations · M · Med
- Domain notification bridges (casehub-work, casehub-engine, casehub-iot) — not yet filed · S · Low each

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #146 | Notification center frontend | L | Med | Remaining: blocks-ui#33, blocks-ui#34 |
| #154 | Guaranteed delivery + tracking | M | Med | Delivery audit trail |
| #138 | DataSource deregistration lifecycle | M | Med | CDI event, router cleanup |
| #140 | Engine DataSourceTrigger | M | Med | Cross-module engine integration |

## References

| Type | Path |
|------|------|
| Blog | `blog/2026-07-08-mdp01-drain-that-eats-its-own.md` |
| Spec | `docs/specs/2026-07-07-persistent-digest-buffer-design.md` |
| Plan | `docs/plans/2026-07-07-persistent-digest-buffer.md` |
