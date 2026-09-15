# Simulation Service Design Decisions

## D1: Initial scope — simulation + capture together

**Choice:** Design both simulation mode (providing responses when no real impl wired) and capture mode (recording real SPI calls for corpus building) in the initial design.
**Alternatives:**
- Simulation first — simpler initial scope but corpora need manual seeding, cold-start problem worse
- Capture first — builds corpora but no way to use them until simulation is designed
**Rationale:** Capture feeds simulation — they're two halves of the same lifecycle. Designing them together ensures the corpus contract serves both sides.
**Trade-offs:** Larger initial design surface. Capture requires CDI @Decorator infrastructure on top of the NoOp upgrade pattern.
**Sources:** Epic #294, cross-repo interaction map
**Exploration:** quick
**Status:** captured

## D2: SPI types live in platform-api

**Choice:** Simulation SPI types (SimulationStrategy, SimulationCorpus, InvocationRecord, etc.) live in `platform-api` alongside existing SPIs.
**Alternatives:**
- New simulation-api module — keeps platform-api focused but adds a dependency for every consumer
- In platform-core — but platform-core depends on platform-api, so SPIs end up there anyway
**Rationale:** Simulation is as fundamental as preferences or ACL — it's a platform primitive. Every SPI already depends on platform-api. Same zero-dep rules apply.
**Trade-offs:** platform-api grows slightly. But simulation types are small and domain-agnostic.
**Sources:** CLAUDE.md module architecture, platform-api package structure
**Exploration:** quick
**Status:** captured

## D3: Generic `<I, O>` contract for SimulationStrategy

**Choice:** `SimulationStrategy<I, O>` where I captures the invocation context and O is the response type. Per-SPI adapters define their own I and O types.
**Alternatives:**
- Untyped Map-based — universal but loses type safety, requires serialization at every boundary
- Sealed types — type-safe at boundary but requires extending sealed hierarchy per SPI
**Rationale:** Clean, type-safe. Each SPI adapter defines its own input/output record types. The strategy contract doesn't know about specific SPIs. Per-SPI adapters are small and mechanical.
**Trade-offs:** Requires an adapter per SPI. But that adapter is where the SPI-specific key extraction and response shaping lives anyway — it's not overhead, it's design.
**Sources:** AgentProvider SPI shape, CaseMemoryStore SPI shape (different signatures prove the need for generic typing)
**Exploration:** quick
**Status:** captured

## D4: CDI @Decorator for capture mode

**Choice:** CDI `@Decorator` wraps each SPI to transparently record input/output pairs to corpus during real runs.
**Alternatives:**
- Config-gated CDI producer — wraps real bean in recording proxy. No decorator complexity but requires per-SPI producer methods
- CDI @Interceptor with @Capturable annotation — more generic but interceptors can't easily access method-specific context
**Rationale:** @Decorator is the established transparent interception pattern in the codebase (callback routing uses it). Well-understood. Records every invocation without changing behaviour.
**Trade-offs:** Must implement all abstract methods (GE-20260818-2589ee). @PostConstruct skipped on decorators (GE-20260806-93549d — use lazy init). Risk of double-application through blocking-to-reactive bridges (GE-20260620-9d043b — use idempotency guard).
**Sources:** GE-20260818-2589ee, GE-20260817-55c9b2, GE-20260806-93549d, GE-20260620-9d043b
**Exploration:** quick
**Status:** captured

## D5: SimulationCorpus follows store pattern

**Choice:** `SimulationCorpus<I, O>` SPI in platform-api, with NoOp @DefaultBean, InMemory @Alternative, and filesystem @Alternative backends. Same ladder as every other platform store.
**Alternatives:**
- Generic key-value store — loses type safety at storage layer
- Embedded in strategy — each strategy owns its data. No shared storage for capture mode
**Rationale:** Follows the established casehub pattern. Corpus is per-SPI, per-scenario. InMemory for test isolation, filesystem for persistent fixtures and captured corpora.
**Trade-offs:** Requires a corpus instance per SPI type (because of the generic typing). But CDI handles this via qualifier or producer methods.
**Sources:** Existing store pattern (NotificationStore, PreferenceStore, CaseMemoryStore), CLAUDE.md module table
**Exploration:** quick
**Status:** captured

## D6: Upgrade existing NoOps in-place for simulation activation

**Choice:** Modify existing NoOp implementations to check for a configured SimulationStrategy and delegate to it. When no strategy is configured, existing silent NoOp behaviour. Evolution, not addition.
**Alternatives:**
- Separate simulation beans (@Alternative @Priority) — new beans between @DefaultBean and real impls. NoOps untouched but priority numbering gets complex
- Strategy-aware base class — abstract base that NoOps extend. Reduces boilerplate but adds inheritance
**Rationale:** The simulation service IS the upgrade from silent NoOps. When no real impl is wired, you get simulation instead of silence. Zero new CDI beans. Config-driven: `casehub.simulation.<spi>.strategy=key-lookup`.
**Trade-offs:** Changes the signature of existing NoOp constructors (adds SimulationStrategy parameter). Downstream test code constructing NoOps directly will need updating (GE-20260910-8ecdb7). CDI wiring is transparent — constructor injection handled by the framework.
**Sources:** NoOpPreferenceStore (platform-core), NoOpAgentProvider (platform), GE-20260910-8ecdb7
**Exploration:** quick
**Depends on:** D3 (strategy contract shape), D5 (corpus storage)
**Status:** captured

## D7: Key extraction owned by strategy

**Choice:** Each strategy defines how it matches inputs. KeyLookupStrategy has a `KeyExtractor<I>`, NearestMatchStrategy has a `SimilarityScorer<I>`. The strategy owns matching semantics.
**Alternatives:**
- On the corpus — corpus handles indexing and retrieval. Simpler strategy interface but corpus becomes smarter
- Separate KeyFunction SPI — independent abstraction. Maximum flexibility but another layer
**Rationale:** Different strategies match differently — key-based lookup needs exact keys, nearest-match needs similarity scores, sequential strategy ignores input entirely. Matching semantics are inherently strategy-specific.
**Trade-offs:** Per-SPI KeyExtractors need writing. But they're functional interfaces — typically one-liners.
**Sources:** Strategy table from epic #294
**Exploration:** quick
**Depends on:** D3 (strategy contract)
**Status:** captured

## D8: Unified contract for request/response and events

**Choice:** Events use the same `SimulationStrategy<I, O>` contract. A trigger (scheduled tick, scenario step, manual) serves as the input. Corpus, seeding, and capture all work identically for events.
**Alternatives:**
- Separate EventSimulationStrategy — explicit timing, ordering, fan-out concerns. But duplicates infrastructure
- Defer events — focus on request/response first. But events are needed for end-to-end scenario testing
**Rationale:** Events are just another output type. The simulation framework should not care whether it's responding to a request or generating an event. Unified infrastructure reduces surface area.
**Trade-offs:** Event timing/scheduling needs to be handled outside the strategy (by whatever triggers the strategy). The strategy itself is stateless — it resolves one event per invocation.
**Sources:** DataSourceRegistry SPI, CloudEvent patterns in engine/work/blocks
**Exploration:** quick
**Status:** captured
