---
layout: post
title: "Filling the gaps"
date: 2026-07-20
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [jq, expression-engine, platform-cleanup]
---

# Filling the Gaps

Two platform gaps that have been quietly accruing workarounds got fixed today.

The first was `JQExpressionEngine.compile()` ignoring its `resultType` parameter for anything that wasn't Boolean or List. If you asked for `String`, you got `List<JsonNode>` back. RAS had already built `JqResultUnwrapper` to compensate --- a wrapper that unpacks the first list element and converts it to the target type. That's the kind of workaround that works perfectly until someone writes a second one in a different repo with slightly different null semantics. The fix was a `ScalarJQExpression` record alongside the existing Boolean and List variants, giving compile() a clean three-way branch. RAS can now delete JqResultUnwrapper entirely.

The second was `SubjectViewOrchestrator.deleteView()`. It deleted the view definition but left membership records orphaned. The lazy cleanup path (the next `evaluateAndTrack` call per subject would self-correct) was technically sufficient, but it meant no REMOVED events fired on deletion. Any downstream system watching for membership changes would never know a view disappeared --- they'd just see subjects silently stop appearing in it.

The fix required adding view-keyed access to `ViewMembershipTracker`, which was previously subject-keyed only. Two new SPI methods (`getSubjectsByView`, `removeMembershipByView`), a view_id index in the schema, and implementations across NoOp, InMemory, and JPA. The orchestrator's `deleteView` now returns `List<SubjectViewEvent>` instead of `boolean` --- consistent with `evaluateAndTrack` returning events rather than firing CDI events.

The ordering within deleteView matters: view definition deleted before membership cleanup, not the other way around. If membership cleanup fails after view deletion, orphaned records self-correct on the next evaluateAndTrack. If the view definition survived but membership was cleared, you'd have a view with no members and no way to know it was supposed to have any. The design review caught this and several other sequencing concerns.

Both changes are breaking --- `deleteView`'s return type change will ripple into engine's `CaseQueueViewManager`, and RAS needs to stop wrapping JQ results. Pre-release platform, so the cost is low. The right design is worth the downstream update.

Also closed epics #137 (DataSource SPI follow-up) and #147 (notification system) after verifying all platform children had landed in the codebase. Both had been done for a while but the epics were never formally closed.
