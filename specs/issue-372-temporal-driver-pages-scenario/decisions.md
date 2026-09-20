# Decisions — #372 Temporal Driver Pages Scenario

## D1: Driver identification model

**Choice:** Profile name as key — one active driver per profile name
**Alternatives:**
- Auto-generated UUID — more flexible but more state to track
- Caller-provided ID — maximum control but collision risk
**Rationale:** Maps directly to YAML config names. Simple mental model for scenario authors. One profile = one running instance.
**Trade-offs:** Cannot run two concurrent instances of the same profile
**Sources:** TemporalProfileRegistry.resolve(name), TemporalProfile.name()
**Exploration:** quick
**Status:** captured

## D2: Conflict on duplicate start

**Choice:** Error when starting a profile that already has a running driver
**Alternatives:**
- Replace (stop existing, start new) — convenient but silently destroys state
- Idempotent no-op — simple but can't restart with different speed
**Rationale:** Explicit lifecycle prevents accidental orphaned drivers. Caller must stop first.
**Trade-offs:** Extra step for callers who want restart semantics
**Sources:** TemporalSimulationDriver.State enum (IDLE → RUNNING → STOPPED is terminal)
**Exploration:** quick
**Depends on:** D1 (profile name keying makes conflicts possible)
**Status:** captured

## D3: Module placement

**Choice:** New simulation-api module for @McpDomain SPI; flat implementation in event-simulation
**Alternatives:**
- Core extraction (simulation-core manager POJO + CDI wiring) — YAGNI, no Spring consumer
- Inline in event-simulation (no API module) — breaks pattern, no clean dep target for Pages
**Rationale:** Follows callback-api/callback pattern. Clean dependency for consumers. No speculative abstractions.
**Trade-offs:** New module to maintain (minimal — pure Java SPI + records)
**Sources:** callback-api/CallbackApi.java, callback/CallbackService.java, graphql-generator APT
**Exploration:** quick
**Status:** captured

## D4: API surface breadth

**Choice:** Full control: start/stop/pause/resume/setSpeed/status + list
**Alternatives:**
- Minimal (start/stop/speed) — simpler but loses pause/resume for mid-scenario assertions
**Rationale:** Matches driver's native capabilities. Scenarios can pause simulation, assert system state, then resume.
**Trade-offs:** Larger API surface, more operations to test
**Sources:** TemporalSimulationDriver public methods
**Exploration:** quick
**Status:** captured

## D5: YAML/Java API parity

**Choice:** Start request supports both named profile reference AND inline profile definition — full parity with YAML temporal-profiles config
**Alternatives:**
- Profile-name-only start — forces all profiles to be pre-declared in YAML, no runtime ad-hoc profiles
**Rationale:** Platform convention: whatever you can do in Java, you can do in pure YAML. Inline profile definition in the API mirrors inline events/loop/speed in YAML config. Named profiles with overrides mirror YAML-declared profiles.
**Trade-offs:** Richer request type, more validation (profileName vs qualifiedName mutual exclusivity)
**Sources:** YamlSimulationConfig temporal-profiles parsing, TemporalProfileConfig, platform YAML/Java parity convention
**Exploration:** quick
**Status:** captured

## D6: JSON Schema for all YAML surfaces

**Choice:** All new YAML surfaces get JSON Schema definitions — temporal-profiles in simulation.schema.json, temporal step type in Pages scenario schema
**Alternatives:**
- Schema-less YAML — undiscoverable, no IDE validation
**Rationale:** Platform convention: all YAML must have schemas. Enables IDE autocomplete, CI validation, documentation generation.
**Trade-offs:** Schema must be maintained alongside YAML parser changes
**Sources:** simulation.schema.json (existing, needs temporal-profiles section added), platform YAML schema convention
**Exploration:** quick
**Status:** captured

## D7: Pages step type

**Choice:** New dedicated temporal: step type, independent from existing simulation: overlay step
**Alternatives:**
- Extend simulation: block — overloads the step type, different lifecycle semantics
- Generic GraphQL step via delivery: 'graphql' — no new step type but less discoverable
**Rationale:** Temporal (start/stop/pause/resume lifecycle) and overlay (push/pop configuration) are orthogonal concerns. Each does one thing.
**Trade-offs:** New concept for scenario authors to learn
**Sources:** 2026-09-16-pages-scenario-simulation-design.md (overlay pattern), issue #372
**Exploration:** quick
**Status:** captured
