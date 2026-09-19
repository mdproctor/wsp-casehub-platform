# Decisions — Simulation.forTest() Fluent Test Harness (#353)

## D1: Strategy selection — implicit from data shape

**Choice:** Strategy is inferred from how data is added: `stub()` implies key-lookup, `seed()` without key implies sequential. Explicit `.strategy(qn, name)` escape hatch available.
**Alternatives:**
- Always explicit — require `.strategy(qn, "key-lookup")` for every method. More typing, no ambiguity.
- Implicit with warning — auto-select but log when implicit choice is used. Noise in test output.
**Rationale:** The 80% case is either "same input → same output" (key-lookup) or "return in order" (sequential). Making the user spell out strategy names adds ceremony without safety — the data shape already communicates intent.
**Trade-offs:** Mixed stub+seed on the same qualifiedName becomes ambiguous — must be an error.
**Sources:** SimulationGettingStartedTest.java (current ceremony), issue #353 API sketch
**Exploration:** quick
**Status:** captured

## D2: Return type — purpose-built Simulation class

**Choice:** `build()` returns a new `Simulation` class wrapping runtime + corpus. Exposes `resolve()`, `overlay()`, `verifier()`, `runtime()` escape hatch.
**Alternatives:**
- Return SimulationRuntime directly — no new type, but `resolve()` requires qualified name + type parameters (turbofishing), losing DX.
- Return SimulationProfile — more composable for overlay stacking, but not self-contained for standalone tests.
**Rationale:** A purpose-built type hides plumbing (corpus, config, extractor registration) and provides a clean test-facing API. The `runtime()` escape hatch preserves access to the full API when needed.
**Trade-offs:** One more type to learn. Justified by 80% case simplification.
**Sources:** SimulationRuntime.java, SimulationOverlay.java, issue #353 API sketch
**Exploration:** quick
**Status:** captured

## D3: Multi-method scope

**Choice:** One `Simulation` instance configures multiple qualified names. `.stub("spi.query", ...).stub("spi.store", ...).build()`.
**Alternatives:**
- Single-method — each Simulation handles one qualifiedName. Simpler type but more objects and wiring for multi-method SPIs.
**Rationale:** Real tests simulate entire SPIs (2-5 methods). One runtime, many methods is the existing SimulationRuntime model — the harness should mirror it.
**Trade-offs:** None significant — single-method is a degenerate case of multi-method.
**Sources:** SimulationRuntimeTest.java (multi-method config), PerMethodStrategyTest.java
**Exploration:** quick
**Status:** captured

## D4: Integrated overlay and verification

**Choice:** `sim.overlay()` auto-pushes an overlay and returns a handle. `sim.verifier()` returns a `SimulationVerifier` on the current overlay's journal.
**Alternatives:**
- Lambda-scoped overlay — `sim.run(overlay -> { ... })` pushes/pops automatically. Clean lifecycle but limits flexibility (can't interleave assertions).
- Manual — users call `runtime().pushOverlay()` and `SimulationVerifier.on(journal)` themselves. No new abstraction but doesn't reduce ceremony.
**Rationale:** Integrated overlay keeps the harness self-contained for the 80% case (push, run, verify, pop). Lambda-scoped is too restrictive when tests need mid-scenario assertions. Manual defeats the purpose of the harness.
**Trade-offs:** Users must still call `popOverlay()` — but this is one line vs the current 3-4 line setup.
**Sources:** SimulationOverlay.java, SimulationVerifier.java, SimulationVerifierTest.java
**Exploration:** quick
**Status:** captured

## D5: stub() vs seed() semantics

**Choice:** `stub(qn, input, output)` auto-derives key from `input.toString()` and registers identity key extractor if none exists. `seed(qn, input, output)` adds a sequential entry with no key. Both add to the same underlying corpus.
**Alternatives:**
- stub = fixed value (ignores input) — `stub(qn, output)` always returns same output. Different mechanism (supplier) from corpus-backed strategies.
- No stub, only seed variants — `seed(qn, input, output)` for keyed, `seed(qn, output)` for sequential. Fewer concepts but less expressive naming.
**Rationale:** `stub` and `seed` communicate intent: "this input always returns this output" vs "return these in order." Using the same corpus underneath keeps the implementation simple and composable with CorpusSeed.
**Trade-offs:** `input.toString()` as default key works for strings and simple types but may need explicit `keyExtractor()` for complex objects.
**Sources:** CorpusSeed.java, KeyExtractor.java, KeyLookupStrategy.java
**Exploration:** quick
**Status:** captured

## D6: Default tenancyId

**Choice:** `forTest()` uses `"test"` as default tenancyId. Override via `forTest("hospital-a")`.
**Alternatives:**
- null default — tests that care about tenancy must provide it. Avoids magic string but may cause NPE in tenant-aware code.
- Required parameter — `forTest(tenancyId)` always requires it. Explicit but adds ceremony back.
**Rationale:** Most tests don't focus on tenant isolation — they need a non-null tenancyId to satisfy CurrentPrincipal assertions. `"test"` is conventional across the platform's test fixtures (FixedCurrentPrincipal uses "test-tenant").
**Trade-offs:** Tests verifying tenant isolation must use `forTest("tenant-a")` — not a hardship.
**Sources:** FixedCurrentPrincipal in testing module, InvocationRecord.of() patterns
**Exploration:** quick
**Status:** captured
