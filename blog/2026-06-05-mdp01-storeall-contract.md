---
layout: post
title: "The Contract storeAll() Didn't Enforce"
date: 2026-06-05
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [quarkus, cdi, jpa, panache, memory]
---

InMemoryMemoryStore was at `@Alternative @Priority(1)`, the same as
SqliteMemoryStore and Mem0CaseMemoryStore. In production this is fine — you
never deploy them together. In `@QuarkusTest` you might: production adapter on
compile scope, memory-inmem on test scope for isolation. When both appear on the
test classpath, CDI throws `AmbiguousResolutionException`. Two beans, same
priority, same interface — CDI can't choose.

The fix is a separate tier. Memory-inmem moves to `@Priority(10)`. Production
adapters stay at `@Priority(1–9)`. Test overrides land at `@Priority(10+)`.
In production augmentation, test-scoped deps are invisible — the priority value
never matters there. In `@QuarkusTest`, the higher value wins cleanly.

## The Javadoc That Recommended the Problem It Was Preventing

The larger work was settling the emission question for `CaseMemoryStore`. Three
options had been documented for months: Option A (inject and call `store()`
directly), B (platform CDI module coupling to domain event types), C (platform
defines a narrow `MemoryStoreRequest` event, apps emit it, platform observer
calls `store()`).

We rejected C on a specific technical ground: `@ObservesAsync` observers run on
a thread pool where `@RequestScoped` context isn't propagated by default.
`JpaMemoryStore` injects `@RequestScoped CurrentPrincipal`. Call it from an
async observer and you hit `ContextNotActiveException` before `assertTenant()`
even fires. The compliance failure is invisible to the caller.

Claude came back from spec review with this in the replacement Javadoc:

> "Use `@ObservesAsync` on the domain event for fire-and-continue semantics while
> keeping exceptions on a managed thread where they can be logged and acted on."

That's Option C, word for word. We'd banned it in the analysis section and
recommended it in the implementation guidance in the same document. Two review
passes later, the Javadoc now warns against `@ObservesAsync` explicitly and calls
out the `@RequestScoped` failure mode. Direct injection is canonical.

## What storeAll() Wasn't Doing

`JpaMemoryStore` inherited the SPI default for `storeAll()`: call `store()` for
each input, each in its own `@Transactional(REQUIRED)`. For a mixed-tenant
batch — item 0 has the correct tenant, item 1 has a different one — item 0
commits before item 1 throws `SecurityException`. Partial write.

The test that pins it:

```java
assertThrows(SecurityException.class,
    () -> store().storeAll(List.of(good, bad)));

assertEquals(0, store().query(query()).size(),
    "Mixed-tenant storeAll must not persist any entries");
```

Before the fix, the count is 1. After — single `@Transactional`, per-item
`assertTenant` inside the stream `.toList()` before `MemoryEntry.persist()` is
called — it's 0. The stream throws on item 1 before any entity reaches the
persistence layer.

SQLite already had a correct `storeAll()` override; the spec omitted it entirely.
That came out in review too.
