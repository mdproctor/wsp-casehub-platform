---
title: "Eighteen Issues Later"
date: 2026-09-18
entry_type: note
subtype: diary
author: mdp
projects: [casehub-platform]
tags: [simulation, spi-design, testing, verification, code-generation, architecture]
series: casehub-platform
---

# Eighteen Issues Later

The simulation epic is done. Eighteen issues, five strategies, a code generator, event simulation, corpus builders, schema-driven data generation, strategy profiles, and a verification API. The branch started three days ago with a single question — "what if every SPI could be simulated without Mockito?" — and the answer turned out to be 18 modules and 85 design decisions.

The final three issues landed today: schema-driven random data generation (#330), strategy profiles with lifecycle progression (#329), and the verification API (#332). Each one filled a gap that would have blocked adoption.

## SchemaDataGenerator — the zero-effort path

The simulation framework already had four ways to populate a corpus: YAML fixtures, programmatic CorpusSeed, LLM generation, and capture mode. But all four require the developer to know something — what a realistic patient record looks like, what fields an AML entity has, what a model descriptor contains.

`SchemaDataGenerator` requires knowing nothing. Pass it a JSON Schema (which `PlatformSchemaGenerator` already produces from any Java type), and it generates structurally valid instances. It respects Jakarta Validation constraints — min/max bounds, string lengths, patterns, enum values — and resolves `$ref`/`$defs` for nested types with a depth guard. A seeded `Random` makes output reproducible.

The interesting design question was what to do with schemas that have no `required` array. The initial implementation randomly included optional properties, which is correct for schema validation but wrong for Java records — Jackson deserialization needs all fields present. The fix: when `required` is absent, generate all properties. When `required` is explicit, generate required plus random optional. A small thing, but it's the difference between "works in theory" and "works when a developer tries it for the first time."

`RandomCorpusPopulator` is the thin layer that connects this to the simulation framework — five lines that generate typed inputs and outputs from their schemas and seed them into a `CorpusSeed`. That's the developer's entry point: `RandomCorpusPopulator.populate(seed, InputType.class, OutputType.class, 50, mapper)`. Fifty test entries with correct types and constraint-bounded values, zero domain knowledge required.

## The verification gap

The simulation framework replaced Mockito's `when/thenReturn` — corpus plus strategy does the same thing with real CDI wiring instead of a mock. But Mockito's `verify()` had no equivalent. The `InvocationJournal` on each overlay already recorded every intercepted call, but tests had to manually filter and count entries. That's the kind of friction that makes people reach for Mockito instead.

The issue's original sketch proposed `SimulationVerifier.forCorpus(corpus)`. I pushed back on that — the corpus stores seed data for strategy resolution, not what happened during a test. The journal is the interaction recording. Getting this wrong would have confused the entire mental model: corpus is `when/thenReturn`, journal is `verify`.

`SimulationVerifier` is stateful — it tracks which methods have been verified, enabling `noUnverifiedCalls()`, which is Mockito's `verifyNoMoreInteractions`. `MethodVerification` provides the fluent API: `forTenant()`, `matching()`, `wasCalled(3)`, `wasNeverCalled()`, `allSimulated()`, `inOrder()`. The predicate takes `JournalEntry` rather than just the input, giving access to all six fields — including `tenancyId`, which I added to `JournalEntry` as part of this issue.

Adding tenancyId was a pre-release decision — no backward compatibility concern. Every platform SPI is tenant-aware, so tenant-scoped verification (`forTenant("hospital-a").wasCalled(2)`) is essential. The generator update was mechanical: the decorators already inject `CurrentPrincipal` for capture mode, so extracting `tenancyId()` for the journal was one line. Until Claude hit a variable name collision — the generated code declared `String tenancyId` as a local, but several SPI methods already have a `tenancyId` parameter. The fix was a `__simTenancyId` prefix convention. Small thing, but it's the kind of bug that costs an hour to diagnose in generated code you didn't write.

## What 85 decisions look like

The decisions file is the real artifact of this branch. Eighty-five design choices, each with alternatives considered and trade-offs acknowledged. Some were quick picks — "simulation-core module placement" is obvious. Others were deep: the synthesis-before-catalogue ordering (D67), the overlay stack versus ThreadLocal debate (D43), the composition-over-inheritance rethinking of CorpusSeed (D55).

The pattern that emerged: decisions compound. D2 (simulation-api as a dedicated module) influenced D55 (CorpusSeed placement), which influenced D57 (key extractor decoupling), which influenced D66 (generated QN constants). Change D2 and a dozen downstream decisions shift. That's why the decisions file tracks dependencies explicitly — a reviewer looking at D57 can trace back to D2 and understand why the constraint exists.

## The three-layer data realism stack

What emerged from the corpus builders work (#328) and the brainstorming sessions around it is a three-layer architecture for test data realism:

**Seeding** (#328, done) — `CorpusSeed` as the universal accumulation point. Five typed descriptors (ACL, Model, Notification, Preference, Credential) plus `AgentCorpus`. `LlmCorpusPopulator` for domain-plausible data. `RandomCorpusPopulator` for structurally valid data.

**Synthesis** (#347, planned) — named patterns, perturbation primitives, domain-specific mutators. The key insight: mutators travel with the corpus as a matched pair. A cardiology team publishes vital-sign exemplars alongside the rules for plausible variation. Consumers load both and say "give me 500 variants" without needing medical knowledge.

**Catalogue** (#348, planned) — exemplar storage with statistical envelopes, canonical sequences, external data importers. The computed envelope defines the valid deviation space — perturbation that stays within it produces plausible output; perturbation outside produces artifacts.

Each layer adds fidelity independently. Seeding alone is already useful. Synthesis without a catalogue operates in degraded mode with user-provided bounds. The catalogue makes everything better but isn't a gate on the other two.

## What this unlocks

The simulation framework is now feature-complete for its initial scope. Every platform SPI can be simulated without Mockito, with real CDI wiring, configurable strategies, schema-driven or LLM-generated data, tenant-aware verification, and runtime overlays for scenario isolation. Consumer repos can adopt it today — the consumer guide, contributor guide, ARC42STORIES, and simulation guide are all updated.

The deeper implication is that testing moves from "mock everything" to "seed what you need." Mocks encode assumptions about the SPI contract in the test. Corpus entries encode responses. When the SPI contract changes, mock-based tests break at compile time (good) but also break at runtime in ways that mislead about the real failure (bad — the mock was wrong, not the code). Corpus-based tests fail because the response doesn't match what the code expects, which is the actual question the test should answer.

The two follow-on issues (#347 synthesis, #348 catalogue) extend the data realism stack. They're designed but not built — each needs its own brainstorming when the time comes. The simulation framework can grow to accommodate them because the accumulation point (`CorpusSeed.add()`) is already the universal entry path.
