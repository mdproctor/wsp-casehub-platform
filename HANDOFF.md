# HANDOFF — casehub-platform

## Last Session (2026-11-02)

Closed **#682** (wire engagement types), **#692** (sourceId linkage fix), and **#693** (engagement test coverage). Also wrote a blog entry.

**#682 — Wire unused EngagementType values (M/Med):**
- New types: `ReplyType`, `ReplyHint`, `ReplyRequest`, `ReplyHintResolver` SPI, `NotificationClicked`, `NotificationReplied` CDI events
- `Notification`, `NotificationInput`, `NotificationTemplate` gain nullable `replyHint` field
- `NotificationApi` gains `trackClick(id)` and `reply(id, ReplyRequest)` — mirror existing `markRead`/`dismiss` pattern
- `NotificationService` fires CDI events via `fireAsync()`; `InAppEngagementBridge` observes and records engagement
- `ReplyHintResolver` SPI with `PassthroughReplyHintResolver` `@DefaultBean` — domains override for custom resolution
- `NotificationDispatcher` applies resolver after `TemplateResolver.resolve()` in both dispatch paths
- CONVERTED stays domain-level via existing `recordDirect()` endpoint
- Flyway V2 adds `reply_hint` column to notification table
- Design spec: `wsp-casehub-platform/specs/issue-682-wire-engagement-types/`
- Landed as `823e721e` on main

**#692 — sourceId linkage fix (S/Low, pre-existing bug from #170):**
- Pre-existing: ALL engagement recording via InAppEngagementBridge was non-functional — delivery attempts stored with `sourceId=null`, bridge `findBySource()` always returned empty
- `DeliveryResult` gains `sourceId` field with backward-compat 2-arg constructor
- `InAppNotificationDeliverer.deliver()` returns stored notification ID in result
- `NotificationDispatcher` captures sourceId from delivery results, passes to `DeliveryTracker`
- Landed as `05c36a4f` on main

**#693 — 24 new tests (S/Low):**
- `NotificationServiceTest` (12 tests): trackClick ownership, reply validation for ACKNOWLEDGE/FREE_TEXT/OPTIONS
- `EngagementIntegrationTest` (3 tests): full dispatch→bridge→engagement chain for OPENED, CLICKED, REPLIED
- `NotificationStoreContractTest` (4 tests): findById ownership enforcement
- `ReplyHintTest` (3 tests): Jackson serialization round-trip
- `TemplateResolverTest` (2 tests): replyHint passthrough assertion
- Landed with `05c36a4f` (squashed with #692)

**Blog entry:** "The Engagement Bridge That Never Crossed" — `blog/2026-11-02-mdp02-engagement-tracking-silent-failure.md`

**CLAUDE.md note:** The module table needs updating with new types (ReplyType, ReplyHint, ReplyHintResolver, ReplyRequest, NotificationClicked, NotificationReplied) and new NotificationApi methods (trackClick, reply). Deferred from this session.

## Immediate Next Step

#662 — Plugin catalog infrastructure. Different domain — fresh session recommended.

## Queue

All 10 original queue items complete. #662 is the sole remaining item, appended during this session.

## References

- Plan queue: `wsp-casehub-platform/.plan` — #662 is the only remaining item
- Design spec: `wsp-casehub-platform/specs/issue-682-wire-engagement-types/`
- Blog entry: `wsp-casehub-platform/blog/2026-11-02-mdp02-engagement-tracking-silent-failure.md`
