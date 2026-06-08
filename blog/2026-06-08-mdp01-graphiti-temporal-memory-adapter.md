---
layout: post
title: "Graphiti temporal memory adapter — graph-native SPI and capability model"
date: 2026-06-08
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [memory, graphiti, knowledge-graph, spi, capability-model]
---

The idea for this one started as an impedance mismatch problem. I wanted to add Graphiti as a Tier 3 memory backend — temporal knowledge graphs, bi-temporal fact validity, the kind of thing that can answer "what did the agent know, and when was that fact still true?" But the `CaseMemoryStore` SPI is a flat abstraction: text in, `Memory` out, optional semantic filter. Graphiti's value lives entirely in what the SPI can't express.

The resolution was a new interface. `GraphCaseMemoryStore extends CaseMemoryStore` adds `graphQuery(GraphMemoryQuery)` — a graph-native entry point with parameters that have no meaning for simpler adapters. `NoOpCaseMemoryStore` in `platform/` now implements it, so `UnsatisfiedResolutionException` can't fire when someone injects `GraphCaseMemoryStore` without a graph adapter deployed. The base injection type is unaffected for consumers who don't need graph semantics.

The capability model came from the same tension. With five different backends — volatile in-memory, PostgreSQL FTS, SQLite FTS5, Mem0 vector search, and now Graphiti — the question of "does this adapter support this operation?" keeps surfacing. `MemoryCapability` enum lets each adapter declare what it actually does. `requireCapability()` throws `MemoryCapabilityException` instead of the silent no-op or `UnsupportedOperationException` that previously made capability gaps hard to detect. The existing `eraseById()` and `eraseEntity()` SPI defaults changed over to this — a breaking change, mechanical to migrate.

Implementing the REST adapter revealed how poorly documented the Graphiti HTTP API is. The routes were wrong in the first spec draft — `POST /retrieve/search` doesn't exist, it's just `POST /search`. The request schemas were wrong too: no `metadata` field on `AddMessagesRequest`, uuid goes on the individual `Message`, not the request. We worked out the actual contracts by reading the FastAPI router source. The big limitation: `FactResult` carries no `group_id`, so batching multiple entity IDs into one search call makes it impossible to attribute which result belongs to which entity. We ended up doing one `POST /search` call per entity, then concatenating in entity order — not score-interleaved, because scores from separate calls aren't cross-comparable.

The spec went through six review rounds before implementation. The most dangerous finding was `new MemoryDomain("")` — the spec said to use an empty string for `Memory.domain` when `FactResult` doesn't carry domain information, but `MemoryDomain` throws on blank. The fix is obvious in retrospect: use `query.domain()`. The source of the problem was the same as most of the others — trying to construct `Memory` from data that Graphiti doesn't return, rather than from the calling context that always has it.

Graphiti's text contract is worth reading before using it as a memory store. Unlike every other adapter, `Memory.text()` is not the original stored text. RELEVANCE queries return LLM-extracted fact descriptions — not the source sentence, but what Graphiti extracted from it. CHRONOLOGICAL queries return episode bodies with a `"(user): "` prefix injected by Graphiti's ingest layer. Any caller expecting verbatim round-trip should use Mem0 instead.
