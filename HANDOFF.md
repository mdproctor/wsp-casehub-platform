# Handoff — Simulation Service (Slot 195)

## What happened this session

Two issues completed (#327, #325), advancing the queue from position 4/18 to 6/18.

**#327 — Docs rewrite:** Rewrote `docs/guides/simulation-guide.md` from mechanism-focused to scenario-driven. Lead with domain scenarios (LLM, banking, healthcare, integration), named design patterns cross-referenced to tutorial tests, strategy decision flowchart, corpus population guide, design-for-simulation section. Structured to accommodate all 13 planned issues without requiring rewrites — future strategies, event simulation, corpus builders, and verification API slot in as new sections. Updated consumer guide with simulation modules and config section.

**#325 — YAML-driven simulation config:** Built two new modules (`simulation-config-core` + `simulation-config`) following the established core/Quarkus split pattern. Three deliverables: (1) `SmallRyeSimulationConfig` — implements `SimulationConfig` via manual prefix scanning of `casehub.simulation.*` properties (avoids SmallRye @ConfigMapping gotchas documented in 5 garden entries), (2) `YamlCorpusLoader` — parses YAML fixture files into `InvocationRecord<Object, Object>`, (3) `DeclarativeExtractorFactory` — config-driven KeyExtractors (`identity`, `field:name`, `composite:a,b`) using Jackson ObjectMapper.convertValue. CDI wiring via `SimulationConfigBeans`. 25 tests (20 unit + 5 integration).

**Discoveries during integration:**
- CDI proxy `instanceof` check fails — proxy for `SimulationConfig` is not `instanceof SmallRyeSimulationConfig`. Fixed by reading config directly from `ConfigProvider.getConfig()` in startup observer.
- Generic beans can't have scope — `InMemorySimulationCorpus<I, O>` with `@ApplicationScoped` causes `DefinitionException`. Stripped CDI annotations from the class; corpus is now produced via `SimulationConfigBeans @Produces @ApplicationScoped`.
- `@Alternative @Priority(100)` without `@ApplicationScoped` defaults to `@Dependent` — multiple instances created, corpus seeding goes to wrong instance.

## Decisions

- **D13: Manual prefix scanning over @ConfigMapping** — 5 garden entries document SmallRye gotchas with two-level dynamic keys. Both precedent modules (endpoints-config, config) use `@ConfigProperty` + manual parsing.
- **D14: Object-typed YAML corpus** — YAML stores input/output as native types. Typed corpora use programmatic API or future corpus builders (#328).
- **D15: Single module** — all 3 deliverables in one module pair (simulation-config-core + simulation-config).
- **D16: Jackson ObjectMapper.convertValue for field access** — handles both Map inputs (YAML) and typed inputs (records, POJOs).

## References

| Artifact | Path |
|----------|------|
| Design spec (Phase 1) | `wksp/specs/feat-294-simulation-service/2026-09-15-simulation-service-design.md` |
| Design spec (#325) | `wksp/specs/feat-294-simulation-service/2026-09-15-yaml-driven-simulation-config-design.md` |
| Implementation plan (#325) | `wksp/plans/2026-09-15-yaml-driven-simulation-config.md` |
| Decisions (D13-D16) | `wksp/specs/feat-294-simulation-service/decisions.md` |
| Simulation guide | `proj/docs/guides/simulation-guide.md` |
| .plan | `wksp/.plan` (position 6/18, #320 active) |

## Next action

Start #320 — CaseMemoryStore simulation adapter. This is the first Path A consumer. CaseMemoryStore lives in platform-api (zero-dep) and can't depend on simulation-api, so `@SimulationEligible` can't go on the interface. Solution per the design spec: the generator reads `META-INF/simulation-eligible.txt` alongside annotation scan. Needs brainstorming for the generator changes.
