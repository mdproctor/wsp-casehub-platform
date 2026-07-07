# HANDOFF — casehub-platform

**Date:** 2026-07-07
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Implemented EventTypeRegistry SPI (#155) and WeeklyAt digest schedule variant (#160) in a single branch. Both were small, pattern-following additions — no design review needed. All code TDD, full build green, both issues closed.

## Immediate Next Step

Pick from What's Next — domain notification bridges (casehub-work, casehub-engine, casehub-iot) need filing as cross-repo issues to make the notification pipeline functional end-to-end. The EventTypeRegistry gives bridges a place to register their event type metadata at startup. Alternatively, #158 persistent digest buffer or #146 notification center frontend are standalone.

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
- #156 Channel subscriber target type · S · Med
- #157 Minor findings from code review · S · Low
- #158 Persistent digest buffer (`digest-jpa/`) · M · Med
- #159 Digest groupBy preference · S · Low
- #161 Digest status REST endpoint · S · Low
- #162 Quiet hours → digest integration · S · Med
- #163 Minor code review findings · S · Low

**Other:**
- casehubio/neocortex#101 — bridge-only reactive implementations · M · Med
- Domain notification bridges (casehub-work, casehub-engine, casehub-iot) — not yet filed · S · Low each
- PLATFORM.md capability ownership update for notification pipeline · XS · Low
- Other child repos add `parent` to publish dispatch lists · XS · Low each

## What's Next

**Epic #147 — Notification system (remaining phases):**

| Phase | # | Description | Scale | Complexity | Notes |
|-------|---|-------------|-------|------------|-------|
| ~~1~~ | ~~#135~~ | ~~In-app notification store~~ | ~~M~~ | ~~Med~~ | **done** |
| ~~2~~ | ~~#142~~ | ~~Subscription management~~ | ~~L~~ | ~~High~~ | **done** |
| ~~3~~ | ~~#148~~ | ~~Target resolution~~ | ~~M~~ | ~~Med~~ | **done** |
| ~~4~~ | ~~#143~~ | ~~User channel preferences~~ | ~~S~~ | ~~Low~~ | **done** |
| ~~5~~ | ~~#145~~ | ~~Mute and snooze~~ | ~~S~~ | ~~Med~~ | **done** |
| ~~6~~ | ~~#144~~ | ~~Digest and batching~~ | ~~M~~ | ~~High~~ | **done** |
| 7 | #146 | Notification center (frontend) | L | Med | after #135 API stable |

**Other:**

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #138 | DataSource deregistration lifecycle | M | Med | CDI event, router cleanup |
| #140 | Engine DataSourceTrigger | M | Med | Cross-module engine integration |
| #158 | Persistent digest buffer | M | Med | JPA-backed DigestBuffer |

## References

| Type | Path |
|------|------|
| Blog | `blog/2026-07-07-mdp01-fourth-registry.md` |
