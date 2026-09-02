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
