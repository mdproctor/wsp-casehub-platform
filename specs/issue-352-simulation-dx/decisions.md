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

**Choice:** `sim.overlay()` auto-pushes an overlay and returns a handle. `sim.verifier()` returns a `SimulationVerifier` on the current overlay's journal.
**Alternatives:**
- Lambda-scoped overlay — `sim.run(overlay -> { ... })` pushes/pops automatically. Clean lifecycle but limits flexibility (can't interleave assertions).
- Manual — users call `runtime().pushOverlay()` and `SimulationVerifier.on(journal)` themselves. No new abstraction but doesn't reduce ceremony.
**Rationale:** Integrated overlay keeps the harness self-contained for the 80% case (push, run, verify, pop). Lambda-scoped is too restrictive when tests need mid-scenario assertions. Manual defeats the purpose of the harness.
**Trade-offs:** Users must still call `popOverlay()` — but this is one line vs the current 3-4 line setup.
**Sources:** SimulationOverlay.java, SimulationVerifier.java, SimulationVerifierTest.java
**Exploration:** quick
**Status:** captured

## D5: stub() vs seed() semantics

**Choice:** `stub(qn, input, output)` auto-derives key from `input.toString()` and registers identity key extractor if none exists. `seed(qn, input, output)` adds a sequential entry with no key. Both add to the same underlying corpus.
**Alternatives:**
- stub = fixed value (ignores input) — `stub(qn, output)` always returns same output. Different mechanism (supplier) from corpus-backed strategies.
- No stub, only seed variants — `seed(qn, input, output)` for keyed, `seed(qn, output)` for sequential. Fewer concepts but less expressive naming.
**Rationale:** `stub` and `seed` communicate intent: "this input always returns this output" vs "return these in order." Using the same corpus underneath keeps the implementation simple and composable with CorpusSeed.
**Trade-offs:** `input.toString()` as default key works for strings and simple types but may need explicit `keyExtractor()` for complex objects.
**Sources:** CorpusSeed.java, KeyExtractor.java, KeyLookupStrategy.java
**Exploration:** quick
**Status:** captured

## D6: Default tenancyId

**Choice:** `forTest()` uses `"test"` as default tenancyId. Override via `forTest("hospital-a")`.
**Alternatives:**
- null default — tests that care about tenancy must provide it. Avoids magic string but may cause NPE in tenant-aware code.
- Required parameter — `forTest(tenancyId)` always requires it. Explicit but adds ceremony back.
**Rationale:** Most tests don't focus on tenant isolation — they need a non-null tenancyId to satisfy CurrentPrincipal assertions. `"test"` is conventional across the platform's test fixtures (FixedCurrentPrincipal uses "test-tenant").
**Trade-offs:** Tests verifying tenant isolation must use `forTest("tenant-a")` — not a hardship.
**Sources:** FixedCurrentPrincipal in testing module, InvocationRecord.of() patterns
**Exploration:** quick
**Status:** captured

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

## D8: Coexistence model — unified file replaces both

**Choice:** The unified YAML file is the single source for strategy config AND corpus data. Drop support for separate MicroProfile Config strategy keys and standalone corpus-only files. One format, one loader.
**Alternatives:**
- Additive — unified file supplements existing MicroProfile Config and corpus files. Maximum backward compat but three config paths to maintain and reason about.
- Unified file replaces corpus files only — strategy config stays in MicroProfile Config properties. Two paths, each single-purpose, but the split remains.
**Rationale:** One format eliminates configuration scattered across two mechanisms. Existing tests and examples migrate to the new format. Reduces cognitive overhead for consumers.
**Trade-offs:** Breaking change — existing MicroProfile Config strategy keys stop working. Migration required for all consumers.
**Depends on:** D7 (dedicated YAML file)
**Sources:** SmallRyeSimulationConfig.java, SimulationConfigBeans.java
**Exploration:** quick
**Status:** captured

## D9: Schema scope — full parity

**Choice:** Support all existing per-method settings (strategy, capture, exhaustion-policy, key-extractor, scorer, threshold) plus corpus entries and profiles in the unified YAML format.
**Alternatives:**
- Strategy + corpus only — other settings stay in MicroProfile Config until migrated later. Smaller initial scope but keeps the split config.
- Strategy + corpus + key-extractor — three most common settings. Pragmatic middle ground but still leaves some config in MicroProfile.
**Rationale:** Since D8 eliminates MicroProfile Config strategy keys, leaving other settings there creates an inconsistent experience. Full parity means one migration, one format, no leftover dependencies.
**Trade-offs:** Larger initial implementation scope. Justified by eliminating dual-config complexity permanently.
**Depends on:** D8 (unified file replaces both)
**Sources:** MethodSimulationConfig.java (6 per-method settings), SmallRyeSimulationConfig profiles/profile corpus files
**Exploration:** quick
**Status:** captured

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

**Choice:** A new `YamlSimulationConfig` class in simulation-config-core that parses the unified YAML format via Jackson. Returns a `SimulationConfig` implementation and parsed corpus records. `SmallRyeSimulationConfig` is retired.
**Alternatives:**
- Extend YamlCorpusLoader — add strategy/config fields to the corpus parser. Changes YamlCorpusLoader's contract and name becomes misleading (no longer just a corpus loader).
- Keep SmallRyeSimulationConfig + YAML ConfigSource — register a custom ConfigSource that flattens structured YAML to property keys. Roundabout flattening, and corpus entries still can't be represented as flat properties.
**Rationale:** The unified format is structured YAML, not flat properties. A purpose-built Jackson parser is simpler, testable, and doesn't fight the MicroProfile Config model. SmallRyeSimulationConfig's prefix-scanning approach is irrelevant when the input is a YAML tree.
**Trade-offs:** New class to maintain. SmallRyeSimulationConfig retirement requires migration of any direct references (primarily SimulationConfigBeans).
**Depends on:** D7 (dedicated YAML file), D8 (replaces both)
**Sources:** SmallRyeSimulationConfig.java, YamlCorpusLoader.java, Jackson YAMLFactory
**Exploration:** quick
**Status:** captured

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
**Rationale:** This repo is pre-release with no external consumers of these classes directly. The corpus loading logic (InputStream → InvocationRecord list) is simple enough to absorb into YamlSimulationConfig without duplication. No value in keeping deprecated code when there are zero downstream dependencies.
**Trade-offs:** Existing corpus YAML test fixtures need to be migrated to the new format or loaded through the new parser's corpus-files mechanism.
**Depends on:** D12 (new YamlSimulationConfig class), D8 (replaces both)
**Sources:** SmallRyeSimulationConfig.java, YamlCorpusLoader.java, SimulationConfigBeans.java
**Exploration:** quick
**Status:** captured
