# Decisions — Issue #268: Capacity Signal SPI + Redistribution Policy

## D1: Separate SPI from ActorState infrastructure

**Choice:** Capacity signal SPI (`CapacitySignalSource`, `ActorCapacityView`) as a separate concern from `ActorStateContributor`/`ActorStateAccumulator`, placed in `io.casehub.platform.api.capacity`.
**Alternatives:**
- Extend `ActorStateAccumulator` with a `pressure(String signalType, double value)` method — couples dashboard read model to operational monitoring, and the accumulator's single-actor push model can't support `observeOverloaded(threshold)` multi-actor scan.
- Add capacity as a field on `ActorStateResponse` — wrong consumer (REST dashboard vs `@Scheduled` sweep + CDI events), wrong aggregation model (accumulate vs max-pressure).
**Rationale:** Different query model (single-actor push vs multi-actor scan), different purpose (dashboard vs operational monitoring), different data shape (heterogeneous typed methods vs homogeneous pressure 0.0–1.0), different consumers (REST → UI vs sweep → CDI → domain executors).
**Trade-offs:** Two parallel actor-related SPIs in platform-api. Acceptable because they serve fundamentally different access patterns.
**Sources:** `ActorStateContributor.java` (platform-api), `ActorStateAccumulator.java` (platform-api), `ActorStateAggregator.java` (engine/actor-state), GE-20260602-c4a68a (dual-constructor aggregator pattern), GE-20260602-047ac4 (visitor/accumulator pattern)
**Exploration:** deep-analysis
**Status:** captured

## D2: Domain executor as RedistributionContext composer

**Choice:** Domain executors (qhorus, engine) observe `CapacityPressureEvent`, query their own domain state, build `RedistributionContext`, and call `RedistributionPolicy.evaluate()`. No central coordinator.
**Alternatives:**
- Platform-level coordinator gathers obligation counts via another SPI, calls policy centrally — avoids over-correction but adds unnecessary complexity (new SPI, central dispatcher).
- Fire `RedistributionDecisionEvent` from platform with pre-evaluated decision — platform lacks domain context (obligation counts, activity timestamps) to build full `RedistributionContext`.
**Rationale:** `RedistributionContext` needs data from two worlds: capacity (platform) and domain workload (domain repos). Only the domain executor has access to both. Over-correction from multiple domains acting simultaneously is self-healing (next sweep sees reduced pressure). Grace periods provide natural coordination window.
**Trade-offs:** Multiple domains may over-correct on the same event. Mitigated by sweep intervals and grace periods. If problematic in practice, a coordinator can be added later without SPI boundary changes.
**Sources:** Draft spec §Layer 3 (domain-specific execution), `CapacityPressureEvent` design
**Exploration:** deep-analysis
**Status:** captured

## D3: Aggregation strategy — max-pressure, not configurable

