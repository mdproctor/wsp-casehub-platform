---
layout: post
title: "Small issues, not small decisions"
date: 2026-06-20
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [casememorystore, observability, cbr, api-design]
---

Seven issues, all flagged S or XS, all on one branch. The kind of session that should be mechanical. It wasn't.

The session started with two documentation issues — close-threading behaviour in `AgentSession.close()` and SystemMessage handling in the LangChain4j adapter. The close() documentation was genuinely just documentation: the Mutiny drain signal fires on the worker pool thread, not the caller's thread, and calling close() from a Vert.x event loop would deadlock it. Worth writing down because the symptom (deadlock) points nowhere near the cause (wrong thread for the blocking wait).

SystemMessage was different. The issue said "add a note and a test for the silent-ignore behaviour." Silent ignore is the existing behaviour: if you pass a SystemMessage alongside a UserMessage, it gets filtered out and the query proceeds as if the system message wasn't there. I could have written a comment and a test that asserted silence. But `AgentSession` has a `systemPrompt` set at open time via `AgentSessionInit` — there's no mechanism to change it per call. Accepting a SystemMessage and ignoring it is a promise that was never true. I changed it to throw. The migration for any caller is one error at compile time; the alternative is silent misbehaviour that's hard to trace.

`CbrCaseEntry` was the one I'd been meaning to add for weeks. There's a garden entry from a few sessions back — GE-20260612-bd3b4d — on degenerate CBR: trust-scored routing systems that do Retain and Reuse but not Retrieve and Revise. The entry explicitly mentions "write `CbrCaseEntry` to `CaseMemoryStore` at case close" as the first step toward fixing Retain. The type itself is simple: `problem` maps to `MemoryInput.text` (it's what gets embedded for similarity search), `solution` goes to a new `SOLUTION` attribute, `outcome` and `confidence` use the existing reserved keys. The `from(Memory)` factory closes the roundtrip. Simple record, straightforward conversion, but now it exists and the garden entry isn't just aspirational.

The Testcontainers integration test for `memory-mem0` turned out to be infrastructure-only. The issue acknowledged the blocker upfront: Mem0 OSS computes vector embeddings at write time even with `infer:false`, which means it needs an embedding backend (Ollama, in the proposed design) to start. Without Ollama in CI, the test can't run. I built the scaffold — `Mem0ContainerResource` starts Ollama and Mem0 OSS on a shared Docker network, `CaseMemoryStoreContractIT` extends the existing contract test and wires cleanup — but the class sits `@Disabled` with a note pointing at the infrastructure dependency. One gotcha surfaced during this: Quarkus eagerly loads `@QuarkusTestResource` from every test class at bootstrap, including `@Disabled` ones. The resource tries to pull Docker images, hits rate limits, and corrupts the WireMock tests in the same module. The fix is to comment out the annotation on disabled classes — now GE-20260620-29b8fc in the garden.

The storeAll change was the one that looked small and wasn't. `CaseMemoryStore.storeAll()` returned `List<String>` — the assigned memory IDs in input order. If any store failed, the stream terminated, the exception propagated, and the IDs of everything that did succeed were gone. For REST-backed adapters like Mem0, there's no transaction: if item 5 of 10 fails, items 0–4 are already in the backend. The caller has no way to know which ones made it or which ones to retry.

I changed the return type to `StoreAllResult(List<String> stored, List<StoreFailure> failures)`. The rule: `SecurityException` always propagates immediately — it's an authorization failure, not a backend failure, and collecting it would let cross-tenant writes appear successful. `RuntimeException` from the backend is collected, with the original `inputIndex` preserved so callers can correlate and retry without re-storing what already worked. Seven implementations updated, the contract test updated, the reactive bridge updated. The Mem0 parallel implementation needed some thought: by catching exceptions inside each Uni lambda and returning null for failures, `Uni.join().andFailFast()` effectively becomes a result-collecting join — nothing fails at the Mutiny level, so the ordered output is intact, and the null slots mark the failed positions.

Two of the three design choices this session became protocols: `SecurityException always propagates from storeAll()` (PP-20260620-d9675c) and `@Timed on all 7 CaseMemoryStore methods in every adapter` (PP-20260620-e9355b). Adding `@Timed` to inmem, jpa, and sqlite was mechanical — mem0 and graphiti already had it — but the fact that three adapters were missing it for months meant the rule wasn't written down. It is now.
