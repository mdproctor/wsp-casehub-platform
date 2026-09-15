---
title: "The Simulation Gap"
date: 2026-09-15
entry_type: note
subtype: diary
author: mdp
projects: [casehub-platform]
tags: [simulation, spi-design, testing, architecture]
series: casehub-platform
---

# The Simulation Gap

Every platform SPI has a NoOp. `CaseMemoryStore` returns empty. `AgentProvider` returns nothing. `PreferenceStore` shrugs. These are architecturally load-bearing — zero dependencies, zero constructor params, trivially constructable — and they're the reason any consumer can start without wiring a real backend.

But they're also useless for testing anything interesting. A NoOp that returns empty doesn't tell you whether your query logic handles three results correctly. It tells you your code doesn't crash on zero results. That's a different question.

The simulation framework fills this gap. Five modules, one annotation, and a corpus of input/output pairs turn any SPI from "returns nothing" into "returns exactly what you seeded." The NoOps stay untouched — a generated `@Decorator` wraps them, checking for a configured strategy before delegating. No strategy configured? Transparent passthrough. Strategy present? The decorator resolves from the corpus instead.

## What makes it interesting

Four strategies ship, and the choice matters more than it looks.

**Sequential** cycles through a list. Seed three responses, get them in order, wrap around forever. That's your load test — finite corpus, unlimited calls. Switch the exhaustion policy to THROW and it becomes a scenario test: exactly N calls expected, then the framework fails loudly.

**Key-lookup** is the deterministic one. Register a `KeyExtractor` that derives a key from the method input — patient ID, transaction type, prompt structure — and the corpus returns the same response for the same key every time. This is what makes demo environments stable. Same input, same output, no surprises.

**Recorded-replay** combines both: key-first for known inputs (deterministic), sequential fallback for unknowns (best-effort). Perfect for replaying captured traffic where most requests are familiar but some are new.

**Random** samples from the corpus. Useful for load testing with varied responses, or fuzzing.

The real power is that these compose per method. A multi-method SPI like `CaseMemoryStore` can simulate `query` with key-lookup (deterministic), capture `store` calls to build a corpus (recording real traffic), and pass `erase` through to the NoOp. Three different strategies on one interface, configured independently.

## The consumer feedback that mattered

A team evaluating the framework for their banking platform flagged something I hadn't considered: the decorator intercepts at the method level. That's fine for flat interfaces where each method is a complete operation — `listTransactions()`, `getBalance()`, `postPayment()`. But capability-based SPIs that return intermediate objects — `chatPlatform.messaging().send()` — break the pattern. The decorator wraps `messaging()`, not `send()`.

This isn't a bug. It's an architectural constraint of CDI `@Decorator` that becomes a design constraint for SPI authors. Flat interfaces map perfectly to decorator-based simulation. Capability-based interfaces need Path B — registering as a backend with the existing routing layer, the way `SimulatedAgentBackend` registers with `RoutingAgentProvider`.

The interesting part: the flat interface preference was already the platform convention. The simulation framework validates it for a reason nobody anticipated when the convention was established.

## What the guide got wrong

The first draft of the user guide explained mechanism — strategies, corpora, extractors — without ever explaining applicability. A banking developer reading it couldn't answer "should I use this to simulate my payment gateway?" because no banking scenario appeared anywhere. An LLM team couldn't find "how to replace a judge LLM" because the guide never mentioned LLMs.

The gap extends deeper. How do you populate a corpus with realistic data? The programmatic API works but constructing `InvocationRecord<MemoryQuery, List<Memory>>` by hand for complex SPIs is painful. YAML fixtures, corpus builders with fluent domain-specific APIs, LLM-generated test data — these are all paths that need building.

## What's ahead

Phase 2 is fourteen issues. The docs rewrite comes first — named patterns (Deterministic Replay, Capture → Replay, Infinite Load) cross-referenced between the guide and tutorial tests, with domain scenarios that developers recognise from their own work. Then YAML-driven configuration so teams can declare simulation setup without writing Java. Then corpus builders, a verification API (the "Mockito verify() equivalent" for captured invocations), the nearest-match strategy for fuzzy similarity scoring, and timed event simulation for replaying event sequences with realistic timing.

The core framework is the easy part. Making it usable across domains — that's where the real work is.
