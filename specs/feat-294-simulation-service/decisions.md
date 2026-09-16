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
