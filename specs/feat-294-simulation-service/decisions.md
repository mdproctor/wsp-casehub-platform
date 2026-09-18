# Simulation Service Design Decisions

## D1: Initial scope — simulation + capture together

**Choice:** Design both simulation mode (providing responses when no real impl wired) and capture mode (recording real SPI calls for corpus building) in the initial design.
**Alternatives:**
- Simulation first — simpler initial scope but corpora need manual seeding, cold-start problem worse
- Capture first — builds corpora but no way to use them until simulation is designed
**Rationale:** Capture feeds simulation — they're two halves of the same lifecycle. Designing them together ensures the corpus contract serves both sides.
**Trade-offs:** Larger initial design surface. Capture requires CDI @Decorator infrastructure on top of the NoOp upgrade pattern.
**Sources:** Epic #294, cross-repo interaction map
**Exploration:** quick
**Status:** captured

---

# Phase 3 — #317 NearestMatchStrategy

## D17: Generic SimilarityScorer<I> in simulation-api, not CBR reuse

**Choice:** Define `SimilarityScorer<I>` as a `@FunctionalInterface` in simulation-api (`double score(I query, I candidate)`). NearestMatchStrategy takes this interface. No dependency on neocortex-memory-api's CBR infrastructure.
**Alternatives:**
- Direct CBR reuse — NearestMatchStrategy takes CbrSimilarityScorer + CbrFeatureSchema directly. Tight coupling, wrong dependency direction (simulation is platform, CBR is neocortex).
- Shared similarity-core module — extract CBR's similarity primitives into a shared module. Clean but requires migration for marginal reuse.
**Rationale:** CBR's `CbrSimilarityScorer` operates on `Map<String, FeatureValue>` with `CbrFeatureSchema` — domain-specific to case retrieval. Simulation operates on arbitrary SPI input types. Forcing inputs through CBR's type system is unnatural. The bridge to CBR is a consumer concern: implement `SimilarityScorer<I>` by converting to FeatureValue maps and delegating to CbrSimilarityScorer. This keeps simulation-core zero-dep on neocortex.
**Trade-offs:** No shared similarity primitives — per-field scoring functions (exact, numeric range, Jaccard) are reimplemented in simulation-core's `RecordFieldScorer`. Acceptable because the implementations are trivial (1-3 lines each) and the abstraction levels differ.
**Sources:** CbrSimilarityScorer.java (neocortex-memory-api), LocalSimilarityFunction.java, SimilaritySpec.java, KeyExtractor.java (simulation-api parallel)
**Exploration:** quick (first-principles analysis confirmed spec's existing direction)
**Status:** captured

## D18: Programmatic builder + declarative config factory (both, not either/or)

**Choice:** `RecordFieldScorer<I>` provides a programmatic builder API for power users. `DeclarativeScorerFactory` (in simulation-config-core) parses config strings into RecordFieldScorer instances — parallel to `DeclarativeExtractorFactory` for KeyExtractors. Both coexist.
**Alternatives:**
- Programmatic only — YAGNI the declarative path. But #329 (strategy configuration) and #330 (domain configuration) are planned; programmatic-only forces a retrofit.
- Declarative only — all scorers from config. Loses type safety and complex scoring (custom lambdas, domain logic).
**Rationale:** #325 established the `DeclarativeExtractorFactory` pattern — config strings → functional instances. NearestMatch follows the same trajectory. The programmatic API handles complex cases; the declarative factory handles common cases via config. #329/#330 extend the declarative layer without reworking NearestMatch.
**Trade-offs:** Two paths to the same result (code vs config). Acceptable — same pattern as KeyExtractor.
**Sources:** DeclarativeExtractorFactory.java (simulation-config-core), #329, #330
**Depends on:** D16 (Jackson ObjectMapper.convertValue for field access — same mechanism reused)
**Exploration:** quick (user correction on YAGNI call)
**Status:** captured

## D19: Threshold as config property, no-match throws SimulationNoMatchException

**Choice:** Threshold is a config property (`casehub.simulation.<spi>.<method>.threshold=0.7`, default 0.0). When no corpus entry exceeds the threshold, `canResolve()` returns false (strategy declines, decorator falls through to delegate). When `resolve()` is called and no match exceeds threshold, throw `SimulationNoMatchException`.
**Alternatives:**
- Threshold on the scorer — couples scoring and matching decisions. Scorer should only score; the strategy decides what's "good enough."
- Fall through silently — return null or empty. Violates the strategy contract (resolve must return a value or throw).
**Rationale:** `canResolve()` + `resolve()` contract from `SimulationStrategy<I, O>` already handles this. The decorator checks `canResolve()` first — if false, it delegates to the real backend. Threshold on the strategy (not the scorer) keeps concerns separate.
**Trade-offs:** Default threshold 0.0 means any match wins — may return poor matches. Acceptable for dev/test; production simulation configs should set explicit thresholds.
**Sources:** SimulationStrategy.java (canResolve/resolve contract), SimulationDecoratorProcessor generated code
**Exploration:** quick
**Status:** captured

## D20: O(n) corpus scan, no indexing

**Choice:** NearestMatchStrategy scans all corpus entries for the qualified name, scores each, returns the best above threshold. No indexing, no pre-filtering.
**Alternatives:**
- Pre-index corpus entries by key dimensions — amortised lookup. But corpora are small (10-50 entries in test fixtures) and the scan runs in dev/test, not production hot paths.
- Approximate nearest neighbor (ANN) — vector-based. Overkill for small corpora; introduces embedding dependency.
**Rationale:** Issue #317 says "naive O(n) scan first, optimise later." Corpora are small. The SimilarityScorer is called per-entry — for 50 entries with a simple field scorer, this is sub-millisecond.
**Trade-offs:** Doesn't scale to large corpora (1000+ entries). If needed, add optional indexing as a follow-on — the strategy contract doesn't change.
**Sources:** Issue #317 ("Corpus indexing — efficient lookup in large corpora. Naive O(n) scan first, optimise later.")
**Exploration:** quick
**Status:** captured

## D2: SPI types live in a dedicated simulation-api module

**Choice:** Simulation SPI types (SimulationStrategy, SimulationCorpus, InvocationRecord, etc.) live in a new `simulation-api` module, not in `platform-api`.
**Alternatives:**
- In platform-api — every SPI already depends on platform-api, so simulation types would be universally available. But platform-api's zero-dep constraint limits evolution, and the surface area will grow (strategy, corpus, key extractor, scorer, invocation records).
- In platform-core — but platform-core depends on platform-api, so SPIs end up there anyway
**Rationale:** Platform-api boundary rule: "A type or SPI belongs in platform-api only if multiple peer repos need it and cannot share it by depending on a single domain api/ module." Simulation types are consumed by NoOp wrappers and capture decorators — not by SPI method signatures across peer repos. CaseMemoryStore's migration from platform-api to neocortex/memory-api (neocortex#56) shows the cost of starting in platform-api: extraction is mechanical but disruptive. Starting in a dedicated module avoids that migration. The epic's Phase 1 (issue #312) already proposes `simulation-api` as a module.
**Trade-offs:** Consumers of simulation must add `simulation-api` as an explicit dependency. This is the correct trade-off — simulation is opt-in, not universal.
**Sources:** Capability Ownership doc (boundary rules), CaseMemoryStore migration (neocortex#56), epic #294 Phase 1, platform-api-scope protocol
**Exploration:** quick
**Status:** revised (R1-04: reviewer correctly identified that platform trajectory contradicts original placement; CaseMemoryStore migration is compelling precedent)

## D3: Generic `<I, O>` contract for SimulationStrategy

**Choice:** `SimulationStrategy<I, O>` where I captures the invocation context and O is the response type. Per-SPI adapters define their own I and O types.
**Alternatives:**
- Untyped Map-based — universal but loses type safety, requires serialization at every boundary
- Sealed types — type-safe at boundary but requires extending sealed hierarchy per SPI
**Rationale:** Clean, type-safe. Each SPI adapter defines its own input/output record types. The strategy contract doesn't know about specific SPIs. Per-SPI adapters are small and mechanical.
**Trade-offs:** Requires an adapter per SPI. But that adapter is where the SPI-specific key extraction and response shaping lives anyway — it's not overhead, it's design.
**Sources:** AgentProvider SPI shape, CaseMemoryStore SPI shape (different signatures prove the need for generic typing)
**Exploration:** quick
**Status:** captured

---

## D4: Annotation-driven generated @Decorator for capture and simulation

**Choice:** A `@SimulationEligible` annotation on SPI interfaces triggers an annotation processor (sibling to `CallbackDecoratorProcessor`) that auto-generates a CDI `@Decorator` per SPI. The generated decorator handles both capture mode (recording input/output to corpus when a real impl is active) and simulation mode (delegating to a SimulationStrategy when no real impl is active). One generated decorator per SPI replaces both hand-written capture decorators AND NoOp modifications.
**Alternatives:**
- Hand-written CDI @Decorator per SPI — requires implementing all abstract methods manually (GE-20260818-2589ee); boilerplate-heavy with 13+ SPIs across 10 repos
- Extend @CallbackEligible directly — wrong semantics; callbacks invoke external webhooks, capture/simulation records/produces data. The generation mechanism is reusable but the annotation semantics must be distinct
- CDI @Interceptor with @Capturable annotation — interceptors can't easily access method-specific context
**Rationale:** The platform already has `CallbackDecoratorProcessor` (in `callback-generator/`) that auto-generates `@Decorator` classes from `@CallbackEligible` annotations via Jandex index scanning. The pattern — read annotated interfaces, generate decorators that implement all methods — is proven and solves the "must implement all abstract methods" trade-off automatically. A sibling `SimulationDecoratorProcessor` reuses the same generation technique but with different decorator logic: config-driven simulation/capture behavior instead of callback fan-out.
**Trade-offs:** Two annotation processors exist (callback + simulation) with similar generation patterns. If this becomes a pattern, the generation framework could be extracted. @PostConstruct skip (GE-20260806-93549d) and double-application risk (GE-20260620-9d043b) apply equally to generated decorators — mitigation is in the generated code template.
**Sources:** `CallbackEligible` annotation (platform-api), `CallbackDecoratorProcessor` (callback-generator/), GE-20260818-2589ee, GE-20260806-93549d, GE-20260620-9d043b
**Exploration:** quick
**Status:** revised (R1-03: reviewer correctly identified that the annotation processor infrastructure already solves the boilerplate problem; combined with R1-05 to unify capture and simulation into a single generated decorator)

## D5: SimulationCorpus follows store pattern in simulation-api

**Choice:** `SimulationCorpus<I, O>` SPI in `simulation-api` (following D2 revision), with NoOp @DefaultBean, InMemory @Alternative, and filesystem @Alternative backends. Same displacement ladder as every other platform store.
**Alternatives:**
- Generic key-value store — loses type safety at storage layer
- Embedded in strategy — each strategy owns its data. No shared storage for capture mode
- JPA backend — adds database survival but corpora are fixtures/snapshots, not transactional business data
**Rationale:** Follows the established casehub store pattern (NotificationStore, PreferenceStore in platform-api; CaseMemoryStore in neocortex/memory-api). Corpus is per-SPI, per-scenario. InMemory for test isolation, filesystem for persistent fixtures and captured corpora. JPA is intentionally omitted in the initial design: captured corpora are exported as fixture files, not stored as transactional entities. If persistence across deployments becomes a requirement, JPA can be added as a follow-on module.
**Trade-offs:** Requires a corpus instance per SPI type (because of the generic typing). But CDI handles this via qualifier or producer methods. No JPA means corpora don't survive without filesystem — intentional for initial scope.
**Sources:** Existing store pattern (NotificationStore in platform-api, PreferenceStore in platform-api, CaseMemoryStore in neocortex/memory-api)
**Exploration:** quick
**Depends on:** D2 (module placement)
**Status:** revised (R1-07: location updated to follow D2; corrected store pattern precedent citations — SPIs are in platform-api not platform-core; JPA omission rationale made explicit)

## D6: Generated @Decorator activates simulation — NoOps remain untouched

**Choice:** The generated `@Decorator` from D4 handles simulation activation. NoOp implementations remain zero-dependency, zero-logic silent fallbacks. When simulation config is present (`casehub.simulation.<spi>.strategy=key-lookup`), the decorator delegates to the configured SimulationStrategy instead of the delegate bean. When no simulation is configured, the decorator passes through to the delegate (which may be a NoOp or a real implementation).
**Alternatives:**
- Modify NoOps in-place — adds SimulationStrategy constructor parameter, breaks the universal zero-dependency NoOp contract (40+ NoOps in the codebase follow this contract), forces downstream tests to provide a strategy or pass null
- Separate simulation beans (@Alternative @Priority(50)) — would displace NoOps when present, but @Alternative @Priority(N) beans win over normal @ApplicationScoped real implementations in Quarkus CDI. The simulation bean would incorrectly beat real implementations, not just NoOps
- Strategy-aware base class — abstract base that NoOps extend. Adds inheritance to classes defined by their simplicity
**Rationale:** The 40+ NoOps in the codebase are architecturally load-bearing: zero dependencies, zero constructor params, trivially constructable in tests. The @Decorator approach preserves this contract. The decorator wraps whatever bean is active — when it's a NoOp and simulation is configured, the strategy provides responses. When it's a real implementation, the decorator passes through (or captures, per D4). The CDI priority ladder is not used for simulation activation — config-driven behavior in the decorator is the correct mechanism.
**Trade-offs:** The decorator adds a layer of indirection on every SPI call when simulation module is on the classpath. Performance overhead is negligible for the use case (dev/test environments, not production hot paths).
**Sources:** 40+ NoOp implementations (all zero-dependency), Demo SPI Convention priority table, CDI @Alternative resolution rules
**Exploration:** quick
**Depends on:** D4 (generated decorator), D3 (strategy contract shape)
**Status:** revised (R1-05: reviewer correctly identified that NoOps must remain silent — the universal zero-dependency contract is load-bearing; the @Alternative @Priority(50) approach was also considered but rejected because it has CDI resolution issues with real implementations)

## D7: Key extraction owned by strategy

**Choice:** Each strategy defines how it matches inputs. KeyLookupStrategy has a `KeyExtractor<I>`, NearestMatchStrategy has a `SimilarityScorer<I>`. The strategy owns matching semantics.
**Alternatives:**
- On the corpus — corpus handles indexing and retrieval. Simpler strategy interface but corpus becomes smarter
- Separate KeyFunction SPI — independent abstraction. Maximum flexibility but another layer
**Rationale:** Different strategies match differently — key-based lookup needs exact keys, nearest-match needs similarity scores, sequential strategy ignores input entirely. Matching semantics are inherently strategy-specific.
**Trade-offs:** Per-SPI KeyExtractors need writing. But they're functional interfaces — typically one-liners.
**Sources:** Strategy table from epic #294
**Exploration:** quick
**Depends on:** D3 (strategy contract)
**Status:** captured

## D8: Unified contract for request/response and events

**Choice:** Events use the same `SimulationStrategy<I, O>` contract. A trigger (scheduled tick, scenario step, manual) serves as the input. Corpus, seeding, and capture all work identically for events.
**Alternatives:**
- Separate EventSimulationStrategy — explicit timing, ordering, fan-out concerns. But duplicates infrastructure
- Defer events — focus on request/response first. But events are needed for end-to-end scenario testing
**Rationale:** Events are just another output type. The simulation framework should not care whether it's responding to a request or generating an event. Unified infrastructure reduces surface area.
**Trade-offs:** Event timing/scheduling needs to be handled outside the strategy (by whatever triggers the strategy). The strategy itself is stateless — it resolves one event per invocation.
**Sources:** DataSourceRegistry SPI, CloudEvent patterns in engine/work/blocks
**Exploration:** quick
**Status:** captured

---

## D9: Simulation service is distinct from Demo SPI Convention

**Choice:** The simulation service is a separate infrastructure from the Demo SPI Convention and the cross-platform Scenario Engine. They are complementary, not overlapping.
**Alternatives:**
- Extend Demo SPI Convention with corpus-backed demo implementations — use `@IfBuildProfile("demo")` for simulation beans
- Make simulation a strategy provider for the Scenario Engine — the scenario engine triggers simulation strategies
- Merge all three into a unified testing/demo infrastructure
**Rationale:** The Demo SPI Convention (documented in `parent/docs/platform/demo-spi-convention.md`) targets **connector SPIs** (ChatPlatform, CalendarPlatform) representing external integrations. It uses `@IfBuildProfile("demo")` — a **compile-time gate** where demo code is absent from production builds. It serves pre-loaded datasets via bootstrap endpoints. The simulation service targets **platform SPIs** (AgentProvider, CaseMemoryStore, etc.) and operates at **runtime** via config-driven strategy selection. Key differences: (1) Scope: connectors vs platform SPIs. (2) Activation: build profile (compile-time) vs configuration (runtime). (3) Data: pre-loaded datasets vs corpus-backed strategies with 5 resolution modes. (4) Capture: Demo convention is one-way (provide data); simulation captures real SPI traffic bidirectionally. The Scenario Engine (ScenarioExecutor in casehub-pages) orchestrates multi-step scenarios across services — it's an **orchestrator** that could use simulation as one of its backends. A scenario step could configure simulation strategies for the SPIs it needs.
**Trade-offs:** Three related-but-distinct systems (demo convention, scenario engine, simulation service) require clear documentation of their boundaries. The boundary: Demo Convention = connector-level, compile-gated, profile-switched. Scenario Engine = cross-service orchestration, step-driven. Simulation Service = SPI-level, config-driven, corpus-backed.
**Sources:** Demo SPI Convention (parent/docs/platform/demo-spi-convention.md), Scenario Format (parent/docs/platform/scenario-format.md), ScenarioExecutor (casehub-pages)
**Exploration:** quick (surfaced by review R1-02, R1-11)
**Status:** captured

## D10: Corpus design is tenant-aware

**Choice:** SimulationCorpus is tenant-scoped. Corpora are stored and retrieved per-tenant. Capture mode records the tenant context of each invocation. Strategy resolution is tenant-scoped by default.
**Alternatives:**
- Tenant-agnostic corpora — simpler storage, but violates the platform's universal tenant-isolation contract
- Per-tenant strategies — different simulation strategies per tenant. Possible but deferred to later phase
- Cross-tenant admin corpus sharing — admin can share corpora across tenants. Supported via the existing `isCrossTenantAdmin()` mechanism
**Rationale:** Every store, SPI, and data-access layer in the platform is tenant-aware (`MemoryPermissions.assertTenant()`, `EndpointPermissions.assertTenant()`, tenant-scoped queries everywhere). Protocol PP-20260520-439daf mandates unconditional tenancy filtering. The simulation corpus must follow this platform-wide contract.
**Trade-offs:** Tenant-scoped corpora mean captured data from one tenant cannot be used for simulation in another without explicit cross-tenant sharing. This is the correct security boundary.
**Sources:** MemoryPermissions.assertTenant(), EndpointPermissions.assertTenant(), Protocol PP-20260520-439daf (unconditional tenancy filtering)
**Exploration:** quick (surfaced by review R1-12)
**Status:** captured

## D11: Configuration is boot-time, not runtime-switchable

**Choice:** Simulation strategy selection is configuration-driven at boot time via `casehub.simulation.<spi>.strategy=<strategy-name>`. Strategies are not switchable at runtime without restart.
**Alternatives:**
- Runtime-switchable via MicroProfile Config hot-reload — strategies change without restart. Adds lifecycle complexity (strategy state, corpus re-binding)
- Per-scenario override via request header — different test scenarios use different strategies within the same boot. Adds request-scoped strategy resolution
- Per-environment profiles — CI uses different simulation config than local dev. Already handled by Quarkus profile-specific application.properties
**Rationale:** Boot-time configuration aligns with the CDI lifecycle — `@ApplicationScoped` strategy beans are created at startup. Runtime switching would require either re-creating CDI beans or adding indirection that complicates the strategy contract. Per-environment variation is already handled by Quarkus's multi-profile `application.properties` mechanism. Per-scenario override can be added as a later refinement if the scenario engine integration (D9) requires it.
**Trade-offs:** Restarting to switch strategies adds friction in interactive development. Mitigated by Quarkus dev mode's fast restart cycle.
**Sources:** Quarkus CDI lifecycle, MicroProfile Config hot-reload constraints
**Exploration:** quick (surfaced by review R1-13)
**Status:** captured

## D12: SimulationCorpus is distinct from CorpusSourceAdapter

**Choice:** `SimulationCorpus` (in `simulation-api`) and `CorpusSourceAdapter` (in `casehub-engine-api`) are separate concepts with different purposes. No naming change required.
**Alternatives:**
- Rename SimulationCorpus to avoid the "corpus" collision — e.g. SimulationFixtureStore, SimulationDataSet
- Unify the two corpus concepts — make SimulationCorpus an implementation of CorpusSourceAdapter
**Rationale:** `CorpusSourceAdapter` (in `io.casehub.api.spi`) provides case data to the orchestration engine — it adapts external case data sources for engine consumption. `SimulationCorpus` stores SPI invocation records (input/output pairs) for simulation strategy resolution. They live in different packages (`io.casehub.api.spi` vs a simulation package), serve different consumers (engine vs simulation framework), and have different type signatures. The "corpus" term is overloaded but the qualifier differentiates: `SimulationCorpus` vs `CorpusSourceAdapter`. The full qualified names are unambiguous.
**Trade-offs:** Two "corpus" concepts in the ecosystem. Documentation should note the distinction. Developers unfamiliar with both may initially confuse them.
**Sources:** CorpusSourceAdapter (casehub-engine-api, io.casehub.api.spi.CorpusSourceAdapter), NoOpCorpusSourceAdapter (engine runtime)
**Exploration:** quick (surfaced by review R1-14)
**Status:** captured

---

# Phase 2 — #325 YAML-driven simulation configuration

## D13: Config binding via manual prefix scanning (not @ConfigMapping)

**Choice:** Implement `SimulationConfig` by scanning `ConfigProvider.getConfig().getPropertyNames()` for the `casehub.simulation.*` prefix and parsing qualified names from keys.
**Alternatives:**
- @ConfigMapping with nested `Map<String, Map<String, MethodConfig>>` — type-safe but risks ghost entries when fixed sibling methods (e.g. `corpus()`) share the prefix (GE-20260609-4c6577), multi-level map silently returns `Optional.empty()` (GE-20260519-b9719e), and strict prefix ownership blocks `@ConfigProperty` under the same prefix (GE-20260612-ed9ff0)
- Hybrid (@ConfigMapping for shape, manual for discovery) — more code for marginal type-safety gain
**Rationale:** Five garden entries document SmallRye Config gotchas with the exact two-level dynamic key pattern this feature needs. Both precedent modules (endpoints-config, config) use `@ConfigProperty` + manual parsing, not `@ConfigMapping`. SimulationConfig is already a 3-method interface — the implementation is a thin wrapper over a `Map<String, MethodConfig>` built at startup.
**Trade-offs:** No IDE auto-completion for config keys. No SmallRye validation of typos. Acceptable because: (1) strategy names are already validated at runtime by SimulationRuntime.createStrategy(), (2) the config key namespace is documented in the guide.
**Sources:** GE-20260519-b9719e, GE-20260609-4c6577, GE-20260612-ed9ff0, GE-20260804-6076a3, endpoints-config/EndpointsConfigBeans.java, config/ConfigBeans.java
**Exploration:** quick
**Status:** captured

---

## D14: YAML corpus uses Object-typed input/output (no type-aware deserialization)

**Choice:** YAML corpus fixtures store input/output as native YAML types (String, Map, List, Number). `InvocationRecord<Object, Object>` is used for YAML-loaded entries. Type erasure means this works at runtime.
**Alternatives:**
- Jackson type-aware deserialization (input-type/output-type fields in YAML) — works but verbose YAML, fragile to refactoring
- JSON string serialisation — most control but ugly YAML
**Rationale:** YAML corpus is for quick scenarios and dev/demo environments. Typed corpus construction belongs to the programmatic API and corpus builders (#328). The simulation guide's DataRealism spectrum already classifies YAML fixtures as `DOMAIN_PLAUSIBLE`, not type-precise. Documenting the limitation is sufficient.
**Trade-offs:** SPIs with rich domain return types (e.g., `List<Memory>`) can't use YAML corpus directly — they need programmatic seeding. This is expected and documented.
**Sources:** InvocationRecord.java (generic record), simulation-guide.md (corpus population section), #328 (corpus builders)
**Exploration:** quick
**Status:** captured

---

## D15: Single module — simulation-config-core + simulation-config

**Choice:** All three deliverables (config binding, corpus populator, declarative extractors) live in one new module pair: `simulation-config-core` (POJO) + `simulation-config` (Quarkus beans).
**Alternatives:**
- Split into simulation-config + simulation-corpus-yaml — more granular, consumers who want config only don't pull Jackson. But adds a module for a startup-only concern.
**Rationale:** All three are startup-time configuration concerns sharing the `casehub.simulation.*` prefix. One module, one dependency to add. Follows the config/ and endpoints-config/ pattern.
**Trade-offs:** Consumers who only want config binding also get Jackson/SnakeYAML on the classpath. Acceptable — simulation is opt-in and the dependencies are transitives of Quarkus anyway.
**Sources:** config-core/ + config/, endpoints-config-core/ + endpoints-config/
**Exploration:** quick
**Status:** captured

---

## D16: Declarative KeyExtractors use Jackson ObjectMapper.convertValue for field access

**Choice:** Declarative extractors (`field:domain`, `composite:x,y`) convert typed SPI inputs to `Map<String, Object>` via Jackson `ObjectMapper.convertValue()`, then do map field access.
**Alternatives:**
- Reflection-based property access — no Jackson dep, but fragile, records need special handling, no nested path support
- Map-only (typed inputs not supported declaratively) — simplest but limits utility
**Rationale:** Jackson is already on the classpath for YAML corpus loading. ObjectMapper.convertValue handles records, POJOs, and Maps uniformly. Declarative extractors are convenience — complex extraction stays programmatic.
**Trade-offs:** Jackson conversion has overhead (serialise then deserialise). Acceptable at startup (extractor factory creates the lambda once) and acceptable per-call (simulation is not a hot path in production — it's dev/test).
**Sources:** KeyExtractor.java (FunctionalInterface), Jackson ObjectMapper API
**Exploration:** quick
**Status:** captured

---

# Phase 4 — #318 Event Simulation

## D21: Dedicated event-simulation-core module

**Choice:** New `event-simulation-core` module (POJO, no CDI) for the emitter logic and CloudEvent building. Paired later with `event-simulation` (Quarkus beans) for CDI wiring (`Event<CloudEvent>` injection, `@Produces` for the emitter).
**Alternatives:**
- In simulation-core — keeps module count down but mixes SPI interception strategies (zero-CDI POJOs) with event emission logic. simulation-core is currently a clean strategy-only module.
- In simulation-config-core — already has Jackson and startup concerns, but mixing config parsing with runtime event emission is a responsibility stretch.
**Rationale:** Event emission is a fundamentally different concern from SPI method interception. agent-simulation-core already established the pattern of domain-specific simulation modules separate from simulation-core. The *-core naming convention (POJO + Quarkus wrapper) is established across the platform.
**Trade-offs:** Another module pair. Acceptable — simulation is opt-in and the module boundary is clean. The core module depends on simulation-api (for SimulationStrategy, SimulationCorpus) and cloudevents-api (for CloudEvent building).
**Sources:** agent-simulation-core/ (precedent for domain-specific simulation module), simulation-core/ (strategy-only module to keep clean), GE-20260909-c81437 (module-core/module/module-spring naming convention)
**Depends on:** D2 (simulation-api as the SPI home)
**Exploration:** quick
**Status:** captured

## D22: CDI Event bus injection — full pipeline fidelity

**Choice:** SimulatedEventEmitter fires via `Consumer<CloudEvent>` callback (CDI wiring provides `Event<CloudEvent>.fireAsync()`). Events traverse DataSourceRouter's tenancy check and acceptedEventTypes filter before reaching wired DataSources.
**Alternatives:**
- Direct DataSource.add() — bypasses DataSourceRouter, injects straight into the alpha network. Faster but skips the routing/filtering layer that real events traverse.
- Both configurable — let config choose injection mode per emitter instance. More surface area for marginal benefit.
**Rationale:** The primary use case is pipeline testing — verifying end-to-end from event → DataSource → SubscriptionEngine → NotificationDispatcher. Full fidelity requires events to take the same path as real events. DataSourceRouter's tenancy check and acceptedEventTypes filter are part of the pipeline being tested. Direct injection would give false confidence by skipping routing.
**Trade-offs:** Requires properly constructed CloudEvents with `id`, `type`, `source`, `time`, `data`, and `tenancyid` extension. No shortcut past routing. Acceptable — CloudEvents are simple records and the corpus stores them complete.
**Sources:** DataSourceRouter.java (lines 159-188: tenancy check + acceptedEventTypes filter), WebhookResource.java (line 109-111: CDI bus pattern), KafkaStreamProcessor.java (lines 153-168: CloudEvent construction)
**Exploration:** quick
**Status:** captured

## D23: tick()-based emitter, not @Scheduled

**Choice:** Core logic in a `tick()` method that emits one batch of events per invocation. Tests call directly for deterministic, synchronous verification. No `@Scheduled` annotation — timed emission is #326's concern.
**Alternatives:**
- @Scheduled only — timer-driven emission. Tests must wait for scheduler ticks or mock the Quarkus scheduler. Matches the design spec's sketch but conflicts with pipeline testing needs.
- Both (tick() + @Scheduled wrapper) — core logic in tick(), separate @Scheduled bean calls tick() on interval. Clean separation but two beans for one concern in this issue; the @Scheduled wrapper is exactly what #326 delivers.
**Rationale:** Pipeline testing needs deterministic, synchronous invocation. DigestFlushScheduler and DeliveryRetryProcessor already use the tick() pattern successfully — both have a `tick()` method called externally, not @Scheduled. The @Scheduled wrapper is a thin layer that #326 adds for continuous background simulation.
**Trade-offs:** No continuous background emission until #326. Acceptable — the queue has #326 (timed simulation) as the next issue.
**Sources:** DigestFlushScheduler.java (tick() at line 49), DeliveryRetryProcessor.java (tick() at line 58), issue #326 (timed simulation)
**Exploration:** quick
**Status:** captured

## D24: Strategy resolves CloudEvent directly

**Choice:** `SimulationStrategy<EventTrigger, CloudEvent>`. The corpus stores complete CloudEvents (or serialisable templates). The emitter calls `strategy.resolve(trigger)` and fires the result via CDI bus.
**Alternatives:**
- Strategy resolves payload, emitter builds CloudEvent — `SimulationStrategy<EventTrigger, EventPayload>`. Strategy returns event data; emitter wraps in CloudEvent with id/type/source/time/tenancyid. More control over CloudEvent metadata at emission time but adds a fabrication layer between strategy and injection.
**Rationale:** Keeps the emitter thin — it's a loop over configured event sources calling `strategy.resolve()` then `fireAsync()`. CloudEvent metadata (type, source, tenancyid) is part of the corpus data, not fabricated at emission time. This aligns with D8 (unified contract for request/response and events) — events are just another output type. The corpus is the single source of truth for what gets emitted.
**Trade-offs:** Corpus entries must include full CloudEvent structure (type, source, tenancyid, data). Acceptable — CloudEvents are simple records with 5-6 fields. YAML fixtures express them naturally. Per-invocation metadata (id, time) can be stamped by the emitter after strategy resolution.
**Sources:** D8 (unified contract), CloudEventBuilder.v1() API, simulation-service-design.md (event simulation section)
**Depends on:** D8 (unified contract for events), D22 (CDI bus injection)
**Exploration:** quick
**Status:** captured

## D25: Scope — core emitter + injection only, timing deferred to #326

**Choice:** This issue delivers: EventEmitter with tick(), EventTrigger record, CloudEvent corpus fixtures, CDI bus injection. Sequential/key-lookup strategies from the existing framework handle event selection. No timing patterns (interval, jitter, burst) — those are #326.
**Alternatives:**
- Include timing patterns now — configurable interval, random jitter, burst mode. More complete but overlaps #326's explicit scope and adds complexity to the emitter's first iteration.
**Rationale:** Clean separation: #318 = what events to emit and how to inject them. #326 = when to emit them. The existing strategies (sequential, key-lookup, random) already handle the "what" selection from the corpus. The emitter's tick() provides the "how" injection. Timing is orthogonal.
**Trade-offs:** No background drip until #326. Acceptable — #326 is the next item in the queue.
**Sources:** Issue #318 (event simulation), issue #326 (timed simulation), .plan (queue position 8/18, #326 at position 9)
**Exploration:** quick
**Status:** captured

---

# Phase 5 — #326 Timed Event Simulation

## D26: Full scope — scheduler + timed sequences + timing preservation

**Choice:** All three deliverables: @Scheduled wrapper for continuous emission, TimedSequence with per-event delays, and corpus timing derivation from InvocationRecord.recordedAt().
**Alternatives:**
- Simple scheduler only — @Scheduled + CDI wiring. TimedSequence deferred. Smaller scope but leaves the timing model incomplete.
- Scheduler + TimedSequence only — without timing preservation. Corpora must be manually authored with delays. Misses the replay use case.
**Rationale:** The three deliverables form a coherent unit: TimedSequence is the data model, the scheduler executes it, and timing preservation populates it from real data. Splitting them creates a half-built system.
**Trade-offs:** Larger implementation scope. Acceptable — the pieces are well-defined and independent.
**Sources:** Issue #326, D8 (unified contract), D23 (tick() pattern), D25 (scope split with #318)
**Exploration:** quick
**Status:** captured

## D27: Relative delays between events

**Choice:** Each `TimedEntry` has a `Duration delay` relative to the previous entry. First entry's delay is the initial wait before the sequence starts.
**Alternatives:**
- Absolute offsets from sequence start — easier to reason about total timeline but requires arithmetic for inter-event gaps.
- Both (relative stored, absolute computed) — most flexible but adds API surface.
**Rationale:** Relative delays map naturally to captured timing gaps (gap between consecutive recordedAt timestamps). The scheduler sleeps for the delay, fires the event, sleeps for the next delay — no arithmetic needed. Absolute positions can be computed if needed: `sequence.entries().stream().mapToLong(e -> e.delay().toMillis()).sum()`.
**Trade-offs:** Computing "when does event N fire relative to sequence start?" requires summing delays. Acceptable — this is a rare query and trivial to compute.
**Sources:** InvocationRecord.recordedAt() (existing field), DigestFlushScheduler tick() pattern
**Exploration:** quick
**Status:** captured

## D28: Virtual-thread sleep for delay execution

**Choice:** The scheduler runs the timed sequence on a virtual thread. Between events, `Thread.sleep(delay)` pauses execution. The whole sequence is one blocking task.
**Alternatives:**
- ScheduledExecutorService — schedule each event as a separate task with computed delays. Non-blocking but harder to track sequence state, cancel, and report results.
- @Scheduled tick with internal clock — fixed-interval ticks check if the next event is due. No sleeping but tick interval limits timing resolution.
**Rationale:** Virtual threads make blocking sleep cheap — no platform thread consumed during the wait. The sequence runs as a coherent unit: start, sleep, emit, sleep, emit, done. Cancellation is a thread interrupt. Result reporting is a return value. The platform already uses virtual threads for blocking SPIs.
**Trade-offs:** Timing accuracy depends on OS scheduling — delays are minimum durations, not exact. Acceptable for simulation use cases (demo, testing, load replay).
**Sources:** Governance module (PolicyEnforcer uses Executors.newVirtualThreadPerTaskExecutor()), Java 21 virtual threads
**Depends on:** D26 (full scope includes scheduler)
**Exploration:** quick
**Status:** captured

## D29: TimedSequence in event-simulation-core, scheduler in event-simulation

**Choice:** `TimedSequence`, `TimedEntry`, time multiplier logic stay in `event-simulation-core` (POJO). The `@Scheduled` wrapper, CDI `Event<CloudEvent>` wiring, and `@Produces` beans go in a new `event-simulation` Quarkus module.
**Alternatives:**
- Everything in event-simulation — simpler module count but mixes pure data types with CDI. Breaks the *-core convention.
- Extend simulation-config — already has @Startup and config. But mixes event emission with general config.
**Rationale:** Follows the established *-core / Quarkus module split (D21, GE-20260909-c81437). TimedSequence is a pure data type — no reason to couple it to CDI. The Quarkus module is thin: wires the emitter with Event<CloudEvent> and adds @Scheduled.
**Trade-offs:** Two modules for event simulation. Acceptable — the split is clean and follows the platform convention.
**Sources:** D21 (event-simulation-core module), agent-simulation-core/ pattern, GE-20260909-c81437
**Depends on:** D21 (event-simulation-core exists)
**Exploration:** quick
**Status:** captured

## D30: Derive timing from InvocationRecord.recordedAt()

**Choice:** `TimedSequence.fromRecorded(List<InvocationRecord<I, O>>)` computes delays as gaps between consecutive `recordedAt` timestamps. No changes to the capture infrastructure or InvocationRecord data model.
**Alternatives:**
- Explicit delay field in InvocationRecord — more explicit but changes the universal data model. Simulation-specific timing metadata doesn't belong in the general-purpose record.
**Rationale:** InvocationRecord already stores `recordedAt` (an Instant). The timing information is there — it just needs to be extracted. A factory method on TimedSequence reads the existing data; no schema migration, no capture changes.
**Trade-offs:** Only works for captured data with real timing. YAML-authored corpora must specify delays explicitly (via TimedEntry constructor, not fromRecorded). This is fine — the two seeding paths are already distinct.
**Sources:** InvocationRecord.java (recordedAt field), simulation-api
**Exploration:** quick
**Status:** captured

## D31: Time multiplier on TimedSequence, not scheduler

**Choice:** `TimedSequence.withMultiplier(double)` returns a new sequence with all delays divided by the multiplier. Pure data transform — scheduler sleeps for whatever delay the sequence provides.
**Alternatives:**
- Multiplier on the scheduler — applies at sleep time. Preserves original timing data in the sequence but makes the scheduler aware of a concern it doesn't need to own.
**Rationale:** Keeps the scheduler simple — it just iterates entries and sleeps for the delay. The multiplier is a sequence construction concern, not a scheduling concern. `withMultiplier(10.0)` on a 30-minute patient case gives a 3-minute demo — the scheduler doesn't need to know this happened.
**Trade-offs:** Original timing is lost after `withMultiplier()`. The caller can always keep a reference to the original sequence. Not a concern in practice — the multiplied sequence is created for a specific run.
**Sources:** Issue #326 (time multiplier for fast-forward), D27 (relative delays — multiplier divides each delay)
**Depends on:** D27 (relative delays)
**Exploration:** quick
**Status:** captured

---

# Phase 6 — #319 REST Client Simulation

## D32: Separate RestClientSimulationProcessor (not extending the base generator)

**Choice:** Create a dedicated `RestClientSimulationProcessor` APT in a new `rest-client-simulation-generator` module. Detects `@RegisterRestClient` interfaces, generates `@Decorator` with `@RestClient`-qualified delegate, reads JAX-RS annotations for HTTP metadata. Reuses SimulationRuntime, strategies, corpus, config from the existing framework.
**Alternatives:**
- Extend existing SimulationDecoratorProcessor — simpler but adds Quarkus REST client awareness to a currently framework-agnostic generator (R1-06)
- Hand-written decorators per client — doesn't scale (5 GitHub clients in devtown alone)
- HTTP-layer interceptor (ClientRequestFilter) — loses type safety, reinvents WireMock
**Rationale:** Keeping the base generator clean preserves its framework-agnosticism. A separate processor also solves the opt-in question — adding the processor module to your build IS the opt-in. The processor follows the same Jandex-scanning pattern as the base generator.
**Trade-offs:** One additional module (`rest-client-simulation-generator`). Acceptable — the processor has distinct concerns (JAX-RS annotation reading, @RestClient qualifier, RestInvocation construction) that don't belong in the base generator.
**Sources:** SimulationDecoratorProcessor.java, decision review R1-06 (framework-agnosticism), R1-03 (opt-in pattern)
**Exploration:** quick → revised after decision review (light)
**Status:** revised

## D33: Hybrid input — Java method level interception with HTTP metadata

**Choice:** Intercept at the Java method level (consistent with Path A) but enrich the input with HTTP metadata extracted from JAX-RS annotations (`@GET`, `@Path`, `@QueryParam`). The hybrid is a strict superset of Java-only — HTTP metadata is optional for key extraction.
**Alternatives:**
- Pure Java method level — consistent with Path A but no HTTP-level key extraction. Limits corpus portability.
- Pure HTTP level — diverges from Path A, adds complexity, more appropriate for WireMock-style interception
**Rationale:** HTTP metadata is free at compile time (generator reads JAX-RS annotations). Adding it to the input enables richer key extraction (`GET /groups/*/members` vs just `membersOf`) without forcing consumers to use it. The Java-only path still works — just ignore the HTTP fields.
**Trade-offs:** RestInvocation is a richer type than raw Object[] parameters. Slightly more complex generated code. Strategy implementations receive RestInvocation instead of domain-specific types.
**Sources:** Issue #319 (mentions "extracts invocation context (method, path, params, body)")
**Exploration:** quick
**Status:** captured

## D34: RestInvocation record as uniform input type

**Choice:** A single `RestInvocation` record in simulation-core: `RestInvocation(String spiName, String methodName, String httpMethod, String pathTemplate, Map<String,Object> params, Object body)`. All REST client methods use this as the strategy input type. Self-describing for corpus entries.
**Alternatives:**
- Object[] parameter array — minimal but loses HTTP metadata and method identity
- Map<String,Object> named params — better than array but still no HTTP metadata
**Rationale:** Uniform type enables uniform key extractors. The record is self-describing: a corpus entry of `{spiName: "scim-client", methodName: "membersOf", httpMethod: "GET", pathTemplate: "/Groups/{id}/Members", params: {id: "grp-1"}}` is readable and portable.
**Trade-offs:** Strategy input is always RestInvocation, not domain-specific. Key extractors and scorers must work with RestInvocation rather than typed domain objects. For REST clients this is acceptable — the HTTP contract IS the domain.
**Depends on:** D33 (hybrid input)
**Sources:** SimulationStrategy<I,O> contract, existing Object-typed corpus (D14)
**Exploration:** quick
**Status:** captured

## D35: Auto-detect @RegisterRestClient — scoped by processor module opt-in

**Choice:** `RestClientSimulationProcessor` auto-detects all `@RegisterRestClient` interfaces in the Jandex index and generates decorators. The opt-in is at the module level: you add `rest-client-simulation-generator` as an APT dependency only in modules where you want REST client simulation. Derives spi-name from `configKey` attribute (falling back to kebab-cased class name).
**Alternatives:**
- Explicit @SimulationEligible required alongside @RegisterRestClient — adds friction and requires simulation-api dependency on every REST client module
- Listing file only (META-INF/simulation-eligible.txt) — no annotation dependency but manual maintenance
**Rationale:** The opt-in pattern is preserved at the module level (R1-03). Within a module that has opted in, auto-detection eliminates friction. The decorator is inert without config — `strategyFor()` returns empty, so the delegate is called directly.
**Trade-offs:** All `@RegisterRestClient` interfaces visible in Jandex get decorators when the processor is present. Acceptable — the module author chose to add the processor.
**Depends on:** D32 (separate processor)
**Sources:** Decision review R1-03 (opt-in pattern), @RegisterRestClient configKey attribute
**Exploration:** quick → revised after decision review (light)
**Status:** revised

## D36: New rest-client-simulation-generator module; RestInvocation + key extractor in simulation-core

**Choice:** New `rest-client-simulation-generator` module (`jar` packaging) for `RestClientSimulationProcessor`. `RestInvocation` record and `RestClientKeyExtractor` in simulation-core (not simulation-api).
**Alternatives:**
- Everything in existing modules — would pollute simulation-api with REST-specific types (R1-10) and the base generator with Quarkus-specific logic (R1-06)
- Full core/Quarkus split — heavy for S-scale
**Rationale:** simulation-api is a zero-dep pure Java SPI module — RestInvocation introduces REST coupling that doesn't belong there (R1-10). simulation-core already contains strategy implementations and is a compile dependency of consumer modules. The processor gets its own module because it has distinct concerns (JAX-RS annotation reading, @RestClient qualifier emission).
**Trade-offs:** One new module. Acceptable — the processor's Quarkus/MicroProfile dependencies don't belong in the framework-agnostic base generator.
**Depends on:** D32 (separate processor)
**Sources:** Decision review R1-06 (framework-agnosticism), R1-10 (API module coupling)
**Exploration:** quick → revised after decision review (light)
**Status:** revised

## D37: Defer reactive return type support — blocking only for now

**Choice:** Generate simulation only for blocking REST client methods. Skip `Uni<T>` and `Multi<T>` return types with a pass-through to the delegate.
**Alternatives:**
- Wrap strategy result in Uni/Multi at generation time — adds Mutiny type awareness to the processor for a capability not yet needed
**Rationale:** All current `@RegisterRestClient` interfaces in platform (ScimClient) are blocking. Mem0Client and GraphitiClient are in neocortex, not platform. No reactive REST clients exist to simulate (R1-13). When reactive clients appear, the extension is straightforward — the processor already inspects return types.
**Trade-offs:** Reactive REST clients won't be simulation-eligible until this is added. Acceptable — YAGNI.
**Depends on:** D32 (separate processor)
**Sources:** Decision review R1-13 (YAGNI), ScimClient (blocking return types verified)
**Exploration:** quick → revised after decision review (light)
**Status:** revised

---

# Phase 7 — #321 DefaultBean Simulation Patterns

## D38: Single platform-simulation-core module for all platform-api SPIs

**Choice:** One new `platform-simulation-core` module with a single `META-INF/simulation-eligible.txt` listing all 11 eligible platform-api SPIs. The APT generates 11 decorators at compile time; they're inert without config.
**Alternatives:**
- Listing file in simulation-config — muddies simulation-config's purpose (SmallRye Config binding) with decorator generation for platform-specific SPIs
- Per-domain modules (acl-simulation-core, notification-simulation-core, etc.) — creates 6+ modules for mechanical listing files in the same repo; the memory-simulation-core precedent applies to cross-repo SPIs, not same-repo
**Rationale:** All 11 SPIs are in platform-api in this repo. The decorator is inert without `casehub.simulation.<spi>.<method>.strategy=...` config — no cost to generating all 11 even if a consumer only simulates 2. One module, one dependency. Follows the memory-simulation-core precedent for listing-file-based generation.
**Trade-offs:** Consumers who want simulation for just one SPI still pull all 11 generated decorators onto the classpath. Acceptable — decorators without config are zero-overhead passthrough.
**Sources:** memory-simulation-core/src/main/resources/META-INF/simulation-eligible.txt, SimulationDecoratorProcessor.java (listing file path), DefaultBeans.java (all 35 NoOps)
**Exploration:** quick
**Status:** captured

## D39: PolicyEnforcer excluded — not an SPI interface

**Choice:** Exclude PolicyEnforcer from the listing. It's a concrete `@ApplicationScoped` class in the governance/ module, not an SPI interface. The simulation decorator pattern requires an interface to wrap.
**Alternatives:**
- Extract a PolicyEnforcer SPI interface — adds an interface for the sole purpose of simulation, when PolicyEnforcer is rarely swapped (it's generic retry/timeout machinery, not domain-specific)
- Wrap PolicyEnforcer via a different mechanism — CDI interceptor on the class. Adds complexity for marginal value
**Rationale:** The governance SPI types in platform-api are data records (ExecutionPolicy, RetryPolicy, CircuitBreakerPolicy) — configuration, not behaviour. PolicyEnforcer applies these policies. Simulating it means simulating retry/timeout behaviour, which is better tested by configuring the policy records themselves.
**Trade-offs:** No simulation path for PolicyEnforcer. Acceptable — you can already control its behaviour by configuring ExecutionPolicy records.
**Sources:** platform-api .governance package (ExecutionPolicy, RetryPolicy — data records), governance/ module (PolicyEnforcer — concrete class)
**Exploration:** quick
**Status:** captured

## D40: Single integration test for CDI ordering verification

**Choice:** One `@QuarkusTest` that verifies the generated decorator correctly wraps a `@DefaultBean` NoOp for one representative SPI (e.g. `AccessControlProvider`). Seeds a corpus, configures a strategy, and asserts the decorator intercepts the NoOp's response. The other 10 SPIs use identical generated code — testing each adds no coverage.
**Alternatives:**
- Test every generated decorator (11 tests) — proves every listing entry generates correctly, but the APT is deterministic and already tested in `SimulationDecoratorProcessorTest`. Coverage gain is marginal.
**Rationale:** The risk is CDI ordering (`@Decorator @Priority(APPLICATION + 200)` wrapping a `@DefaultBean`), not code generation correctness. One integration test proves the ordering. The APT's unit tests in simulation-generator already verify that listing-file-based generation produces correct Java source.
**Trade-offs:** If a specific SPI has an unusual method signature that the APT mishandles, it won't be caught until that SPI is used. Mitigated by the APT's existing method-signature test coverage.
**Sources:** SimulationDecoratorProcessorTest.java, SimulatedCaseMemoryStoreTest.java (precedent for single-SPI verification)
**Exploration:** quick
**Status:** captured

## D41: Platform SPI simulation section in the existing simulation guide

**Choice:** Add a "Platform SPIs" section to the existing simulation guide documenting which SPIs are available, their qualified names, and quick-start config snippets. No separate migration guide document.
**Alternatives:**
- Separate migration-guide.md — standalone document. More discoverable as a standalone artifact but fragments simulation documentation across two files
**Rationale:** The simulation guide already has "Quick start", "Named patterns", and "Core concepts" sections. A "Platform SPIs" table with qualified names and example config fits naturally after the existing content. Consumers already go to the simulation guide — don't split the docs.
**Trade-offs:** The guide grows longer. Acceptable — a table of 11 SPIs with qualified names is compact.
**Sources:** docs/guides/simulation-guide.md (existing structure)
**Exploration:** quick
**Status:** captured

## D42: Intercept all interface methods — remove abstract/default distinction

**Choice:** Remove the `isAbstract` check from `SimulationDecoratorProcessor`. All interface methods (abstract and default) get simulation interception logic. The config layer (`casehub.simulation.<spi>.<method>.strategy=...`) controls which methods are active — unconfigured methods passthrough regardless.
**Alternatives:**
- Listing file format extension (`FQCN=spi-name:method1,method2`) — backward compatible method specifiers. Unnecessary complexity for a pre-release codebase with one listing file.
- Intercept abstract only (status quo) — excludes pure-default interfaces like AccessControlProvider. Artificial limitation.
**Rationale:** The generator's abstract/default distinction was premature. The config layer is the real activation gate, not the generated code. Generating simulation logic for every method costs nothing when unconfigured (one ConcurrentHashMap lookup returning Optional.empty). This removes a category of "can't simulate this SPI" failures. AccessControlProvider (14 default methods, zero abstract) becomes simulatable.
**Trade-offs:** Slightly more generated code per decorator. Negligible — the methods are small and the overhead is a map lookup.
**Sources:** SimulationDecoratorProcessor.java (lines 159-166 — abstract/default branch), AccessControlProvider.java (pure-default interface)
**Exploration:** quick
**Status:** captured

---

# Phase 8 — #322 Pages Scenario Integration

## D43: Layered runtime overlay — no ThreadLocal

**Choice:** `SimulationRuntime` gains a stack of `SimulationOverlay` objects. `pushOverlay(config, corpus)` adds a layer; `popOverlay(overlay)` removes it. Strategy resolution walks the stack top-down — first overlay with a strategy for a given qualified name wins, then falls through to base config. No ThreadLocal anywhere.
**Alternatives:**
- ThreadLocal-scoped context — scope travels with execution thread. Rejected: ThreadLocal causes subtle bugs, leaks across pooled threads, and is hard to debug. Platform has near-zero ThreadLocal usage and should stay that way.
- Named scope registry — decorators look up active scope by name. Requires associating execution with a scope name — indirection without benefit over direct overlay.
- Config + corpus namespacing — prefix qualified names with a scope ID. Zero infrastructure but awkward and error-prone naming convention.
**Rationale:** Decorators already inject `SimulationRuntime`. The overlay stack is invisible to them — `strategyFor()` just returns a different result when an overlay is active. No API changes needed downstream. The push/pop model naturally supports mid-scenario switching (multiple layers). Sequential scenario execution (pages ScenarioOrchestrator is single-scenario) means no concurrency concerns on the stack.
**Trade-offs:** Global mutable state on SimulationRuntime — concurrent overlays from different callers would conflict. Acceptable because the scenario orchestrator is single-scenario and this is dev/test infrastructure.
**Sources:** SimulationRuntime.java (strategyFor, strategy cache), D11 (boot-time config — this extends D11 to support runtime overlays), ThreadLocal audit (UUIDv7 only, platform is clean)
**Depends on:** D11 (extends boot-time config)
**Exploration:** quick
**Status:** captured

## D44: Isolated corpus per overlay — no bleed between scenarios

**Choice:** Each `SimulationOverlay` gets its own fresh `InMemorySimulationCorpus`. Scenario seeds only its own data. On `popOverlay()`, the corpus is discarded. The base corpus (boot-time seeded) is only consulted when no overlay is active.
**Alternatives:**
- Layered corpus (overlay + fallback to base) — overlay checked first, then base. More flexible but scenarios can accidentally depend on base corpus state, creating hidden coupling.
- Same corpus, clear/restore — scenario clears relevant qualified names, seeds, runs, restores. Fragile — crash during scenario leaves corrupt corpus state.
**Rationale:** Clean isolation is the design constraint from #322. Each scenario should be fully self-contained. If a scenario needs base corpus data, it explicitly seeds it — no implicit inheritance. Discarding on pop guarantees no bleed.
**Trade-offs:** Scenarios can't "extend" base corpus data without re-seeding. Acceptable — explicit is better than implicit for test isolation.
**Sources:** InMemorySimulationCorpus.java (ConcurrentHashMap, seed/clear), issue #322 (design constraint: scenario isolation)
**Depends on:** D43 (overlay stack)
**Exploration:** quick
**Status:** captured

## D45: Invocation journal on overlay for assertion support

**Choice:** Each `SimulationOverlay` contains an `InvocationJournal` that records every intercepted call — `JournalEntry(qualifiedName, input, output, timestamp, simulated)`. The `simulated` flag distinguishes strategy-resolved calls from passthrough-to-delegate. After scenario execution, the caller queries the journal for assertions. Discarded with the overlay.
**Alternatives:**
- Reuse capture mode (corpus.record()) — conflates corpus building with assertion verification. Capture is for replay; journal is for inspection.
- CDI event-based — fire SimulationInvocationEvent on every call. More decoupled but adds CDI event overhead on every intercepted call in dev/test.
**Rationale:** The journal is a read-only record of what happened. Capture mode writes to the corpus for future replay — different purpose, different lifecycle. Keeping them separate means capture can be enabled independently (for corpus building) alongside the journal (for assertions). The journal is always active when an overlay is present — no config needed.
**Trade-offs:** Every intercepted call records a journal entry when an overlay is active. Acceptable — overlays are dev/test only, and the journal is an in-memory list.
**Sources:** Issue #322 (assertion support), InvocationRecord.java (similar shape — journal entry is lighter)
**Depends on:** D43 (overlay stack), D44 (isolated corpus)
**Exploration:** quick
**Status:** captured

## D46: Mid-scenario strategy switching included in initial design

**Choice:** Support `pushOverlay()` at any point during scenario execution. The overlay stack handles multiple layers. Strategy resolution walks top-down, so a new push shadows earlier overlays for the qualified names it declares. Strategy cache is invalidated per qualified name on push (not globally).
**Alternatives:**
- Defer to follow-on — simpler initial design (setup-once, run, teardown). But the overlay stack model supports this naturally; deferring adds no simplification.
- Step-level config in scenario YAML — each step declares its own overrides. Maximum flexibility but tightly couples platform API to scenario YAML schema.
**Rationale:** The push/pop model already supports multiple layers — "mid-scenario switching" is just "push another overlay." The strategy cache invalidation is per qualified name: when a new overlay declares a strategy for `agent-provider.invoke`, only that cache entry is evicted. Other cached strategies remain valid. The implementation cost is one cache eviction loop on push.
**Trade-offs:** Stack depth grows with mid-scenario pushes. All layers must be popped on teardown. Mitigated by `popAll()` convenience method on SimulationRuntime.
**Sources:** D43 (overlay stack), SimulationRuntime.java (strategyCache ConcurrentHashMap)
**Depends on:** D43 (overlay stack)
**Exploration:** quick
**Status:** captured

## D47: SimulationOverlay API in simulation-core — no new modules

**Choice:** `SimulationOverlay`, `InvocationJournal`, and `JournalEntry` live in `simulation-core` alongside `SimulationRuntime`. No new modules needed.
**Alternatives:**
- New simulation-context module — clean separation but adds a module for 3-4 classes that are tightly coupled to SimulationRuntime.
- In simulation-api — keeps it zero-dep. But simulation-api is intentionally minimal (strategy contracts only) and the overlay depends on SimulationRuntime internals.
**Rationale:** The overlay is an extension of SimulationRuntime's behaviour. It accesses the strategy cache, the config resolution chain, and the corpus. Putting it in a separate module would require exposing internals. Same module, same dependency footprint.
**Trade-offs:** simulation-core grows slightly. Acceptable — the addition is 3-4 small classes.
**Sources:** simulation-core/ (SimulationRuntime.java, strategy implementations), D2 (simulation-api is minimal)
**Exploration:** quick
**Status:** captured

---

# Phase 9 — #323 Consumer Adoption

## D49: Platform-side docs + example fixtures only — consumer changes via issues

**Choice:** Scope #323 to platform repo only: extend simulation-guide.md with a Consumer Adoption section, create minimal YAML corpus fixture templates at `docs/examples/simulation/<app>/`, and file GitHub issues on consumer repos for actual adoption work.
**Alternatives:**
- Modify consumer repos directly — more complete but violates the platform repo constraint ("do not modify these repos — raise issues instead")
- Documentation only, no fixtures — less useful; consumers need concrete examples to copy
**Rationale:** The consumer repos (clinical, devtown, aml, fsitrading) are not in this slot and CLAUDE.md explicitly constrains modifications. Example fixtures in the platform repo give consumers something concrete to adapt without cross-repo changes. Comprehensive corpora deferred to a separate issue once the framework matures.
**Trade-offs:** Consumers must copy and adapt fixtures themselves. Acceptable — the fixtures are minimal templates (2-3 entries per SPI), not production data.
**Sources:** CLAUDE.md (consumer repo constraint), issue #323
**Exploration:** quick
**Status:** captured

## D50: Per-app sections in simulation-guide.md

**Choice:** Organise the Consumer Adoption section by application. Each app gets a subsection with: SPI priority table, recommended strategy per SPI, pointer to example fixtures. Migration patterns and CI guidance are shared sections.
**Alternatives:**
- Per-pattern sections — organise by simulation pattern (agent, memory, REST client) with per-app annotations. Better for cross-app developers but forces reading multiple sections for one app's picture.
- Matrix table — single apps × SPIs table. Compact but no room for rationale or app-specific nuance.
**Rationale:** Each app has a genuinely different simulation profile (clinical = agent-first, devtown = REST-client-first, aml/fsitrading = memory+governance). Per-app sections make the guide actionable for a developer adopting simulation in one specific consumer.
**Trade-offs:** Some repetition across app sections (e.g. CaseMemoryStore appears in all four). Acceptable — the sections are short and the repetition provides self-contained reading.
**Sources:** Issue #323 (per-app priorities), simulation-guide.md (existing structure)
**Exploration:** quick
**Status:** captured

## D51: Minimal corpus templates — 2-3 entries per SPI per app

**Choice:** Create minimal YAML corpus fixtures with 2-3 entries per SPI per app. Domain-plausible field values (real-ish patient IDs, GitHub repo names, AML entity names). Comprehensive corpora deferred to a follow-on issue.
**Alternatives:**
- Comprehensive starter sets (10-15 entries) — more useful out of the box but significant manual authoring, risk of going stale before consumers adopt, and overlaps with #328 (corpus builders) and #330 (domain data generation)
- One app deep, others minimal — proves the pattern end-to-end but unevenly useful
**Rationale:** The fixtures demonstrate shape and config wiring, not production data. Later issues (#328, #330) deliver programmatic and LLM-driven corpus population that supersedes hand-authored YAML for comprehensive coverage.
**Trade-offs:** Minimal fixtures are not enough for real testing — consumers need to extend them. Acceptable — that's the explicit intent (templates to copy and adapt).
**Sources:** Issue #323, #328 (domain-specific corpus builders), #330 (domain data generation)
**Exploration:** quick
**Status:** captured

## D52: Generic @InjectMock → simulation migration patterns

**Choice:** Document 2-3 generic migration patterns showing before/after code: (1) mock SPI method return → key-lookup strategy, (2) mock sequential returns → sequential strategy, (3) mock with verify → capture + journal assertions. Not tied to specific consumer code.
**Alternatives:**
- Skip migration section — the Quick Start and tutorial tests already show how to use simulation. But the mental model shift from "mock the bean" to "configure a strategy" is non-obvious and worth documenting explicitly.
**Rationale:** The biggest adoption friction is conceptual, not mechanical. Developers know @InjectMock; they need to see the equivalent in simulation terms. Generic patterns let each consumer map their own tests without the guide going stale when consumer code changes.
**Trade-offs:** Generic examples may not cover every mock pattern (e.g. ArgumentCaptor, verify with times()). Acceptable — the verification API (#332) will address the assertion side.
**Sources:** simulation-guide.md (Quick Start, tutorial tests), #332 (verification API)
**Exploration:** quick
**Status:** captured

## D53: Quarkus profile-based CI guidance

**Choice:** Document the CI integration pattern using Quarkus profiles: `%test` enables simulation strategies, `%staging`/`%prod` has no simulation config (passthrough). Show the application.properties layout with profile-scoped keys.
**Alternatives:**
- Maven profile + CI config example — go further with Maven profile activation for simulation deps and sample GitHub Actions steps. More involved than needed for a config convention.
**Rationale:** Simulation activation is entirely config-driven (D11). The profile pattern is the natural Quarkus mechanism — no new code, no Maven profiles, no CI changes. Just profile-scoped properties.
**Trade-offs:** Doesn't cover Maven dependency scoping (test vs compile for simulation modules). Acceptable — the Quick Start already documents dependency scopes.
**Sources:** D11 (boot-time configuration), Quarkus profile documentation, simulation-guide.md (Configuration Reference)
**Depends on:** D11 (configuration is boot-time)
**Exploration:** quick
**Status:** captured

## D54: Fixtures at docs/examples/simulation/<app>/

**Choice:** Example YAML corpus fixtures live at `docs/examples/simulation/<app>/` (e.g. `docs/examples/simulation/clinical/`, `docs/examples/simulation/devtown/`). One YAML file per SPI.
**Alternatives:**
- simulation-config/src/test/resources/ — alongside tutorial tests. Discoverable but conflates reference material with module test fixtures.
- simulation-core/src/test/resources/examples/ — same concern; test resources are module-specific.
**Rationale:** These are reference material for consumers, not runtime artifacts or test fixtures for platform modules. `docs/examples/` makes the intent clear and keeps them out of module builds.
**Trade-offs:** Not on any module's classpath — can't be loaded by tests directly. Acceptable — consumers copy them into their own repos.
**Sources:** Issue #323, docs/ directory structure
**Exploration:** quick
**Status:** captured

---

# Phase 10 — #328 Domain-Specific Corpus Builders

## D55: Composition over inheritance — CorpusSeed<I,O> is final, not abstract

**Choice:** `CorpusSeed<I, O>` is a final concrete class in simulation-api. Per-SPI descriptor classes are utility classes with only static members. No abstract base class, no per-SPI subclasses.
**Alternatives:**
- Abstract `CorpusBuilder<I, O>` with per-SPI subclasses (issue's original proposal) — familiar builder pattern. But the base class behavior (accumulate records, seed into corpus) is identical for every SPI. Per-SPI variation is all static (constants, factories, extractors) — none needs virtual dispatch or `this` reference. Inheritance adds a mechanism where none is needed.
- Static utility + per-SPI builder (no shared type) — duplicates record accumulation logic. No polymorphism, though polymorphism is unused.
**Rationale:** First-principles analysis: the generator uses `Object[]` for multi-param methods (SimulationDecoratorProcessor lines 186-194). An abstract class hierarchy that types the input as `Object[]` provides no type safety. What actually helps is typed factory methods that construct the `Object[]` correctly — and those are static. Additionally, domain fixture factories (e.g. `resource("case", "c-1")`) are independently useful in non-simulation tests. Locking them in a builder subclass makes them unreachable. Composition separates concerns cleanly: CorpusSeed handles accumulation, descriptors handle domain knowledge.
**Trade-offs:** Two concepts to learn (CorpusSeed + descriptor) vs one (builder). Acceptable — both concepts are simple and together they produce a static-importable mini-DSL per SPI.
**Sources:** SimulationDecoratorProcessor.java (lines 186-194 — Object[] for multi-param), InvocationRecord.java, SimulationCorpus.java, issue #328
**Exploration:** deep-analysis (first-principles re-examination of the issue's proposed approach)
**Status:** revised (R3-03, R3-06: CorpusSeed moves from simulation-core to simulation-api — enabled by splitting seedInto to remove SimulationRuntime dependency)

## D56: InvocationRecord.of() convenience factories in simulation-api

**Choice:** Add static factory methods to InvocationRecord: `of(tenancyId, input, output)` and `of(tenancyId, key, input, output)`. Both default `recordedAt` to `Instant.now()`. The first defaults `key` to null.
**Alternatives:**
- Leave InvocationRecord as-is — all convenience in CorpusSeed. But InvocationRecord.of() is useful even without CorpusSeed, e.g. when directly calling `corpus.seed()`.
**Rationale:** The 5-arg constructor (`tenancyId, key, input, output, recordedAt`) is painful when you only care about 2 fields (input, output). Convenience factories eliminate timestamp and null-key boilerplate everywhere — including tutorial tests, YAML loader, and CorpusSeed internals. Zero new types, zero dependencies, zero risk.
**Trade-offs:** None. This is a strict convenience addition to an existing record.
**Sources:** InvocationRecord.java, tutorial tests (SimulationGettingStartedTest — helper methods that do exactly this)
**Depends on:** None
**Exploration:** quick
**Status:** captured

## D57: CorpusSeed auto-derives keys via withKeyExtractor()

**Choice:** `CorpusSeed.withKeyExtractor(KeyExtractor<I>)` configures an extractor. When set, `add(input, output)` auto-derives the key from the input — no manual key argument needed. `add(key, input, output)` still available for explicit override. `seedInto(corpus)` seeds data only. Extractor and qualified name are accessible via `qualifiedName()` and `keyExtractor()` — the caller registers separately via `runtime.registerExtractor(seed.qualifiedName(), seed.keyExtractor())`.
**Alternatives:**
- Coupled `seedInto(corpus, runtime)` — seeds data AND registers the extractor in one call. Prevents forgetting to register. But the method name suggests data seeding while also mutating global runtime state (hidden side effect), and last-writer-wins on `registerExtractor()` means two seeds sharing a runtime silently override each other. Verified: `SimulationRuntime.requireExtractor()` throws `SimulationConfigException` when no extractor is registered — the failure mode of forgetting to register is loud, not silent. The safety justification for coupling doesn't hold.
- No key derivation on CorpusSeed — user always provides explicit keys or registers extractors separately. Simpler API but loses the "just works" convenience.
- Key extractor required (not optional) — forces every CorpusSeed to have an extractor. Overspecified — sequential and random strategies don't use keys.
**Rationale:** Separating data seeding from runtime configuration makes both operations explicit. The caller writes two lines instead of one, but each operation is visible and nameable. Key consistency between seeding and resolution is ensured by using the same extractor instance for both — the CorpusSeed stores it, the caller registers it. Forgetting to register causes a loud `SimulationConfigException("Strategy for X requires a KeyExtractor, but none registered")`, not a silent passthrough. This split also enables CorpusSeed to live in simulation-api (D55 revision) — its only dependencies are SimulationCorpus and InvocationRecord, both in simulation-api.
**Trade-offs:** Two calls instead of one in test setup. Acceptable — explicit is better than surprising, and the failure mode of omitting the second call is a clear exception.
**Sources:** SimulationRuntime.registerExtractor() (line 32), SimulationRuntime.requireExtractor() (line 144 — fail-fast on missing extractor), KeyLookupStrategy (requires key match), AgentSimulationInput.defaultKeyExtractor() (precedent)
**Depends on:** D55 (CorpusSeed design)
**Exploration:** quick
**Status:** revised (R3-03: split seedInto — data seeding decoupled from runtime registration; R3-06: enables CorpusSeed placement in simulation-api)

## D58: withOutputMapper() for derivable outputs

**Choice:** `CorpusSeed.withOutputMapper(Function<I, O>)` enables `add(input)` (no output argument) — the output is derived from the input via the mapper. Optional convenience for SPIs where the output is a transformation of the input (e.g. NotificationStore.store: input is NotificationInput, output is Notification with generated id + UNREAD status + timestamps).
**Alternatives:**
- No output mapper — user always provides both input and output. Simpler but forces duplicated construction for store-like SPIs.
**Rationale:** For query SPIs (canAccess, resolveById, find), input and output are independent — no mapper applicable. For store SPIs, the output is derivable from the input with generated fields. The mapper is optional — most descriptors won't set it.
**Interaction with withKeyExtractor:** When both `withKeyExtractor(KeyExtractor<I>)` and `withOutputMapper(Function<I, O>)` are configured and `add(input)` is called, key derivation and output mapping are independent and both operate on the original input `I`: (1) `keyExtractor.extract(input)` derives the key, (2) `outputMapper.apply(input)` derives the output. There is no interaction between the two — the extractor never sees the mapped output, and the mapper never sees the derived key. Both functions receive the raw input as provided to `add()`.
**Trade-offs:** API surface — one more method on CorpusSeed. Acceptable — it's clearly optional and self-documenting.
**Sources:** NotificationStore.store(NotificationInput) → Notification, PreferenceStore.set() → PreferenceRecord
**Depends on:** D55 (CorpusSeed design), D57 (withKeyExtractor)
**Exploration:** quick
**Status:** revised (R3-05: added explicit specification of withOutputMapper/withKeyExtractor interaction)

## D59: Per-SPI descriptor classes — static members only

**Choice:** Each descriptor is a `public final class` with only static members: typed `CorpusSeed` factory methods (pre-configured with default extractor), and domain fixture factories (static methods constructing SPI input/output types with sensible defaults). For multi-param methods, typed factory methods return `Object[]` internally — hiding the positional array from the user. Qualified name constants are imported from generated companion classes (D66), not hand-authored as string literals.
**Alternatives:**
- Hand-authored qualified name string constants in descriptors — simpler but fragile: a typo compiles but fails silently at runtime (`strategyFor()` returns `Optional.empty()`, decorator passes through to delegate). Three-way string coupling between listing file, generator, and descriptor with no compile-time verification.
- Instance-based descriptors with configuration — each descriptor is instantiated and configured. Adds state and lifecycle for no benefit — the configuration is per-SPI, not per-instance.
- Enum-based method registry — each method is an enum constant with its qualified name. Type-safe but overly rigid and can't carry factory methods.
**Rationale:** Static utility classes with static imports produce a clean mini-DSL per SPI. `canAccess("tenant").add(check(...), true).seedInto(corpus)` reads naturally. The fixture factories (`check()`, `resource()`, `model()`) are independently importable for non-simulation tests. No instantiation, no lifecycle, no state. Generated constants (D66) eliminate the three-way string coupling between listing file, generator, and descriptor — a listing file rename or SPI method rename causes a compile error in the descriptor, not a silent runtime mismatch.
**Trade-offs:** Static methods don't participate in dependency injection. Acceptable — corpus seeding is test setup code, not a CDI concern. Descriptors depend on generated constants classes — acceptable because the generator already produces code per SPI.
**Sources:** AgentSimulationInput.from() (precedent for static factory), SimulatedAgentBackend.defaultKeyExtractor() (precedent for static extractor factory)
**Depends on:** D55 (CorpusSeed design), D66 (generated qualified name constants)
**Exploration:** quick
**Status:** revised (R3-02: qualified name constants now imported from generated classes, not hand-authored strings)

## D60: simulation-testing module for platform-api SPI descriptors

**Choice:** New `casehub-platform-simulation-testing` module. Depends on simulation-core + platform-api. Contains: AclCorpus, ModelCorpus, NotificationCorpus, PreferenceCorpus, CredentialCorpus, and LlmCorpusPopulator. Consumers add as test-scope.
**Alternatives:**
- In simulation-core — but simulation-core is currently domain-agnostic (no platform-api dependency). Adding platform-api couples it to the casehub type system.
- In platform-simulation-core — alongside generated decorators. But that module's purpose is APT-generated code, not hand-written test utilities. Mixing the concerns invites confusion about what's generated vs authored.
- In existing testing/ module — but testing/ is for identity fixtures and @Alternative test beans (FixedCurrentPrincipal, InMemoryGroupMembershipProvider). Corpus builders are a different concern.
**Rationale:** Clean separation: simulation-core = framework, simulation-testing = per-SPI test utilities. Follows the platform convention where test-scope modules are distinct (testing/ for identity fixtures, simulation-testing for corpus fixtures). The module is test-scope only — it doesn't affect production classpaths.
**Trade-offs:** One new module. Acceptable — it's a test-scope module with a clear, bounded purpose.
**Sources:** testing/ module pattern, simulation-core (domain-agnostic by design — D2)
**Depends on:** D55 (CorpusSeed in simulation-api), D59 (descriptor classes), D66 (generated QN constants)
**Exploration:** quick
**Status:** captured

## D61: AgentCorpus descriptor in agent-simulation-core

**Choice:** Add `AgentCorpus` descriptor class to the existing `agent-simulation-core` module alongside `SimulatedAgentBackend` and `AgentSimulationInput`. AgentCorpus provides typed CorpusSeed factories, the existing `defaultKeyExtractor()`, and convenience factories for `AgentSimulationInput` and common `AgentEvent` responses (textResponse, toolCallResponse).
**Alternatives:**
- In simulation-testing — but AgentProvider types are in agent-api, not platform-api. simulation-testing would need agent-api as a dependency, pulling all agent types into the test-scope module.
- New agent-simulation-testing module — too much module proliferation for one descriptor class.
**Rationale:** agent-simulation-core already has both dependencies (agent-api + simulation-core) and contains the domain-specific types (AgentSimulationInput, SimulatedAgentBackend). Adding a descriptor class alongside them is natural.
**Trade-offs:** agent-simulation-core gains a hand-written class alongside the existing hand-written types. Acceptable — the module's purpose is agent-specific simulation support.
**Sources:** agent-simulation-core/ (AgentSimulationInput.java, SimulatedAgentBackend.java), AgentSessionConfig (invoke input type)
**Depends on:** D55 (CorpusSeed), D59 (descriptor pattern)
**Exploration:** quick
**Status:** captured

## D62: LlmCorpusPopulator takes Function<String,String>, not AgentProvider

**Choice:** `LlmCorpusPopulator` takes a `Function<String, String>` (prompt → response text) and an `ObjectMapper`. Framework-agnostic — works with any LLM backend. Uses `PlatformSchemaGenerator` to produce JSON Schema from Java types for the LLM prompt. Lives in simulation-testing. A static adapter method in `AgentCorpus` wires `AgentProvider` → `Function<String, String>` for convenience.
**Alternatives:**
- Direct AgentProvider dependency — simpler constructor but couples simulation-testing to agent-api, forcing agent-api onto every test classpath that uses simulation-testing.
- New simulation-llm-core module — cleanest separation but adds another module for one utility class.
**Rationale:** The `Function<String, String>` interface decouples corpus generation from the specific LLM backend. simulation-testing depends on simulation-core + platform-api + schema-generator + jackson — no agent-api. The adapter in agent-simulation-core bridges the gap for consumers who use AgentProvider. This means consumers who don't use LLM generation pay zero dependency cost for it.
**Error handling contract:** All exceptions propagate — invalid JSON, schema mismatch, function errors (rate limit, timeout, content filter), and context overflow all throw unchecked exceptions and let the test fail. No retry, no fallback, no partial results. This is the correct stance for a test utility — tests should fail fast on corpus generation errors, not silently produce malformed data.
**Trade-offs:** The adapter wiring (AgentProvider → Function) is a few lines of code in AgentCorpus. Acceptable — it's authored once. Structured output support (`Function<String, Class<T>, T>` or similar) is a valid evolution path but deferred — the current function has exactly one adapter (AgentCorpus), so migration is mechanical, not cross-codebase.
**Sources:** PlatformSchemaGenerator.generate(Class<?>) → JsonNode, AgentProvider.invoke() → Multi<AgentEvent>, schema-generator module
**Depends on:** D55 (CorpusSeed), D60 (simulation-testing module), D61 (AgentCorpus)
**Exploration:** quick
**Status:** revised (R3-04: added explicit error handling contract; structured output deferred)

## D63: High-value SPIs get descriptors first — 5 of 11

**Choice:** Initial scope: AclCorpus (AccessControlProvider), ModelCorpus (ModelRegistry), NotificationCorpus (NotificationStore), PreferenceCorpus (PreferenceProvider), CredentialCorpus (CredentialResolver). The remaining 6 SPIs (DataSourceRegistry, EndpointRegistry, SubscriptionStore, ExpressionEngineRegistry, DocumentSigningService, CurrentPrincipal) are deferred — they are less commonly simulated and their descriptors are mechanical to add later.
**Alternatives:**
- All 11 from the start — complete coverage. But 6 of the deferred SPIs are infrastructure registries (DataSource, Endpoint, Subscription, Expression), a security service (DocumentSigning), and an identity accessor (CurrentPrincipal) — rarely simulated at the corpus level.
- Just the base class + 1 example — proves the pattern but doesn't deliver enough value. Consumers still hand-construct InvocationRecords for 4 other SPIs.
**Rationale:** The 5 selected SPIs cover the most common simulation use cases: authorization checks (ACL), model selection (ModelRegistry), notification pipeline testing (NotificationStore), configuration testing (PreferenceProvider), and secret resolution (CredentialResolver). Together they give consumers enough coverage to validate the pattern. The remaining SPIs follow the same mechanical pattern and can be added in follow-ons.
**Trade-offs:** 6 SPIs without descriptors. Consumers can still seed them directly via CorpusSeed — just without convenience factories.
**Sources:** platform-simulation-core listing (11 SPIs), SPI method catalog (query vs mutation analysis)
**Depends on:** D60 (simulation-testing module)
**Exploration:** quick
**Status:** captured

## D64: Pattern-based synthesis as a planned extension — not in #328 scope

**Choice:** #328 delivers CorpusSeed + descriptors + LlmCorpusPopulator. Pattern-based synthesis (#347) is a separate follow-on with three key design surfaces: (1) named pattern vocabulary — curated exemplar pools indexed by semantic labels (e.g. "bull-run", "flash-crash", "pre-arrest"), composable into multi-phase scenarios via `compose(segment("high-vol-open"), segment("bull-run").scaled(1.5), segment("flash-crash"))`. (2) Domain-specific statistical mutators — typed perturbation functions that encode domain expertise: `Mutators.clinical().heartRate(gaussian(0, profile.std("heart-rate"))).bloodPressure(correlated("heart-rate", 0.6)).temperature(bounded(36.0, 42.0))`. Framework provides perturbation primitives (gaussian, log-normal, bounded, uniform, correlated, preserveRatios, enforceConstraints); domains compose them into publishable mutator sets. Perturbation primitives at Level 2+ compose with Apache Commons Math (CorrelatedRandomVectorGenerator for multivariate correlation, RealDistribution implementations for sampling, EmpiricalDistribution for fitting from data) — the platform provides the domain vocabulary and constraint layer, not custom statistical implementations. At Level 1 (descriptive statistics), standard Java library code suffices. Testing-oriented generation frameworks (jqwik, Instancio) solve a different problem — property-based test data generation, not domain-constrained statistical mutation from empirical distributions — and are not suitable as the synthesis primitive layer. (3) Constraint-aware perturbation — perturbation samples from the empirical distribution of all known exemplars, rejects values outside the observed statistical envelope, and preserves inter-field correlations. A synthesized heart rate of 240 bpm during "pre-arrest" is rejected because no exemplar shows that. Mutators travel with the corpus as a matched pair — a domain team publishes data + rules together. Consumers load both and say "give me 100 plausible variants" without needing domain expertise. CorpusSeed is designed as the universal accumulation point — synthesis primitives add entries via the same `seed.add()` path, no architecture changes needed. Three architectural commitments are binding and constrain #347's design space intentionally: (1) named pattern vocabulary — exemplar pools indexed by semantic labels, (2) mutators travel with the corpus as a matched pair — domain expertise co-located with data, (3) perturbation primitives in platform, domain-specific compositions in app repos — follows boundary-rules.md ("Do not add domain logic to foundation repos"). The API sketches above (Mutators.clinical()..., compose()...) are illustrative, not prescriptive — #347's brainstorming should start from first principles within these architectural constraints. These sketches have not been validated by implementation and may not survive contact with real domain constraints (e.g., conditional distributions, regime-switching models).
**Alternatives:**
- Include synthesis primitives in #328 — larger scope but coherent. Rejected because synthesis has its own design surface (perturbation distributions, temporal correlation, constraint validation, boundary smoothing, named pattern vocabulary, mutator composition) that warrants dedicated brainstorming.
- Defer entirely without architectural accommodation — risks a design that can't support synthesis later. Rejected because CorpusSeed's `add()` + `build()` API already accommodates it naturally.
**Rationale:** Three data realism paths compose at different levels: (1) LLM generation — good at domain vocabulary and structural correctness, bad at temporal patterns and statistical properties. (2) Pattern synthesis — good at statistical realism and temporal fidelity, needs exemplar data and domain-specific mutators. (3) Capture replay — perfect fidelity, zero variation. The hybrid is: capture → catalogue → statistics → constrained synthesis → LLM-enrich metadata. Random perturbation produces noise; domain-constrained perturbation produces plausible variation. The difference is the mutator set — domain expertise encoded once, reused by every consumer. Each domain has known valid deviation ranges across all observed data; perturbation must stay within this statistical envelope to produce plausible output.
**Trade-offs:** #328 alone doesn't solve temporal/statistical data realism. Consumers needing plausible time-series data (stock prices, patient vitals, sensor readings) must wait for #347 + catalogue. Mitigated by the hybrid LLM path — few-shot examples from real data produce better results than pure schema-based generation. Mutators-with-corpus creates a versioning concern — mutators must stay in sync with the data schema. Acceptable because they're co-located (same repo/package) and CI-validatable. Synthesis without a catalogue (#347 before #348) operates in degraded mode: user-provided bounds replace computed envelopes, and constraint satisfaction uses explicit domain rules rather than data-derived statistics. Degraded mode's value is specifically for volume multiplication with expert-specified constraints — e.g., 5 captured patient records → 500 synthetic variants with bounded vital-sign perturbation. It is not a general-purpose data generation tool; for developers without domain expertise, LLM-generated corpus entries (D62) or hand-authored fixtures remain more practical for initial test setup. Domain-vs-platform placement: the perturbation primitive framework (gaussian, bounded, correlated) belongs in the platform; domain-specific mutator compositions (Mutators.clinical(), Mutators.fsitrading()) and domain catalogues belong in application repositories or external repositories. The platform provides infrastructure and primitives; domain teams provide data and rules.
**Sources:** TimedSequence (event-simulation-core), capture mode, LlmCorpusPopulator (D62), CorpusSeed (D55), RecordFieldScorer (simulation-config-core — per-field *decomposition* is shared with mutation: both decompose objects into fields via Jackson convertValue. The *composition* models differ categorically: scoring composes via weighted sum of independent field scores using trivial primitives (Objects.equals, ratio, contains — each 1-3 lines in FieldSimilarity), while mutation requires constraint satisfaction with non-trivial mathematical operations (Cholesky decomposition for correlation preservation, rejection sampling with convergence guarantees, error function for gaussian sampling). Perturbation primitives must delegate to Apache Commons Math at Level 2+ — custom implementations of these operations produce subtly wrong output that looks plausible but isn't statistically valid. The analogy is structural, not operational)
**Depends on:** D55 (CorpusSeed as universal accumulator), D62 (LlmCorpusPopulator), D65 (planning dependency — catalogue provides computed statistical envelopes; synthesis operates in degraded mode with user-provided bounds when catalogue is unavailable; not a module dependency — no compile-time coupling between synthesis and catalogue modules)
**Exploration:** deep-analysis (first-principles examination of data realism paths — LLM vs synthesis vs capture; statistical mutators and constraint-aware perturbation emerged from domain analysis)
**Status:** revised (R1-02: clarified RecordFieldScorer analogy limits — decomposition shared, composition models differ; R1-03: added illustrative caveat on API sketches; R1-04: added degraded mode for synthesis without catalogue; R1-13: made domain-vs-platform placement explicit; ADR1-02: added build-vs-reuse evaluation — perturbation primitives compose with Commons Math, not reimplement; ADR1-03: strengthened complexity gap acknowledgment; ADR1-04: narrowed degraded mode value proposition to volume multiplication with expert-specified constraints; ADR1-05: separated architectural commitments from illustrative API sketches)

---

## D65: Data catalogue as planned infrastructure layer — not in #328 scope

**Choice:** The simulation framework's data realism stack has three layers: catalogue (curate + store + discover + statistical envelope), synthesis (compose + perturb + constrain), seeding (accumulate + register). #328 delivers the seeding layer. #347 delivers synthesis. #348 delivers the catalogue. A catalogue is persistent, metadata-rich, relationship-aware storage of exemplar data fragments. It stores: (1) exemplar pools indexed by named patterns, (2) canonical sequences linking related fragments (pre-arrest exemplar 12 + arrest-onset exemplar 8 + post-arrest exemplar 15 were captured from the same real event), (3) statistical profiles computed across all exemplars per pattern — the aggregate envelope that defines valid deviation space for synthesis. The statistical envelope includes per-field distributions (min, max, percentiles, fitted distribution), inter-field correlations (heart rate and PR interval: r=-0.3), and domain constraints (hard physiological/financial limits). The richer the catalogue, the tighter the envelope: 5 exemplars = crude range, 500 = proper distribution with tail behavior, 5000 = conditional distributions ("heart rate given age 60-70 on beta blockers"). Statistical envelope computation scales in tiers: Level 1 (descriptive) delivers min, max, percentiles, and Pearson correlations — achievable with standard Java library code, no external dependency. Level 2 (distributional) adds fitted distribution families (normal, log-normal, Weibull) and multivariate correlations — requires a statistical library dependency (Apache Commons Math or similar). Level 2 carries an implicit minimum sample size requirement: distribution fitting on fewer than ~50 exemplars per pattern is statistically unreliable (Kolmogorov-Smirnov tests cannot meaningfully distinguish distribution families on small samples). Below this threshold, Level 2 degrades gracefully to Level 1 descriptive statistics rather than producing unreliable fitted parameters. Level 3 (conditional) adds conditional density estimation and time-series modeling (autocorrelation, state-space models) — a research-grade capability requiring specialized libraries, or a standalone REST-based statistical service following the established platform pattern (memory-graphiti, memory-mem0: separate Python-backed services accessed via HTTP, not subprocess integration from Java). Python subprocess integration would violate the platform's pure-Java architecture (ARC42STORIES.MD §2, boundary-rules.md) and is explicitly excluded. Level 3 represents an architectural boundary that warrants explicit debate during #348 brainstorming. The initial catalogue (#348) targets Level 1. Library dependencies and statistical sophistication decisions are deferred to #348's brainstorming, informed by real domain needs. A corpus ships with optional statistical mutators as a matched pair — the data and the rules for plausible variation travel together. Without mutators, the synthesizer falls back to generic perturbation. As mutators are added, synthesis quality improves without consumer code changes. Different fidelity tiers are possible: a research-grade catalogue ships 20 correlated mutators with tight envelopes; a demo catalogue ships 3 simple bounded ones. Same API, different fidelity. GitHub repos serve as the interchange and authoring format — version-controlled, shareable, CI-validatable. For catalogues exceeding ~100 exemplars, a SQLite-backed catalogue store (following the memory-sqlite pattern with HikariCP + FTS5) provides indexed queries and incremental envelope computation as the runtime representation. The import path from Git to SQLite runtime: a CDI @Startup bean reads YAML/JSON exemplar files from the classpath (following the YamlCorpusPopulator pattern from simulation-config), populates the SQLite database, and computes statistical profiles during initialization. The SQLite file is neither checked into Git (binary, doesn't diff) nor generated at build time (static) — it is populated at boot from the version-controlled source-of-truth YAML files. This mirrors how YAML corpus fixtures (flat files) coexist with InMemorySimulationCorpus (runtime) in the existing framework. External data importers normalize from PhysioNet (clinical), Kaggle (financial), MIMIC (clinical events) into the framework's InvocationRecord/TimedSequence format. Licensing constraints (PhysioNet DUA, MIMIC credentialing, per-dataset Kaggle licenses) mean raw exemplar data cannot be redistributed. The shareable catalogue layer is statistical profiles + mutator definitions, not raw exemplars. Raw exemplar pools are deployment-local — each site imports its own licensed data. Shared catalogues contain computed envelopes that encode domain knowledge without reproducing the source data. CorpusSeed remains the universal accumulation point for all three layers.
**Alternatives:**
- Include catalogue in #328 or #347 — too much scope. The catalogue has its own design surface (metadata schema, canonical sequence relationships, statistical envelope computation, mutator specification format, search/discovery, external data importers, version-controlled storage format).
- Skip catalogue entirely — synthesis works on ad-hoc captured data. But without curation, metadata, relationships, and statistical envelopes, synthesis quality is limited: random mix-and-match without knowing which fragments form real canonical sequences produces implausible transitions, and unconstrained perturbation produces values outside observed ranges.
**Rationale:** The catalogue is what separates "perturb some captured data" from "compose realistic multi-phase scenarios with statistically plausible variation." Three catalogue capabilities are load-bearing: (1) Canonical sequences — cardiac rhythm simulation needs to know that pre-arrest, arrest-onset, and post-arrest exemplars are related, enabling faithful composition (use a canonical triple) vs mix-and-match (combine unrelated fragments with boundary smoothing). (2) Statistical envelope — defines the valid deviation space. Perturbation that stays within the observed envelope produces plausible output; perturbation outside it produces artifacts. Inter-field correlations prevent individually-valid-but-jointly-implausible combinations (heart rate up + blood pressure unchanged). (3) Mutators-with-corpus — domain expertise encoded once by a domain team (cardiologist, quant), consumed by every downstream team without domain knowledge. This creates a flywheel: capture → catalogue → statistics → constrained synthesis → better tests → deploy → capture more → richer catalogue. The flywheel's entry point is capture — but simulation's primary use case (D1) is when no real backend exists. The flywheel therefore starts not at project inception but after the first end-to-end integration, or via imported external data (PhysioNet, Kaggle) or LLM-generated exemplars (D62). The catalogue's value proposition is for mature systems (load testing, regression testing, demos) and differs from simulation's core value of replacing missing backends during initial development.
**Trade-offs:** #328 alone produces structurally correct but statistically naive data. The full stack (#328 + #347 + #348) is three issues of design + implementation. Mitigated by incremental value delivery: #328 is immediately useful for test setup, #347 adds pattern composition, #348 adds statistical realism. Each layer improves synthesis quality independently. The catalogue flywheel requires domain expert curation — labeling patterns, validating labels, identifying canonical sequences, defining domain constraints. This is inherent to domain-specific data: the expertise is the value, not a bottleneck to be automated away. Domain teams bear the curation cost and publish the result for all consumers. Automated pattern discovery (clustering, LLM-based labeling) is a future extension that can reduce curation effort but cannot eliminate the expert validation step. Catalogue infrastructure (storage, envelope computation, query, importer framework) belongs in the platform. Domain-specific exemplar data, domain catalogues, and domain mutator sets belong in application repositories or external repositories. The platform provides the infrastructure layer; domain teams provide the data and rules.
**Sources:** D64 (synthesis extension), TimedSequence (temporal data), capture mode (exemplar acquisition), existing domain data sources (PhysioNet, Kaggle, MIMIC), RecordFieldScorer (per-field scoring pattern — structural analogy only, see D64 for analogy limits), memory-sqlite (precedent for SQLite-backed indexed storage with HikariCP + FTS5)
**Depends on:** D55 (CorpusSeed), D64 (planning dependency — catalogue stores data and mutators that synthesis consumes; not a module dependency — the catalogue module needs no compile-time coupling to the synthesis module, and vice versa. The shared type vocabulary for statistical profiles and mutator specifications will be resolved during #347/#348 brainstorming when the types' shapes are known)
**Exploration:** deep-analysis (emerged from first-principles discussion of data realism — statistical envelopes, constraint-aware perturbation, and mutators-with-corpus emerged from domain-specific analysis of cardiac and financial use cases)
**Status:** revised (R1-07: added SQLite runtime representation for large catalogues; R1-08: added tiered statistical capabilities — Level 1 initial scope; R1-09: addressed licensing constraints — shareable layer is profiles not raw data; R1-10: acknowledged curation cost — domain teams bear it; R1-13: made domain-vs-platform placement explicit; ADR1-07: replaced Python subprocess with REST-based service pattern; ADR1-09: acknowledged cold-start — flywheel starts after first integration, not at project inception; ADR1-10: added Git-to-SQLite import path sketch; ADR1-11: added minimum sample size requirement for Level 2)

## D66: Generator produces qualified name constants class per SPI

**Choice:** `SimulationDecoratorProcessor` generates a companion constants class alongside each `@Decorator` — e.g. `AccessControlProviderQN` with `public static final String CAN_ACCESS = "access-control-provider.canAccess"`. One constant per intercepted method. Constants are derived from the Jandex index: `spiName + "." + method.name()` — the same construction used by the decorator itself (SimulationDecoratorProcessor line 171). Descriptors (D59) import these constants instead of authoring string literals.
**Alternatives:**
- Hand-authored string constants in descriptor classes — the original approach. Compiles regardless of correctness — a typo (`"access-control-provider.can-access"` vs `"access-control-provider.canAccess"`) creates a three-way string coupling between listing file, generator, and descriptor that fails silently at runtime: `strategyFor()` returns `Optional.empty()`, decorator passes through to delegate, test appears to pass.
- Enum-based constants — type-safe but rigid and harder to import statically.
**Rationale:** The generator already produces one file per SPI (the decorator). Producing a companion constants class adds negligible generation cost — one additional file with string constants derived from the same Jandex metadata. The benefit is significant: a listing file rename or SPI method rename causes a compile error in every descriptor that imports the constant. The entire class of "descriptor references nonexistent method" bugs is eliminated. Constants are derived from actual SPI interface methods via Jandex — only real methods produce constants.
**Trade-offs:** One additional generated file per SPI. Negligible — the files are small (one constant per method) and the generation is mechanical.
**Sources:** SimulationDecoratorProcessor.java (line 171 — qualified name construction: `spiName + "." + method.name()`), Jandex MethodInfo (authoritative source of method names)
**Depends on:** D4 (annotation processor), D59 (descriptors import generated constants)
**Exploration:** quick (surfaced by review R3-02)
**Status:** captured

## D67: Issue ordering — synthesis (#347) before catalogue (#348)

**Choice:** Synthesis (#347) is implemented before catalogue (#348). Synthesis operates first in degraded mode (user-provided bounds), then the catalogue adds computed envelopes when it arrives.
**Alternatives:**
- Catalogue first (#348 → #347) — delivers immediate value from data curation and discovery (browsing captured data, computing descriptive statistics, tagging patterns). Synthesis then builds on real curated data rather than hand-specified bounds. The catalogue is independently useful: even without synthesis, knowing "the 95th percentile heart rate across 200 pre-arrest exemplars is 145 bpm" is valuable for manually authored test data.
- Parallel development — both issues designed and implemented concurrently. Higher resource cost and coordination overhead, but delivers the full stack sooner.
**Rationale:** Synthesis-first is preferred for three reasons: (1) Synthesis primitives are immediately useful in degraded mode — domain experts who know their statistical bounds can produce plausible variations without waiting for catalogue infrastructure. (2) The catalogue's full unique value (statistical envelopes, canonical sequences) is specifically for *synthesis consumption* — building the consumer first ensures the catalogue's API shape is driven by real usage patterns rather than speculative design. (3) Framework validation — synthesis exercising degraded mode validates the perturbation primitive API before the catalogue adds computed bounds, reducing integration risk. The catalogue-first alternative's independent value (browsing, descriptive statistics) is largely already delivered by the existing YAML corpus + LlmCorpusPopulator.
**Trade-offs:** No computed statistical envelopes until #348. Acceptable — degraded mode with expert-specified bounds covers the immediate need, and each issue has independent justification through its own brainstorming.
**Sources:** D64 (synthesis extension), D65 (catalogue), D62 (LlmCorpusPopulator — delivers browsing/discovery value in the interim)
**Depends on:** D64, D65 (both planning decisions that define the design space)
**Exploration:** quick (surfaced by adversarial review ADR1-14)
**Status:** captured

---

## D48: Cross-repo design — platform API + pages consumer together

**Choice:** Design both platform-side API (#322) and pages-side consumer (casehub-pages#450) in one spec. Implement platform first, then pages. Both repos are in slot 195.
**Alternatives:**
- Platform-only design — design the API in isolation. Risks misalignment with actual consumer usage patterns.
**Rationale:** The API shape should be driven by how the scenario orchestrator actually uses it. Designing both together ensures the platform API serves the real consumer without speculative abstractions.
**Trade-offs:** Larger spec scope. Acceptable — the pages side is thin (lifecycle hooks + YAML schema extension).
**Sources:** casehub-pages ScenarioOrchestrator.java, issue #322, casehub-pages#450
**Exploration:** quick
**Status:** captured

---

# Phase 11 — #329 Strategy Configuration and Profiles

## D68: Scope — profile infrastructure + lifecycle guide, no CLI

**Choice:** #329 delivers named simulation profiles (config bundles) with profile-aware overlay integration, plus a lifecycle progression guide section. No CLI scaffolding tool.
**Alternatives:**
- Profiles only — infrastructure without the guide leaves teams to figure out progression themselves from the existing config reference. Low-cost omission that hurts developer onboarding.
- Profiles + lifecycle guide + CLI — a CLI that scaffolds profile configs for each maturity stage. The profile format isn't battle-tested yet; a CLI adds maintenance cost before the format is proven. Natural follow-on once the format stabilizes from real adoption.
**Rationale:** The guide section costs almost nothing and directly answers "what should I do at each stage?" for developers new to the simulation framework. A CLI makes sense once the profile config shape is validated by real usage across consumer apps — building it now risks maintaining a tool against a moving target.
**Trade-offs:** No automated scaffolding. Developers copy-paste from the guide. Acceptable — profile config is a handful of properties lines, not a complex artifact.
**Sources:** Issue #329, simulation-guide.md (existing Quick Start and Configuration Reference sections)
**Exploration:** quick
**Status:** captured

## D69: Flat config as implicit default — profiles override, zero migration

**Choice:** Existing flat config (`casehub.simulation.<spi>.<method>.<property>`) remains as the implicit default. Named profiles (`casehub.simulation.profiles.<name>.<spi>.<method>.<property>`) override individual entries when activated via `casehub.simulation.active-profile=<name>`. Resolution order: active profile entries → flat config entries → empty.
**Alternatives:**
- Profiles only — all config must be in a named profile. Cleaner model but breaks every existing config and forces migration.
- Profiles extend flat config (layered inheritance) — profiles inherit all flat config entries and can override or add. Functionally identical to "flat as default" but described differently. The mental model is the same: profile entries win over flat entries for matching qualified names.
**Rationale:** Zero migration. Existing `application.properties` files keep working unchanged. Profiles are purely additive — you opt in by declaring a profile and activating it. Users who never use profiles see no change in behavior.
**Trade-offs:** Two config shapes coexist (flat and profile-nested). Slight complexity in the parser. Acceptable — the parser already does prefix scanning; adding a second prefix depth is mechanical.
**Sources:** SmallRyeSimulationConfig.java (existing prefix scanning), D13 (config binding via manual prefix scanning)
**Depends on:** D68 (scope includes profiles)
**Exploration:** quick
**Status:** captured

## D70: Single active profile — overlay stack handles layering

**Choice:** One profile at a time via `casehub.simulation.active-profile=ci-replay`. No comma-separated multi-profile support. The overlay stack (D43) already handles layering for scenarios — profiles don't need to replicate that mechanism.
**Alternatives:**
- Multiple profiles (comma-separated, later wins on conflict) — more flexible but adds a resolution layer that duplicates what the overlay stack already provides. Scenarios that need multiple layers use `pushProfile()` sequentially.
**Rationale:** The overlay stack is the layering mechanism. Profiles are the naming mechanism. Mixing the two (multiple boot-time profiles) creates ambiguity about resolution order and duplicates the overlay stack's purpose. A single boot-time profile keeps the config model predictable: one profile, one behavior.
**Trade-offs:** No boot-time profile composition. If you need elements from two profiles at boot time, build a single profile that combines them. Acceptable — profiles are config, and config is easy to merge manually.
**Sources:** D43 (layered runtime overlay), SimulationRuntime.pushOverlay() (existing layering API)
**Depends on:** D69 (flat config as default), D43 (overlay stack)
**Exploration:** quick
**Status:** captured

## D71: Extend SmallRyeSimulationConfig — profiles parsed alongside flat config

**Choice:** SmallRyeSimulationConfig gains profile parsing in the same constructor. Properties with a `profiles.<name>.` segment after the prefix are routed into a `Map<String, Map<String, MethodSimulationConfig>>`. The class adds `resolveProfile(name)` returning a composed `SimulationConfig` (profile entries → flat fallback) and `profileNames()` for discovery. Active-profile resolution happens at construction time.
**Alternatives:**
- New ProfileSimulationConfig wrapper — a separate class that wraps base and profile configs. Keeps SmallRyeSimulationConfig unchanged but adds a class for a concern that naturally belongs in the same parser. The prefix scanning is identical; splitting it across two classes creates artificial separation.
**Rationale:** SmallRyeSimulationConfig already does the prefix scanning that profile parsing requires. The property key `casehub.simulation.profiles.ci-replay.agent-provider.invoke.strategy` is parsed by the same `split("\\.")` mechanism — just with 5 parts instead of 3. Keeping it in one class means one pass over `config.getPropertyNames()`, one set of MethodSimulationConfig instances, one place to understand the config model.
**Trade-offs:** SmallRyeSimulationConfig grows in responsibility. Acceptable — it's still a single concern (simulation config parsing), just with two shapes (flat and profiled).
**Sources:** SmallRyeSimulationConfig.java (existing prefix scanning, constructor, split logic), MethodSimulationConfig.java (reused for profile entries)
**Depends on:** D69 (flat config as default), D13 (prefix scanning pattern)
**Exploration:** quick
**Status:** captured

## D72: SimulationRuntime.pushProfile(name) — convenience over manual overlay

**Choice:** SimulationRuntime gains `pushProfile(String name)` which looks up the named profile via a `ProfileSource` functional interface, loads profile corpus files into an overlay-isolated InMemorySimulationCorpus, and calls the existing `pushOverlay(config, corpus)`. Returns the SimulationOverlay for pop.
**Alternatives:**
- Profile resolution only — no new method on SimulationRuntime. Caller resolves the profile and pushes manually. Keeps SimulationRuntime unaware of profiles but forces every scenario consumer to write the same 3-line pattern (resolve, load corpus, push).
**Rationale:** The 3-line pattern (resolve profile → load corpus → push overlay) is boilerplate that every scenario consumer would repeat. `pushProfile(name)` encapsulates it. The method is thin — resolve, load, push — and uses the existing overlay mechanics unchanged.
**Trade-offs:** SimulationRuntime gains awareness of profiles via the ProfileSource dependency. Acceptable — the dependency is a functional interface set once at startup, not a hard coupling to SmallRye.
**Sources:** SimulationRuntime.java (pushOverlay, popOverlay), D43 (overlay stack), D44 (isolated corpus per overlay)
**Depends on:** D70 (single active profile), D71 (SmallRye resolves profiles), D73 (ProfileSource SPI)
**Exploration:** quick
**Status:** captured

## D73: ProfileSource and SimulationProfile in simulation-core — SPI unchanged

**Choice:** New types in simulation-core: `ProfileSource` (functional interface: `Optional<SimulationProfile> resolve(String name)`) and `SimulationProfile` (record: `SimulationConfig config, List<String> corpusFiles`). The `SimulationConfig` interface in simulation-core is unchanged. SmallRyeSimulationConfig implements ProfileSource. SimulationRuntime takes ProfileSource via `setProfileSource(ProfileSource)`.
**Alternatives:**
- Extend SimulationConfig with `resolveProfile()` and `profileNames()` as default methods — widens the SPI for a concern (profile naming) that not all implementations need. MapSimulationConfig and other test configs would inherit do-nothing defaults.
**Rationale:** SimulationConfig is the strategy dispatch contract — "what strategy for this qualified name?" Profiles are a naming/bundling concern orthogonal to strategy dispatch. A separate functional interface keeps the SPI minimal and avoids forcing every SimulationConfig implementation to understand profiles.
**Trade-offs:** Two interfaces instead of one. Acceptable — the concerns are genuinely different (dispatch vs naming), and ProfileSource is a single-method functional interface.
**Sources:** SimulationConfig.java (4-method SPI), MapSimulationConfig.java (test implementation), D2 (simulation-api is minimal)
**Depends on:** D72 (pushProfile uses ProfileSource)
**Exploration:** quick
**Status:** captured

## D74: Profiles carry corpus files — loaded into overlay-isolated corpus at runtime

**Choice:** Each profile can declare `casehub.simulation.profiles.<name>.corpus.files=<paths>`. At boot time, the active profile's corpus files are loaded into the base corpus alongside base corpus files. At runtime (via `pushProfile(name)`), profile corpus files are loaded into the overlay's isolated InMemorySimulationCorpus — discarded on `popOverlay()`. Consistent with D44 (scenario isolation).
**Alternatives:**
- Strategy config only — profiles only bundle strategy/capture/extractor/scorer config. Corpus loading stays global. Users who need different corpora per profile manage it via overlay pushes in code. Simpler but less useful — the whole point of a profile is bundling everything needed for a scenario.
**Rationale:** A simulation profile that bundles strategies but not the data those strategies resolve against is half a solution. The ci-replay profile needs its captured traffic YAML; the dev-demo profile needs its demo fixtures. Bundling corpus files in the profile declaration makes activation a single action: `pushProfile("ci-replay")` sets up both strategies and data.
**Trade-offs:** Profile corpus loading adds startup I/O when the active profile has corpus files. Acceptable — corpus files are small YAML fixtures loaded once. Runtime `pushProfile()` also loads files, but this is scenario setup (not hot path).
**Sources:** SimulationConfigBeans.java (existing corpus loading at startup), YamlCorpusLoader.java (existing YAML corpus parsing), D44 (isolated corpus per overlay), D43 (overlay stack)
**Depends on:** D69 (flat config as default), D72 (pushProfile), D73 (SimulationProfile record carries corpus files)
**Exploration:** quick
**Status:** captured
