# Neocortex Reactive Retirement — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural editing.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/parent#384 — Retire reactive tier
**Issue group:** casehubio/parent#384

**Goal:** Remove all Mutiny/reactive code from casehub-neocortex — the final repo — completing the platform-wide reactive retirement.

**Architecture:** Three backend modules (memory-qdrant, memory-mem0, memory-graphiti) are reactive-primary: their blocking classes delegate to reactive implementations. These must be converted to direct blocking implementations. Everything else (decorators, bridges, stubs, SPIs, tests) is straight deletion — blocking implementations already have their own logic.

**Tech Stack:** Java 21, Quarkus 3.32, Qdrant Java client (gRPC/ListenableFuture), Quarkus REST Client (@RegisterRestClient), Mutiny (being removed)

## Global Constraints

- All edits to `.java` files via IntelliJ MCP tools (`ide_edit_member`, `ide_replace_member`, `ide_insert_member`, `ide_create_file`). Never bash Edit/Write on existing Java files.
- File deletions via `ide_refactor_safe_delete` with `force: true` (references will be broken intentionally).
- Build command: `JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn --batch-mode clean install -pl <module> -am`
- Full build: `JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn --batch-mode clean install`
- Project path for all IDE calls: `/Users/mdproctor/claude/casehub/neocortex`
- Repo path for all git operations: `/Users/mdproctor/claude/casehub/worktrees/30/neocortex`

---

### Task 1: Convert memory-qdrant — QdrantCbrCaseMemoryStore

Rewrite `QdrantCbrCaseMemoryStore` with the real Qdrant gRPC logic currently in `ReactiveQdrantCbrCaseMemoryStore`. This is a refactoring — existing tests validate correctness.

**Files:**
- Rewrite: `memory-qdrant/src/main/java/io/casehub/neocortex/memory/cbr/qdrant/QdrantCbrCaseMemoryStore.java` (currently a thin shell, becomes the 1070-line real implementation)
- Delete after conversion: `memory-qdrant/src/main/java/io/casehub/neocortex/memory/cbr/qdrant/ReactiveQdrantCbrCaseMemoryStore.java`
- Delete: `memory-qdrant/src/main/java/io/casehub/neocortex/memory/cbr/qdrant/QdrantFutures.java`
- Test (existing): `memory-qdrant/src/test/java/io/casehub/neocortex/memory/cbr/qdrant/QdrantCbrCaseMemoryStoreTest.java`

**Interfaces:**
- Consumes: `CbrCaseMemoryStore` SPI (blocking), `CbrCollectionManager`, `EmbeddingModel`, `SparseEmbedder`, `QdrantCbrConfig`, Qdrant gRPC client
- Produces: `QdrantCbrCaseMemoryStore` @ApplicationScoped (same CDI bean, same API, direct implementation)

**Conversion pattern:**
Every `toUni(client.xxxAsync(args))` becomes:
```java
try {
    return client.xxxAsync(args).get();
} catch (InterruptedException e) {
    Thread.currentThread().interrupt();
    throw new RuntimeException("Interrupted during Qdrant operation", e);
} catch (ExecutionException e) {
    throw new RuntimeException("Qdrant operation failed", e.getCause());
}
```

Every `.map(result -> { ... })` becomes sequential code after the `.get()` call.
Every `.flatMap(x -> toUni(client.yyy()))` becomes a second sequential `.get()` call.
Every `Multi.createFrom().iterable(items).onItem().transformToUniAndMerge(...)` becomes a `for` loop or `stream().map(...)`.

- [ ] **Step 1: Read ReactiveQdrantCbrCaseMemoryStore in full**

Read the complete 1070-line file to understand every method's reactive logic before converting. Note: the reactive store has fields for `CbrCollectionManager`, `EmbeddingModel`, `SparseEmbedder`, `QdrantCbrConfig`, `CaseMemoryStore delegate`, and `Map<String, CbrFeatureSchema> schemas`.

