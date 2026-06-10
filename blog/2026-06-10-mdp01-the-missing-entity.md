---
layout: post
title: "The Missing Entity"
date: 2026-06-10
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [memory, spi, security, gdpr, async, cdi]
---

The platform had five open correctness issues — none of them features, all of them things that worked but worked wrong. No external users means no reason to tread carefully. I fixed each in the intended way, which meant breaking signatures that should have been different from the start.

**Issue #54** was already done in a previous commit. One gh command.

**Issue #62** was two fixes to `ScimActorDIDProvider`. The test constructor had `requireHttps = true`, which looks like it's enforcing something but isn't — `@PostConstruct` never fires for directly-constructed objects, so the field is inert. Changing it to `false` documents what the constructor actually does. The second fix added an authToken blank check to `validateEndpoint()`: a configured-but-blank token sends `Authorization: Bearer ` on every request, receives 401s that are never cached, and retries forever. Hard fail at activation time.

**Issue #79** was the most interesting. Every `CaseMemoryStore` adapter calls `MemoryPermissions.assertTenant(tenantId, principal)` at the top of every operation. In `@ObservesAsync` handler threads there's no CDI request scope, which means `CurrentPrincipal` returns its sentinel value, the tenant comparison fails, and every async memory write silently drops. The clinical harness — which drives all domain completions via async CDI events — hit this constantly.

The fix was a 3-arg overload: `assertTenant(tenantId, principal, requestContextActive)`. When the request context isn't active, the principal comparison is skipped and the tenantId from `MemoryInput` is trusted directly. In async context, the caller is trusted application code that already validated the tenantId at event-fire time — there's no external actor to protect against.

This introduced a complication. `@QuarkusTest` test methods that call adapter beans directly also have no CDI request context by default — the same condition as `@ObservesAsync`. Without an additional fix, every cross-tenant security test in every adapter would silently pass because the assertTenant check would be a no-op. The `requestContextActive()` helper handles this: `var c = Arc.container(); return c == null || c.requestContext().isActive()`. When there's no Quarkus container at all — a plain JUnit test — it returns `true` (enforce). When CDI is present but the request context isn't active — `@ObservesAsync` — it returns `false` (bypass). `@ActivateRequestContext` on the five `@QuarkusTest` adapter classes covers the middle case: CDI present, context active, enforcement on.

`CurrentPrincipal` has four abstract methods and isn't a functional interface, which meant the new test helper needed a full anonymous class rather than a lambda. The existing `MemoryPermissionsTest.principal()` helper already did this correctly.

**Issue #72** changed `eraseEntity()` from `void` to `int`. GDPR Art.5(2) requires demonstrating what was actually deleted, not just that deletion was requested. For JDBC adapters the count comes from `executeUpdate()` naturally. For REST adapters it required a count-then-delete: Mem0 calls `list()` before `deleteAll()`, Graphiti calls `getEpisodes()` — capped at 10,000 — before `deleteGroup()`. The Graphiti `getEpisodes()` return can be null from the MicroProfile client, and the delete needs to be in the same try-catch as the count fetch, not a separate block. Both details matter when the operation is a GDPR erasure and an exception on either half needs the same error handling.

**Issue #64** was the largest break. `eraseById(memoryId, tenantId)` was the only `CaseMemoryStore` operation without an `entityId` parameter. Every other operation — `store()`, `query()`, `erase()`, `eraseEntity()` — scopes to an entity. The missing parameter created an intra-tenant gap: any entity within tenant A that knows a memoryId can delete another entity's memory in the same tenant.

The fix was a third parameter: `eraseById(memoryId, entityId, tenantId)`. For JDBC adapters, `AND entity_id = ?` in the WHERE clause means a mismatch silently affects 0 rows — no error, no information leak about whether the memory exists under a different entity. For Mem0, it required a preflight `GET /memories/{id}`: fetch the memory, verify the `user_id` field exactly matches `{tenantId}::{entityId}`, return silently if it doesn't. The Mem0 OSS API surface doesn't explicitly document a single-memory GET endpoint — the existing client only covered `POST /memories`, `GET /memories`, and `POST /search`. I've flagged this as needing verification before deployment; the client interface documents it as a blocker.

The entity mismatch contract is silent no-op rather than `SecurityException`. Throwing would reveal that the memoryId exists in the tenant but belongs to a different entity — information the caller shouldn't have.

Four of the five fixes were breaking changes. `eraseEntity` returned a different type, `eraseById` got a third parameter, five `@QuarkusTest` classes got a new annotation, one interface method was removed. The callers in this repo were updated in the same commits. The other casehubio repos will pick up the new signatures at their next integration. That's the price of getting it right, and with no external users, the price is low.

The memory SPI now has a consistent entity-scoped model across all operations. `query()` was always entity-scoped. `erase()` and `eraseEntity()` were entity-scoped. `eraseById()` was the gap. There are no longer any memory operations that act without knowing which entity they're acting for.
