---
layout: post
title: "The pre-flight pattern: why REST adapters can't rely on transaction rollback"
date: 2026-06-07
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [memory, quarkus, testing, wiremock, security]
---

The issue existed for a good reason. `Mem0CaseMemoryStore` had no `storeAll()` override — the SPI default fires one REST call per item, and Mem0 OSS had no batch endpoint to improve on that. Platform#69 deferred the work: if Mem0 adds a batch endpoint, revisit.

I went to check whether that endpoint had arrived. Two open PRs (#4804, #5194) add `batch_add` to the Python Memory SDK — not a server endpoint. The "batch" is a `ThreadPoolExecutor` with four workers by default, firing the same single-item `POST /memories` N times concurrently. No new API surface, no server-side atomicity. Worth knowing, because the Java side would face the same trade-off if parallelism mattered. It doesn't change what we're working with.

Sequential is the right call anyway. The real problem with `storeAll()` via REST isn't latency — it's partial writes.

## The test gap that hid a bug

The SPI default is `inputs.stream().map(this::store).toList()`. Each `store()` asserts tenant then fires HTTP. For a batch of `[good_tenant, bad_tenant]`:
- `store(item_0)` — check passes → REST call fires → memory stored
- `store(item_1)` — tenant check throws `SecurityException`

Item 0 is already in Mem0 when item 1 fails. A security failure should mean nothing was persisted.

InMemoryMemoryStore had exactly the same bug. I wouldn't have seen it without the right test. The existing contract test covers the all-bad case — `[bad, bad]` — which throws on the first `store()` before anything gets written. The `[good, bad]` case, where item 0 succeeds before item 1 fails, was never tested. Classic gap: the test that proves the guarantee was missing precisely the scenario where the guarantee breaks.

I brought Claude in to add the missing contract test first. We ran it against InMemory — failed immediately. That's the proof we needed before writing the fix.

## The pre-flight pattern

The fix is straightforward: assert tenant for every input before touching the backend.

```java
@Override
public List<String> storeAll(List<MemoryInput> inputs) {
    if (inputs.isEmpty()) return List.of();
    inputs.forEach(i -> MemoryPermissions.assertTenant(i.tenantId(), principal));
    final var ids = new ArrayList<String>(inputs.size());
    for (final var input : inputs) {
        ids.add(sendAdd(input)); // private — no assertTenant
    }
    return List.copyOf(ids);
}
```

The `sendAdd()` extraction avoids re-running the tenant check per item. `store()` still calls `assertTenant` itself — it's a public SPI method and has to stay self-defending. The double-check in InMemory is a minor redundancy that preserves clear method boundaries.

JPA and SQLite didn't need this. Both call `assertTenant` per item inside a real transaction: a mid-batch failure rolls back everything. Pre-flight is specifically for adapters with no transaction — check everything before touching anything, fail-fast on the first error.

The `memory-storeall-transactional-contract` protocol covered JDBC adapters only. We updated it with a REST-adapter clause. Anyone writing a future adapter (Graphiti, for instance) will find the rule and know what it means for them.

## WireMock tip worth keeping

Testing pre-flight in a WireMock-backed test: don't stub the endpoint. If the implementation fires HTTP before the security check, WireMock returns a 404, the REST client wraps it in `WebApplicationException`, and `toStoreException()` produces `Mem0StoreException` — not `SecurityException`. The wrong exception type is the test failure signal. The absence of a stub is stronger than a `verify(0, ...)` call: it makes the spurious call a different kind of failure, not just a count mismatch.