**Choice:** Max-pressure across signal types. Pre-release: hardcoded in `AggregatingActorCapacityView`, not configurable.
**Alternatives:**
- Weighted average — misleading when one dimension is saturated (0.9 context + 0.1 tasks = 0.5 average, but agent can't take new work).
- Configurable strategy (max / weighted / domain-priority) — adds complexity for no clear pre-release benefit.
**Rationale:** Any single saturated dimension prevents new work. Max-pressure is the correct safety model. Implementation can change later without SPI boundary changes.
**Trade-offs:** May trigger redistribution when only one signal is high and others are low. Acceptable — conservative is correct for an operational safety mechanism.
**Sources:** Draft spec §Layer 0.5 aggregation rationale
**Exploration:** quick
**Status:** captured

## D4: Capacity signals are tenant-agnostic; redistribution is tenant-scoped

**Choice:** `CapacitySignal` has no `tenancyId` field. Signals represent aggregate physical state of the actor. Tenant scoping happens at the redistribution execution level.
**Alternatives:**
- Per-tenant signals — would require `observeOverloaded()` to be tenant-scoped, increasing query complexity. An agent at 0.9 context window is overloaded regardless of which tenant's work caused it.
- Tenant field on signal, aggregate at view level — unnecessary indirection when the physical constraint (context window, session slots) is tenant-agnostic.
**Rationale:** An agent's context window and session slots are physical resources shared across tenants. Pressure represents aggregate physical state. Domain executors already operate in tenant context and filter redistribution targets accordingly.
**Trade-offs:** Can't distinguish "overloaded because of tenant-A work" from "overloaded because of tenant-B work" at the signal level. Domain executors handle this by only redistributing work within their tenant.
**Sources:** Draft spec open question #4, `CurrentPrincipal.tenancyId()` pattern
**Exploration:** deep-analysis
**Status:** captured

## D5: Redistribution scope and circular guard are executor concerns

**Choice:** The `RedistributionPolicy` SPI says WHAT to do (compress/redistribute/hold/escalate). HOW MUCH to redistribute and circular guard logic are domain executor responsibilities, not platform SPI concerns.
**Alternatives:**
- Add `targetPressure` to `Redistribute` decision to guide partial redistribution — premature optimization; executors can iterate until pressure drops.
- Add `maxDepth` to `Redistribute` for circular guard — qhorus already has `CIRCULAR_DELEGATION` watchdog.
**Rationale:** The policy provides shared decision vocabulary (all domains use same thresholds). Execution details (how many obligations to move, how to guard against circularity) are domain-specific and already handled by existing domain infrastructure.
**Trade-offs:** Executors must independently implement "move obligations until pressure drops" logic. Acceptable — each domain's movable work has different semantics.
**Future consideration:** When multiple domain executors are deployed (engine executor in batch 4), cross-domain circular redistribution becomes theoretically possible. The qhorus `CIRCULAR_DELEGATION` watchdog only traces within-domain delegation chains via `parentCommitmentId`. A cross-domain coordination mechanism should be evaluated at that time. Not needed with a single domain executor.
**Sources:** Draft spec open questions #2 and #3, qhorus `CIRCULAR_DELEGATION` watchdog
**Exploration:** quick
**Status:** captured

## D6: Bridge capacity into ActorState via contributor + accumulator method

**Choice:** Add `capacity(double aggregatePressure, Map<String, Double> pressureBySignalType)` to `ActorStateAccumulator`. Ship a `CapacityActorStateContributor` in platform that injects `ActorCapacityView` and writes capacity data into the accumulator. The capacity SPI remains independent; the contributor is a bridge.
**Alternatives:**
- Add fleet-wide query methods to `ActorStateContributor` — leaks capacity-specific semantics (threshold, overloaded) into a general-purpose SPI. "Above threshold" has no meaning for trust scores or work items.
- Keep capacity entirely separate, no bridge — dashboard endpoint misses capacity data, operators must query two endpoints for a complete actor view.
**Rationale:** The two SPIs serve different purposes (D1) but describe the same actors. The dashboard should show capacity alongside trust and workload. A contributor bridge connects them without merging the SPI contracts.
**Trade-offs:** Adds one method to `ActorStateAccumulator` (breaking change — pre-release, cost is zero). `ActorStateAccumulatorImpl` in engine-actor-state must implement the new method.
**Depends on:** D1 (separate SPIs — the bridge only makes sense because they're separate)
**Sources:** `ActorStateAccumulator.java` (platform-api), `ActorStateAccumulatorImpl.java` (engine/actor-state)
**Exploration:** deep-analysis
**Status:** captured

## D7: Stateless fire-and-forget executor with sweep-based re-evaluation

**Choice:** The redistribution executor uses fire-and-forget compression (option 1) with sweep-based re-evaluation. The executor is stateless across sweeps — all state lives in the commitment store (obligations), capacity view (pressure), and ledger (signal freshness). Two guards ensure eventual consistency: (1) compression freshness guard (`countMessagesSince()` before `triggerUpdate()`) prevents wasteful LLM calls, (2) routing failure escalation (if policy says Redistribute and zero HANDOFFs succeed, fire Escalate) prevents infinite stuck loops. The executor must respect the `gracePeriod` field on `Redistribute` decisions — after a redistribution action for an actor, skip subsequent redistribution for that actor until the grace period expires. Derive last-redistribution timestamp via `CrossTenantCommitmentStore.findLatestDelegatedByObligor(actorId)`, which returns the most recently delegated commitment for the actor; use `resolvedAt` as the redistribution timestamp. `Duration.ZERO` (immediate threshold ≥ 0.95) disables the cooldown. This also serves as the oscillation prevention mechanism.
**Alternatives:**
- Synchronous wait (option 2) — executor blocks during LLM-driven compression, re-evaluates, then HANDOFFs. Clean sequential flow but holds a managed `@ObservesAsync` executor thread for seconds to minutes per channel. Shared thread pool — one slow redistribution delays all other async CDI event processing.
- Two-phase event (option 3) — executor fires `CompressionRequestedEvent`, re-evaluates on `CompressionCompletedEvent`. Non-blocking with precise timing, but requires cross-event state correlation, two new CDI event types, and timeout handling. The sweep cycle already provides this coordination for free.
- Drop compression entirely (option 4) — treat Compress as Hold, only act on Redistribute and Escalate. Simplest executor but discards a potentially effective intervention. Channel summaries directly reduce context window tokens for multi-channel agents (the common case).
**Rationale:** The sweep cycle is the re-evaluation mechanism — it runs every 60s, queries ground truth (current obligations and pressure), and re-triggers the policy. Compression gets a fair shot (one sweep interval), and if it doesn't help, the policy naturally escalates via pressure thresholds. The two guards cover the only STUCK failure mode (F6: no routing targets) and prevent waste (F3/F5: repeated compression). 10 failure modes were analyzed; 1 STUCK (fixed by guard #2), 4 WASTEFUL (3 fixed by guard #1, 1 harmless), 5 HARMLESS (self-correcting). Crash recovery is free — next sweep reads current state.
**Trade-offs:** 60s delay between compression and re-evaluation (acceptable — summaries are background artifacts). Grace period introduces an implicit per-actor cooldown derived from the commitment store — not new state but a query of existing data. The executor remains stateless across sweeps. Stale signals (F4) can cause wasteful redistribution but not corruption — could add observedAt age check as a future refinement.
**Depends on:** D2 (domain executor as context composer), D3 (max-pressure aggregation), D5 (circular guard is executor concern)
**Sources:** `ChannelSummaryService.triggerUpdate()` (qhorus), `CommitmentService.delegate()` (qhorus), `RoutingBridge.resolve()` (qhorus), GE-20260605-373190 (@ObservesAsync + @RequestScoped), GE-20260512-6887c9 (@ObservesAsync + @Transactional), GE-20260517-e10a0f (HANDOFF commitment gotcha), GE-20260602-6941d6 (separate @Transactional delegate)
**Exploration:** deep-analysis
**Status:** revised (R1-04: grace period field now respected by executor; also addresses R1-02 oscillation prevention)

## D8: Cross-channel global query for ContextPressureCapacitySource

**Choice:** New `findLatestContextPressureGlobal()` method on `MessageLedgerEntryRepository` — single SQL query across all channels and tenants, returns latest `contextWindowPct` per actorId via MAX(sequenceNumber) grouping — the most recent measurement per actor is the correct reading of a shared physical resource, not a statistical aggregate. `ContextPressureCapacitySource` injects this directly.
**Alternatives:**
- Iterate all channels via `crossTenantChannelStore.listAll()` + existing per-channel `findLatestContextPressure()` — reuses existing code but O(channels) queries, N+1 pattern, inefficient at scale.
**Rationale:** Capacity signals are tenant-agnostic (D4). A single `GROUP BY actorId` query is both simpler and more efficient. The watchdog's per-channel iteration is legacy design — the signal source should not copy it.
**Trade-offs:** New repository method to maintain. Requires an index with `actorId` as a leading column for efficient GROUP BY — without it, the query degrades to a sequential scan on the ledger table.
**Depends on:** D4 (tenant-agnostic signals)
**Sources:** `MessageLedgerEntryRepository.findLatestContextPressure()` (qhorus), `WatchdogEvaluationService.evaluateContextPressure()` (qhorus)
**Exploration:** quick
**Status:** revised (R1-05: aggregation semantics specified as most-recent-per-actor; index requirement noted)

## D9: Module placement — executor in runtime, event in api

**Choice:** `ContextPressureCapacitySource` and `QhorusRedistributionExecutor` in qhorus-runtime (`io.casehub.qhorus.runtime.capacity`). `RedistributionExecutedEvent` in qhorus-api (`io.casehub.qhorus.api.capacity`).
**Alternatives:**
- Executor in a separate qhorus module (e.g., `capacity/`) — unnecessary isolation for a single class with runtime-internal dependencies.
- Event in runtime — prevents external modules (notification-bridge) from observing without depending on runtime.
**Rationale:** Executor depends on runtime-internal classes (`RoutingBridge`, `ChannelSummaryService`, `CommitmentService`, `MessageLedgerEntryRepository`). Event in api follows the existing pattern (`CommitmentDeclinedEvent`, `CommitmentExpiredEvent` in qhorus-api).
**Trade-offs:** None significant.
**Sources:** `CommitmentDeclinedEvent` (qhorus-api), `RoutingBridge` (qhorus-runtime)
**Exploration:** quick
**Status:** captured

## D10: Capability tag on Commitment for redistribution target resolution

**Choice:** Add `capabilityTag` (String, nullable) to the `Commitment` record. Populated at commitment creation when the dispatch was role-routed (`role:X` target). Null for directly-addressed commitments. The executor reads this directly — null means "skip, don't redistribute explicitly-addressed work."
**Alternatives:**
- Read from ledger (`MessageLedgerEntry.routingOriginalTarget`) — reconstructs data from audit history that should have been captured at creation time. Indirect lookup, design smell. Additional query per commitment during redistribution.
**Rationale:** The commitment data model is incomplete without the capability context. It already has who (requester/obligor), where (channelId), what type (messageType) — `capabilityTag` adds "for what capability." Pre-release, schema change cost is zero. Also enables obligation analytics and routing diagnostics beyond redistribution.
**Trade-offs:** One more field on Commitment record, entity, store implementations, and migration. Pre-release — cost is zero. Deployment constraint: capacity redistribution via HANDOFF requires `casehub-eidos` on the classpath for `AgentRegistry` resolution. Without eidos, `RoutingBridge.resolve()` returns null, no HANDOFF targets can be resolved, and D7's guard #2 correctly falls back to Escalate. Direct-addressed commitments (`capabilityTag = null`) are inherently non-redistributable — the executor skips them and falls through to Escalate if all obligations are direct-addressed.
**Depends on:** D7 (executor needs capability to resolve HANDOFF targets)
**Sources:** `Commitment.java` (qhorus-api), `RoutingBridge.resolve()` (qhorus-runtime), `MessageLedgerEntry.routingOriginalTarget` (qhorus-runtime)
**Exploration:** quick
**Status:** revised (R1-06: eidos deployment dependency and direct-addressed limitation documented)

## D11: Executor CDI design — delegate pattern for @ObservesAsync

**Choice:** `@ApplicationScoped` executor with `@ObservesAsync` handler. Delegates transactional work (commitment queries, HANDOFF dispatch) to a separate `@ApplicationScoped @Transactional` delegate bean. Uses `CrossTenantCommitmentStore` for obligation queries — requires two new methods: (1) `findOpenByObligor(String obligor)` — cross-tenant equivalent of the existing `CommitmentReader` default method, returns active (OPEN/ACKNOWLEDGED) commitments; (2) `findLatestDelegatedByObligor(String obligor): Optional<Commitment>` — returns the most recently delegated commitment for the actor, ordered by `resolvedAt` DESC, used by D7's grace period mechanism to derive the last-redistribution timestamp. No `CurrentPrincipal` injection — HANDOFF dispatch sets `tenancyId` explicitly from the commitment's own `tenancyId` field.
**Alternatives:**
- Single class with `@ObservesAsync` + `@Transactional` — unreliable per GE-20260512-6887c9.
- Inject `CurrentPrincipal` with `ContextNotActiveException` catch — fragile, unnecessary when commitment already carries `tenancyId`.
**Rationale:** Direct application of existing qhorus patterns. `WatchdogEvaluationService` uses the same approach: `QhorusSystemCurrentPrincipal` + `CrossTenant*Store` for background operations.
**Trade-offs:** Two classes instead of one. Acceptable — the pattern is established and the separation is clean.
**Sources:** GE-20260605-373190 (@ObservesAsync + @RequestScoped), GE-20260512-6887c9 (@ObservesAsync + @Transactional), GE-20260602-6941d6 (separate @Transactional delegate), `WatchdogEvaluationService` (qhorus-runtime)
**Exploration:** quick
**Status:** revised (R1-07: findOpenByObligor; R2-02: findLatestDelegatedByObligor for grace period mechanism)

## D12: Event throttling strategy for CapacityPressureMonitor

**Choice:** No throttling on `CapacityPressureEvent` firing. The single-sweep design in `CapacityPressureMonitor` is the throttling mechanism — events fire once per sweep interval per overloaded actor, not per signal source or per data point.
**Alternatives:**
- Batch events (single event containing all overloaded actors) — changes CDI event contract, executors must iterate the batch rather than receiving per-actor events.
- Per-sweep parallelism cap (semaphore in executor) — limits concurrent executor work but doesn't reduce event count.
- Event deduplication (skip events for actors with in-flight executor work) — requires per-actor state in the monitor, breaking the stateless design.
**Rationale:** Pre-release fleet size is small (< 10 agents). Even with all agents overloaded, the event volume is manageable on the Quarkus managed executor thread pool. The sweep interval (60s default) naturally caps event frequency to at most N events per 60s where N is the overloaded agent count. If fleet size grows significantly, the executor can add a semaphore without SPI changes.
**Trade-offs:** Large fleets with many overloaded agents could saturate the `@ObservesAsync` thread pool with concurrent executor work. Acceptable pre-release — fleet scaling is a post-release concern.
**Sources:** R1-09 (implicit decision surfaced by reviewer)
**Exploration:** quick (implicit decision, not previously debated)
**Status:** captured
