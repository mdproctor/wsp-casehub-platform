---
layout: post
title: "Temporal simulation — giving timed sequences a lifecycle"
date: 2026-09-20
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [simulation, temporal, virtual-threads, yaml, concurrency]
---

The simulation framework already had the data model for timed event sequences — `TimedEntry<E>` carries an event and a relative delay, `TimedSequence<E>` orders them with a time multiplier. What it didn't have was a way to *run* one with any control beyond fire-and-forget. `EventSequenceRunner.run()` blocks until the sequence completes. No pause. No resume. No speed changes. No looping. Fine for a test fixture; useless for simulating an IoT morning routine that runs continuously at 10x speed while a developer watches the dashboard.

The first design question was whether to create new types (`TemporalEvent`, `TemporalProfile`) as the issue proposed, or compose with what exists. I went with composition. The issue was aspirational — the real gaps were lifecycle control and YAML loading, not the data model. `TimedEntry` gained two optional fields: `label` (for journal verification — "motion-cascade" beats "sequence[2]") and `qualifiedName` (so concatenated sequences preserve per-entry attribution). `TimedSequence` stayed unchanged except for preserving those fields through `withMultiplier()`.

Both types moved from `event-simulation-core` to `simulation-core`. They were generic — no CloudEvent dependency — sitting in a module that pulled in `cloudevents-core` only because `EventSequenceRunner` needed it. The move is a dependency hygiene fix: consumers wanting temporal simulation no longer inherit a transitive CloudEvent dependency they don't use.

`TemporalSimulationDriver<E>` is the new piece. It runs a `TemporalProfile` on a virtual thread with a five-state lifecycle: IDLE → RUNNING ↔ PAUSED → STOPPED, plus COMPLETED for non-looping profiles. Each event: sleep the delay divided by current speed, deliver via `TemporalEventSink.deliver(qualifiedName, label, event)`, record to the journal if a `SimulationRuntime` is attached. Error isolation per event — one failing delivery doesn't stop the sequence. The sink receives `qualifiedName` as context, which the CDI producer uses as the CloudEvent type.

I considered `ScheduledExecutorService` for the scheduling — schedule each event individually, cancel and reschedule on speed changes. A garden entry (GE-20260701-82909e) documented the cancel-clear-reschedule gotcha: concurrent reconfiguration leaks orphaned `ScheduledFuture` instances that fire indefinitely with no visible error. Virtual-thread sleep avoids the entire problem class. Each driver owns one virtual thread. Speed changes update a volatile field; the next sleep reads it. Pause blocks on a `ReentrantLock` `Condition`. Stop interrupts the thread. Simple, correct, and the same pattern `EventSequenceRunner` already uses.

The YAML surface mirrors the existing simulation config pattern. A new `temporal-profiles:` top-level section in `simulation.yaml` with four mutually exclusive event sources: inline `events:` for small profiles, `events-file:` for external loading, `from-corpus:` to derive timing from recorded `InvocationRecord` timestamps, and `sequence:` for concatenating named profiles. Both top-level and inline-within-profiles are supported — same dual pattern as corpus data. Gap delays in `sequence:` refs absorb into the referenced profile's first entry rather than inserting a phantom event that would fire through the sink and appear in the journal as a real delivery.

The CDI wiring splits by concern: `simulation-config` produces a `TemporalProfileRegistry` (YAML-parsed profiles available by name), `event-simulation` produces a `TemporalDriverFactory<Map<String, Object>>` that creates drivers wired to `Event<CloudEvent>.fireAsync()` with `qualifiedName` → CloudEvent type mapping. Domains inject the factory, grab a profile from the registry, call `start()`. The factory type is `Map<String, Object>` because YAML payloads parse to maps — type-safe domain payloads would need a `PayloadMapper<T>` SPI, which can come later when a consumer needs it.

The design review caught several things I'd missed. `tenancyId` needs to be on the profile, not derived from `CurrentPrincipal` — the driver runs on its own virtual thread with no security context. `Consumer<E>` was too thin for the sink — the CloudEvent producer needs `qualifiedName` to set the event type, so `TemporalEventSink<E>` carries `(qualifiedName, label, event)`. And a `COMPLETED` state is needed — non-looping profiles that finish naturally shouldn't report as STOPPED, which implies external termination.

IoT is the first consumer. Device state change patterns — morning routines, emergency sequences, quiet nights — are continuous temporal profiles that loop at configurable speed. The platform owns the scheduling; the domain owns the event content and the CDI bridge. Same separation as `SimulationStrategy` (platform) and corpus data (domain).