- [ ] **Step 2: Run existing blocking tests to establish baseline**

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn --batch-mode test -pl memory-qdrant -am
```
Expected: All tests pass (currently via delegation to reactive).

- [ ] **Step 3: Rewrite QdrantCbrCaseMemoryStore**

Replace the thin delegation shell with the full implementation. Copy the reactive class's fields, constructors, and method logic. Convert each method from reactive to blocking using the pattern above. The class keeps `implements CbrCaseMemoryStore` and `@ApplicationScoped`.

Key methods to convert:
- `registerSchema()` — schema validation + collection manager delegation
- `store()` — point building, embedding, upsert via gRPC
- `retrieveSimilar()` — multi-leg fusion (dense + sparse + BM25), prefetch queries, result mapping, similarity scoring
- `erase()`, `eraseEntity()`, `eraseByScope()` — filter-based deletion
- `recordOutcome()` — payload update
- `purge()` — filtered deletion with retention policy
- `supersede()`, `reinstate()`, `getSupersessionStatus()`, `findSupersededCases()` — payload updates and queries

Create a private helper for the try/catch pattern:
```java
private static <T> T awaitFuture(ListenableFuture<T> future, String operation) {
    try {
        return future.get();
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new RuntimeException("Interrupted during " + operation, e);
    } catch (ExecutionException e) {
        throw new RuntimeException(operation + " failed", e.getCause());
    }
}
```

- [ ] **Step 4: Delete ReactiveQdrantCbrCaseMemoryStore and QdrantFutures**

Use `ide_refactor_safe_delete` with `force: true` for both files.

- [ ] **Step 5: Remove Mutiny imports from QdrantCbrCaseMemoryStore**

Ensure no `io.smallrye.mutiny` imports remain. Run `ide_optimize_imports`.

- [ ] **Step 6: Run tests to verify conversion**

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn --batch-mode test -pl memory-qdrant -am
```
Expected: All tests pass with direct blocking implementation.

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/worktrees/30/neocortex add memory-qdrant/
git -C /Users/mdproctor/claude/casehub/worktrees/30/neocortex commit -m "feat(#384): convert memory-qdrant to blocking — direct Qdrant gRPC"
```

---

### Task 2: Convert memory-mem0 — Mem0CaseMemoryStore

Create a blocking REST client interface and rewrite `Mem0CaseMemoryStore` with the real logic currently in `ReactiveMem0CaseMemoryStore`.

**Files:**
- Create: `memory-mem0/src/main/java/io/casehub/neocortex/memory/mem0/Mem0Client.java` (blocking REST client — same endpoints as ReactiveMem0Client, return `X` instead of `Uni<X>`)
- Rewrite: `memory-mem0/src/main/java/io/casehub/neocortex/memory/mem0/Mem0CaseMemoryStore.java`
- Delete after conversion: `memory-mem0/src/main/java/io/casehub/neocortex/memory/mem0/ReactiveMem0CaseMemoryStore.java`
- Delete after conversion: `memory-mem0/src/main/java/io/casehub/neocortex/memory/mem0/ReactiveMem0Client.java`
- Test (existing): `memory-mem0/src/test/java/io/casehub/neocortex/memory/mem0/Mem0CaseMemoryStoreTest.java`

**Interfaces:**
- Consumes: `CaseMemoryStore` SPI (blocking), `Mem0AuthFilter` (shared — keeps working)
- Produces: `Mem0Client` @RegisterRestClient (blocking), `Mem0CaseMemoryStore` @Alternative @Priority(1) (same CDI bean, direct implementation)

- [ ] **Step 1: Run existing tests to establish baseline**

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn --batch-mode test -pl memory-mem0 -am
```

- [ ] **Step 2: Create blocking Mem0Client interface**

Copy `ReactiveMem0Client`, change return types from `Uni<X>` to `X`. Keep all annotations (`@RegisterRestClient`, `@RegisterProvider`, `@Path`, etc.). Use `ide_create_file`.

