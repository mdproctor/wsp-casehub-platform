## D1: PlaybookRunnerCore location

**Choice:** Extract PlaybookRunnerCore POJO into yaml-test-core alongside YamlTestExecutor
**Alternatives:**
- New standalone yaml-playbook-runner module — cleaner boundaries but duplicates simulation wiring
- Inline into yaml-step-runtime — simplest but mixes step evaluation concerns with top-level runner
**Rationale:** yaml-test-core already has the simulation wiring (SimulateBlockParser, SimulationRuntime integration). PlaybookRunnerCore shares the same parse → resolve → evaluate → trace pipeline. RunPlaybookPlugin becomes a thin delegate. CLI and MCP both compose PlaybookRunnerCore.
**Trade-offs:** Adds a conceptual dependency from RunPlaybookPlugin → PlaybookRunnerCore, but the code is already there — just extracted.
**Sources:** RunPlaybookPlugin.java, YamlTestExecutor.java, SimulateBlockParser.java
**Exploration:** quick
**Status:** captured

## D2: Step trace model — shared base type

**Choice:** StepTraceNode tree record with children list, StepOutcome enum, and extensible detail map
**Alternatives:**
- Flat list with depth marker — simpler to serialize but loses parent-child structure
**Rationale:** Tree mirrors playbook nesting naturally (block, parallel, if/else branches as children). Flattening for CLI is a trivial depth-first walk. Extensible detail map avoids type explosion while capturing type-specific info (simulation strategy, condition value, matched case).
**Trade-offs:** Slightly more complex serialization than flat list, but Jackson handles tree records natively.
**Sources:** StructuralStepEvaluator.java (dispatches by ResolvedStep variant), RunPlaybookPlugin.java (existing flat stepEvents)
**Exploration:** quick
**Status:** captured

## D3: MCP API surface — PlaybookApi

**Choice:** Focused API with run (dry-run flag) + validate operations on @McpDomain("playbooks")
**Alternatives:**
- Richer API with run + validate + list + compile — scope creep for M/Low issue, list/compile are different concerns
**Rationale:** Two operations match issue scope. validate is nearly free (Walker.resolve already does structural validation). PlaybookRunRequest carries dryRun boolean, optional vars, optional corpusPath override, optional simulation profile name. Additional operations are additive later.
**Trade-offs:** No list/compile in v1 — acceptable since those are different user journeys.
**Depends on:** D1 (PlaybookRunnerCore location), D2 (StepTraceNode in result)
**Sources:** AgentHttpApi.java (API pattern), TemporalDriverService.java (MCP domain pattern)
**Exploration:** quick
**Status:** captured

## D4: Simulation activation for dry-run

**Choice:** Push overlay from simulation.yaml convention + optional corpus override + optional named profile
**Alternatives:**
- New "dry-run runtime" that wraps all SPIs at CDI level — reinvents simulation layer, complex, tightly coupled
**Rationale:** SimulationRuntime.pushOverlay/popOverlay is the existing mechanism for test-scoped simulation activation. Dry-run uses the same path: discover simulation.yaml (convention), optionally layer a corpus override or named profile on top. No new simulation infrastructure needed.
**Trade-offs:** CLI must construct SimulationRuntime from scratch (no CDI container) — requires standalone bootstrap. MCP path gets it injected.
**Depends on:** D1 (PlaybookRunnerCore takes SimulationRuntime)
**Sources:** YamlTestExecutor.java:48-53 (pushOverlay pattern), SimulationRuntime.java (overlay stack), YamlSimulationConfig.java (convention discovery)
**Exploration:** quick
**Status:** captured

## D5: CLI surface

**Choice:** Extend YamlTestCli with --dry-run flag and playbook mode (file extension distinction)
**Alternatives:**
- New PlaybookCli class — clean separation but duplicates arg parsing and introduces second CLI binary
**Rationale:** One CLI, two modes. .test.yaml files run as tests (existing). .yaml files run as playbooks through PlaybookRunnerCore. --dry-run forces simulation on. Also fixes the existing gap where YamlTestCli doesn't wire SimulationRuntime — benefits test execution too.
**Trade-offs:** YamlTestCli grows in responsibility, but the two modes share enough infrastructure (plugin registry, simulation wiring, report output) that separation would be more code for less clarity.
**Depends on:** D1 (PlaybookRunnerCore), D4 (simulation activation)
**Sources:** YamlTestCli.java (existing CLI, no SimulationRuntime wiring)
**Exploration:** quick
**Status:** captured
