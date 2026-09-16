# Handoff — Simulation Service (Slot 195)

## What happened this session

Two issues completed (#326, #319), advancing the queue from position 9/18 to 11/18.

**#326 — Timed event simulation (closed from previous session):** All tasks were already done. Closed on GitHub and advanced the queue at session start.

**#319 — REST client simulation:** New `rest-client-simulation-generator` module with `RestClientSimulationProcessor` APT. Generates `@Decorator` classes for `@RegisterRestClient` interfaces with `@RestClient`-qualified delegates and `RestInvocation` inputs. Reads JAX-RS annotations (`@GET`/`@POST`/`@Path`/`@PathParam`/`@QueryParam`) for HTTP metadata at compile time. Skips `@SimulationEligible` interfaces (handled by base generator). Foundation types in `simulation-core`: `RestInvocation` record (spiName, methodName, httpMethod, pathTemplate, params, body) and `RestClientKeyExtractor` (httpMethod + resolved path key). `rest-client` extractor registered in `DeclarativeExtractorFactory`. 24 tests (8 foundation + 16 processor). Decision review (light) revised 4 decisions: separate processor module (D32), module-level opt-in (D35), RestInvocation in simulation-core not simulation-api (D36), defer reactive support (D37).

## Decisions

- **D32: Separate RestClientSimulationProcessor** — own module, not extending base generator. Preserves framework-agnosticism.
- **D33: Hybrid input** — Java method level interception with HTTP metadata. Superset of pure Java-only.
- **D34: RestInvocation uniform type** — single record for all REST client methods. Self-describing corpus entries.
- **D35: Auto-detect @RegisterRestClient** — scoped by processor module opt-in. Adding the module IS the opt-in.
- **D36: New rest-client-simulation-generator module** — RestInvocation + key extractor in simulation-core.
- **D37: Defer reactive support** — blocking only for now. No reactive REST clients exist in platform.

## References

| Artifact | Path |
|----------|------|
| Design spec (#319) | `wksp/specs/feat-294-simulation-service/2026-09-16-rest-client-simulation-design.md` |
| Implementation plan (#319) | `wksp/plans/2026-09-16-rest-client-simulation.md` |
| Decisions (D32-D37) | `wksp/specs/feat-294-simulation-service/decisions.md` |
| Decision review | `/Users/mdproctor/reviews/casehub-slots/319-rest-client-simulation-decision-20260916-105234/` |
| Simulation guide | `proj/docs/guides/simulation-guide.md` |
| .plan | `wksp/.plan` (position 11/18, #321 active) |

## Next action

Start #321 — DefaultBean simulation patterns. This issue is about ensuring simulation decorators work alongside the existing `@DefaultBean` no-op pattern — the decorator wraps the real implementation (or the DefaultBean when no real impl exists). May need brainstorming to clarify scope.
