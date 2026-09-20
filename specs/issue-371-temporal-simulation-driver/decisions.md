## D1: Compose with existing types — no parallel hierarchy

**Choice:** Extend `TimedEntry<E>` + `TimedSequence<E>` and add `TemporalProfile<E>` as a wrapper. Do not create new `TemporalEvent<T>` / `TemporalProfile<T>` SPIs as the issue proposed.
**Alternatives:**
- New parallel types (`TemporalEvent`, `TemporalProfile`, `TemporalEventConsumer`) — duplicates existing data model, two ways to represent the same thing
**Rationale:** The issue is aspirational. The real gaps are lifecycle control, looping, runtime speed, YAML loading, and journal integration — not the data model. TimedEntry/TimedSequence already cover the event+delay structure.
**Trade-offs:** TimedEntry needs a new `label` field. Minor schema change vs entire new type family.
**Sources:** event-simulation-core/TimedEntry.java, event-simulation-core/TimedSequence.java, issue #371 body
**Exploration:** quick
**Status:** captured

## D2: Move TimedEntry + TimedSequence to simulation-core

**Choice:** Relocate `TimedEntry<E>` and `TimedSequence<E>` from `event-simulation-core` to `simulation-core`.
**Alternatives:**
- Keep in event-simulation-core — consumers wanting temporal simulation must depend on a module that drags in cloudevents-core even though TimedEntry/TimedSequence are generic
- New module — unnecessary; simulation-core is the right home alongside SimulationRuntime
**Rationale:** These types are generic (no CloudEvent dependency). They belong alongside SimulationRuntime and the strategy implementations. EventSequenceRunner (CloudEvent-specific) stays in event-simulation-core.
**Trade-offs:** Breaking import change for any code importing from event-simulation-core. Pre-release — no backward compat concern.
**Sources:** event-simulation-core/pom.xml (cloudevents-core dep), simulation-core/SimulationRuntime.java
**Exploration:** quick
**Status:** captured

## D3: Add optional label to TimedEntry

**Choice:** Add `String label` to `TimedEntry<E>` (nullable, defaults to null).
**Alternatives:**
- Positional tracking only (`sequence[0]`, `sequence[1]`) — breaks on dynamic composition, meaningless in verification
**Rationale:** Labels like `"motion-cascade"` are meaningful in journal verification. `SimulationVerifier` assertions (`wasCalledWith("temperature-drift")`) need stable identifiers, not array indices.
**Trade-offs:** Existing callers constructing `TimedEntry(event, delay)` need updating to the new signature or a convenience constructor.
**Sources:** event-simulation-core/EventSequenceRunner.java:37 (positional pattern), simulation-core/SimulationVerifier
**Exploration:** quick
**Status:** captured

## D4: TemporalProfile wraps TimedSequence with lifecycle metadata

**Choice:** New `TemporalProfile<E>` record in `simulation-core`: `name`, `qualifiedName`, `loop`, `speed`, `TimedSequence<E>`.
**Alternatives:**
- Add loop/name/speed directly to TimedSequence — muddies a clean data type with lifecycle concerns
**Rationale:** TimedSequence is a pure data structure (ordered events with delays). Profile metadata (name, looping, speed, qualified name for journaling) is a separate concern that the driver needs.
**Trade-offs:** One more type to learn. Worth it for clean separation.
**Sources:** simulation-core/SimulationProfile.java (precedent: wraps SimulationConfig + SimulationCorpus)
**Exploration:** quick
**Status:** captured

## D5: Virtual-thread sleep loop for the driver

**Choice:** `TemporalSimulationDriver<E>` uses virtual-thread `Thread.sleep()` for inter-event delays, same pattern as `EventSequenceRunner`.
**Alternatives:**
- ScheduledExecutorService — schedule each event individually, cancel/reschedule on speed change. More complex state management, ScheduledFuture cancel-clear-reschedule gotcha (GE-20260701-82909e)
**Rationale:** Virtual threads are cheap for simulation workloads. Sleep-based loop is simple: speed changes recalculate next delay, pause via LockSupport, stop via interrupt. Same proven pattern as EventSequenceRunner.
**Trade-offs:** One virtual thread per active driver. Acceptable for simulation (not production scheduling).
**Sources:** event-simulation-core/EventSequenceRunner.java (Thread.sleep pattern), GE-20260701-82909e (ScheduledFuture gotcha)
**Exploration:** quick
**Status:** captured

## D6: YAML parity — dual inline/top-level temporal profiles

**Choice:** New `temporal-profiles:` top-level section in simulation.yaml + inline `temporal:` within profiles. Both forms supported — inline for small, top-level for larger/reusable.
**Alternatives:**
- Top-level only — forces extraction of even trivial single-event sequences
- Inline only — no reuse across simulation profiles
**Rationale:** Matches existing corpus pattern (inline `corpus:` per-method + external `corpus-files:`). Four mutually exclusive event sources per profile: `events:` (inline), `events-file:` (external), `from-corpus:` (derived from InvocationRecords), `sequence:` (concatenation of refs).
**Trade-offs:** Parser must handle both locations and validate mutual exclusivity.
**Sources:** simulation-config-core/YamlSimulationConfig.java (inline corpus + corpus-files pattern)
**Exploration:** quick
**Status:** captured
