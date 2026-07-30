---
layout: post
title: "Filling the Gaps Before Anyone Falls Through Them"
date: 2026-07-30
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [acl, platform-api, operational-hardening]
---

The platform ACL landed back in June — flat grant model, JPA and in-memory backends, parent inheritance, tenant isolation, audit logging. Functionally correct. Operationally incomplete.

Expired entries sat in the database forever. The audit log grew without bound. `accessibleResources` returned everything in one unbounded list. And ADMIN didn't imply READ — you needed three separate grants to give someone full access to a resource. These aren't bugs, exactly. They're the gaps between "the design is correct" and "the design works in production."

We started the session fixing a CI failure that had nothing to do with ACL. jackson-jq added a `Supplier<JsonNode>` overload to `Scope.setValue()`, and `ObjectMapper.valueToTree()` returns `<T extends JsonNode>` — a generic return type that the compiler can't disambiguate even with an explicit `(JsonNode)` cast. CI resolved the newer SNAPSHOT; the local Maven cache masked the issue. The fix is one line — extract to a typed local variable — but the gotcha is real: you'd never suspect a cast is insufficient until you understand how Java's type inference interacts with overload resolution.

Then we turned to the ACL gaps. Filed an epic with 11 children, picked the six S-sized items, and knocked them out in a single branch.

The most fundamental change: `AclAction.satisfiedBy()`. The hierarchy is ADMIN > WRITE > READ, with CLAIM orthogonal. Rather than checking exact action matches, both implementations now query with IN-clauses against the set of satisfying actions. A single ADMIN grant covers READ, WRITE, and ADMIN checks — no need to create three separate entries. The hierarchy is defined once on the enum with pre-computed immutable sets, not scattered across implementation code.

Bulk grant/revoke adds `GrantRequest` as an input record and `grantBatch`/`revokeBatch` to the SPI. The JPA override wraps the batch in a single `@Transactional` — when Case Definition authorization YAML lands in the engine, creating N grants per action and group happens atomically.

Retention purges follow the `delivery-tracking-jpa` pattern: `AclRetentionPurge` with two `@Scheduled` methods. Expired entries purge daily at 03:00. Audit log entries older than 365 days (configurable) purge at 03:30. Both schedules configurable via `casehub.acl.retention.*` properties.

Pagination for `accessibleResources` uses the same cursor-keyset pattern as `NotificationPage` and `DeliveryAttemptPage` — `AclQuery` and `AclPage` records, fetch-limit+1 for has-more detection, JPA override with `ORDER BY resourceId > cursor`.

The last piece, `accessibleResourcesIncludingInherited`, was the most interesting to implement. The in-memory version does a reverse traversal of the parent map — walk outward from every granted resource collecting children that match the requested type prefix. The JPA version uses a recursive CTE on `resource_parent`, joining against the granted resource set to find all children at any depth.

All six changes touch the SPI (platform-api), the contract test base, and both implementations. The contract tests grew from 28 to 45 cases. Every test passes in both backends.

The M-sized items — wildcard type-level grants and an ACL administration REST API — are filed but deferred. The engine integration work (Case Definition authorization YAML, identity propagation, worker rights) is tracked as cross-repo references on the epic. That's where the ACL subsystem stops being a platform concern and starts being an engine integration problem — `PropagationContext.inheritedAttributes` is still empty in production, and until identity flows through the case hierarchy, ACL enforcement on internal execution paths is impossible.
