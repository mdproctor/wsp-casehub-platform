# Decisions — Epic #683: Declarative Playbook Testing

## D1: Assertion model

**Choice:** Extend the existing expression engine with assertion functions
**Alternatives:**
- Structured assertion vocabulary (contains, equals, hasSize as first-class YAML keys) — more readable but introduces a parallel DSL alongside expressions
- Both expression + structured sugar — best readability but double the surface area to maintain
**Rationale:** The existing `AssertPlugin` already uses `ExpressionEngineRegistry` for expression-based assertions. Adding assertion functions (contains(), hasSize(), matches(), allSucceeded()) to the expression engine keeps one syntax for conditions and assertions. Consistent with the four-tier escape model established in prior specs.
**Trade-offs:** Expression syntax is less immediately readable than structured YAML keys for simple assertions. Mitigated by clear function naming and good error messages.
**Sources:** yaml-step-runtime AssertPlugin.java, issue-391 spec D14 (four-tier escape model)
**Exploration:** quick
**Status:** captured

## D2: Test runner integration

**Choice:** JUnit Platform TestEngine + standalone CLI
**Alternatives:**
- JUnit Platform TestEngine only — no CLI for non-Maven contexts
- Maven plugin only — no IDE integration (no green/red tree, no click-to-navigate)
**Rationale:** TestEngine gives native IntelliJ integration (critical for tutorials-as-tests DX) and automatic Surefire discovery. Standalone CLI supports CI pipelines, Docker containers, and non-Maven build systems. The two share the same core — CLI wraps the engine.
**Trade-offs:** Two entry points to maintain. Mitigated by the core extraction pattern (yaml-test-core does the work, both entry points are thin).
**Sources:** JUnit Platform TestEngine SPI documentation
**Exploration:** quick
**Status:** captured

## D3: Tutorial level ordering

**Choice:** Convention-based ordering by directory structure and filename prefix
**Alternatives:**
- Explicit depends-on declarations in YAML — flexible but more ceremony
- Suite manifest file — central control but another file to maintain
**Rationale:** Directory structure (tutorials/01-basics/, tutorials/02-sessions/) naturally implies order. Files within a level run independently. The runner discovers and orders by path prefix. No extra metadata needed — the filesystem IS the manifest.
**Trade-offs:** No cross-directory dependency declaration. If a test in 03-advanced/ depends on a specific test in 02-sessions/, the convention doesn't express that. Acceptable because tutorial levels should be self-contained.
**Sources:** Existing ops tutorial structure (level-based directories)
**Exploration:** quick
**Status:** captured

## D4: Test file model

**Choice:** A .test.yaml file IS a playbook with a `simulate:` top-level block. The simulate block uses the same schema as simulation.yaml's methods section.
**Alternatives:**
- Reference-only (point to simulation.yaml profiles) — minimal test files but requires maintaining separate corpus files, breaks tutorial self-containment
- New test-specific format — simpler but introduces a new parser and a new concept to learn
**Rationale:** First-principles analysis: a test sets up environment (simulate block → overlay push), runs steps (standard playbook execution), and checks results (assert steps). The playbook compiler already handles sequencing, decorators, variable resolution. The simulate block reuses YamlSimulationConfig's schema because it IS the same concept — configuring which SPI calls get intercepted. One format, one parser, one concept.
**Trade-offs:** Test files look like playbooks (because they are). Someone expecting a dedicated test format might find it surprising initially.
**Sources:** simulation-config-core YamlSimulationConfig, simulation-core SimulationRuntime overlay stack, feat-294 D43-47 (overlay isolation)
**Exploration:** deep-analysis
**Status:** captured

## D5: Output capture from run-playbook

**Choice:** Capture block with named outputs — `run-playbook: { file: path.yaml, capture: results }` — outputs land in `${results.outputName}`
**Alternatives:**
- Merge into parent scope — simpler but risks name collisions, unclear provenance
- Structured result object (outputs, stepCount, events, duration) — powerful but complex
**Rationale:** Follows the existing `capture:` pattern used by agent-session-query and other step types. Consistent, predictable, no new concept.
**Trade-offs:** Can't directly assert on execution metadata (step count, duration) without extending the capture. Acceptable — add structured result later if needed.
**Sources:** yaml-step-runtime agent-session-query step capture pattern
**Exploration:** quick
**Status:** captured

## D6: emit-event step type

**Choice:** `@Plugin` step type (like assert)
**Alternatives:**
- Structural compiler step (like delay/if/match) — compiler visibility for optimisation but more work, less flexibility
- Reuse existing signal: step — fewer concepts but conflates coordination signals with CloudEvent emission
**Rationale:** CloudEventFixtureBuilder.fromMap() already converts maps to CloudEvents. A @Plugin step calls fromMap() and fires via CDI event bus. No compiler changes needed. Simple, discoverable, follows the plugin pattern.
**Trade-offs:** No compiler-level optimisation of emit-event + delay sequences. Acceptable — the simplicity/flexibility tradeoff favours the plugin approach.
**Sources:** event-simulation-core CloudEventFixtureBuilder, yaml-plugin-api @Plugin
**Exploration:** quick
**Status:** captured

## D7: Module layout

**Choice:** yaml-test-core (framework-neutral POJO) + yaml-test (Quarkus CDI wiring + JUnit Platform TestEngine registration)
**Alternatives:**
- Single yaml-test module — simpler but breaks core extraction pattern, makes Spring support harder
- Three modules (api + core + runner) — maximum separation but over-engineered for a test framework
**Rationale:** Follows the established -core pattern (simulation-core, expression-core, agent-claude-core, etc.). yaml-test-core contains discovery, overlay orchestration, result model, CLI entry point. yaml-test contains CDI wiring and JUnit Platform TestEngine. Spring support later via yaml-test-spring if needed.
**Trade-offs:** Two modules instead of one. Acceptable — the pattern is established and the Spring path is clear.
**Sources:** All -core modules in platform (simulation-core, expression-core, etc.)
**Exploration:** quick
**Status:** captured
