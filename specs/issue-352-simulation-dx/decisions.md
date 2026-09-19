# Decisions — Simulation DX (#352)

## D1: Strategy selection — implicit from data shape

**Choice:** Strategy is inferred from how data is added: `stub()` implies key-lookup, `seed()` without key implies sequential. Explicit `.strategy(qn, name)` escape hatch available.
**Alternatives:**
- Always explicit — require `.strategy(qn, "key-lookup")` for every method. More typing, no ambiguity.
- Implicit with warning — auto-select but log when implicit choice is used. Noise in test output.
**Rationale:** The 80% case is either "same input → same output" (key-lookup) or "return in order" (sequential). Making the user spell out strategy names adds ceremony without safety — the data shape already communicates intent.
**Trade-offs:** Mixed stub+seed on the same qualifiedName becomes ambiguous — must be an error.
**Sources:** SimulationGettingStartedTest.java (current ceremony), issue #353 API sketch
**Exploration:** quick
**Status:** captured

## D2: Return type — purpose-built Simulation class

**Choice:** `build()` returns a new `Simulation` class wrapping runtime + corpus. Exposes `resolve()`, `overlay()`, `verifier()`, `runtime()` escape hatch.
**Alternatives:**
- Return SimulationRuntime directly — no new type, but `resolve()` requires qualified name + type parameters (turbofishing), losing DX.
- Return SimulationProfile — more composable for overlay stacking, but not self-contained for standalone tests.
**Rationale:** A purpose-built type hides plumbing (corpus, config, extractor registration) and provides a clean test-facing API. The `runtime()` escape hatch preserves access to the full API when needed.
**Trade-offs:** One more type to learn. Justified by 80% case simplification.
**Sources:** SimulationRuntime.java, SimulationOverlay.java, issue #353 API sketch
**Exploration:** quick
**Status:** captured

## D3: Multi-method scope

**Choice:** One `Simulation` instance configures multiple qualified names. `.stub("spi.query", ...).stub("spi.store", ...).build()`.
**Alternatives:**
- Single-method — each Simulation handles one qualifiedName. Simpler type but more objects and wiring for multi-method SPIs.
**Rationale:** Real tests simulate entire SPIs (2-5 methods). One runtime, many methods is the existing SimulationRuntime model — the harness should mirror it.
**Trade-offs:** None significant — single-method is a degenerate case of multi-method.
**Sources:** SimulationRuntimeTest.java (multi-method config), PerMethodStrategyTest.java
**Exploration:** quick
**Status:** captured

## D4: Integrated overlay and verification

