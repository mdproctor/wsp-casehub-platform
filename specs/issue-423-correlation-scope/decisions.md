# Decisions — CorrelationScope

## D1: Module placement — yaml-core orchestration package

**Choice:** CorrelationScope lives in `yaml-core`'s `io.casehub.yaml.core.orchestration` package alongside the primitives it composes.
**Alternatives:**
- `yaml-step-runtime` — forces consumers who only want CorrelationScope (simulation drivers, request-reply bridges) to pull Quarkus, Jackson, platform-api transitive deps
- New `orchestration-utils` module — adds a module boundary for a single utility class
**Rationale:** CorrelationScope's implementation dependencies are exclusively yaml-core types (OrcChannel, ScenarioScope) and JDK (ConcurrentHashMap, CompletableFuture, ScheduledExecutorService). Zero external deps. It's a composition utility like DefaultScenarioScope — both compose orchestration primitives with lifecycle management. The #410 D1 "consuming layer" deferral was about not adding a new primitive to ScenarioScope's interface, not about module placement. CorrelationScope doesn't add to ScenarioScope — it wraps it.
**Trade-offs:** yaml-core gains a class that isn't a primitive. Precedent: DefaultScenarioScope is already a composition utility in the same package.
**Sources:** #410 D1, yaml-core zero-dep constraint, yaml-step-runtime pom.xml transitive deps, review R1-02
**Exploration:** quick
**Status:** revised (R1-02: moved from yaml-step-runtime to yaml-core based on actual dependency profile)

## D2: Channel ownership — OrcChannel constructor with scope convenience factory

**Choice:** CorrelationScope takes an `OrcChannel<V>` in its constructor — the channel is all it needs. A static convenience factory `CorrelationScope.forScope(ScenarioScope, String, Function<V,K>)` creates the channel via `scope.channel()` and registers the CorrelationScope as a primitive for lifecycle cascade. The channel's `T` and CorrelationScope's `V` are the same type parameter.
**Alternatives:**
- ScenarioScope-only constructor — couples CorrelationScope to scope context, prevents reuse in simulation drivers, OpenClaw bridges, or streams processing
- External channel injection without factory — correct but makes scope integration verbose
**Rationale:** OrcChannel is the only thing CorrelationScope needs from the scope. Taking OrcChannel directly enables reuse anywhere (simulation, direct-call bridges, streams). The convenience factory preserves the easy path for YAML consumers and wires lifecycle cascade automatically.
**Trade-offs:** Two construction paths. The factory is the recommended path for scope-integrated use; the constructor is for standalone use.
**Sources:** Review R1-09 (T vs V clarification), R1-10 (ScenarioScope coupling), OpenClaw DirectCallBridge precedent
**Exploration:** quick
**Status:** revised (R1-09, R1-10: decoupled from ScenarioScope, clarified type parameter identity)

## D3: Timeout mechanism — CorrelationTimeoutException extends TimeoutException, SpeedMultiplier-aware

**Choice:** `CorrelationTimeoutException extends java.util.concurrent.TimeoutException` with correlation key and duration fields. `awaitResponse(K)` throws it when the per-correlation deadline expires. The correlation is auto-cleaned on timeout. Per-correlation timeouts respect SpeedMultiplier — a 10s timeout at 10x speed expires in 1s real time, consistent with DefaultScenarioScope's deadline watcher. Constructor takes an optional SpeedMultiplier (defaults to `SpeedMultiplier.identity()` when not scope-integrated).
**Alternatives:**
- Plain TimeoutException — loses correlation key context
- Non-speed-aware timeouts — breaks the simulation time model; a 10s correlation timeout at 10x speed would take 10s real time while scope deadlines expire in 1s
**Rationale:** Extending TimeoutException gives rich error info while remaining catchable as standard TimeoutException. SpeedMultiplier integration ensures correlation timeouts compose correctly with scenario deadlines — both respect the same time model.
**Trade-offs:** SpeedMultiplier adds a constructor parameter. The convenience factory `forScope()` extracts it from the scope automatically.
**Sources:** Issue #423 API sketch, DefaultScenarioScope.startDeadlineWatcher() adaptive-sleep pattern, review R1-07
**Exploration:** quick
**Status:** revised (R1-07: added SpeedMultiplier integration for simulation time consistency)

## D4: Lifecycle integration — OrcPrimitive with scope cascade

**Choice:** CorrelationScope implements `OrcPrimitive`. `releaseForClose()` cancels all pending correlations and stops the listener thread. When created via the `forScope()` factory, it registers in the scope's primitive map — ScenarioScope.close() cascades to CorrelationScope automatically via polymorphic dispatch. When created standalone (constructor), caller manages lifecycle via try-with-resources.