```java
@RegisterRestClient(configKey = "mem0")
@RegisterProvider(Mem0AuthFilter.class)
@Path("/")
public interface Mem0Client {
    @POST @Path("/memories") @Consumes(MediaType.APPLICATION_JSON) @Produces(MediaType.APPLICATION_JSON)
    Mem0AddResponse add(Mem0AddRequest request);

    @GET @Path("/memories") @Produces(MediaType.APPLICATION_JSON)
    Mem0ListResponse list(@QueryParam("user_id") String userId, @QueryParam("agent_id") String agentId, @QueryParam("run_id") String runId);

    @POST @Path("/search") @Consumes(MediaType.APPLICATION_JSON) @Produces(MediaType.APPLICATION_JSON)
    Mem0ListResponse search(Mem0SearchRequest request);

    @GET @Path("/memories/{memoryId}") @Produces(MediaType.APPLICATION_JSON)
    Mem0Memory getById(@PathParam("memoryId") String memoryId);

    @DELETE @Path("/memories/{memoryId}")
    void deleteById(@PathParam("memoryId") String memoryId);

    @DELETE @Path("/memories")
    void deleteAll(@QueryParam("user_id") String userId, @QueryParam("agent_id") String agentId, @QueryParam("run_id") String runId);
}
```

- [ ] **Step 3: Rewrite Mem0CaseMemoryStore**

Replace delegation shell with real logic from `ReactiveMem0CaseMemoryStore`. Change injected client from `ReactiveMem0Client` to `Mem0Client`. Remove all Uni operators — call client methods directly and use the return values inline.

- [ ] **Step 4: Delete ReactiveMem0CaseMemoryStore and ReactiveMem0Client**

Use `ide_refactor_safe_delete` with `force: true`.

- [ ] **Step 5: Run tests**

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn --batch-mode test -pl memory-mem0 -am
```

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/worktrees/30/neocortex add memory-mem0/
git -C /Users/mdproctor/claude/casehub/worktrees/30/neocortex commit -m "feat(#384): convert memory-mem0 to blocking — direct REST client"
```

---

### Task 3: Convert memory-graphiti — GraphitiCaseMemoryStore

Same pattern as Mem0. Create blocking client, rewrite store, delete reactive.

**Files:**
- Create: `memory-graphiti/src/main/java/io/casehub/neocortex/memory/graphiti/GraphitiClient.java`
- Rewrite: `memory-graphiti/src/main/java/io/casehub/neocortex/memory/graphiti/GraphitiCaseMemoryStore.java` (must now implement `GraphCaseMemoryStore` directly — was delegating through reactive which implemented `ReactiveGraphCaseMemoryStore`)
- Delete after conversion: `memory-graphiti/src/main/java/io/casehub/neocortex/memory/graphiti/ReactiveGraphitiCaseMemoryStore.java`
- Delete after conversion: `memory-graphiti/src/main/java/io/casehub/neocortex/memory/graphiti/ReactiveGraphitiClient.java`
- Test (existing): `memory-graphiti/src/test/java/io/casehub/neocortex/memory/graphiti/GraphitiCaseMemoryStoreTest.java`
- Test (existing): `memory-graphiti/src/test/java/io/casehub/neocortex/memory/graphiti/GraphitiCaseMemoryStoreKnownDomainsTest.java`

**Interfaces:**
- Consumes: `GraphCaseMemoryStore` SPI (blocking), `GraphitiAuthFilter` (shared)
- Produces: `GraphitiClient` @RegisterRestClient (blocking), `GraphitiCaseMemoryStore` @Alternative @Priority(2) implements `GraphCaseMemoryStore` (was CaseMemoryStore + reactive delegation for graphQuery — now direct blocking graphQuery)

**Important:** `ReactiveGraphitiCaseMemoryStore` implements `ReactiveGraphCaseMemoryStore` which extends `ReactiveCaseMemoryStore`. After conversion, `GraphitiCaseMemoryStore` must implement `GraphCaseMemoryStore` (blocking) to provide `graphQuery()`. Check the current `GraphitiCaseMemoryStore` to see if it already implements `GraphCaseMemoryStore` or just `CaseMemoryStore`.

- [ ] **Step 1: Read current GraphitiCaseMemoryStore to check which interface it implements**

Determine if it currently implements `GraphCaseMemoryStore` or `CaseMemoryStore`, and whether `graphQuery()` is delegated through the reactive store.