**Choice:** `sim.overlay()` auto-pushes an overlay and returns a handle. `SimulationOverlay` implements `AutoCloseable` — `try (var overlay = sim.overlay()) { ... }` auto-pops on normal exit and on exception. `sim.verifier()` returns a cached `SimulationVerifier` per overlay — repeated calls return the same instance, accumulating verified-method state for `noUnverifiedCalls()`.
**Alternatives:**
- Lambda-scoped overlay — `sim.run(overlay -> { ... })` pushes/pops automatically. Clean lifecycle but limits flexibility (can't interleave assertions).
- Manual — users call `runtime().pushOverlay()` and `SimulationVerifier.on(journal)` themselves. No new abstraction but doesn't reduce ceremony.
**Rationale:** Integrated overlay keeps the harness self-contained for the 80% case (push, run, verify, pop). AutoCloseable gives exception safety without sacrificing the ability to interleave assertions within the try block. Cached verifier per overlay ensures `noUnverifiedCalls()` works correctly when users verify methods across multiple calls.
**Trade-offs:** SimulationOverlay needs a back-reference to the runtime for `close()`. Acceptable coupling since overlays are already created by the runtime.
**Sources:** SimulationOverlay.java, SimulationVerifier.java, SimulationVerifierTest.java
**Exploration:** quick
**Status:** revised (R1-04, R1-06: added AutoCloseable lifecycle and cached verifier)

## D5: stub() vs seed() semantics

**Choice:** `stub(qn, input, output)` auto-derives key from `input.toString()` and registers identity key extractor if none exists. `seed(qn, input, output)` adds a sequential entry with no key. Both add to the same underlying corpus.
**Alternatives:**
- stub = fixed value (ignores input) — `stub(qn, output)` always returns same output. Different mechanism (supplier) from corpus-backed strategies.
- No stub, only seed variants — `seed(qn, input, output)` for keyed, `seed(qn, output)` for sequential. Fewer concepts but less expressive naming.
**Rationale:** `stub` and `seed` communicate intent: "this input always returns this output" vs "return these in order." Using the same corpus underneath keeps the implementation simple and composable with CorpusSeed.
**Trade-offs:** The 3-arg `stub()` validates at build time that the input type has stable `toString()` — permitted for String, primitive wrappers, and Records. Other types throw `SimulationConfigException` pointing the user to the 4-arg `stub(qn, key, input, output)` variant or `.keyExtractor()`. This prevents silent key mismatches from `ClassName@hashCode` defaults.
**Sources:** CorpusSeed.java, KeyExtractor.java, KeyLookupStrategy.java
**Exploration:** quick
**Status:** revised (R1-02: fail-fast validation for toString() stability)

## D6: Default tenancyId

**Choice:** `forTest()` uses `"test"` as default tenancyId. Override via `forTest("hospital-a")`.
**Alternatives:**
- null default — tests that care about tenancy must provide it. Avoids magic string but may cause NPE in tenant-aware code.
- Required parameter — `forTest(tenancyId)` always requires it. Explicit but adds ceremony back.
**Rationale:** Most tests don't focus on tenant isolation — they need a non-null tenancyId to satisfy CurrentPrincipal assertions. `"test"` is conventional across the platform's test fixtures (FixedCurrentPrincipal uses "test-tenant").
**Trade-offs:** Tests verifying tenant isolation must use `forTest("tenant-a")` — not a hardship. The `defaultTenancyId` is stored on the `Simulation` instance and passed to `recordJournal()` in `resolve()`, ensuring tenant-aware verification works end-to-end.
**Sources:** FixedCurrentPrincipal in testing module, InvocationRecord.of() patterns
**Exploration:** quick
**Status:** revised (R1-05: defaultTenancyId flows through to journal recording)

---

# Decisions — Inline Corpus in Unified YAML (#361)

## D7: Config home — dedicated YAML file

**Choice:** A standalone simulation YAML file that combines strategy declarations and corpus entries per qualified name. Loaded by a new parser in simulation-config-core. Platform owns parsing, consumers point to the file.
**Alternatives:**
- Extension of existing corpus YAML — extend corpus file format to optionally include strategy declarations. Minimal new surface but conflates two concerns in one format.
- Embedded in application.yaml — structured YAML section under casehub.simulation key, parsed via SmallRye Config or custom ConfigSource. Fights MicroProfile Config's flat property model.
**Rationale:** The unified format is structured YAML (lists of maps for corpus entries). MicroProfile Config can't represent this natively. A dedicated file with its own parser is the cleanest approach.
**Trade-offs:** One more file to discover. Mitigated by convention-based classpath discovery (D10).
**Sources:** SmallRyeSimulationConfig.java (current flat-property parsing), YamlCorpusLoader.java (current corpus parsing), issue #361 example YAML
**Exploration:** quick
**Status:** captured

## D8: Coexistence model — additive (YAML + MicroProfile Config)

**Choice:** The unified YAML file handles all structured simulation configuration (per-method strategies, corpus data, profiles, default-tenancy-id). Environment-level knobs (`active-profile`, `config` file path) remain as MicroProfile Config properties, preserving Quarkus profile qualification (`%test.casehub.simulation.active-profile=ci-replay`). Standalone corpus-only files are retired — corpus moves into the unified YAML (inline or via corpus-files refs).
**Alternatives:**
- Unified file replaces everything — drop MicroProfile Config entirely. Single source but loses Quarkus profile integration for environment switching.
- Unified file replaces corpus only — strategy config stays in MicroProfile Config. Preserves profile integration but keeps structured data (corpus) split from its configuration.
**Rationale:** The strategy profiles spec (2026-09-18) was designed around Quarkus profile integration — `%test` and `%dev` qualifiers select simulation profiles per environment. A standalone YAML parser has no awareness of Quarkus profiles. The additive model matches the platform's existing endpoints-config pattern: YAML for structured data, MicroProfile Config for simple environment-level knobs. Each format serves its strength — no duplication.
**Trade-offs:** Two configuration mechanisms remain, but with clear separation of concerns: YAML for structured simulation config, MicroProfile Config for environment knobs. No overlap in what each handles.
**Depends on:** D7 (dedicated YAML file)
**Sources:** SmallRyeSimulationConfig.java, SimulationConfigBeans.java, EndpointsConfigBeans.java (additive pattern precedent), 2026-09-18-strategy-profiles-design.md §2 (Quarkus profile interaction)
**Exploration:** quick
**Status:** revised (R1-09: additive model preserves Quarkus profile integration)

## D9: Schema scope — full parity

**Choice:** Support all existing per-method settings (strategy, capture, exhaustion-policy, key-extractor, scorer, threshold) plus corpus entries and profiles in the unified YAML format.
**Alternatives:**
- Strategy + corpus only — other settings stay in MicroProfile Config until migrated later. Smaller initial scope but keeps the split config.
- Strategy + corpus + key-extractor — three most common settings. Pragmatic middle ground but still leaves some config in MicroProfile.
**Rationale:** Per-method settings (strategy, capture, exhaustion-policy, key-extractor, scorer, threshold) are part of a method's simulation configuration — they belong alongside the method's strategy and corpus in the structured YAML, not scattered in flat MicroProfile Config properties. Full parity in YAML means each method's simulation is fully declared in one place.
**Trade-offs:** Larger initial implementation scope. Justified by coherent per-method configuration in a single format.
**Depends on:** D8 (YAML for structured config)
**Sources:** MethodSimulationConfig.java (6 per-method settings), SmallRyeSimulationConfig profiles/profile corpus files
**Exploration:** quick
**Status:** revised (R1-15: rationale updated for additive model)

## D10: Discovery — convention path

**Choice:** Look for `simulation.yaml` (or `simulation.yml`) on the classpath root by convention. A single MicroProfile Config property (`casehub.simulation.config`) can override the path. Zero config for the common case.
**Alternatives:**
- Config property only — require explicit `casehub.simulation.config=classpath:path` in application.properties. No magic but more ceremony.
- Directory scan — scan a classpath directory for all .yaml files and merge. Supports multi-module composition but more complex discovery and ordering.
**Rationale:** Convention-over-configuration. Most consumers have one simulation config file. The override property handles non-standard paths. Directory scan is premature — multi-file composition is already handled by corpus-files references within the unified format (D11).
**Trade-offs:** "Magic" classpath discovery can surprise if an unexpected simulation.yaml appears. Low risk in practice — simulation modules are opt-in.
**Sources:** endpoints-config/ (precedent: casehub.platform.endpoints.files config), Quarkus application.yaml convention
**Exploration:** quick
**Status:** captured

## D11: External corpus refs — both inline and file refs

**Choice:** Each qualified name can have inline `corpus:` entries AND/OR a `corpus-files:` list pointing to external YAML files. Inline for small scenarios, file refs for large fixture sets. Entries from both merge (append, not replace).
**Alternatives:**
- Inline only — all corpus entries must be inline. Simplest schema but forces large corpora into one file, impractical for domain-specific fixtures.
- File refs at top level only — per-method corpus is always inline; a top-level key includes external files across all qualified names. Two scopes with different semantics.
**Rationale:** Real consumers range from 2-entry test stubs to 200-entry domain fixtures. Inline covers the small case (#361's primary goal), file refs cover the large case. Merging preserves composability.
**Trade-offs:** Two corpus sources per qualified name adds merge-order awareness. Mitigated by append semantics (inline first, then file refs).
**Sources:** YamlCorpusLoader.loadFromPaths() (existing merge-by-append), issue #361 example
**Exploration:** quick
**Status:** captured

## D12: Parser implementation — new YamlSimulationConfig class

**Choice:** A new `YamlSimulationConfig` class in simulation-config-core that parses the unified YAML format via Jackson. Absorbs all responsibilities currently in `SmallRyeSimulationConfig`: implements `SimulationConfig` (strategyFor, captureEnabled, exhaustionPolicy, threshold), implements `ProfileSource` (resolve named profiles), and exposes `extractorSpecs()`, `scorerSpecs()`, `defaultTenancyId()`, `profileNames()`, and `activeProfileCorpusFiles()` for CDI wiring by `SimulationConfigBeans`. `SmallRyeSimulationConfig` is retired.
**Alternatives:**
- Extend YamlCorpusLoader — add strategy/config fields to the corpus parser. Changes YamlCorpusLoader's contract and name becomes misleading (no longer just a corpus loader).
- Keep SmallRyeSimulationConfig + YAML ConfigSource — register a custom ConfigSource that flattens structured YAML to property keys. Roundabout flattening, and corpus entries still can't be represented as flat properties.
**Rationale:** The unified format is structured YAML, not flat properties. A purpose-built Jackson parser is simpler, testable, and doesn't fight the MicroProfile Config model. SmallRyeSimulationConfig's prefix-scanning approach is irrelevant when the input is a YAML tree.
**Trade-offs:** New class to maintain. SmallRyeSimulationConfig retirement requires migration of any direct references (primarily SimulationConfigBeans).
**Depends on:** D7 (dedicated YAML file), D8 (YAML for structured config)
**Sources:** SmallRyeSimulationConfig.java, YamlCorpusLoader.java, Jackson YAMLFactory, SimulationConfigBeans.onStartup()
**Exploration:** quick
**Status:** revised (R1-11: enumerated full API surface including ProfileSource, extractors, scorers)

## D13: Profile representation — nested in same file

**Choice:** Profiles are nested under a top-level `profiles:` key within the same simulation.yaml file. Each profile contains a `methods:` block that overrides the base `methods:`. Base methods are under a top-level `methods:` key. Known top-level keys: `default-tenancy-id`, `methods`, `profiles`.
**Alternatives:**
- Separate profile files — base in simulation.yaml, profiles in simulation-{profile}.yaml. Convention-discovered by active profile name. Mirrors Spring's application-{profile}.yaml but adds file proliferation.
- Flat schema — qualified names as top-level keys directly, no `methods:` wrapper. Terser but reserves the top-level namespace and makes profile syntax asymmetric.
**Rationale:** One file is easier to read, discover, and version. The `methods:` wrapper key cleanly separates known framework keys (default-tenancy-id, profiles) from qualified-name keys, avoiding namespace collisions. Profile layering mirrors the existing SmallRyeSimulationConfig inheritance model.
**Trade-offs:** Large configs with many profiles get long. Acceptable — most consumers have 1-2 profiles.
**Depends on:** D7 (dedicated YAML file), D9 (full parity)
**Sources:** SmallRyeSimulationConfig profiles, Spring application-{profile}.yaml convention
**Exploration:** quick
**Status:** captured

## D14: Retirement — delete SmallRyeSimulationConfig and YamlCorpusLoader

**Choice:** Remove both classes entirely. YamlSimulationConfig absorbs all corpus loading logic. Tests and SimulationConfigBeans migrate to the new class. Clean break, no dead code.
**Alternatives:**
- Keep YamlCorpusLoader internally — reuse it for loading external corpus-files references. Preserves tested loader but adds an internal dependency that YamlSimulationConfig could handle directly.
- Deprecate both for one release — mark @Deprecated, keep alongside YamlSimulationConfig. Softer migration but dual paths add confusion.
**Rationale:** This repo is pre-release with no external downstream consumers of these classes. Internal platform references (~46 across production code, tests, specs, and guides) require coordinated migration — including `consumer-guide.md` and `contributor-guide.md` which teach consumers to work with `SmallRyeSimulationConfig`. The corpus loading logic (InputStream → InvocationRecord list) is simple enough to absorb into YamlSimulationConfig without duplication. No value in keeping deprecated code when there are zero downstream dependencies — the internal migration is mechanical.
**Trade-offs:** Existing corpus YAML test fixtures need to be migrated to the new format or loaded through the new parser's corpus-files mechanism. Documentation migration is part of the scope.
**Depends on:** D12 (new YamlSimulationConfig class), D8 (YAML for structured config)
**Sources:** SmallRyeSimulationConfig.java, YamlCorpusLoader.java, SimulationConfigBeans.java
**Exploration:** quick
**Status:** revised (R1-10: qualified "no external consumers" to "no external downstream consumers," acknowledged internal migration surface)

## D15: JSON Schema for YAML validation

**Choice:** Publish a JSON Schema alongside the YAML parser for IDE auto-completion and validation of `simulation.yaml` files. The schema is generated from or validated against the parser's expected structure and published as a classpath resource.
**Alternatives:**
- No schema — users rely on documentation and error messages. Lower initial effort but poor DX for a framework centered on DX improvement.
- YAML schema comments only — inline `# Valid values: ...` comments in example files. Partial IDE support, no real-time validation.
**Rationale:** Issue #352 is specifically about simulation DX. A dedicated YAML file with a well-defined schema is the perfect candidate for IDE-assisted authoring. JSON Schema enables auto-completion in IntelliJ, VS Code, and other editors. The previous MicroProfile Config approach had "no IDE auto-completion for config keys" as a known trade-off — the move to a dedicated file eliminates this limitation.
**Trade-offs:** Schema must be kept in sync with the parser. Mitigated by a test that validates the schema against the parser's accepted structure.
**Depends on:** D7 (dedicated YAML file), D9 (full parity defines schema scope)
**Sources:** Issue #352 (simulation DX)
**Exploration:** quick (surfaced by reviewer R1-12)
**Status:** captured

## D16: Simulation.forTest() is standalone — no YAML/CDI composition

**Choice:** `Simulation.forTest()` creates its own `SimulationRuntime` with a fresh `InMemorySimulationCorpus`, independent of any CDI-configured runtime or YAML config. The two worlds (programmatic test setup and declarative config) share `SimulationRuntime` as the underlying engine but do not compose.
**Alternatives:**
- forTest(runtime) — accept an existing `SimulationRuntime` (from CDI) and layer programmatic overrides on top. Enables composing YAML baseline with test-specific stubs.
- forTest() loads simulation.yaml — auto-discover and merge YAML baseline config. Reduces test setup when a YAML baseline exists.
**Rationale:** `Simulation.forTest()` targets standalone unit tests — the 80% case where no CDI container or YAML config exists. The spec explicitly scopes this as "POJO only, in simulation-core" (out of scope: CDI integration). CDI integration tests already have `SimulationRuntime` injected and can use the overlay API directly. Mixing programmatic and declarative config in one API adds complexity for the common case to serve an edge case.
**Trade-offs:** Tests with a YAML baseline that need one programmatic override must use the runtime API directly. A future `forTest(runtime)` overload could serve this case without changing the base API.
**Sources:** 2026-09-19-fluent-test-harness-design.md (scope section), Simulation.Builder.build()
**Exploration:** quick (surfaced by reviewer R1-13)
**Status:** captured
