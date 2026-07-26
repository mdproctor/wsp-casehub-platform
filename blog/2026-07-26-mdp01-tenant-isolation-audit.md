---
layout: post
title: "Tenant Isolation Audit"
date: 2026-07-26
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [security, tenant-isolation, acl, delivery, webhooks]
---

A tenant isolation audit across the platform repo surfaced four gaps — three SPI-level and one endpoint-level.

`GroupMembershipProvider.membersOf()` and `groupsOf()` had no tenancyId parameter. Both ACL providers and the notification `TargetResolver` called them, meaning group expansion for permission checks and notification delivery was cross-tenant. The fix was clean: add tenancyId to both methods, pass `subscription.tenancyId()` from the notification path and `principal.tenancyId()` from the ACL path.

`AccessControlProvider` stored tenancyId on every entity but never queried by it. Same tuple `(actor, resource, action)` in different tenants would collide at the database level. The fix had two layers: Flyway V2 adds tenancyId to the unique constraint and the resource_parent composite PK, then all JPA queries got tenant predicates. Reads bypass for cross-tenant admins; mutations always scoped — a distinction the design review caught (the original spec applied bypass to both, which would have let a cross-tenant admin's `revoke()` wipe grants across all tenants).

`DeliveryAttemptStore` had five query methods without tenancyId. Four got tenant-scoped signatures. `claimRetryable()` stays cross-tenant — it is a privileged system operation.

The webhook endpoints (`EngagementCallbackResource` callback path and `WebhookResource`) accepted unauthenticated requests. The root cause on the engagement side: `EngagementCallbackHandler.translate()` had a Javadoc contract requiring HMAC verification, but never received HTTP headers — so verification was impossible, not just optional. The fix passes headers to `translate()` and catches `SecurityException` before the existing catch-all. `WebhookResource` now validates bearer tokens from the endpoint descriptor's `credentialRef`, with `require-auth=true` by default.

Zero cross-repo callers for any of the four SPIs. The entire change was self-contained.
