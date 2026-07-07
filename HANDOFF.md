# HANDOFF — casehub-platform

**Date:** 2026-07-07
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Implemented all S/XS issues from Epic #147 in a single branch (issue-157-notification-s-xs-batch). Six issues closed: #157, #163, #159, #161, #162, #156. Design-reviewed spec, 8 subagent-driven implementation tasks, final code review. 41 files, ~1600 lines. Key architectural decisions: store-authoritative mute expiry, "deferred not lost" quiet hours principle, EntityWatcherProvider SPI.

## Immediate Next Step

Pick from What's Next — domain notification bridges (casehub-work, casehub-engine) need filing as cross-repo issues. The EventTypeRegistry + EntityWatcherProvider SPIs give bridges everything they need. Alternatively, #158 persistent digest buffer or #154 guaranteed delivery are standalone.

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
- #158 Persistent digest buffer (`digest-jpa/`) · M · Med
- #164 Validate BUFFER_FOR_DIGEST requires digested channel · S · Low
- #165 Secondary index for pendingKeysForUser · XS · Low (profile first)

**Other:**
- casehubio/neocortex#101 — bridge-only reactive implementations · M · Med
- Domain notification bridges (casehub-work, casehub-engine, casehub-iot) — not yet filed · S · Low each
- Other child repos add `parent` to publish dispatch lists · XS · Low each

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #146 | Notification center frontend | L | Med | Remaining: blocks-ui#33 (sub editor), blocks-ui#34 (preferences UI) |
| #158 | Persistent digest buffer | M | Med | JPA-backed DigestBuffer |
| #154 | Guaranteed delivery + tracking | M | Med | Delivery audit trail |
| #138 | DataSource deregistration lifecycle | M | Med | CDI event, router cleanup |
| #140 | Engine DataSourceTrigger | M | Med | Cross-module engine integration |

## References

| Type | Path |
|------|------|
| Blog | `blog/2026-07-07-mdp01-deferred-not-lost.md` |
| Spec | `docs/specs/2026-07-07-notification-s-xs-batch-design.md` |
