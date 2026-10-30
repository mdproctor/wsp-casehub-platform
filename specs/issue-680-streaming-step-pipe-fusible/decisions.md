# Decisions — Issue #680: Streaming Step Type

## D1: StreamingStep interface shape

**Choice:** Standalone `StreamingStep<I,O>` interface with `apply(I) → O`, explicit type token methods, `materialize()` boundary, and constructor-injected services

**Alternatives:**
- StreamingAction<I,O> extends Action — couples streaming and non-streaming contracts, default execute() has to guess how to extract I from Map
- Annotation + reflection — loses type safety and Java-speed goal
- Single Action interface with optional typed override (`applyTyped()` default methods) — pollutes `@FunctionalInterface` with optional methods, erases generic relationship between type tokens and apply() signature, violates interface segregation principle

**Rationale:** Clean separation of concerns. The interface declares:
```java
public interface StreamingStep<I, O> {
    Class<I> inputType();
    Class<O> outputType();
    O apply(I input);
    default Result materialize(Map<String, Object> params, ServiceRegistry services) {
        throw new UnsupportedOperationException("APT-generated override");
    }
}
```
`inputType()` and `outputType()` provide runtime type tokens that compensate for generic erasure — the fusion pass uses these for compile-time type compatibility checks via `isAssignableFrom()`. `apply()` is composed via `Function.andThen()`. Explicit, type-safe, Java-speed.

**materialize():** Bridges streaming to non-streaming execution. The APT-generated implementation: (1) extracts typed `I` from the `Map<String,Object>` params using the same kebab-case extraction as `BinderEmitter`, (2) calls `apply(input)`, (3) wraps the output `O` into `Result.of(Map.of("output", result))`. For InputStream outputs, materializes by reading to byte[] or delegating to a result serializer. This method is the boundary between the streaming and `Action`-compatible worlds — the `@StreamPlugin` APT generates both a `StreamingStep<I,O>` implementation and an `Action` adapter that delegates through `materialize()`.

**Error model:** Within a fused chain, errors propagate as exceptions through the `Function.andThen()` composition. The chain wrapper catches exceptions at the boundary and converts to `Result.Failure(message, category)` where category is derived from the exception type. This preserves natural exception propagation for composed functions while maintaining `Result` semantics for the evaluator, decorator chain (`wrapOnError`, `wrapRetry`), and step result recording.

**Service access and step lifecycle:** Streaming steps are constructed per-invocation, matching the existing `BinderEmitter` pattern where `Action.execute()` constructs a new record instance from the params Map each time (lines 62-71). The `@StreamPlugin` APT generates a factory: `(Map<String,Object> resolvedParams, ServiceRegistry services) → StreamingStep<I,O>` that (1) constructs the `@StreamPlugin` record from resolved YAML params using kebab-case extraction, (2) looks up `@Execute` method service dependencies via `services.lookup(Class)`, and (3) returns a configured `StreamingStep` instance. Config params and services are available inside `apply()` as record fields and final fields respectively. Each YAML step usage (even of the same action with different params) gets its own step instance.

**Trade-offs:** Steps that want streaming execution implement `StreamingStep<I,O>` via `@StreamPlugin`. The generated `materialize()` provides the `Action`-compatible fallback path. Dual interface implementation (`StreamingStep` + `Action`) is handled entirely by the APT — step authors write one `@StreamPlugin` record with one `@Execute` method.

**Sources:** yaml-plugin-api Result.java, Action.java, ServiceRegistry.java — current contracts are Map<String,Object> only; BinderEmitter.java — service parameter injection pattern
**Exploration:** quick → revised after adversarial review
**Status:** revised — R1-02 (error model), R1-03 (service access), R1-04 (type tokens), R1-05 (materialize boundary), R2-01 (per-invocation construction) addressed

## D2: Fusion detection and chain compilation

**Choice:** Compile-time fusion pass producing `ResolvedStep.FusedPipelineStep`, with `PluginRegistry`-backed type metadata lookup

**Alternatives:**
- Lazy evaluation-time fusion — StructuralStepEvaluator detects on the fly, but SWF path can't use it
- Explicit `pipeline:` YAML block — author declares intent, but requires new syntax and loses auto-detection

**Rationale:** Fits both execution paths (StructuralStepEvaluator and SWF compiler). The fusion pass:

