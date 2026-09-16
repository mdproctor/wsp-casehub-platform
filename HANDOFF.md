# Handoff — Simulation Service (Slot 195)

## What happened this session

One issue completed (#322), advancing the queue from position 12/18 to 13/18. Pages repo added to slot 195 with casehub-pages#450 created for pages-side integration.

**#322 — Pages scenario integration:** Six deliverables across two repos:

1. **JournalEntry + InvocationJournal** (platform): Record type and thread-safe journal for tracking every intercepted SPI call. Records qualified name, input, output, timestamp, and whether the call was simulated or passthrough.

2. **MapSimulationConfig + SimulationOverlay** (platform): Programmatic `SimulationConfig` implementation from `Map<String, String>` (no SmallRye Config needed). `SimulationOverlay` is an opaque handle containing config, isolated corpus, journal, and per-overlay strategy cache.

3. **SimulationRuntime overlay stack** (platform): `pushOverlay(config, corpus)` / `popOverlay(overlay)` / `popAll()` / `recordJournal()` / `journal()` / `hasActiveOverlay()`. Strategy resolution walks the overlay stack top-down before base config. Strategy cache invalidation on push/pop. `simulation-inmem` promoted from test to compile scope in simulation-core.

4. **Generator template update** (platform): `SimulationDecoratorProcessor.generateSimulatedMethod()` now emits `simulation.recordJournal()` after both strategy resolution (simulated=true) and delegate passthrough (simulated=false). No-op fast path when no overlay is active.

5. **SimulationSpec + parser** (pages): `SimulationSpec` record (strategies, corpus, capture). `HierarchicalParser` extended to parse `simulation:` YAML block. `HierarchicalScenario` gains `simulation` field.

6. **ScenarioOrchestrator lifecycle hooks** (pages): `activateSimulation()` on `start()` pushes overlay with seeded corpus from fixture files. `deactivateSimulation()` on `stop()` pops overlay. Uses `Instance<SimulationRuntime>` for graceful degradation.

## Decisions

- **D43: Layered runtime overlay — no ThreadLocal** — push/pop on SimulationRuntime, strategy resolution walks stack top-down
- **D44: Isolated corpus per overlay** — fresh InMemorySimulationCorpus per overlay, discarded on pop
- **D45: Invocation journal on overlay** — every intercepted call recorded with simulated flag
- **D46: Mid-scenario switching included** — multiple pushOverlay() calls supported, stack handles layering
- **D47: All in simulation-core** — no new modules
- **D48: Cross-repo design together** — platform API + pages consumer designed as one spec

## References

| Artifact | Path |
|----------|------|
| Design spec (#322) | `wksp/specs/feat-294-simulation-service/2026-09-16-pages-scenario-simulation-design.md` |
| Implementation plan (#322) | `wksp/plans/2026-09-16-pages-scenario-simulation.md` |
| Decisions (D43-D48) | `wksp/specs/feat-294-simulation-service/decisions.md` |
| Simulation guide | `proj/docs/guides/simulation-guide.md` |
| Pages issue | casehub-pages#450 |
| .plan | `wksp/.plan` (position 13/18, #323 active) |

## Next action

Start #323 — consumer. Needs brainstorming to clarify scope.