On close/releaseForClose: all pending CompletableFutures are cancelled via `future.cancel(true)`. `awaitResponse()` catches `CancellationException` and throws `InterruptedException("correlation scope closed")` — consistent with how other primitives signal scope closure (channel.receive() returns null, latch.await() throws InterruptedException).
**Alternatives:**
- AutoCloseable only — ScenarioScope.close() kills the internal channel but pending futures hang until individual timeouts fire; creates a silent degradation window
- Fire and forget — stale correlations linger
**Rationale:** OrcPrimitive is a lifecycle interface, not a type classification. CorrelationScope wraps OrcChannel (which IS an OrcPrimitive) and needs the same lifecycle cascade. The "conflating layers" objection doesn't hold — lifecycle participation doesn't make something a primitive.
**Trade-offs:** CorrelationScope appears in the scope's primitive map alongside OrcChannel, OrcLatch, etc. Acceptable — it participates in the same lifecycle.
**Sources:** OrcPrimitive.releaseForClose(), DefaultScenarioScope.close() cascade, CompletableFuture.cancel()/CancellationException semantics, review R1-03, R1-04
**Exploration:** quick
**Status:** revised (R1-03: added OrcPrimitive cascade; R1-04: clarified CancellationException → InterruptedException translation)

## D5: Cardinality — one-shot only

**Choice:** Strict request-response: one `expectResponse(K, Duration)`, one `awaitResponse(K)`, auto-cleanup after match. No 1:N scatter-gather support.
**Alternatives:**
- Configurable cardinality (`expectedCount` parameter) — no concrete consumer identified; yaml-step-runtime already has QuorumTracker for M-of-N completion via OrcLatch; scatter-gather if needed should compose with QuorumTracker rather than reinventing counting+collection
**Rationale:** YAGNI. Issue #423 scope says "auto-deregister after first match (request-response is one-shot)." Scatter-gather adds significant internal complexity (bifurcated PendingCorrelation, collecting list + countdown, partial-result exception) with no identified consumer. If a concrete scatter-gather need surfaces, design it with QuorumTracker awareness.
**Trade-offs:** 1:N patterns require manual composition from channels + latches + QuorumTracker. Acceptable — these primitives already exist and compose well.
**Sources:** Issue #423 scope, QuorumTracker in yaml-step-runtime, review R1-05
**Exploration:** quick
**Status:** revised (R1-05: dropped scatter-gather per YAGNI, noted QuorumTracker composition path)

## D6: Key extraction — Function<V, K> with safety constraints

**Choice:** Constructor takes `Function<V, K>` key extractor. The listener thread applies it to every value received from the internal channel, routing matches to pending correlations. Safety constraints:
1. **Failure isolation:** Extractor is wrapped in try-catch on the listener thread. If the extractor throws (ClassCastException, NPE, any unchecked exception), the message is logged and discarded — the listener continues draining. A dead listener is worse than a dropped message.
2. **Thread-safety contract:** The extractor must not use `synchronized` blocks — the listener runs on a virtual thread and `synchronized` causes pinning. Documented in Javadoc.
3. **Performance contract:** The extractor must be fast and non-blocking — called on the listener thread for every message. A slow extractor blocks all correlation routing.
**Alternatives:**
- Map + field name — loses type safety, constrains V to Map
- Caller routes via deliverResponse(K, V) — pushes routing complexity to caller
**Rationale:** Type-safe, composable, and keeps routing internal. The safety constraints prevent the single-threaded listener from becoming a SPOF.
**Trade-offs:** Caller must provide a well-behaved extractor. Malformed messages are silently dropped (logged at DEBUG).
**Sources:** Issue #423 (trigger filter for key-based matching), yaml-core virtual-thread-pinning constraint, review R1-08, R1-15
**Exploration:** quick
**Status:** revised (R1-08: added failure isolation; R1-15: added virtual-thread-pinning constraint)

## D7: Internal architecture — CompletableFuture registry with listener thread

**Choice:** ConcurrentHashMap of `K → PendingCorrelation` where PendingCorrelation holds a CompletableFuture and a registration timestamp. Single virtual listener thread drains the internal OrcChannel, extracts keys via Function<V, K>, completes matching futures. Per-correlation timeouts tracked via a single-thread ScheduledExecutorService (virtual thread) that fails futures with CorrelationTimeoutException on expiry, then auto-cleans. Timeout durations are SpeedMultiplier-adjusted at scheduling time.

**ScheduledExecutorService lifecycle:**
- Created per-CorrelationScope (single virtual thread)
- On close(): `shutdownNow()` AFTER cancelling all pending futures. Order matters — cancel futures first (so awaiters get CancellationException → InterruptedException), then kill the scheduler (prevents new timeout tasks from firing against already-cancelled futures).
- The scheduler also evicts stale entries from the early-arrival buffer (see D8).
**Alternatives:**
- Per-correlation child scope with deadline — one child scope + watcher thread per correlation is heavier; latch doesn't carry data
- Channel-per-correlation — pushes routing to callers, doesn't compose with external event sources
**Rationale:** Clean separation — one reader thread, keyed dispatch via ConcurrentHashMap, per-key timeout via scheduler. CompletableFuture is the natural single-value completion primitive for 1:1 correlation. SpeedMultiplier integration reuses the same adaptive pattern as DefaultScenarioScope.
**Trade-offs:** ScheduledExecutorService is an additional resource (shut down on close).
**Sources:** DefaultOrcChannel implementation, DefaultScenarioScope.startDeadlineWatcher() SpeedMultiplier pattern, review R1-07, R1-12
**Exploration:** quick
**Status:** revised (R1-07: SpeedMultiplier-aware timeouts; R1-12: specified ScheduledExecutorService lifecycle and shutdown ordering)