1. Receives the resolved step list AND the `PluginRegistry`
2. For each consecutive `PluginStep`, queries `registry.resolve(actionName)` to obtain the `Definition`, which carries optional streaming metadata: `Optional<StreamingTypeInfo> streamingType()` where `StreamingTypeInfo(Class<?> inputType, Class<?> outputType, StreamingStepFactory<?,?> factory)`. The factory produces configured step instances per-invocation — `StreamingTypeInfo` carries type metadata for the fusion pass, not a pre-configured singleton (see D1 service access)
3. Detects fusible sequences where `outputType` is assignable to the next step's `inputType` via `isAssignableFrom()`
4. Validates that no intermediate step's `name()` is referenced by `${results.<name>}` in any downstream step outside the chain — referenced steps become fusion boundaries
5. Checks each step's `decorators()` map for chain-compatible decorators per D3 — chain-breaking decorators force fusion boundaries
6. Collapses valid sequences into `FusedPipelineStep` — a data record carrying per-step action names, param maps, decorator maps, and references to the `StreamingStepFactory` from each step's `StreamingTypeInfo`. The chain is NOT pre-composed at fusion time; step instances are constructed and composed at execution time.

The `Definition` record is extended with `Optional<StreamingTypeInfo> streamingType()` (default `Optional.empty()` for non-streaming actions). The `@StreamPlugin` APT's `RegistryEmitter` populates this from the generated factory.

**Execution-time chain assembly:** When the evaluator processes a `FusedPipelineStep`:
1. For each step in the chain: resolve YAML params via `VariableResolver`, then call `factory.create(resolvedParams, services)` to get a configured `StreamingStep` instance
2. Compose the `apply()` methods from those instances (with inline fusible decorator wrappers per D3)
3. Execute the composed chain: feed the first step's typed input (extracted from its resolved params), pipe through successive `apply()` calls
4. Wrap the final output in `Result.of(Map.of("output", finalOutput))`

**Pass ordering:** resolve steps → fusion pass (reads `decorators()` maps from `ResolvedStep` records + queries `PluginRegistry` for streaming metadata) → compile fused chains. No circular dependency with decorator resolution — decorator data is already present in `ResolvedStep.PluginStep.decorators()` as raw `Map<String, Object>` after step resolution.

