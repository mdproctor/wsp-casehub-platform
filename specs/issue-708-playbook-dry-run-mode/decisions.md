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
