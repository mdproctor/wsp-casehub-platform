# HANDOFF — casehub-platform

**Date:** 2026-07-07
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Designed, reviewed, and implemented notification digest and batching (#144, epic #147 phase 6). Sealed `DigestSchedule` interface with polymorphic `isFlushDue()`, `DigestBuffer` SPI, `InMemoryDigestBuffer` (ConcurrentHashMap, max-size eviction), `ChannelRouter` digest routing, `NotificationDispatcher` three-path delivery loop, `DigestFlushScheduler` (@Scheduled tick). 3-round adversarial design review (13 issues, all resolved). 8 implementation tasks. Final code review: 3 Important fixed, 6 Minor filed as #163. 6 deferred issues filed (#158–#162, #163). Two garden entries submitted (Jackson isX() phantom property gotcha, ConcurrentHashMap.compute() inner-collection technique).

## Immediate Next Step

Pick from What's Next — domain notification bridges (casehub-work, casehub-engine, casehub-iot) need filing as cross-repo issues to make the digest pipeline functional end-to-end. Alternatively, #144's deferred issues (#158 persistent buffer, #160 weekly schedule) are standalone.

## Cross-Module

**We're blocking:**
- `casehub-work` — `WorkEventTypeTest` needs updating for new notification/subscription event types · XS · Low

## What's Left

*Unchanged — retrieve with: `git show HEAD~1:HANDOFF.md`*

**Added:**
- #158 Persistent digest buffer (`digest-jpa/`) · M · Med
- #159 Digest groupBy preference · S · Low
- #160 Weekly schedule variant (`WeeklyAt`) · XS · Low
- #161 Digest status REST endpoint · S · Low
- #162 Quiet hours → digest integration · S · Med
- #163 Minor code review findings (test names, Javadoc, jackson-annotations policy) · S · Low

## What's Next

**Epic #147 — Notification system (remaining phases):**

| Phase | # | Description | Scale | Complexity | Notes |
|-------|---|-------------|-------|------------|-------|
| ~~1~~ | ~~#135~~ | ~~In-app notification store~~ | ~~M~~ | ~~Med~~ | **done** |
| ~~2~~ | ~~#142~~ | ~~Subscription management~~ | ~~L~~ | ~~High~~ | **done** |
| ~~3~~ | ~~#148~~ | ~~Target resolution~~ | ~~M~~ | ~~Med~~ | **done** |
| ~~4~~ | ~~#143~~ | ~~User channel preferences~~ | ~~S~~ | ~~Low~~ | **done** |
| ~~5~~ | ~~#145~~ | ~~Mute and snooze~~ | ~~S~~ | ~~Med~~ | **done** |
| ~~6~~ | ~~#144~~ | ~~Digest and batching~~ | ~~M~~ | ~~High~~ | **done** — landed as 028fd4d on main |
| 7 | #146 | Notification center (frontend) | L | Med | after #135 API stable |

*Other items unchanged — retrieve with: `git show HEAD~1:HANDOFF.md`*

## References

| Type | Path |
|------|------|
| Design spec | `docs/superpowers/specs/2026-07-06-notification-digest-batching-design.md` |
| Design review | `~/adr/casehub-platform/notification-digest-batching-20260706-203703/tracker.md` |
| Plan | `plans/attic/issue-144-notification-digest-batching/` |
| Garden entries | `jvm/GE-20260706-261904.md` (Jackson isX() phantom), `jvm/GE-20260706-ab4bc8.md` (compute() inner collection) |
| Blog | `blog/2026-07-06-mdp03-digest-batching.md` |
