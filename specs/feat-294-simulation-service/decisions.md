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

## D15: Single module — simulation-config-core + simulation-config

**Choice:** All three deliverables (config binding, corpus populator, declarative extractors) live in one new module pair: `simulation-config-core` (POJO) + `simulation-config` (Quarkus beans).
**Alternatives:**
- Split into simulation-config + simulation-corpus-yaml — more granular, consumers who want config only don't pull Jackson. But adds a module for a startup-only concern.
**Rationale:** All three are startup-time configuration concerns sharing the `casehub.simulation.*` prefix. One module, one dependency to add. Follows the config/ and endpoints-config/ pattern.
**Trade-offs:** Consumers who only want config binding also get Jackson/SnakeYAML on the classpath. Acceptable — simulation is opt-in and the dependencies are transitives of Quarkus anyway.
**Sources:** config-core/ + config/, endpoints-config-core/ + endpoints-config/
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
