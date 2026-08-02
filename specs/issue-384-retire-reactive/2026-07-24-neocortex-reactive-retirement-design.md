# Neocortex Reactive Retirement — Design Spec

**Issue:** casehubio/parent#384
**Repo:** casehub-neocortex
**Date:** 2026-07-24

## Context

Neocortex is the final repo in the #384 reactive retirement initiative. All other repos (platform, ledger, eidos, qhorus, ras, connectors, claudony, openclaw, blocks) are complete.

The previous session's handover classified neocortex as "reactive-primary" across the board. Investigation reveals this is only partially true — 3 backend modules are reactive-primary, while RAG backends, all decorators, and all in-memory stubs have independent blocking implementations.

## Architecture Finding

| Layer | Delegation direction | Action |
|-------|---------------------|--------|
| SPI interfaces (memory-api, rag-api, corpus-api) | N/A — pure interfaces | Delete reactive interfaces |
| Qdrant CBR (memory-qdrant) | Blocking → Reactive (1070 lines) | **Convert** |
| Mem0 (memory-mem0) | Blocking → Reactive | **Convert** |
| Graphiti (memory-graphiti) | Blocking → Reactive | **Convert** |
| RAG backends (rag/) | Independent dual implementations | Delete reactive |
| All decorators (memory/, rag-*/) | Independent dual implementations | Delete reactive |
| In-memory stubs | Reactive delegates to blocking | Delete reactive |
| Bridges (BlockingToReactive*) | Wrap blocking for reactive API | Delete |
| CDI producers (ReactiveRagBeanProducer) | Produces reactive beans | Delete |
| Tests | Reactive parity and unit tests | Delete |

## Conversion Targets (3 modules)

### 1. memory-qdrant — ReactiveQdrantCbrCaseMemoryStore

**Current:** ReactiveQdrantCbrCaseMemoryStore (1070 lines, @ApplicationScoped) is the canonical implementation. QdrantCbrCaseMemoryStore is a thin shell delegating every method via `.await().indefinitely()`.

**Conversion pattern:** Replace `toUni(client.xxxAsync(...))` with `client.xxxAsync(...).get()` wrapped in try/catch for InterruptedException/ExecutionException. This is the exact pattern used by the existing blocking HybridCaseRetriever in the rag/ module.

**Steps:**
1. Move ReactiveQdrantCbrCaseMemoryStore's logic into QdrantCbrCaseMemoryStore
2. Replace all `Uni<T>` return types with `T`
3. Replace `toUni(future)` calls with `future.get()` + exception handling
4. Replace `.map()` / `.flatMap()` / `.chain()` operators with sequential code
5. Delete ReactiveQdrantCbrCaseMemoryStore
6. Delete QdrantFutures utility (no longer needed — rag/ has its own copy that also gets deleted)

### 2. memory-mem0 — ReactiveMem0CaseMemoryStore

**Current:** ReactiveMem0CaseMemoryStore (@Alternative @Priority(1)) is the canonical implementation. Mem0CaseMemoryStore delegates via `.await().indefinitely()`. ReactiveMem0Client is a @RegisterRestClient with `Uni<>` return types.

**Conversion pattern:** 
1. Create blocking Mem0Client interface — same endpoints, return `X` instead of `Uni<X>`
2. Move ReactiveMem0CaseMemoryStore's logic into Mem0CaseMemoryStore, using blocking client
3. Delete ReactiveMem0CaseMemoryStore and ReactiveMem0Client

### 3. memory-graphiti — ReactiveGraphitiCaseMemoryStore

**Current:** ReactiveGraphitiCaseMemoryStore (@Alternative @Priority(2)) implements ReactiveGraphCaseMemoryStore (which extends ReactiveCaseMemoryStore). GraphitiCaseMemoryStore delegates via `.await().indefinitely()`. ReactiveGraphitiClient is a @RegisterRestClient with `Uni<>` return types.

**Conversion pattern:** Same as Mem0 —
1. Create blocking GraphitiClient interface
2. Move logic into GraphitiCaseMemoryStore (now implements GraphCaseMemoryStore directly)
3. Delete reactive classes