**Output wrapping:** A `FusedPipelineStep` produces typed output `O` from the final step's `apply()`. The evaluator wraps this: `Result.of(Map.of("output", finalOutput))`, recording the result under the chain's name (first step's name). Intermediate step names within the chain are NOT individually recorded — they do not execute independently. If downstream YAML references `${results.intermediateStep}` where `intermediateStep` is an internal chain member, the fusion pass must detect this and refuse to fuse that step.

**Trade-offs:** Type information must be available at resolution time (the plugin registry carries streaming type metadata via the extended Definition record). The fusion pass requires PluginRegistry access, which is already available in the step catalog resolution path.

**Sources:** ResolvedStep.java (sealed hierarchy), StructuralStepEvaluator.java (dispatch model), PluginRegistry.java (resolve by name), Definition.java (action + metadata), CatalogStepRunner.java (existing registry→action lookup pattern)
**Exploration:** quick → revised after adversarial review
**Depends on:** D1 (StreamingStep interface provides inputType/outputType)
**Status:** revised — R1-08 (registry type metadata), R1-09 (Result wrapping + variable references), R1-10 (ordering clarification), R2-01 (factory pattern, execution-time chain assembly) addressed

## D3: Decorator application on fused chains

**Choice:** Structural decomposition with decorator classification at YAML-to-executor time

**Alternatives:**
- Merge all decorators into chain-level — loses per-step granularity (a timeout on one step becomes chain-wide)
- Break chain at any decorator boundary — defeats fusion when steps have common decorators like timeout

**Rationale:** Decorators are classified into three categories for fused chain handling:

**Fusible decorators** (valid as per-step wrappers within a fused chain — wrap individual `apply()` calls inline):
- `timeout` — wraps individual `apply()` call with deadline
- `retry` — retries individual `apply()` on failure (catches exceptions, re-invokes)
- `on-error` — catches and handles individual `apply()` failure
- `delay` — pauses before individual `apply()` invocation
- `when` — conditionally skips individual `apply()` (short-circuits with pass-through)
- `transform` — post-processes individual step output

**Chain-breaking decorators** (force a fusion boundary — the step executes independently via the standard `StepRunner` path):
- `from` — data source, changes input origin (reads from `OrcChannel`)
- `background` — spawns async execution via `scope.spawn()`
- `semaphore` / `mutex` / `resource` — concurrency control (acquires `OrcSemaphore`)
- `wait` — blocks on `OrcSignal`
- `at` — threshold gate on `OrcNumericPrimitive`
- `forEach` — changes cardinality (iterates over list)
- `cancel` — signal-triggered cancellation
- `loop` — iteration control
- `transition` — state machine side effect (`OrcStateMachine`)
- `signal` / `publish` — post-execution side effects (signals/channel sends)

**Chain-level decorators:** Apply to the entire fused chain via an enclosing block step, not from individual steps within the chain. If a YAML author wants to retry the entire pipeline, they wrap it in a block with `retry: 3`. Per-step `retry: 3` on a mid-chain step wraps only that step's `apply()` inline within the composed function.

The fusion pass refuses to fuse a step carrying a chain-breaking decorator. At compile time, the YAML-to-executor pass validates decorator compatibility — a chain-breaking decorator on a step that would otherwise be fused produces a compile-time diagnostic explaining why the chain is broken at that point.

**Inline wrapper implementations:** Fusible decorators within fused chains require NEW inline wrapper implementations that operate on the exception-based error model (D1), separate from the existing `DecoratorChain` methods which operate on `DecoratedExecution → Result`. Specifically:
- `retry` inline: catches exceptions from `apply()` and re-invokes, deriving retry category from exception type — vs. `DecoratorChain.wrapRetry()` (lines 243-296) which checks `Result.isSuccess()` and inspects `Result.Failure.category()`
- `on-error` inline: catches exceptions and maps to fallback output — vs. `wrapOnError()` (lines 188-212) which inspects `Result.Failure`
- `timeout` inline: wraps `apply()` in a virtual-thread executor with deadline — structurally similar to `wrapTimeout()` but returns the typed output or throws
- `delay`, `when`, `transform`: simpler wrappers that are structurally similar to their `DecoratorChain` counterparts

The existing `DecoratorChain` methods remain authoritative for the standard `Result`-based execution path (standalone steps, chain-level decorators on enclosing blocks). The inline wrappers are a parallel code path for the exception-based model within fused chains.

**Trade-offs:** The composed function is more complex when per-step decorators exist (each decorated step is a mini-wrapper within the chain). The inline wrappers are additional implementation effort beyond the existing `DecoratorChain`. But this is compile-time complexity, not runtime cost. YAML authors use explicit block wrappers for chain-level behavior.

**Sources:** DecoratorChain.java (18 decorator types, apply() model — standard Result-based path), StructuralStepEvaluator.java (evaluateInternal decorator wrapping)
**Exploration:** quick → revised after adversarial review
**Depends on:** D2 (fusion pass identifies chains and their per-step decorator sets)
**Status:** revised — R1-12 (decorator classification), R1-13 (chain-level scoping from blocks, not positional rule), R2-02 (inline wrapper implementations for exception model) addressed

## D4: SWF durability constraint for byte streams

**Choice:** Non-serializable types (`InputStream`, `Reader`, etc.) are rejected by the SWF compilation path. Serializable types including `byte[]` are accepted with size-limit awareness. Both work in the StructuralStepEvaluator path.

**Alternatives:**
- Allow non-serializable streams in SWF with explicit materialization checkpoints — adds complexity, violates the "no materialization in fused chains" goal
- Don't support SWF at all for streaming — loses the "both paths from the start" requirement for serializable types

**Rationale:** You can't serialize/checkpoint a live `InputStream` for durable execution. The SWF path validates that all types in a fusible chain implement `Serializable`. `byte[]` is serializable and valid in SWF chains, though SWF task payload size limits apply — chains processing large byte arrays should use external storage handles (e.g., S3 URIs) rather than inline `byte[]` values as intermediates. `InputStream` chains are valid only in the StructuralStepEvaluator path.

Non-durable chains (`InputStream`-based) restart from the beginning on failure. This requires the data source to be replayable (idempotent fetch). Non-replayable sources (WebSocket audio streams, one-time webhook payloads, expiring pre-signed URLs) must buffer to a replayable store as the first step before entering the fused chain.

**Trade-offs:** InputStream processing is non-durable. byte[] processing is durable but size-constrained by SWF payload limits. Acceptable for the audio/image use cases in issue #680.

**Sources:** 2026-10-09-durable-playbook-execution-swf-integration.md spec, user clarification
**Exploration:** quick → revised after adversarial review
**Status:** revised — R1-15 (byte[] is serializable, distinct from InputStream), R1-16 (replayability requirement for non-durable sources) addressed

## D5: Union merge model

**Choice:** Explicit `StreamingMerge<T>` interface — merge is a special streaming step type

**Alternatives:**
- Implicit merge via parallel block — compiler auto-inserts merge, but behavior is implicit and merge strategy unclear
- Channel-based via from decorator — reuses OrcChannel fan-in but byte streams don't map to channels

**Rationale:** Merge step accepts `List<T>` from N upstream branches, produces single `T` downstream. Author controls merge strategy (concatenation, multiplex, collect). Compiler validates all upstream output types match merge input type.

**Data path from parallel to merge:** The evaluator handles the parallel-to-merge transition as a special case. When a `ParallelStep` is followed by a merge step:
1. The evaluator executes parallel branches, each producing a `Result`
2. For branches that are `StreamingStep` outputs, the typed output is extracted from `Result.output().get("output")`
3. The extracted typed outputs are collected into `List<T>`
4. The merge step's `apply(List<T>)` is called with the collected list
5. The merge step returns `T`, which the evaluator wraps in `Result`

This is an evaluator-level data path, not a fusion pass concern — the fusion pass does not attempt to fuse across parallel boundaries. `StreamingMerge<InputStream>` can produce a `SequenceInputStream` (concatenation), a multiplexing `InputStream` (interleaved reads from the input list), or a collecting strategy — the merge step's implementation decides. All strategies are compatible with `apply(List<T>) → T` because the returned `T` (e.g., InputStream) can be lazy and read from the input list on demand.

**Trade-offs:** Explicit merge step required in YAML — more verbose than implicit detection. But merge strategy is always clear and the step is independently testable.

**Sources:** datasource-alpha AlphaDataSource.java (fan-out pattern, no fan-in exists yet), StructuralStepEvaluator.evaluateParallel() (current parallel evaluation)
**Exploration:** quick → revised after adversarial review
**Status:** revised — R1-18 (merge data path from parallel evaluator) addressed

## D6: Plugin system integration

**Choice:** New `@StreamPlugin` annotation on records, parallel to `@Plugin`

**Alternatives:**
- Manual implementation only — no APT support, more boilerplate for plugin authors
- Extend @Plugin itself — overloads semantics, type inference ambiguity when @Execute takes Map vs typed param

**Rationale:** Consistent authoring pattern with `@Plugin`. APT infers `I` and `O` from `@Execute` method signature (parameter type = input, return type = output). Generates both:
1. A `StreamingStep<I,O>` implementation with `inputType()`, `outputType()`, `apply()`, and `materialize()`
2. An `Action` adapter that delegates through `materialize()` for standalone/fallback execution

The `Action` adapter is registered in the `PluginRegistry` as a standard `Definition` with the additional `StreamingTypeInfo` metadata (see D2). This ensures backward compatibility with the existing step catalog, `CatalogStepRunner`, and `ValidatingAction` wrapping.

**Authoring model:** One annotation per step — `@Plugin` for Map-based steps, `@StreamPlugin` for typed streaming steps. A step migrating to streaming support changes from `@Plugin` to `@StreamPlugin`; the APT generates both the streaming fast-path and the Action-compatible fallback. There is no need for dual annotations on the same class.

Record fields remain configuration parameters (same as `@Plugin`). `@Execute` method service parameters are resolved at construction time and bound as final fields on the generated implementation, rather than per-invocation via `ServiceRegistry.lookup()`.

**Trade-offs:** The APT generates two artifacts (StreamingStep + Action adapter) instead of one. This is mechanical code generation complexity, not design complexity — the BinderEmitter and RegistryEmitter patterns from the existing `StepPluginProcessor` are directly reusable. JSON Schema generation is identical.

**Sources:** yaml-plugin-processor APT (generates Action from @Plugin), yaml-plugin-api @Plugin/@Execute annotations, BinderEmitter.java (parameter extraction + service injection patterns)
**Exploration:** quick → revised after adversarial review
**Depends on:** D1 (StreamingStep interface)
**Status:** revised — R1-22 (dual code generation clarified), R1-23 (single-annotation authoring model clarified) addressed

## D7: Streaming step portability

**Choice:** Streaming steps are `Portability.JAVA` initially. TypeScript parity is deferred.

**Alternatives:**
- Require UNIVERSAL portability from the start — blocks the feature on TypeScript runtime design
- Design a cross-language streaming interface — TypeScript uses structural typing, not Java generics; the abstraction would be forced

**Rationale:** Java generics (`StreamingStep<I,O>`) have no direct TypeScript equivalent. The TypeScript step runtime uses structural typing and has its own `Action`/`Result` model (in `chat-app/src/main/webui/.casehub-packages/packages/yaml-core/src/step/walker.ts`). The `Portability` enum already tracks cross-language compatibility — streaming steps are `Portability.JAVA`, consistent with existing Java-only steps.

Universal playbooks can include streaming steps — the fusion pass is compile-time, and the SWF/evaluator paths handle streaming transparently. A TypeScript runtime encountering a streaming step falls back to the `Action` adapter (via `materialize()`) just like any other Java-specific step.

TypeScript streaming parity can follow later, using TypeScript's structural typing to define an equivalent interface. This is an additive change that doesn't affect the Java design.

**Trade-offs:** Streaming steps are initially Java-only. This is acceptable because the primary use cases (audio processing, byte-stream transforms, image pipelines) are server-side Java workloads.

**Sources:** Portability.java enum, TypeScript step runtime walker.ts
**Exploration:** surfaced by adversarial review (R1-27)
**Status:** captured
