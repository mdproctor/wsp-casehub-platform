## D1: Separate CapacitySignalSource SPI, parallel to ActorStateContributor

**Choice:** New `CapacitySignalSource` SPI independent of `ActorStateContributor`. Different lifecycle — signals change frequently (per-sweep), actor state is queried on demand. Different consumers, different timing.
**Alternatives:**
- Extend ActorStateAccumulator with capacity methods — conflates snapshot (actor state) with continuous signal (capacity). Forces capacity consumers to depend on the full actor state pipeline.
**Rationale:** Capacity signals are orthogonal to actor state. The monitor sweeps on a schedule; the actor state aggregator responds to queries. Mixing them creates coupling between unrelated consumers.
**Trade-offs:** Two parallel CDI discovery paths (`Instance<ActorStateContributor>` and `Instance<CapacitySignalSource>`). Acceptable — the separation is semantic, not just structural.
**Sources:** `ActorStateContributor.java` (existing pattern), `ActorStateAccumulator.java` (existing accumulator)
**Exploration:** quick
**Status:** captured

## D2: Scalar pressure model (0.0–1.0)

**Choice:** `CapacitySignal` carries a single normalised `double pressure` value. 0.0 = idle, 1.0 = at capacity. Max-pressure aggregation across sources gives overall actor pressure.
**Alternatives:**
- Multi-dimensional signals (queue depth, response time, error rate) — richer but harder to aggregate and threshold. Premature for a first version.
- Enum levels (LOW/MEDIUM/HIGH/CRITICAL) — easy to threshold but loses granularity. Can't distinguish "almost high" from "barely medium". Hard to aggregate across sources.
**Rationale:** Scalar is composable (max, mean, weighted sum all work), thresholdable (operators set numbers), and extensible (sources can derive pressure from any internal metric). The loss of dimensionality is intentional — the policy layer doesn't need to know what causes pressure, only how much.
**Trade-offs:** Sources must normalise their internal metrics to 0.0–1.0. This is a feature, not a burden — it forces sources to define what "at capacity" means.
**Sources:** Issue #268 ("max-pressure aggregation"), casehubio/qhorus#405
**Exploration:** quick
**Status:** captured

## D3: SPIs and records in platform-api, implementations in platform/

**Choice:** All SPI interfaces and records in `platform-api/.capacity`. `AggregatingActorCapacityView`, `DefaultRedistributionPolicy`, and `CapacityPressureMonitor` as `@ApplicationScoped` / `@DefaultBean` in `platform/`. Follows the existing pattern.
**Alternatives:**
- New `capacity/` Maven module — more isolation but adds a module for 3 implementation classes. Premature split.
**Rationale:** Consistent with how `platform-api/` and `platform/` work today. SPIs are zero-dependency. Implementations use CDI + config — already present in platform/.
**Trade-offs:** platform/ grows by 3 classes. Trivial.
**Sources:** `platform-api/.actor` (ActorStateContributor pattern), `platform/` (existing @DefaultBean implementations)
**Exploration:** quick
**Status:** captured

## D4: MicroProfile Config for default policy thresholds

**Choice:** `casehub.capacity.threshold.{compress,redistribute,escalate}` with sensible defaults (0.7, 0.85, 0.95). Operators tune without code.
**Alternatives:**
- CDI @Alternative only — hardcoded defaults, full policy replacement required to change thresholds. Simpler but operators can't tune without writing Java.
**Rationale:** Consistent with how platform/ configures other defaults. Thresholds are the most commonly tuned parameter — making them config-driven is the minimum viable flexibility.
**Trade-offs:** Adds 3 config keys + a @ConfigMapping interface. Trivial.
**Sources:** `platform/` existing @ConfigProperty patterns, governance module
**Exploration:** quick
**Status:** captured

## D5: Source-provides-all signal collection

**Choice:** `CapacitySignalSource.signals()` returns all current signals across all actors. The monitor sweeps all sources periodically; the aggregator filters by actor.
**Alternatives:**
- Per-actor method `signal(String actorId)` — requires the monitor to know which actors to check. Source-provides-all is simpler and bounded by active actors.
**Rationale:** The monitor needs to detect pressure across all actors, not query specific ones. Sources know which actors they're tracking (work queues, channel assignments). The full list is bounded by active actor count, not total actors.
**Trade-offs:** Each sweep gets all signals from all sources. For O(actors × sources) total signals, this is fine — both are small numbers in practice.
**Sources:** `ActorStateContributor.contribute()` (per-actor pattern — deliberately not followed here)
**Exploration:** quick
**Status:** captured

## D6: CDI event for pressure decisions, not for raw signals

**Choice:** `CapacityPressureEvent` fired only when `RedistributionDecision.action() != NONE`. Raw signals stay internal to the capacity subsystem.
**Alternatives:**
- Fire events for every signal change — noisy, consumers must filter. Most signal changes don't cross thresholds.
- Fire events only for ESCALATE — misses COMPRESS and REDISTRIBUTE which are equally actionable.
**Rationale:** Events are for action triggers, not data feeds. The view SPI (`ActorCapacityView`) serves diagnostic/query needs. Events serve "something needs to happen" needs.
**Trade-offs:** Consumers that want raw signal data use ActorCapacityView directly. Acceptable — that's the query path.
**Sources:** `SubscriptionMatched` CDI event pattern (action-triggered, not data-feed)
**Exploration:** quick
**Status:** captured
