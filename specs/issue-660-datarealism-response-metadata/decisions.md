## D1: Access pattern — last-write-wins

**Choice:** Last-write-wins holder that updates on each SPI call
**Alternatives:**
- Floor aggregation — tracks lowest DataRealism across request, loses per-call granularity
- Per-QN map — maps qualifiedName → DataRealism for all calls, heavier than needed
**Rationale:** Consumers need to check "was that specific call simulated?" — last-write-wins answers this directly
**Trade-offs:** Cannot query realism of earlier calls in same request (use journal for that)
**Sources:** SimulationRuntime.java:141-148 (recordJournal), SimulationDecoratorProcessor.java:388-403 (generated code)
**Exploration:** quick
**Status:** captured

## D2: Module placement — simulation-core POJO

**Choice:** Framework-neutral DataRealismContext POJO in simulation-core, CDI producer in simulation-config
**Alternatives:**
- simulation-api — adds surface to zero-dep API module, minimal benefit
- simulation-config CDI-only — ties to CDI, Spring/standalone can't use
**Rationale:** simulation-core already hosts SimulationRuntime, InvocationJournal, and other runtime POJOs; CDI/Spring producers belong in their respective modules
**Trade-offs:** Requires generator change to inject the new field into decorators
**Sources:** SimulationConfigBeans.java (existing CDI producers), SimulationDecoratorProcessor.java (generator)
**Exploration:** quick
**Status:** captured

## D3: Context shape — Observation record with qualifiedName

**Choice:** DataRealismContext holds an Observation record (qualifiedName + DataRealism)
**Alternatives:**
- DataRealism only — simpler but consumers can't verify which call set the value
**Rationale:** qualifiedName lets consumers guard against reading stale context from a different SPI call
**Trade-offs:** Marginally more data per observation (one String reference)
**Sources:** JournalEntry.java (already carries qualifiedName + DataRealism together)
**Exploration:** quick
**Status:** captured

## D4: No ThreadLocal — scope-managed isolation

**Choice:** Plain mutable POJO, rely on CDI @RequestScoped / Spring @RequestScope for thread isolation
**Alternatives:**
- ThreadLocal-based holder — framework-neutral isolation but platform convention avoids ThreadLocals
**Rationale:** Platform convention avoids ThreadLocal; CDI/Spring scope mechanisms provide the same isolation without manual cleanup
**Trade-offs:** Standalone (non-CDI, non-Spring) tests must create and inject DataRealismContext manually — same pattern already used in DataRealismEndToEndTest for CurrentPrincipal
**Sources:** DataRealismEndToEndTest.java:35-40 (manual inject pattern), user feedback (ThreadLocal avoidance)
**Exploration:** quick
**Status:** captured

## D5: Setting mechanism — generator-injected, decorator-owned

**Choice:** Generator adds @Inject DataRealismContext to decorators; decorators call set() alongside recordJournal()
**Alternatives:**
- SimulationRuntime.recordJournal() sets context — avoids generator changes but conflates concerns (runtime shouldn't know about request-scoped context)
**Rationale:** The decorator already has the DataRealism value; setting context there keeps SimulationRuntime focused on journaling
**Trade-offs:** Generator change required (one new @Inject field + two set() calls per generated method)
**Depends on:** D2 (module placement), D4 (no ThreadLocal)
**Sources:** SimulationDecoratorProcessor.java:332-416 (generateSimulatedMethod)
**Exploration:** quick
**Status:** captured
