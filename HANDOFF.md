# HANDOFF — casehub-platform

## Last Session (2026-11-07)

Completed #729 — Dynamic corpus selection (M/Med), landed as 44080d94 on main:

- `CorpusSelector` interface + `PhasedCorpus` decorator in simulation-api — wraps `SimulationCorpus`, delegates lookups to the active phase's entries. Strategies don't know phases exist.
- `CorpusSelectorConfig` sealed interface with four variants: `StateMachine`, `DurationBased`, `LookupCount`, `Weighted`
- Four selector implementations in simulation-core: `StateMachineSelector` (AtomicReference + advance(trigger)), `DurationSelector` (SpeedMultiplier-aware), `LookupCountSelector` (onResolved lifecycle hook), `RandomSelector` (weighted probabilistic)
- `SimulationConfig.corpusSelection()` extension + `SimulationRuntime` wiring — selector persistence across overlay push/pop, strategy wrapping for onResolved callback
- `YamlSimulationConfig` parsing for `corpus-selection` blocks — state-machine, duration, lookup-count, random types. Mutual exclusion with `corpus`/`corpus-files`
- `simulation.schema.json` updated with `corpus-selection-config` definition
- Paired `.simulation.yaml` file discovery in `PlaybookRunnerCore` — checks `<basename>.simulation.yaml` before walking up directories
- 10 simulation tutorial playbooks in `playbooks/src/main/playbooks/simulation/` with paired `.simulation.yaml` files
- 53 new tests across simulation modules, all green. 426 total simulation tests, zero regressions.
- Blog: "The Test Double That Changes Its Mind"

Also filed: #744 (step lifecycle wiring), #745 (CDI event triggers), #746 (MCP phase inspection), #747 (per-phase corpus-files), #748 (profile-level corpus-selection). #735 and #742 (combined-key shorthand + capture/name step keys) already landed in the same session.

Also discovered and investigated: `playbooks/` directory was emptied by a bad squash — files had been moved to `playbook-catalog` module. Restored via squash fix on main.

## Epic #702 — YAML Playbook Polish

| # | Title | Scale | Complexity | Status |
|---|-------|-------|------------|--------|
| 698 | Enforce combined-key syntax | S | Low | Done |
| 703 | Playbook variable declarations | L | Med | Done |
| 699 | Type-safe expression resolution | XL | High | Done |
| 700 | `@` annotations with `@Inject` | XL | High | Done |
| 716 | Nested step-level annotations | S | Low | Done |
| 718 | Match/select annotation threading | XS | Low | Done |
| 710 | yaml-codegen expression format | XS | Low | Done |
| 711 | AssertPlugin migration evaluation | XS | Low | Done |
| 712 | Scope dual-registration | S | Med | Done |
| 713 | ConditionEvaluator unification eval | S | Med | Done |
| 706 | Typed error handling in catch blocks | M | Med | Done |
| 705 | JSON Schema for playbook documents | M | Med | Done |
| 708 | Playbook dry-run mode | M | Low | Open — next |
| 701 | Playbook imports via module system | L | Med | Open |

## Simulation Follow-ups (#729)

| # | Title | Scale | Complexity | Blocked by | Notes |
|---|-------|-------|------------|------------|-------|
| 744 | Step lifecycle wiring for StateMachineSelector.advance() | S | Low | — | Thin wiring: step completion → advance(stepName). Start here. |
| 745 | CDI event observer wiring for event-triggered corpus selection | M | Med | 744 | Condition evaluation against CloudEvents/domain events |
| 746 | MCP tool for runtime phase inspection + manual triggers | S | Low | — | simulation_phase_status, simulation_advance, simulation_reset |
| 747 | Per-phase corpus-files support | XS | Low | — | Reuse CompositeCorpusLoader within phase parsing |
| 748 | Profile-level corpus-selection | M | Med | — | One selector driving multiple methods within a profile |

## Immediate Next Step

#744 — Step lifecycle wiring (S/Low). Connects playbook step completion to `StateMachineSelector.advance()`. This is the last piece needed to make the state-machine tutorial example (`07-state-machine-selection`) fully functional end-to-end.

Alternative: #747 (XS/Low) if the next session wants a quick win — per-phase `corpus-files` is a ~20-line change to `YamlSimulationConfig`.

## References

- Epic: casehubio/platform#702
- Simulation follow-ups: #744, #745, #746, #747, #748
- Design spec: specs/issue-729-dynamic-corpus-selection/2026-11-06-dynamic-corpus-selection-design.md