## D8: Unmatched messages — time-bounded early-arrival buffer

**Choice:** When a value arrives on the channel but no pending correlation matches the extracted key, hold it in a ConcurrentHashMap buffer with a timestamp. When `expectResponse()` is called, check the buffer first — if a matching value exists, complete the future immediately (no waiting). The ScheduledExecutorService (from D7) evicts stale buffer entries older than a configurable grace period (default 1 second). Buffer entries that are never claimed are logged at DEBUG and discarded on eviction.
**Alternatives:**
- Discard silently — creates a correctness hazard; in YAML scenarios, the correlation registration and the triggering invoke may be separate steps with no guaranteed ordering when spawned tasks are involved
**Rationale:** The ordering contract "expectResponse() must precede the response" is a documentation constraint, not a design constraint — nothing in the API prevents violation. A time-bounded buffer handles the common race condition (fast response arrives before registration completes) with minimal overhead. The timeout scheduler already runs periodic cleanup, so buffer eviction is near-zero additional cost. The 1s grace period covers realistic network/scheduling jitter without holding stale data.
**Trade-offs:** Small memory overhead for buffered messages. Bounded by the eviction interval — at most 1s worth of unmatched messages.
**Depends on:** D7 (ScheduledExecutorService handles eviction)
**Sources:** OpenClaw DirectCallBridge registration-before-call pattern, review R1-06
**Exploration:** quick
**Status:** revised (R1-06: added time-bounded buffer instead of silent discard to eliminate ordering race)

## D9: Observability — pendingCount() and oldestPendingAge()

**Choice:** Two observability methods:
- `int pendingCount()` — number of active correlations awaiting response
- `Optional<Duration> oldestPendingAge()` — time since the oldest pending correlation was registered; empty if no pending correlations

Both are computed from the ConcurrentHashMap registry (size and min registration timestamp). Lock-free reads — no synchronization needed.
**Alternatives:**
- No observability — issue #423 scope explicitly requires it
**Rationale:** The issue scope specifies "Observability: pending correlation count, oldest correlation age." PendingCorrelation already stores a registration timestamp (needed for buffer eviction in D8). Both methods are O(1) or O(n) scans of a ConcurrentHashMap with no lock contention.
**Trade-offs:** `oldestPendingAge()` is an O(n) scan. Acceptable — pending correlation counts are small (typically <100).
**Sources:** Issue #423 API sketch, review R1-11
**Exploration:** quick
**Status:** captured (R1-11: surfaced from issue scope)

## D10: Error propagation — channel error-close fails all pending correlations

**Choice:** When the internal OrcChannel is error-closed (`close(Throwable cause)`), the listener thread detects this via `ChannelClosedException` with a non-null cause. All pending correlations are failed with the channel's error — futures are completed exceptionally with the cause wrapped in an `ExecutionException`. `awaitResponse()` unwraps and throws the cause. This is distinct from normal close (which produces CancellationException → InterruptedException).
**Alternatives:**
- Ignore channel errors — pending correlations hang until individual timeouts; caller has no visibility into the upstream failure
**Rationale:** If the external message source encounters an error and error-closes the channel, all pending correlations should fail fast with the upstream error — not silently degrade to timeout-based cleanup. Error propagation gives callers immediate, specific failure information.
**Trade-offs:** `awaitResponse()` can throw arbitrary exceptions (whatever the channel's close cause was). Callers must handle this in addition to TimeoutException and InterruptedException.
**Depends on:** D7 (listener thread architecture)
**Sources:** OrcChannel.close(Throwable), DefaultOrcChannel.isErrorClosed()/closeError(), review R1-16
**Exploration:** quick
**Status:** captured (R1-16: error propagation path designed)

## D11: Key uniqueness — fail-fast on duplicate pending key

**Choice:** `expectResponse(K, Duration)` throws `IllegalStateException` if a correlation with the same key is already pending. Duplicate keys indicate a caller bug — two concurrent requests with the same correlation ID would route the single response to an arbitrary waiter.
**Alternatives:**
- Allow duplicates silently — second response completes the first request's future; undefined behavior
- Queue multiple waiters per key — adds complexity for a scenario that indicates a design error
**Rationale:** Correlation keys must be unique among pending correlations. Failing fast on duplicates catches caller bugs at registration time rather than producing undefined behavior at match time. Callers who need to reuse keys must await the first correlation before registering the second.
**Trade-offs:** Callers must ensure key uniqueness. For UUID-based correlation IDs, this is trivially satisfied.
**Sources:** Review R1-14
**Exploration:** quick
**Status:** captured (R1-14: fail-fast on duplicate key)
