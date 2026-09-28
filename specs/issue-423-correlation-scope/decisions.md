# Decisions — CorrelationScope

## D1: Module placement — yaml-step-runtime

**Choice:** CorrelationScope lives in `yaml-step-runtime` alongside other step-level utilities (DecoratorChain, StepContext, DeadlineContext, QuorumTracker).
**Alternatives:**
- New `orchestration-utils` module — adds a module boundary for a single utility class
- `yaml-core` — violates #410 D1 which deferred CorrelationScope to consuming layer; yaml-core is zero-dep/J2CL-safe and CorrelationScope may need platform types in future
**Rationale:** yaml-step-runtime is the existing consuming module that composes yaml-core primitives with platform services. CorrelationScope is a step-level coordination utility, not a standalone framework.
**Trade-offs:** Ties CorrelationScope to the step-runtime module. If a non-step consumer needs correlation, it would need to depend on yaml-step-runtime.
**Sources:** #410 D1 (correlation as composition, consuming-layer utility), yaml-step-runtime module structure
**Exploration:** quick
**Status:** captured

## D2: Channel ownership — ScenarioScope factory

**Choice:** CorrelationScope takes a ScenarioScope in its constructor and creates its own internal OrcChannel via `scope.channel()`. The channel is an implementation detail — callers never see it.
**Alternatives:**
- External channel injection — more flexible but leaks internal plumbing
- Standalone (no scope) — creates DefaultOrcChannel directly, independent of scope lifecycle
**Rationale:** ScenarioScope is the natural factory for channels. Creating the channel internally keeps the CorrelationScope API clean — callers work with correlation keys, not channels.
**Trade-offs:** CorrelationScope is coupled to ScenarioScope. Cannot be used outside a scope context.
**Sources:** ScenarioScope.channel() factory, OrcChannel interface
**Exploration:** quick
**Status:** captured

## D3: Timeout mechanism — CorrelationTimeoutException extends TimeoutException

**Choice:** `CorrelationTimeoutException extends java.util.concurrent.TimeoutException` with correlation key and duration fields. `awaitResponse(K)` throws it when the per-correlation deadline expires. The correlation is auto-cleaned on timeout.
**Alternatives:**
- Plain TimeoutException — loses correlation key context
- Optional.empty() return — loses ability to distinguish timeout from null response, no stack trace
**Rationale:** Extending TimeoutException gives rich error info (key, duration) for callers that need it while remaining catchable as standard TimeoutException. Consistent with awaitResponse declaring `throws TimeoutException`.
**Trade-offs:** One new exception class. Minimal — extends an existing JDK type.
**Sources:** Issue #423 API sketch (awaitResponse throws TimeoutException)
**Exploration:** quick
**Status:** captured

## D4: Lifecycle integration — AutoCloseable

**Choice:** CorrelationScope implements AutoCloseable. On close(), cancels all pending correlations (awaiters get InterruptedException), stops the listener thread, and cleans up. Caller manages via try-with-resources or explicit close.
**Alternatives:**
- OrcPrimitive registration — automatic cascade via releaseForClose() but CorrelationScope is not a primitive
- Fire and forget — stale correlations linger until individual timeouts expire
**Rationale:** AutoCloseable is the standard Java lifecycle pattern. Try-with-resources gives deterministic cleanup. CorrelationScope is a utility, not a primitive — OrcPrimitive registration would conflate layers.
**Trade-offs:** Caller is responsible for closing. If caller forgets, correlations leak until timeout. ScenarioScope.close() does NOT automatically close CorrelationScope — caller must wire this.
**Sources:** ScenarioScope.close() cascade behavior, OrcPrimitive.releaseForClose()
**Exploration:** quick
**Status:** captured

## D5: Cardinality — configurable with default one-shot

