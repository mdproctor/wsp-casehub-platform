# Design Journal — issue-294-simulation-service

## 2026-09-15 — Phase 1 complete, phase 2 planned

### What shipped

Five modules implementing the core simulation framework:
- **simulation-api** — zero-dep contracts (SimulationStrategy, SimulationCorpus, KeyExtractor, InvocationRecord, @SimulationEligible, NoOpSimulationCorpus, SimulationConfig, SimulationRuntime)
- **simulation-core** — four strategy POJOs (Sequential, KeyLookup, Random, RecordedReplay) + SimulationRuntime strategy factory
- **simulation-inmem** — InMemorySimulationCorpus @Alternative @Priority(100)
- **simulation-generator** — APT generating @Decorator per @SimulationEligible SPI
- **agent-simulation-core** — SimulatedAgentBackend (Path B for RoutingAgentProvider)

112 tests total. 20 are tutorial-style tests in a `tutorial/` package showing usage patterns.

### Consumer feedback (banking platform evaluation)

Key insight: flat interfaces are a prerequisite for decorator-based simulation. Capability-based SPIs (returning intermediate objects) break method-level interception. This validates the flat interface design choice for reasons not anticipated when the decision was made.

Also surfaced: the guide explains mechanism but not applicability. Developers need domain scenarios (simulate a payment gateway, simulate a judge LLM, simulate a ticker stream) to understand where simulation fits their work.

### Design gap: platform-api SPI registration

@SimulationEligible lives in simulation-api (design decision D2). platform-api SPIs (CaseMemoryStore, PreferenceStore) cannot depend on simulation-api without breaking the zero-dep boundary. Solution: config-driven scan via META-INF/simulation-eligible.txt alongside the annotation scan. Filed as part of #320.

### Phase 2 planned (epic #331)

14 issues queued covering: docs rewrite with named patterns and use-case catalog (#327), YAML config (#325), corpus builders (#328), domain data generation (#330), verification API (#332), nearest-match strategy (#317), strategy combination/profiles (#329), event simulation (#318, #326), REST client simulation (#319), and more.
