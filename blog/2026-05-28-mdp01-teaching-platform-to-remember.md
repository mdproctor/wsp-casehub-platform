---
layout: post
title: "Teaching the Platform to Remember"
date: 2026-05-28
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [casehub-memory, spi, quarkus, mutiny, architecture]
---

Every CaseHub case starts cold. A new work item opens, the engine spins up, and
it knows nothing about the entity it's about to reason over — not what happened in
prior cases, not what agents learned, not what was observed and flagged. Everything
that came before is invisible.

That's not a small gap. For devtown, a new PR review starts without the history of
the contributor. For clinical, a follow-up appointment knows nothing about the
patient's prior site interactions. For aml, a transaction review has no context from
previous investigations into the same entity. Each case starts from zero because
the platform gives it no way to do otherwise.

`CaseMemoryStore` is the answer — a queryable, permission-aware SPI that bridges
case-to-case knowledge. Platform issue #27. It shipped this week.

## The Fact That Wasn't

The design spec called the stored units "facts." We used that word for weeks before
I checked whether it was standard. It isn't. In AI agent memory systems — Mem0,
Graphiti, Zep — the stored units are called "memories" or "episodes." "Fact" is
common English but not technical vocabulary in this space.

More importantly, "fact" overstates what we're storing. A clinical agent observing a
possible side effect isn't asserting a verified truth — it's recording a memory of an
observation. "Fact" carries epistemic weight that the data doesn't necessarily have.

So the types became `MemoryInput`, `Memory`, `MemoryQuery`. The SPI is
`CaseMemoryStore`. The unit is a memory.

## Where Should the Adapters Live?

My first instinct was to keep adapters inside `casehub-platform` — the same
submodule pattern as `persistence-jpa/` and `persistence-mongodb/`. Consistent,
low overhead, one repo to publish.

Claude pushed back on that. The comparison wasn't quite right. JPA and MongoDB
adapters connect directly to databases — infrastructure the platform already owns.
The memory adapters (Memori, Mem0, Graphiti) are REST clients to external AI
services. They bring different dependency profiles, different operational concerns,
and — critically — they're useful outside CaseHub. Any Quarkus multi-agent system
needs agent memory. The adapters aren't a casehub concern; they're a general
capability.

The closer comparison is `casehub-work` or `casehub-ledger` — capabilities that
were extracted into their own repos because they're independently useful and
operationally substantial. We avoided the mistake casehub-eidos made: starting
inside another repo and paying the extraction cost later.

The SPI and `@DefaultBean` no-op stay in `casehub-platform-api` and
`casehub-platform`. The adapters will live in `casehub-memory` — a separate repo,
tracked in ADR-0008 and platform issues #31–36.

## A Quarkus Surprise

The `BlockingToReactiveBridge` wraps the blocking `CaseMemoryStore` as a reactive
`ReactiveCaseMemoryStore`. The bridge injects whichever blocking impl is active and
delegates, so adapters only need to implement one interface. The design called for
`@Blocking` on each method — the standard Quarkus annotation for signalling that a
method blocks and should run on a worker thread.

Quarkus rejected it.

```
Build failure:
@Blocking, @NonBlocking and @RunOnVirtualThread are not supported
on non-entrypoint methods
```

`ExecutionModelAnnotationsProcessor` only processes `@Blocking` on framework
entrypoints — JAX-RS resource methods, reactive messaging consumers, GraphQL
resolvers. A plain `@ApplicationScoped` CDI bean method returning `Uni<T>` is
not an entrypoint. The annotation is illegal there and the build fails hard.

The docs say "use @Blocking on methods that block." Nothing says "only on
entrypoints." You find the restriction by hitting it.

Thread dispatch on a bridge like this is the entrypoint's responsibility anyway —
if a JAX-RS resource method is `@Blocking`, the entire call chain runs on a worker
thread, including the bridge. The annotation was unnecessary. We removed it and
noted it in the garden.

## The Bridge Pattern

The CDI priority ladder that emerged is clean:

| Tier | Class | Annotation | Active when |
|------|-------|-----------|-------------|
| 0 | `NoOpCaseMemoryStore` | `@DefaultBean` | No adapter |
| — | `BlockingToReactiveBridge` | `@DefaultBean` | Always (wraps tier 0–2) |
| 1 | Memori | `@ApplicationScoped` | Memori dep on classpath |
| 2 | Mem0 | `@Alternative @Priority(1)` | Mem0 dep on classpath |

Adding an adapter to the classpath silently promotes it. The bridge's `@DefaultBean`
yields automatically when a native async adapter (Graphiti) supplies its own
`@Alternative` on `ReactiveCaseMemoryStore`. One interface to implement; the
reactive path is a freebie.

## The Reviews

The spec went through four rounds of review before implementation started, plus a
final code review. That's not ceremony — each round caught something real.

The first round surfaced the store-vs-upsert ambiguity (`store()` is append-only at
the SPI level), the silent no-op on erasure (`eraseById()` default must throw, not
succeed silently — a false success on a GDPR-adjacent operation is serious), and
the reactive bridge pattern replacing parallel SPIs.

Later rounds caught that `ReactiveCaseMemoryStore.eraseById()` was returning
`Uni.createFrom().voidItem()` — a silent success — when it should return a failed
`Uni` matching the blocking default. And that `MemoryPermissions.assertTenant()`
needed to be a static utility rather than a default method, because reactive-only
adapters (those implementing `ReactiveCaseMemoryStore` directly) can't call a
`default` on `CaseMemoryStore` — they have no reference to it.

The final code review caught an `EraseRequest` field order discrepancy between the
spec and the code. Spec said `entityId, domain, caseId, tenantId`. Code had
`entityId, domain, tenantId, caseId`. The code was right; the spec was wrong. Fixed.

144 tests. All green.

## What Shipped

The SPI is in `casehub-platform-api` at `io.casehub.platform.api.memory`. The
reactive interface and bridge are in `casehub-platform`. Seven GitHub issues cover
the deferred adapter work. One protocol captures the silent-no-op rule for
data-deletion defaults. One ADR records the repo placement decision. Three garden
entries cover the `@Blocking` gotcha, the bridge pattern, and the cross-SPI
security utility.

The adapters come next.
