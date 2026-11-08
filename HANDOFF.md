# HANDOFF — casehub-platform

## Last Session (2026-11-07/08)

Completed #744 — Step lifecycle wiring for StateMachineSelector.advance() (S/Low), landed as 65da0373 on main. Also completed #755 (phase-aware agent responses) in the same branch.

**Core wiring:**
- `SimulationRuntime.advanceStateMachines(trigger)` — iterates all registered `StateMachineSelector` instances
- `StepTraceCollector.afterStep()` calls `advanceStateMachines(stepName)` on successful step completion
- `SimulationConfig.corpusSelectionKeys()` + eager selector creation in `pushOverlay()` — selectors exist before any action calls `strategyFor()`
- `SimulationRuntime.stateMachineStates()` — returns current phase of all state machines

**Test infrastructure wiring:**
- `TestExecutionContext` carries `SimulationRuntime` (as `Object` to avoid cross-module dependency)
- `YamlTestEngine` creates a `SimulationRuntime` and threads it through to `YamlTestExecutor`
- `RunPlaybookPlugin` passes runtime to `PlaybookRunnerCore` with `dryRun=true` when active; exposes `stateMachines` map in output (sanitized keys for dot-path compatibility)
- `AgentSessionTestSupport.CorpusBackend` + `CorpusSession` check `SimulationRuntime` for phased responses before falling back to static `simulate:` block

**Naming convention:**
- `discoverSimulationYaml()` checks `<base>.simulation.yaml` before `simulation.yaml` — paired naming
- Example: `order-lifecycle.playbook.yaml` + `order-lifecycle.simulation.yaml` + `order-lifecycle.test.yaml`

**End-to-end YAML example** in `playbooks/src/main/playbooks/simulation/` — three named agent steps advance state machine from pending → checked → paid → shipped. Test asserts both final state (`shipped`) and response content (`"Payment confirmed"` from the `paid` phase).

**Also landed (separate session):** #750-#754 compact invoke binding syntax (colon-separated compound keys for enumerables, space-separated for user-defined, verbose forms rejected), `primaryInput()` for scalar shorthand, sweep across all 59 playbooks.

**Blog:** "The Test Double That Changes Its Mind" revised with end-to-end example + step-lifecycle-wiring.svg.

## Simulation Follow-ups (#729)

| # | Title | Scale | Complexity | Status |
|---|-------|-------|------------|--------|
| 744 | Step lifecycle wiring | S | Low | Done |
| 755 | Phase-aware agent responses | S | Low | Done |
| 746 | MCP tool for runtime phase inspection | S | Low | Open — next |
| 747 | Per-phase corpus-files support | XS | Low | Open |
| 745 | CDI event observer wiring | M | Med | Open |
| 748 | Profile-level corpus-selection | M | Med | Open |

## Queue

The `.queue` file is stale — `Current: none` and completed items not marked. Next session should clean it up. Remaining open items: #746, #747, #745, #748.

## Immediate Next Step

#746 — MCP tool for runtime simulation phase inspection (S/Low). Exposes `stateMachineStates()` and `advance()` as MCP tools for LLM debugging. Self-contained, no dependencies on other follow-ups.

Alternative: #747 (XS/Low) for per-phase `corpus-files` — small config parsing change.