- [ ] **Step 2: Run existing tests**

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn --batch-mode test -pl memory-graphiti -am
```

- [ ] **Step 3: Create blocking GraphitiClient interface**

Same pattern as Mem0 — copy reactive client, replace `Uni<X>` with `X`, `Uni<Response>` with `Response`, `Uni<Void>` with `void`.

- [ ] **Step 4: Rewrite GraphitiCaseMemoryStore**

Move logic from `ReactiveGraphitiCaseMemoryStore`. Ensure it implements `GraphCaseMemoryStore` (not just `CaseMemoryStore`) to provide `graphQuery()` directly.

- [ ] **Step 5: Delete ReactiveGraphitiCaseMemoryStore and ReactiveGraphitiClient**

Use `ide_refactor_safe_delete` with `force: true`.

- [ ] **Step 6: Run tests**

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn --batch-mode test -pl memory-graphiti -am
```

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/worktrees/30/neocortex add memory-graphiti/
git -C /Users/mdproctor/claude/casehub/worktrees/30/neocortex commit -m "feat(#384): convert memory-graphiti to blocking — direct REST client"
```

---

### Task 4: Delete all reactive code, POM cleanup, build verification

Bulk deletion of reactive SPIs, decorators, bridges, stubs, tests, and Mutiny dependencies. After Tasks 1-3, no implementation depends on reactive interfaces — this is a clean sweep.

**Files to delete (use `ide_refactor_safe_delete` with `force: true`):**

*Reactive SPI interfaces (11):*
- `memory-api/src/main/java/io/casehub/neocortex/memory/ReactiveCaseMemoryStore.java`
- `memory-api/src/main/java/io/casehub/neocortex/memory/ReactiveGraphCaseMemoryStore.java`
- `memory-api/src/main/java/io/casehub/neocortex/memory/cbr/ReactiveCbrCaseMemoryStore.java`
- `memory-api/src/main/java/io/casehub/neocortex/memory/cbr/ReactiveCbrRetrievalTracker.java`
- `memory-api/src/main/java/io/casehub/neocortex/memory/cbr/ReactiveAgentTrustProvider.java`
- `rag-api/src/main/java/io/casehub/neocortex/rag/ReactiveCaseRetriever.java`
- `rag-api/src/main/java/io/casehub/neocortex/rag/ReactiveEmbeddingIngestor.java`
- `rag-api/src/main/java/io/casehub/neocortex/rag/ReactiveRetrievalTracker.java`
- `corpus-api/src/main/java/io/casehub/neocortex/corpus/ReactiveCorpusReader.java`
- `corpus-api/src/main/java/io/casehub/neocortex/corpus/ReactiveCorpusStore.java`
- `corpus-api/src/main/java/io/casehub/neocortex/corpus/ReactiveChangeSource.java`

*Reactive decorators (10):*
- `memory/src/main/java/io/casehub/neocortex/memory/cbr/runtime/ReactiveTemporalDecayCbrCaseMemoryStore.java`
- `memory/src/main/java/io/casehub/neocortex/memory/cbr/runtime/ReactiveOutcomeWeightingCbrCaseMemoryStore.java`
- `memory/src/main/java/io/casehub/neocortex/memory/cbr/runtime/ReactiveScopeDecayCbrCaseMemoryStore.java`
- `memory/src/main/java/io/casehub/neocortex/memory/cbr/runtime/ReactiveTrendEnrichmentCbrCaseMemoryStore.java`
- `memory-cbr-crossencoder/src/main/java/io/casehub/neocortex/memory/cbr/crossencoder/ReactiveRerankingCbrCaseMemoryStore.java`
- `memory-cbr-tracking/src/main/java/io/casehub/neocortex/memory/cbr/tracking/ReactiveTrackingCbrCaseMemoryStore.java`
- `rag-crossencoder/src/main/java/io/casehub/neocortex/rag/crossencoder/corrective/ReactiveCorrectiveCaseRetriever.java`
- `rag-crossencoder/src/main/java/io/casehub/neocortex/rag/crossencoder/reranking/ReactiveRerankingCaseRetriever.java`
- `rag-expansion/src/main/java/io/casehub/neocortex/rag/expansion/ReactiveQueryExpandingCaseRetriever.java`
- `rag-tracking/src/main/java/io/casehub/neocortex/rag/tracking/ReactiveTrackingCaseRetriever.java`

*Bridges (9):*
- `memory/src/main/java/io/casehub/memory/runtime/BlockingToReactiveBridge.java`
- `memory/src/main/java/io/casehub/neocortex/memory/cbr/runtime/BlockingToReactiveCbrBridge.java`
- `rag/src/main/java/io/casehub/neocortex/rag/runtime/BlockingToReactiveCaseRetriever.java`
- `rag/src/main/java/io/casehub/neocortex/rag/runtime/BlockingToReactiveEmbeddingIngestor.java`
- `rag-tracking/src/main/java/io/casehub/neocortex/rag/tracking/BlockingToReactiveRetrievalTracker.java`
- `memory-cbr-tracking/src/main/java/io/casehub/neocortex/memory/cbr/tracking/BlockingToReactiveCbrRetrievalTracker.java`
- `corpus/src/main/java/io/casehub/neocortex/corpus/zip/BlockingToReactiveCorpusStoreBridge.java`
- `corpus/src/main/java/io/casehub/neocortex/corpus/zip/BlockingToReactiveCorpusReaderBridge.java`
- `corpus/src/main/java/io/casehub/neocortex/corpus/zip/BlockingToReactiveChangeSourceBridge.java`

*In-memory reactive stubs (4):*
- `memory-inmem/src/main/java/io/casehub/neocortex/memory/inmem/ReactiveInMemoryMemoryStore.java`
- `memory-cbr-inmem/src/main/java/io/casehub/neocortex/memory/cbr/inmem/ReactiveInMemoryCbrCaseMemoryStore.java`
- `rag-testing/src/main/java/io/casehub/neocortex/rag/testing/InMemoryReactiveCaseRetriever.java`
- `rag-testing/src/main/java/io/casehub/neocortex/rag/testing/InMemoryReactiveEmbeddingIngestor.java`

*RAG reactive implementations (3):*
- `rag/src/main/java/io/casehub/neocortex/rag/runtime/ReactiveHybridCaseRetriever.java`
- `rag/src/main/java/io/casehub/neocortex/rag/runtime/ReactiveQdrantEmbeddingIngestor.java`
- `rag/src/main/java/io/casehub/neocortex/rag/runtime/ReactiveRagBeanProducer.java`

*Utility (1):*
- `rag/src/main/java/io/casehub/neocortex/rag/runtime/QdrantFutures.java`

*Tests to delete (~20):*
- `memory-api/src/test/java/io/casehub/neocortex/memory/ReactiveCaseMemoryStoreSpiTest.java`
- `memory-api/src/test/java/io/casehub/neocortex/memory/ReactiveGraphCaseMemoryStoreSpiTest.java`
- `memory-api/src/test/java/io/casehub/neocortex/memory/cbr/BlockingReactiveParityTest.java`
- `rag-api/src/test/java/io/casehub/neocortex/rag/BlockingReactiveParityTest.java`
- `corpus-api/src/test/java/io/casehub/neocortex/corpus/BlockingReactiveParityTest.java`
- `memory-inmem/src/test/java/io/casehub/neocortex/memory/inmem/ReactiveInMemoryMemoryStoreTest.java`
- `memory-cbr-inmem/src/test/java/io/casehub/neocortex/memory/cbr/inmem/ReactiveInMemoryCbrCaseMemoryStoreTest.java`
- `rag-testing/src/test/java/io/casehub/neocortex/rag/testing/InMemoryReactiveCaseRetrieverTest.java`
- `rag-testing/src/test/java/io/casehub/neocortex/rag/testing/InMemoryReactiveEmbeddingIngestorTest.java`
- `rag/src/test/java/io/casehub/neocortex/rag/runtime/ReactiveHybridCaseRetrieverTest.java`
- `rag/src/test/java/io/casehub/neocortex/rag/runtime/ReactiveQdrantEmbeddingIngestorTest.java`
- `rag/src/test/java/io/casehub/neocortex/rag/runtime/BlockingToReactiveCaseRetrieverTest.java`
- `rag/src/test/java/io/casehub/neocortex/rag/runtime/BlockingToReactiveEmbeddingIngestorTest.java`
- `rag/src/test/java/io/casehub/neocortex/rag/runtime/AssertTenantReactiveTest.java`
- `memory/src/test/java/io/casehub/memory/runtime/BlockingToReactiveBridgeThreadingTest.java`
- `memory/src/test/java/io/casehub/neocortex/memory/cbr/runtime/ReactiveOutcomeWeightingCbrCaseMemoryStoreTest.java`
- `rag-crossencoder/src/test/java/io/casehub/neocortex/rag/crossencoder/corrective/ReactiveCorrectiveCaseRetrieverTest.java`
- `rag-crossencoder/src/test/java/io/casehub/neocortex/rag/crossencoder/reranking/ReactiveRerankingCaseRetrieverTest.java`
- `rag-expansion/src/test/java/io/casehub/neocortex/rag/expansion/ReactiveQueryExpandingCaseRetrieverTest.java`
- `memory-cbr-tracking/src/test/java/io/casehub/neocortex/memory/cbr/tracking/ReactiveTrackingCbrCaseMemoryStoreTest.java`
- `corpus/src/test/java/io/casehub/neocortex/corpus/zip/BlockingToReactiveBridgeTest.java`
- `memory-qdrant/src/test/java/io/casehub/neocortex/memory/cbr/qdrant/QdrantFuturesTest.java`
- `rag/src/test/java/io/casehub/neocortex/rag/runtime/QdrantFuturesTest.java`

*Tests to modify (remove reactive parts, keep blocking):*
- `memory/src/test/java/io/casehub/memory/runtime/NoOpCaseMemoryStoreTest.java` — remove `@Inject ReactiveCaseMemoryStore reactiveStore` and any test methods that use it
- `memory-cbr-tracking/src/test/java/io/casehub/neocortex/memory/cbr/tracking/CdiDecoratorChainTest.java` — remove `@Inject ReactiveCbrCaseMemoryStore` and reactive chain assertions
- `memory-cbr-tracking/src/test/java/io/casehub/neocortex/memory/cbr/tracking/DecoratorChainIntegrationTest.java` — remove reactive test methods and inner classes (`BridgedReactiveTestStore`, `SimpleReactiveCbrRetrievalTracker`, `stubReactiveDelegate`)

**POM files to modify (remove Mutiny dependencies):**
- `memory-api/pom.xml`
- `rag-api/pom.xml`
- `corpus-api/pom.xml`
- `memory/pom.xml`
- `rag-testing/pom.xml`
- `rag-tracking/pom.xml`
- `memory-cbr-tracking/pom.xml`
- `rag-expansion/pom.xml`
- `rag-crossencoder/pom.xml`
- `memory-cbr-crossencoder/pom.xml`
- `corpus/pom.xml`

- [ ] **Step 1: Delete all reactive source files**

Delete all files listed above using `ide_refactor_safe_delete` with `force: true`. Process in order: implementations first (decorators, bridges, stubs, RAG impls), then SPI interfaces, then tests.

- [ ] **Step 2: Update tests that reference reactive types**

For each test listed under "Tests to modify":
- `NoOpCaseMemoryStoreTest` — remove `@Inject ReactiveCaseMemoryStore reactiveStore` and any reactive test methods
- `CdiDecoratorChainTest` — remove reactive store injection and reactive chain assertions
- `DecoratorChainIntegrationTest` — remove reactive test methods, `BridgedReactiveTestStore`, `SimpleReactiveCbrRetrievalTracker`, `stubReactiveDelegate`

Use `ide_edit_member` or `ide_replace_member` for targeted removals.

- [ ] **Step 3: Remove Mutiny dependencies from POMs**

For each of the 11 POM files, remove the `<dependency>` block for `io.smallrye.reactive:smallrye-mutiny-vertx-core` or `io.smallrye.reactive:mutiny`. Use bash (POMs are config files, not source code).

- [ ] **Step 4: Check for any remaining reactive imports**

```bash
# Search across neocortex for any remaining Mutiny references
```
Use `ide_search_text` with query `io.smallrye.mutiny` across all `*.java` files. Fix any stragglers.

- [ ] **Step 5: Full build verification**

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn --batch-mode clean install
```
Expected: BUILD SUCCESS with zero Mutiny usage.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/worktrees/30/neocortex add -A
git -C /Users/mdproctor/claude/casehub/worktrees/30/neocortex commit -m "feat(#384): delete reactive tier — SPIs, decorators, bridges, stubs, tests, Mutiny deps"
```

---

## Post-Implementation

After all 4 tasks:
- Update `CLAUDE.md` — remove all `Reactive*` references from module descriptions
- Update `ARC42STORIES.MD` if it references reactive architecture
- Update HANDOFF.md with completion status
