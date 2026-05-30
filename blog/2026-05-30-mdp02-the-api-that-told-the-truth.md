---
layout: post
title: "The API that told the truth"
date: 2026-05-30
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [memory, spi, java, api-design, hibernate]
---

Platform#48 came in as feedback from devtown — the first consumer to wire up `CaseMemoryStore` in a real application. The core interface was right; the gaps were in what surrounded it. No standard way to emit memories. No attribute key conventions. A query API that handled one entity at a time.

Five gaps. Most were straightforward. One wasn't.

## The boolean that promised what it couldn't deliver

The original proposal for gap 4 was a `recentFirst: boolean` on `MemoryQuery`. Callers signal whether they want time ordering or relevance. Except both existing adapters always sort `createdAt DESC` regardless of the flag. A caller passing `recentFirst=false` — meaning "prefer relevance" — would silently get recency order. The flag promised semantics it couldn't deliver across the adapter boundary.

We replaced it with `MemoryOrder enum { CHRONOLOGICAL, RELEVANCE }`. The difference is that the enum makes the fallback documentable: non-semantic adapters "always use CHRONOLOGICAL regardless of this field." That sentence can go in the Javadoc. The equivalent sentence for a boolean would be a lie.

The routing table that fell out of this was clean. One detail I hadn't noticed until reviewing the actual adapter code: the JPA FTS path was already ordering by `ts_rank DESC`. The original spec had said "relevance ranking is not in scope for JPA" — wrong. The enum meant JPA could now properly honour `RELEVANCE`, not just ignore it.

## The bug in the confidence helper

`MemoryAttributeKeys.formatConfidence` uses `String.format("%.4f", v)`. In a JVM running with a German or French locale, that produces `"0,8700"` — comma as decimal separator. `Double.parseDouble("0,8700")` throws. English-locale CI passes cleanly; production breaks silently on non-English systems.

The fix is one character: `String.format(Locale.ROOT, "%.4f", v)`. A code review caught it before it shipped.

## Hibernate's undocumented behaviour

Multi-entity recall needed `entity_id IN (:entityIds)` with a list parameter. For JPQL, passing `List<String>` to a named IN parameter is standard — Hibernate expands it. For native SQL, the documentation is silent. As it turns out, Hibernate 6 does the same expansion in native queries. Verified against real PostgreSQL via Testcontainers with list sizes 1, 2, and larger. The native FTS path and the JPQL chronological path both use it.

## What shipped

Ten commits: `MemoryOrder`, `MemoryAttributeKeys` with confidence helpers (including `Locale.ROOT`), `MemoryInput` blank text guard, the evolved `MemoryQuery` — `entityIds: List<String>`, `with*` fluent API, `MAX_ENTITY_IDS=25` — Javadoc for three emission pattern options, and adapter updates for in-mem and JPA.

The CDI emission question is deferred — issue #49 tracks three candidate approaches waiting for app feedback. All future adapter work (#33, #34, #37, #40) builds against the clean SPI.
