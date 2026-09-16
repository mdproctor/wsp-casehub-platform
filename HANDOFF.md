# Handoff — Simulation Service (Slot 195)

## What happened this session

Two issues completed (#318, #326), advancing the queue from position 8/18 to 10/18.

**#318 — Event simulation core (push-side strategies):** New `event-simulation-core` module (POJO, no CDI). `SimulatedEventEmitter` with `tick()` method — iterates configured event sources, resolves CloudEvents from `SimulationStrategy<EventTrigger, CloudEvent>`, stamps fresh id/time per emission, fires via `Consumer<CloudEvent>` callback. `CloudEventFixtureBuilder` converts between YAML-friendly `Map<String, Object>` and `CloudEvent` instances. `EventTrigger`, `EventSourceConfig`, `EmissionResult`, `EmittedEvent`, `EmissionFailure` records. Per-source error isolation. CDI bus injection path (`Event<CloudEvent>.fireAsync()`) for full pipeline fidelity — events traverse DataSourceRouter's tenancy check. 21 tests.

**#326 — Timed event simulation:** Extended `event-simulation-core` with `TimedEntry<E>` + `TimedSequence<E>` — generic ordered sequences with relative delays, `withMultiplier(double)` for speed control, `fromRecorded(List<InvocationRecord>)` for timing derivation from captured data. `EventSequenceRunner` executes sequences with `Thread.sleep()` between events (virtual-thread friendly). `SequenceResult` for execution reporting. New `event-simulation` Quarkus module with CDI wiring: `@Produces SimulatedEventEmitter` with `Event<CloudEvent>.fireAsync()` sink, `@Produces EventSequenceRunner`, `@Scheduled` continuous tick (configurable interval, OFF by default). Config-driven `EventSourceConfig` loading from `casehub.simulation.event.sources.*` properties. 21 additional tests (42 total across both modules).

## Decisions

- **D21: Dedicated event-simulation-core module** — separate from simulation-core (SPI interception). Follows agent-simulation-core precedent.
- **D22: CDI Event bus injection** — full pipeline fidelity via `Event<CloudEvent>.fireAsync()`. Same path as real stream processors.
- **D23: tick()-based emitter** — synchronous, deterministic. @Scheduled wrapper deferred to #326 (then delivered).
- **D24: Strategy resolves CloudEvent directly** — corpus stores complete CloudEvent templates. Emitter stamps id/time.
- **D25-D26: Scope split** — #318 = what/how, #326 = when. Clean separation delivered.
- **D27: Relative delays** — each TimedEntry carries Duration from previous entry. Natural for replay.
- **D28: Virtual-thread sleep** — Thread.sleep() between events. Simple, blocking, cheap on virtual threads.
- **D29: Core/Quarkus split** — TimedSequence in event-simulation-core (POJO), CDI wiring in event-simulation.
- **D30: Derive timing from recordedAt** — TimedSequence.fromRecorded() computes gaps. No capture changes needed.
- **D31: Multiplier on TimedSequence** — withMultiplier(10.0) divides all delays. Scheduler stays simple.

## References

| Artifact | Path |
|----------|------|
| Design spec (#318) | `wksp/specs/feat-294-simulation-service/2026-09-16-event-simulation-design.md` |
| Design spec (#326) | `wksp/specs/feat-294-simulation-service/2026-09-16-timed-event-simulation-design.md` |
| Implementation plan (#318) | `wksp/plans/2026-09-16-event-simulation.md` |
| Implementation plan (#326) | `wksp/plans/2026-09-16-timed-event-simulation.md` |
| Decisions (D21-D31) | `wksp/specs/feat-294-simulation-service/decisions.md` |
| Simulation guide | `proj/docs/guides/simulation-guide.md` |
| .plan | `wksp/.plan` (position 10/18, #319 active) |

## Next action

Start #319 — REST client simulation. `@RegisterRestClient` proxy interception with strategy dispatch for simulating external HTTP services. Different interception mechanism from Path A (decorator) and Path B (backend) — needs its own brainstorming. The design spec notes this as Phase 3 scope. Key question: MicroProfile REST Client proxy mechanism vs CDI decorator on the client interface.