**Choice:** `expectResponse(K, Duration)` defaults to expectedCount=1. `expectResponse(K, Duration, int expectedCount)` overload for scatter-gather. For 1:1: `V awaitResponse(K)` returns single value. For 1:N: `List<V> awaitResponses(K)` blocks until all N arrive or timeout.
**Alternatives:**
- One-shot only — simpler but scatter-gather is a real pattern that would need ad-hoc composition from channels + latches
**Rationale:** Scatter-gather (send request to N services, collect N responses) is common enough to justify first-class support. The overload keeps the simple case clean while the implementation generalizes naturally — a collecting list with a CountDownLatch-like gate.
**Trade-offs:** More complex internal state (per-key list + countdown vs single CompletableFuture). The 1:N path needs to handle partial arrival on timeout (throw with partial results? discard?).
**Sources:** Issue #423 scope definition (auto-deregister after first match), scatter-gather pattern
**Exploration:** quick
**Status:** captured

## D6: Key extraction — Function<V, K>

**Choice:** Constructor takes `Function<V, K>` key extractor. The listener thread applies it to every value received from the internal channel, routing matches to pending correlations.
**Alternatives:**
- Map + field name — loses type safety, constrains V to Map
- Caller routes via deliverResponse(K, V) — pushes routing complexity to caller
**Rationale:** Type-safe, composable, and keeps routing internal. The extractor is the only caller-supplied routing logic.
**Trade-offs:** Extractor must be fast and non-blocking — called on the listener thread for every message. A slow extractor blocks all correlation routing.
**Sources:** Issue #423 (trigger filter for key-based matching)
**Exploration:** quick
**Status:** captured

## D7: Internal architecture — CompletableFuture registry with listener thread

**Choice:** ConcurrentHashMap of `K → PendingCorrelation` where PendingCorrelation holds a CompletableFuture (1:1) or countdown + List (1:N). Single virtual listener thread drains the internal OrcChannel, extracts keys via Function<V, K>, completes matching futures. Per-correlation timeouts tracked via ScheduledExecutorService that fails futures with CorrelationTimeoutException on expiry, then auto-cleans.
**Alternatives:**
- Per-correlation child scope with deadline — one child scope + watcher thread per correlation is heavier; latch doesn't carry data
- Channel-per-correlation — pushes routing to callers, doesn't compose with external event sources
**Rationale:** Clean separation — one reader thread, keyed dispatch via ConcurrentHashMap, per-key timeout via scheduler. CompletableFuture naturally generalizes 1:1 (complete) to 1:N (collecting). ScheduledExecutorService is minimal overhead (single virtual thread).
**Trade-offs:** ScheduledExecutorService is an additional resource to manage (shutdown on close).
**Sources:** DefaultOrcChannel implementation, java.util.concurrent patterns
**Exploration:** quick
**Status:** captured

## D8: Unmatched messages — discard silently

**Choice:** When a value arrives on the channel but no pending correlation matches the extracted key, discard silently. Log at TRACE/DEBUG level for diagnostics.
**Alternatives:**
- Buffer for late registration — holds unmatched values briefly in case expectResponse() is called after the response arrives; adds complexity and memory pressure
**Rationale:** CorrelationScope is for expected request-response patterns. If a response arrives before the correlation is registered, the design is wrong — the caller should register before sending the request.
**Trade-offs:** Race condition where expectResponse() is called slightly after the response arrives causes a missed match. Caller must ensure expectResponse() precedes the request send.
**Depends on:** D7 (listener architecture)
**Sources:** Request-response ordering contract
**Exploration:** quick
**Status:** captured

## D9: Partial results on 1:N timeout — carry in exception

**Choice:** CorrelationTimeoutException includes a `List<V> partialResults()` accessor. For 1:1, this is empty. For 1:N scatter-gather that times out after receiving K of N responses, the list contains the K received values.
**Alternatives:**
- Discard partial results — simpler exception but caller loses data that was successfully received
**Rationale:** Partial results are valuable — a scatter-gather that receives 4 of 5 responses may still be actionable. The caller decides whether partial is good enough.
**Trade-offs:** Exception carries mutable state (the list). Defensive copy on construction.
**Depends on:** D5 (configurable cardinality)
**Sources:** Scatter-gather pattern, partial-success handling
**Exploration:** quick
**Status:** captured
