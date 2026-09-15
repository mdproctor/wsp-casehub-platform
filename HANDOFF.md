# Handoff — Simulation Service (Slot 195)

## What this is

A generic, domain-agnostic simulation framework for casehub-platform. Any SPI without a real implementation wired at runtime gets configurable simulation behaviour instead of silent no-op responses. Three concerns: seeding data, responding to invocations via pluggable strategies, and capturing real invocations for corpus building.

## What's ready

- **Design spec:** `wksp/specs/feat-294-simulation-service/2026-09-15-simulation-service-design.md` (723 lines, 12 design decisions, 3 rounds of adversarial review)
- **Implementation plan:** `wksp/plans/2026-09-15-simulation-service.md` (631 lines, 6 batches, 7 tasks, full TDD steps)
- **Epic:** casehubio/platform#294 with 12 child issues (#312–#323)
- **Branch:** `issue-294-simulation-service` (already checked out in this slot)
- **Decisions:** `wksp/specs/feat-294-simulation-service/decisions.md` (12 decisions with rationale)

## How to start

Run `work` in this directory. The `.plan` is scaffolded — work-start will detect it and resume. Then follow the implementation plan at `wksp/plans/2026-09-15-simulation-service.md` task by task.

## Architecture — the short version

**Two modes, one framework:**
- **Simulation mode** — strategy-driven responses when no real impl is wired. Config: `casehub.simulation.<spi>.<method>.strategy=key-lookup`
- **Capture mode** — record real SPI calls to corpus for replay. Config: `casehub.simulation.<spi>.<method>.capture=true`

**Two integration paths:**
- **Path A (generated @Decorator)** — for simple request-response SPIs (CaseMemoryStore, PreferenceStore, etc.). An annotation processor generates a @Decorator per `@SimulationEligible` SPI.
- **Path B (backend integration)** — for SPIs with existing routing layers (AgentProvider → RoutingAgentProvider → AgentBackend). Simulation registers as a backend.

**NoOps remain untouched.** The simulation decorator wraps them — it does not modify them.

## Module structure (to be created)

| Module | What it is |
|--------|-----------|
| `simulation-api` | Zero-dep SPI: SimulationStrategy<I,O>, SimulationCorpus<I,O>, @SimulationEligible, KeyExtractor, InvocationRecord, DataRealism. NoOp @DefaultBean corpus. |
| `simulation-core` | Strategy implementations: SequentialStrategy, KeyLookupStrategy, RandomStrategy, RecordedReplayStrategy. Constructor-injected POJOs, no CDI. |
| `simulation-inmem` | InMemorySimulationCorpus @Alternative @Priority(100). ConcurrentHashMap, thread-safe. |
| `simulation-generator` | Annotation processor (extends AbstractProcessor). Generates @Decorator per @SimulationEligible SPI. Sibling to callback-generator. |
| `agent-simulation-core` | SimulatedAgentBackend — Path B integration. Registers with BackendInstanceRegistry, dispatched by RoutingAgentProvider. |

## Key design decisions to know

1. **SimulationCorpus is an SPI** — storage is pluggable. InMemory is one backend. Filesystem is another. JPA deferred. The corpus could be backed by disk, generated data, database, or anything else.
2. **Separate simulation-api module** — NOT in platform-api. Simulation is opt-in. SPIs that want simulation add simulation-api as a dependency.
3. **Per-method strategy config** — multi-method SPIs like CaseMemoryStore get different strategies per method (e.g. `query` uses key-lookup, `store` uses sequential).
4. **SimulationRuntime** — non-generic @ApplicationScoped bean that avoids CDI type erasure. Strategies resolved by qualified name at runtime, not by generic type parameters.
5. **`qualifiedName`** — every corpus/strategy operation uses `"spi-name.method-name"` as namespace key.

## Test design philosophy

**Tests should read as tutorials.** Structure test classes so they teach developers how to use the simulation framework — how to configure strategies, seed corpora, write KeyExtractors, and combine components. Each test class should read like a how-to guide for the feature it tests. A developer reading the tests should understand how to adopt simulation in their own SPI.

## CDI gotchas to watch for (from garden)

- **GE-20260818-2589ee:** @Decorator must implement ALL abstract methods — the generator handles this
- **GE-20260806-93549d:** @PostConstruct skipped on @Decorator — use lazy init
- **GE-20260620-9d043b:** @Decorator double-application through blocking-to-reactive bridges — use idempotency guard
- **GE-20260604-81a6a6:** @DefaultBean @Unremovable required when injection point is in a different Maven module

## Precedent to follow

**callback-generator/** is the direct precedent for simulation-generator:
- `CallbackDecoratorProcessor` extends `AbstractProcessor`
- Scans Jandex indexes from dependency JARs for `@CallbackEligible`
- Generates @Decorator source files
- Tests use `com.google.testing.compile:compile-testing`
- Package: `io.casehub.platform.callback.generator`

Mirror this structure for `SimulationDecoratorProcessor` in `io.casehub.platform.simulation.generator`.

## What's NOT in scope for this slot

- Nearest-match strategy (#317) — deferred, hard problem
- Filesystem corpus (#314 partial) — deferred to after in-memory proves the pattern
- REST client simulation (#319) — different integration mechanism
- Pages scenario integration (#322) — needs runtime strategy switching
- Consumer adoption (#323) — after the framework ships

## Cross-repo impact

This slot only modifies platform. But the simulation framework will be consumed by:
- blocks (326+ AgentProvider hits), clinical (8 files), engine (via blocks) — via agent-simulation-core
- 7 repos use CaseMemoryStore — via @SimulationEligible decorator (after this slot ships)

No cross-repo changes in this slot. Consumer repos add simulation modules as dependencies later.
