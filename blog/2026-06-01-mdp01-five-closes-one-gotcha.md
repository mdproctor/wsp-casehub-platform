---
layout: post
title: "Five closes, one gotcha"
date: 2026-06-01
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [scim, memory]
---

Seven issues with S or XS labels. I wanted to get through them in one session
rather than let the list drift further.

The first two turned out to be non-work. Issue #50 — an fts.enabled=false test
profile for the SQLite memory store — was already in the #37 squash from last
session. The file was there, the test was there. Closed. Issue #51, which a
previous HANDOFF had flagged as a possible logic inversion in
`InMemoryMemoryStore.erase()`, turned out to be correct code. We traced the
null-caseId path carefully: when caseId is null, the filter expression
`request.caseId() != null && !...` evaluates to false for every entry — which
is the right outcome, erase all. The JPA implementation agrees. We added an
explicit contract test to lock in the semantics and closed #51 as verified.
The fix was the test, not the implementation.

Issue #46 was a duplicate of #47. Closed before touching any code.

Issue #35 was quick. `ReactiveCaseMemoryStore` was missing `storeAll()` to
mirror the blocking SPI. We added a default using `Uni.join().all(...).andFailFast()`
— parallel submission, ordered results, fail-fast on any error — and a bridge
override that delegates to the blocking `storeAll()` on a worker thread.

#47 was the one worth thinking about. The SCIM `GroupMembershipProvider` fetched
group members in up to two steps: inline from the `listGroups` response, then
directly from `getGroup()` if members were absent. Neither path handled truncation.
If a SCIM server paged its member list, you'd get only the first page, silently.

The question was how to detect truncation. `ScimListResponse.totalResults` counts
groups, not members. A group resource doesn't return a member total. So we used
a page-size threshold: if members equals or exceeds a configurable
`casehub.platform.scim.member-page-size` (default 1000), treat it as possibly
truncated and fall through to a paginated `fetchAllMembers()` loop.

```java
do {
    ScimGroupResource page = scimClient.getGroup(groupId, "members", startIndex, memberPageSize);
    List<ScimMemberRef> members = page != null ? page.members() : null;
    if (members == null || members.isEmpty()) break;
    allMembers.addAll(members);
    startIndex += members.size();
} while (members.size() >= memberPageSize);
```

`ScimClient.getGroup()` got a second overload with `startIndex` and `count`.
`ScimListResponse` got `itemsPerPage` — it was in the SCIM RFC all along, just
absent from the record. The test uses page-size=3: three-member first page,
two-member second page, five total confirmed.
