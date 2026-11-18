# HANDOFF — casehub-platform

**Last worked:** Queue sweep — 9 issues closed (8 implemented + 1 already-fixed), 3 new issues filed
**Landed:** `ab8cc45c` on main (7 commits published)
**Queue:** 7 items remaining, #849 is next active

## This session

Swept through S/XS issues in the epic #827 queue. Implemented 6 features and 3 fixes, closed 2 as already-resolved, deferred 1 (#863) to a slot for cross-repo migration (which another slot completed), and filed 3 follow-up issues.

**Implemented:**

1. **#864 — Capability-aware schema emission** — `StepSchemaComposer.compose()` gains a `Set<String> capabilities` parameter. Structural variants (if/then/else, parallel, race, invoke, pause/resume) and decorator properties are conditionally included. Two-arg overload delegates with all capabilities for backward compat.

2. **#862 — SourceLocation line/column tracking** — Switched `PlaybookParser` from SnakeYAML `loadAll()` to the Composer API (`composeAll()`). `LocationIndex` (IdentityHashMap-based) records each parsed mapping's start mark. Threaded through Walker so `ParseError` instances carry precise `SourceLocation(file, line, column)` instead of sentinel `-1` values.

3. **#865 — Domain-grouped catalogue** — Added `domain` field to `Definition` record. `PluginRegistry` gains `availableDomains()` and `actionsInDomain(String)`. MCP-sourced steps inherit their `@McpDomain` name via `McpStepCatalogWiring`. Orthogonal to capability-based level filtering.

4. **#841 — Parallel fail-fast + concurrency** — Added fail-fast cancellation (AtomicReference + future cancel pattern) and `concurrency` field (Semaphore gate) to `evaluateParallel` simple path. Same pattern as `DecoratorChain.executeForEachParallel`.

5. **#842 — Background error observability** — Added `backgroundFailureHandler` BiConsumer to `DecoratorConfig`. Spawned background tasks now catch failures and call the handler. `StructuralStepEvaluator` wires logging. Public constructor delegates to private for consistent handler wiring.

6. **#840 — Capture consolidation** — Removed incorrect `captureCollector != null` guard from `evaluateBlock`'s resolver threading. Capture scoping now works independently of external CaptureCollector.

7. **#868 — Map.copyOf NPE fix** — `PlaybookRunnerCore.run()` capture scope registration replaced `Map.copyOf()` (rejects nulls) with `Collections.unmodifiableMap(new LinkedHashMap<>())`. Cherry-picked to main as hotfix for connectors.

8. **#839 — Static ObjectMapper** — `SimulationRuntimeActivator.loadYamlMap()` now uses a static `YAML_MAPPER` field instead of per-call allocation.

9. **#843 — LoopDirective max alias** — `max` accepted as alias for `count` in loop directive parse, overriding the default 1000-iteration cap on `until` loops.

**Already resolved (closed without code):**

- **#838** — `advanceStateMachines` wiring already restored by #850's `stepCompletionNotifier` Consumer.
- **#765** — `CorpusSelectionEventObserver.bindingsForEventType()` already lazily rebuilds trigger index on every event.

**Code review:** 0 CRITICAL, 3 WARNING (all fixed): barrier/quorum SourceLocation regression, public constructor missing bgHandler, StepSchemaComposer string literals vs constants. 3 NOTEs (all fixed): LocationIndex EMPTY mutation guard, scalar parsing documentation, error message wording.

**Blog:** "The Line Number Your Tools Need" — SnakeYAML Composer API, identity-based position tracking, precision through the validation stack.

**Issues filed:** #869 (parallel concurrency docs, XS), #870 (LocationIndex import expansion, S/Med), #871 (background structured trace, S/Med)

## Resuming #849

**Next issue:** #849 — Streaming + ContextParam intersection not handled in generator (S/Med)

The `GraphQLResolverProcessor` streaming path skips `@ContextParam` injection — when `isStreaming && !meta.subject.isEmpty()`, the `hasNonHttpContextParams` branch is unreachable. Generator/APT code — different domain from this session's playbook work.

## Queue (7 items)

1. #849 — Streaming + ContextParam intersection (S/Med) ← next
2. #851 — Restore module-system demonstration (M/Med)
3. #867 — capture: result name collision (XS/Low)
4. #869 — StepSchemaComposer concurrency docs (XS/Low)
5. #870 — LocationIndex import expansion (S/Med)
6. #871 — Background trace integration (S/Med)
7. #848 — Streaming plugins bypass validation and coercion (M/Med) — reopened, not addressed this session
