---
layout: post
title: "Teaching a Java adapter to talk to Mem0 — and what the docs got wrong"
date: 2026-06-04
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [java, quarkus, memory, mem0, vector-search, rest-client]
---

The starting assumption was wrong, and catching it early changed the whole design.

I brought Claude in to design the Mem0 REST adapter — a `CaseMemoryStore` implementation that stores agent memories in Mem0 OSS and retrieves them by semantic similarity. The first question I expected to debate was text fidelity: Mem0's default mode sends your stored text through an LLM, extracts atomic facts, and stores those instead. A reviewer asking "give me back what I stored" might not get it.

That's a real issue, but it isn't the real issue. The real issue is that with LLM extraction active, one `store()` call can produce N Mem0 memories. Our `CaseMemoryStore` contract assumes 1:1 — one store call, one memoryId, one erasable record. Extraction breaks that at three levels simultaneously: the ID mapping, the limit semantics of `query()`, and GDPR erasure via `eraseById()`. Once we established that, the answer was straightforward: set `infer: false`. Mem0 still computes vector embeddings from the verbatim text, so `RELEVANCE` search still works. The embedding captures the semantics; we just skip the LLM rewriting step.

## What the Mem0 cloud docs don't tell you

Mem0 publishes documentation for its cloud API. The open source server is a different codebase with the same endpoints, minus several features. Reading the source revealed the gaps.

The cloud API uses a `/v1/` URL prefix. The OSS server uses bare paths — `POST /memories`, `GET /memories`, `POST /search`. Every client path containing `/v1/` would 404.

More significantly: `app_id` doesn't exist in OSS. The cloud API uses it for multi-tenant isolation. The OSS server's `MemoryCreate` schema accepts `user_id`, `agent_id`, `run_id`, metadata, and `infer` — nothing else. We needed tenant isolation and the only handle available was `user_id`, so the design uses a compound key: `{tenantId}::{entityId}`. The `::` separator is safe because UUIDs are hex and hyphens only.

The list endpoint has no `limit` or pagination parameter. `GET /memories` with a filter returns every matching record. Any assumption about passing a limit to the server is silently ignored — the limit is always applied client-side, after the full result set comes back.

Search scores, though, work exactly as expected — `POST /search` returns a `score: float` on each result. The gotcha is comparability. Mem0's scoring function normalises by a `max_possible` denominator that varies per call (1.0, 2.0, or 2.5 depending on whether BM25 matches exist for that entity). Two calls to different entities can produce the same score value with different denominators behind it. Sorting a merged multi-entity result set by score gives you something that looks like global relevance ranking but isn't. The correct approach: each entity's results are internally score-ordered; across entities, fan-out order is all you have.

## The structural catch

After implementation, a code review flagged three missing tests: `query()`, `erase()`, and `eraseEntity()` all had the same `WebApplicationException` → `Mem0StoreException` wrapping path but only `eraseById()` had a non-2xx test. Claude caught the gap, we added the three tests, and the result is 36 tests covering all five SPI methods including error handling.

Two garden entries went in from the session: the API surface deviations from cloud docs (undocumented, score 13), and the score incomparability gotcha (score 11). A protocol went in for a pattern that will recur: library JARs that want `@Timed` annotations should depend on `micrometer-core` (annotation only), not `quarkus-micrometer` (an extension that carries deployment metadata and confuses consumers' augmentation phase).

The module is `casehub-platform-memory-mem0`, beating `@ApplicationScoped` JPA and `@DefaultBean` no-op via `@Alternative @Priority(1)`. Configure two properties and it's live: `quarkus.rest-client.mem0.url` and `casehub.memory.mem0.api-key`. The three constraints worth knowing before adding it: GET /memories is unbounded so large entity histories are expensive to query chronologically; multi-entity RELEVANCE queries concatenate in entity order, not by cross-entity score; and Mem0 OSS has no native tenant isolation so the compound user_id encoding is load-bearing.
