---
layout: post
title: "Parallel storeAll and Cross-Tenant GDPR Erasure"
date: 2026-06-18
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [memory, gdpr, reactive, platform-api, mem0]
---

Three issues on one branch — `#70`, `#90`, `#99`. The sequencing was forced: `#90` (moving `ReactiveCaseMemoryStore` to `platform-api`) had to land before `#99` could add methods to it. You can't add a method to an interface that's going to move in the same commit.

## The 2-arg bug

`Mem0CaseMemoryStore.storeAll()` had the wrong pre-flight. Every other method in the adapter uses the 3-arg `MemoryPermissions.assertTenant(tenantId, principal, requestContextActive())` — the async-aware form that skips the check in `@ObservesAsync` handlers. `storeAll()` used the 2-arg form, which always enforces. `SqliteMemoryStore.storeAll()` had the same problem — same class of bug, same undetected status.

Neither was caught because `@QuarkusTest` classes run with `@ActivateRequestContext`, where both forms behave identically. One-line fix in each file. The practical impact is small, but the inconsistency had been quietly in violation of PP-20260529-57cc3b since both adapters were written.

## Parallel storeAll

Mem0's REST client is blocking. Making `storeAll()` parallel meant choosing how to bound concurrency without rewriting the REST layer. I brought Claude in to build this. We settled on `Semaphore(Math.max(1, Math.min(config.storeAllConcurrency(), inputs.size())))` — each Uni acquires a permit before calling `sendAdd()`, releases it in `finally`. `Uni.join().all(unis).andFailFast()` runs all subscriptions, collects results in input order, fails fast on the first HTTP error.

One point worth being precise about: `andFailFast()` doesn't abort in-flight HTTP calls. Blocking code on the Mutiny worker pool doesn't respond to cancellation signals — it runs to natural completion. The guarantee is "no new calls start after the first error", not "all in-flight calls abort". A code review pass flagged this, and the test name was updated to reflect what's actually verifiable.

## The SPI move

`ReactiveCaseMemoryStore` was in `casehub-platform` — the mock module. This forced production consumers like `casehub-engine`'s `CaseHubReactor` to carry a compile-scope dependency on the mock module just to inject the reactive SPI interface. It was always in the wrong place. Mutiny is explicitly allowed in Tier 1 per PLATFORM.md, so the move to `platform-api` is clean.

We also fixed two defaults that were throwing `UnsupportedOperationException`. They should throw `MemoryCapabilityException` — matching the blocking counterparts. The old exceptions were wrong and untested; the `BlockingToReactiveBridgeThreadingTest` spy had overridden both methods to return successfully, so the incorrect exception type had been invisible since the defaults were written.

After this ships, `engine#466` can downgrade `casehub-platform` from compile to test scope.

## The GDPR gap

`CaseMemoryStore.eraseEntity(entityId, tenantId)` is per-tenant. GDPR Art.17 requires erasure across all tenancies for a data subject. The gap: GDPR endpoints have to loop over tenant IDs and call `eraseEntity()` per tenant, but `assertTenant()` rejects cross-tenant calls. The loop was impossible through the SPI.

The new `eraseEntityAcrossTenants(entityId, Set<String> tenantIds)` closes it. `Set<String>` not `Collection<String>` — the semantic intent is a set. Accepting duplicates causes double-counting in Mem0's best-effort count (list + delete runs twice for the same compound userId) and redundant HTTP calls in Graphiti.

`MemoryPermissions.assertCrossTenantAdmin(principal)` gates it — deliberately 1-arg only, no async bypass. Cross-tenant erasure is a deliberate administrative operation, not an async-hop event handler. An async bypass would let `@ObservesAsync` handlers silently skip the admin check.

`NoOpCaseMemoryStore` overrides the method to return 0, but its `capabilities()` stays `Set.of()`. The NoOp is the only adapter where erase methods succeed without being declared in capabilities — `eraseEntity()` works the same way and always has. Adding `CROSS_TENANT_ERASE` to capabilities would break that documented invariant.

SQLite's `SQLITE_LIMIT_VARIABLE_NUMBER` is 999. A single DELETE with 1000+ tenant placeholders would fail silently. We chunk at 500. JPA/PostgreSQL's limit is 32767 — documented rather than guarded.

## Sequential erasure in Mem0

I considered parallelising `eraseEntityAcrossTenants` in Mem0 — same argument as storeAll: O(N × RTT) across 50+ tenants. But the first draft of the spec had wrong reasoning: I'd argued that "sequential avoids fail-fast parallelism, which would abort remaining tenants on error." That's false. The sequential loop throws on first error too — tenant 3 failing abandons tenants 4–50 exactly the same way.

The correct justification is simpler: sequential is retry-safe (deleteAll is idempotent, already-erased tenants return empty on retry), GDPR doesn't mandate sub-second completion, and parallel with proper error-collection semantics would need a `MultiEraseException` type and aggregation logic. Complexity with no architectural benefit. The reasoning in the spec needed fixing; the design stayed the same.