## Straight Deletion (~50 files)

### Reactive SPI interfaces (11)
- memory-api: ReactiveCaseMemoryStore, ReactiveGraphCaseMemoryStore, ReactiveCbrCaseMemoryStore, ReactiveCbrRetrievalTracker, ReactiveAgentTrustProvider
- rag-api: ReactiveCaseRetriever, ReactiveEmbeddingIngestor, ReactiveRetrievalTracker
- corpus-api: ReactiveCorpusReader, ReactiveCorpusStore, ReactiveChangeSource

### Reactive decorators (10)
- memory/: ReactiveTemporalDecayCbrCaseMemoryStore, ReactiveOutcomeWeightingCbrCaseMemoryStore, ReactiveScopeDecayCbrCaseMemoryStore, ReactiveTrendEnrichmentCbrCaseMemoryStore
- memory-cbr-crossencoder/: ReactiveRerankingCbrCaseMemoryStore
- memory-cbr-tracking/: ReactiveTrackingCbrCaseMemoryStore
- rag-crossencoder/: ReactiveCorrectiveCaseRetriever, ReactiveRerankingCaseRetriever
- rag-expansion/: ReactiveQueryExpandingCaseRetriever
- rag-tracking/: ReactiveTrackingCaseRetriever

### Bridges (9)
- memory/: BlockingToReactiveBridge, BlockingToReactiveCbrBridge
- rag/: BlockingToReactiveCaseRetriever, BlockingToReactiveEmbeddingIngestor
- rag-tracking/: BlockingToReactiveRetrievalTracker
- memory-cbr-tracking/: BlockingToReactiveCbrRetrievalTracker
- corpus/: BlockingToReactiveCorpusStoreBridge, BlockingToReactiveCorpusReaderBridge, BlockingToReactiveChangeSourceBridge

### In-memory reactive stubs (4)
- memory-inmem/: ReactiveInMemoryMemoryStore
- memory-cbr-inmem/: ReactiveInMemoryCbrCaseMemoryStore
- rag-testing/: InMemoryReactiveCaseRetriever, InMemoryReactiveEmbeddingIngestor

### RAG reactive implementations (3)
- rag/: ReactiveHybridCaseRetriever, ReactiveQdrantEmbeddingIngestor, ReactiveRagBeanProducer

### Utility (2)
- memory-qdrant/: QdrantFutures
- rag/: QdrantFutures

### Tests (~20)
All reactive-specific test classes (parity tests, reactive unit tests, bridge threading tests)

## POM Cleanup

Remove `smallrye-mutiny-vertx-core` / `mutiny` dependencies from 11 modules:
memory-api, rag-api, corpus-api, memory/, rag-testing/, rag-tracking/, memory-cbr-tracking/, rag-expansion/, rag-crossencoder/, memory-cbr-crossencoder/, corpus/

## Execution Order

1. **SPI interfaces first** — delete reactive interfaces from memory-api, rag-api, corpus-api (this breaks everything downstream, establishing the direction)
2. **Convert backends** — Qdrant CBR, Mem0, Graphiti (these become the sole implementations)
3. **Delete reactive implementations** — decorators, bridges, stubs, RAG backends
4. **Delete tests** — parity tests, reactive unit tests
5. **POM cleanup** — remove Mutiny dependencies
6. **Build and verify** — `JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn clean install`

## Risks

- **Qdrant CBR store size (1070 lines):** Largest conversion target. The logic is well-structured and the blocking pattern is established in the codebase. Risk is moderate — methodical line-by-line conversion.
- **REST client blocking semantics:** Quarkus REST Client supports blocking return types natively. No framework-level risk.
- **No external consumers:** Confirmed via cross-repo search. Zero blast radius outside neocortex.

## Non-Goals

- No REST endpoint changes (neocortex has no REST endpoints affected)
- No @RunOnVirtualThread annotations needed (no JAX-RS resources in affected modules)
- No migration of platform-api's CaseMemoryStore — that's a separate interface already retired in platform PR #194
