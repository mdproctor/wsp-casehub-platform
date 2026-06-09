---
layout: post
title: "Erasing What Was Extracted"
date: 2026-06-09
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [memory, graphiti, gdpr, erasure, capability]
---

After delivering the Graphiti memory adapter last session, I had a short list of follow-up items to resolve — none of them new features, all of them correctness questions the adapter had left open.

The first was a SQLite inconsistency. When you call `storeAll()` on the SQLite adapter, it was checking the tenant on only the first input before opening a transaction. The right pattern — established when the Mem0 adapter was wired up — is to check every input before any backend operation. If item 3 has the wrong tenant, you shouldn't have started the transaction for items 1 and 2. A one-line change.

The interesting one was Graphiti's `eraseById()`.

The Graphiti REST server exposes `DELETE /episode/{uuid}`. We'd declared `ERASE_BY_ID` as a capability, wired it to that endpoint, and it worked — the endpoint responded, the EpisodicNode was gone. What we discovered is that this is where the deletion stops.

Graphiti's LLM extraction pipeline creates `EntityNode` and `EntityEdge` records from each stored episode — these are the knowledge graph structures, the derived facts about what the text described. That extraction happens asynchronously. When you delete the source episode, the derived facts don't go with it. They stay in the graph, associated with other nodes and edges, disconnected from their origin.

This matters because `ERASE_BY_ID` is the capability callers check when they need to remove a specific memory for GDPR Art.17. Declaring it while only deleting the EpisodicNode gives callers a false guarantee. They call `eraseById()`, get no error, and believe the data is gone. It isn't.

The fix is to stop claiming we support something we don't. I removed `ERASE_BY_ID` from `capabilities()` and had `eraseById()` throw `MemoryCapabilityException` — the same pattern the adapter already uses for domain-scoped deletion, which it also can't do correctly. Callers who need complete entity erasure should use `eraseEntity()`, which calls `DELETE /group/{groupId}` and does remove everything.

A new protocol formalises this for future adapters: declaring `ERASE_BY_ID` requires complete deletion — source record and all derived data.

The third item was a verification exercise: whether Graphiti's REST search endpoint accepts `valid_at`, `entity_types`, or `traversal_depth`. It doesn't. The Python library supports all of these; the REST server passes only `group_ids`, `query`, and `max_facts`. The temporal filtering capability — `TEMPORAL_GRAPH` — stays, because the response does include `validAt` and `invalidAt` per returned fact, which is enough to filter client-side. Entity-type filtering can't be implemented at all without a server-side parameter, so those capabilities remain absent from the declarations.

Separately, a protocol violation in the claudony integration. `ClaudonyLedgerEventCapture` was silently defaulting `tenancyId` to the string `"default"` when none arrived on the event. That's not a valid tenant ID — it's a sentinel with no data ownership semantics. The fix was fail-fast: if `tenancyId` is null, log an error and drop the event. No silent corruption. The fix also surfaced a Hibernate field shadowing issue in `CaseLedgerEntry` that needs a separate fix in the engine dependency — filed and tracked.

The session ran shorter than expected. Three fixes, one of which led to a GDPR correctness principle that will apply to every memory adapter we add from here.
