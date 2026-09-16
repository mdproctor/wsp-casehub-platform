# Handoff — Simulation Service (Slot 195)

## What happened this session

One issue completed (#321), advancing the queue from position 11/18 to 12/18.

**#321 — DefaultBean simulation patterns:** Three deliverables:

1. **Generator enhancement (D42):** Removed the abstract/default method distinction from `SimulationDecoratorProcessor` and `RestClientSimulationProcessor`. All interface methods now get simulation interception logic — the config layer (`casehub.simulation.<spi>.<method>.strategy=...`) controls activation. Also added wildcard type (`?`) and method-level type parameter (`<C, R>`) support to the generator's `typeToJava` — these were compilation blockers for `DataSourceRegistry` (uses `DataSource<?>`) and `ExpressionEngineRegistry` (has `<C,R> compile(...)`).

2. **New `platform-simulation-core` module:** `META-INF/simulation-eligible.txt` listing 11 platform-api SPIs. The APT generates 11 `@Decorator` classes at compile time. One unit test (`SimulatedAccessControlProviderTest`) verifies the decorator intercepts a pure-default interface — `canAccess` returns `false` from corpus instead of the NoOp's `true`.

3. **Guide + CLAUDE.md updates:** "Platform SPIs" section added to simulation guide with dependency, qualified name table, and example config.

## Decisions

- **D38: Single platform-simulation-core module** — one listing file for all 11 SPIs, not per-domain modules
- **D39: PolicyEnforcer excluded** — concrete class, not an SPI interface
- **D40: Single integration test** — one test proves CDI ordering; APT unit tests cover generation correctness
- **D41: Guide section** — in existing simulation guide, not separate doc
- **D42: Intercept all methods** — removed abstract/default distinction; pre-release, no backward compat needed

## References

| Artifact | Path |
|----------|------|
| Design spec (#321) | `wksp/specs/feat-294-simulation-service/2026-09-16-defaultbean-simulation-patterns-design.md` |
| Implementation plan (#321) | `wksp/plans/2026-09-16-defaultbean-simulation-patterns.md` |
| Decisions (D38-D42) | `wksp/specs/feat-294-simulation-service/decisions.md` |
| Simulation guide | `proj/docs/guides/simulation-guide.md` |
| .plan | `wksp/.plan` (position 12/18, #322 active) |

## Next action

Start #322 — pages. Needs brainstorming to clarify scope.
