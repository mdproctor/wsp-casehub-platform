## D1: CorpusSelector integration point

**Choice:** Corpus-level decorator (PhasedCorpus wraps real corpus, delegates to phase-specific data based on selector state)
**Alternatives:**
- Strategy wrapper (PhasedStrategy) — more powerful (per-phase strategy types) but more complex wiring and config changes
- Overlay automation — reuses overlay stack but overlays are global, causing interference across methods
**Rationale:** Zero changes to existing strategies, generated @Decorators, or SimulatingAction. The selector is invisible above the corpus layer. All YAML examples in the issue show the same strategy type across phases with different data, which is exactly what this handles.
**Trade-offs:** Cannot support per-phase strategy type changes (e.g., key-lookup in phase 1, sequential in phase 2). This is an unusual edge case and can be added via strategy-level wrapping later if needed.
**Sources:** SimulationRuntime.java:52-66, KeyLookupStrategy.java, SimulatedPreferenceProvider.java (generated decorator)
**Exploration:** quick
**Status:** captured

## D2: Module placement

**Choice:** CorpusSelector interface + PhasedCorpus in simulation-api (zero-dep), implementations in simulation-core
**Alternatives:**
- All in simulation-core — simpler but breaks the established api/core separation pattern
**Rationale:** Follows the same pattern as SimulationStrategy (interface in api) and its implementations (in core). PhasedCorpus decorates SimulationCorpus which is already in simulation-api, so it belongs there.
**Trade-offs:** DurationSelector needs SpeedMultiplier (from yaml-core) — this means simulation-core already depends on yaml-core, so implementations naturally live there.
**Sources:** simulation-api module (SimulationStrategy, SimulationCorpus), simulation-core module (strategy implementations)
**Exploration:** quick
**Depends on:** D1 (corpus-level decorator determines what goes in api vs core)
**Status:** captured

## D3: StateMachineSelector trigger mechanism

**Choice:** Callback-based — selector exposes `advance(String trigger)`, wiring layer connects step hooks / event observers / signals to advance() calls
**Alternatives:**
- Event bus subscription — more decoupled but requires new event bus abstraction in simulation-core (which currently has none)
- Wrap yaml-core StateMachine directly — powerful but deep coupling to orchestration layer
**Rationale:** Clean, testable API. The selector doesn't need to know where triggers come from. Step lifecycle hooks, CDI event observers, and playbook signal handlers all just call advance(). The YAML config declares the transition map; the wiring layer connects sources to advance().
**Trade-offs:** Wiring layer must be written for each trigger source (step completion, event detection, explicit signal). This is a pro for testability and a con for convenience — but the wiring is thin.
**Sources:** yaml-core StateMachine, SimulatingAction.java (step lifecycle integration point)
**Exploration:** quick
**Depends on:** D1 (selector architecture)
**Status:** captured

## D4: YAML schema — corpus vs corpus-selection mutual exclusion

**Choice:** `corpus` and `corpus-selection` are mutually exclusive on a method. You use one or the other.
**Alternatives:**
- Top-level `corpus` as default/fallback phase — convenient but ambiguous semantics when selector has no matching phase
**Rationale:** Clear semantics. Static corpus (existing) or phased corpus (new). No ambiguity about fallback behavior. Validation can reject configs that have both.
**Trade-offs:** Users must move all corpus entries into phases when adopting corpus-selection. This is the right friction — it forces explicit phase modeling.
**Sources:** simulation.schema.json, YamlSimulationConfig.java
**Exploration:** quick
**Depends on:** D1 (corpus-level decorator)
**Status:** captured

## D5: SimulationRuntime wiring for PhasedCorpus

**Choice:** Extend SimulationConfig with `Optional<CorpusSelectorConfig> corpusSelection(String qualifiedName)`. SimulationRuntime.createStrategy() checks it and wraps the corpus in PhasedCorpus when present.
**Alternatives:**
- Separate PhasedCorpusFactory — builds PhasedCorpus during corpus loading, runtime receives pre-built corpus. Cleaner separation but selector lifecycle managed outside runtime.
**Rationale:** Config metadata flows through the established SimulationConfig interface. The runtime already uses SimulationConfig for strategy name, exhaustion policy, match policy, etc. — corpus selection is another per-method configuration dimension.
**Trade-offs:** SimulationConfig gets another method (growing interface). This is acceptable — the interface uses default methods returning Optional.empty() so existing implementations aren't affected.
**Sources:** SimulationConfig.java, SimulationRuntime.java:171-196 (createStrategy)
**Exploration:** quick
**Depends on:** D1, D4 (corpus-level decorator + mutual exclusion)
**Status:** captured

## D6: CorpusSelectorConfig shape

**Choice:** Typed sealed interface — one record per selector type (StateMachine, Duration, LookupCount, Weighted)
**Alternatives:**
- Generic map-based config — single record with type string + properties map, runtime validation only
**Rationale:** Four known selector types with distinct configuration shapes. Sealed interface gives compile-time exhaustiveness checking in SimulationRuntime.createStrategy(). Parse-time validation in YamlSimulationConfig catches config errors early.
**Trade-offs:** Adding a new selector type requires adding a new record to the sealed interface (in simulation-api). This is acceptable — new selector types are infrequent and should be deliberate.
**Sources:** simulation-api module pattern (sealed types: Result in yaml-plugin-api)
**Exploration:** quick
**Depends on:** D5 (SimulationConfig carries CorpusSelectorConfig)
**Status:** captured
