# Streaming Step Type — Pipe-Fusible Data Pipelines

**Issue:** #680
**Date:** 2026-10-30

## Goal

Add a typed streaming step interface to the playbook step engine that enables
pipe-fusible data pipelines. When consecutive steps implement `StreamingStep<I,O>`
with compatible types, the compiler fuses them into a single execution chain —
data flows through via `Function.andThen()` composition at Java speed, without
materializing to `Map<String, Object>` at each step boundary.

Two data kinds are supported with the same 1:1 transform API shape:
- **Byte streams**: continuous binary data (`InputStream`, `byte[]`) for audio,
  images, documents — laziness comes from `InputStream`'s read model
- **Typed transforms**: domain objects processed as a typed pipeline (e.g.,
  `SensorEvent → AnnotatedEvent`), each `apply()` call processes one input

The "streaming" in `StreamingStep` refers to data flowing through the chain
without materialization to `Map<String, Object>` at step boundaries — not to
reactive-streams backpressure or flow control. The framework enables zero-copy
data flow; the types themselves determine whether processing is lazy
(`InputStream`) or eager (domain objects).

## Motivation

The current step execution model is request/response: each step runs, produces a
`Result(Map<String, Object>)`, which the next step reads via `StepResultStore` and
`${result.stepName.field}` variable resolution. This works for orchestration but
adds overhead for data-intensive pipelines.

Real-time inbound channel processing (connectors #188) surfaced this: a WhatsApp
voice note arrives → download binary → denoise → STT transcribe → text cleanup.
Each stage is a natural streaming transform. With current step semantics, the full
audio payload materializes at each boundary. With streaming steps, the compiler
wires them into a direct Java function chain.

## Architecture

### StreamingStep Interface (yaml-plugin-api)

```java
public interface StreamingStep<I, O> {
    String OUTPUT_KEY = "output";

    Class<I> inputType();
    Class<O> outputType();
    O apply(I input);

    default Result materialize(Map<String, Object> params, ServiceRegistry services) {
        throw new UnsupportedOperationException(
            getClass().getName() + " must override materialize() for standalone execution");
    }
}
```

- `OUTPUT_KEY` — contract constant for the key used when wrapping typed output
  in a `Result` map. The APT-generated `materialize()` uses
  `Result.of(Map.of(OUTPUT_KEY, result))`. The merge data path uses the same
  key for extraction. All implementations must use this constant
- `inputType()` / `outputType()` — runtime type tokens compensating for generic
  erasure. The fusion pass uses these for type compatibility checks via
  `isAssignableFrom()`. **Constraint:** type tokens must be non-generic concrete
  classes (`InputStream`, `String`, `SensorEvent`). Parameterized types
  (`List<SensorEvent>`, `Map<String, Object>`) are not supported — Java generic
  erasure makes `isAssignableFrom()` unsound for parameterized types. If
  parameterized type support is needed in future, a `TypeToken` mechanism can
  be added
- `apply(I) → O` — the streaming transform. Composed via `Function.andThen()`
  in fused chains
- `materialize()` — bridges streaming to non-streaming execution. The APT
  generates this: extract typed `I` from params, call `apply()`, wrap output in
  `Result.of(Map.of(OUTPUT_KEY, result))`. This is the boundary between the
  streaming and `Action`-compatible worlds. Hand-written `StreamingStep`
  implementations (not using `@StreamPlugin`) must override `materialize()`
  themselves — the default throws to catch missing overrides at development time.
  The throw is intentional: within fused chains, `materialize()` is never called
  (the chain uses `apply()` directly). It only fires when a step is used
  standalone outside a fused chain, which is the exact scenario where the
  override is needed

### StreamingMerge Interface (yaml-plugin-api)

```java
public interface StreamingMerge<T> {
    Class<T> mergeType();
    T merge(List<T> inputs);
}
```

Union merge for same-type fan-in. Accepts `List<T>` from N upstream branches,
produces a single `T` downstream. The merge step author controls strategy
(concatenation, multiplexing, collection). For byte streams:
`StreamingMerge<InputStream>` can return a `SequenceInputStream` (concatenation)
or a multiplexing implementation that interleaves reads.

### StreamingTypeInfo (yaml-plugin-api)

```java
public record StreamingTypeInfo(
    Class<?> inputType,
    Class<?> outputType,
    String inputKey,
    StreamingStepFactory<?, ?> factory
) {}

@FunctionalInterface
public interface StreamingStepFactory<I, O> {
    StreamingStep<I, O> create(Map<String, Object> resolvedParams, ServiceRegistry services);
}
```

Carried by the `Definition` record in `PluginRegistry`. The fusion pass reads
type metadata from here; the factory creates configured step instances at
execution time (per-invocation construction, matching the existing
`BinderEmitter` pattern).

- `inputKey` — the YAML key (kebab-case) that provides the first step's typed
  input when the step appears at the head of a fused chain. For
  `@StreamPlugin`-annotated steps, the APT derives this from the `@Execute`
  method parameter name (e.g., `apply(String url)` → `inputKey = "url"`). For
  mid-chain steps, `inputKey` is unused — the input comes from the previous
  step's output. For hand-written `StreamingStep` implementations, the author
  sets `inputKey` in the `StreamingTypeInfo` passed to the `Definition`

### Definition Record Change

The `Definition` record gains an 8th component:
`Optional<StreamingTypeInfo> streamingType`. This is a breaking change to the
canonical constructor — all existing callers (`PluginScanner.scanAndRegister()`,
`Definition.Builder.build()`, APT-generated code) require migration.

A secondary constructor preserves ergonomics for non-streaming steps:

```java
public Definition(String name, String description,
    Map<String, Parameter> inputs, Map<String, Parameter> outputs,
    Portability portability, Action action, String capability) {
    this(name, description, inputs, outputs, portability, action,
         capability, Optional.empty());
}
```

The `Builder` gains a `streamingType(StreamingTypeInfo info)` method, defaulting
to `Optional.empty()` when not called. The secondary constructor is not a
backward-compatibility shim — it's API ergonomics for the common case where
streaming metadata is absent.

### @StreamPlugin Annotation (yaml-plugin-api)

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
public @interface StreamPlugin {
    String name();
}
```

Parallel to `@Plugin`. Applied to Java records. The APT infers `I` and `O` from
the `@Execute` method signature. Generates:
1. A `StreamingStep<I,O>` implementation with type tokens, `apply()`, and
   `materialize()`
2. An `Action` adapter delegating through `materialize()` for standalone/fallback
   execution
3. Registry manifest with `StreamingTypeInfo` metadata

### Example: Authoring a Streaming Step

```java
@StreamPlugin(name = "denoise")
public record DenoisePlugin(@Optional String model) {
    @Execute
    public InputStream apply(InputStream audio) {
        // denoise the audio stream using the configured model
        return new DenoisedInputStream(audio, model != null ? model : "gtcrn");
    }
}
```

The APT generates `DenoisePluginStreamingStep implements StreamingStep<InputStream, InputStream>`
and `DenoisePluginAction implements Action` (the materialize bridge).

## Compilation: Fusion Pass

### ResolvedStep.FusedPipelineStep

New sealed variant in the `ResolvedStep` hierarchy:

```java
record FusedPipelineStep(
    String name,
    List<FusedStageDescriptor> stages,
    Map<String, Object> decorators
) implements ResolvedStep {}

record FusedStageDescriptor(
    String actionName,
    Map<String, Object> params,
    Map<String, Object> decorators,
    StreamingStepFactory<?, ?> factory
) {}
```

### Fusion Algorithm

The fusion pass receives the resolved step list and `PluginRegistry`:

1. Walk steps sequentially
2. For each `PluginStep`, query `registry.resolve(actionName)` for
   `Definition.streamingType()`
3. If present, start accumulating a candidate chain
4. Check the next step — if it's also a streaming step and its `inputType()` is
   assignable from the current step's `outputType()`, extend the chain
5. Validate no intermediate step's `name()` is referenced by
   `${result.<name>}` in any downstream step outside the chain (referenced
   steps become fusion boundaries). The scan is **syntactic**: a regex for
   `${result.<name>}` patterns applied to both step parameter values AND
   decorator parameter values. Limitations:
   - Nested variable resolution (`${result.${dynamic}.field}`) is not detected
   - JQ expressions referencing step names via `JQEvaluator` are not detected
   - **Conservative strategy**: when uncertain, do not fuse. This is safe
     (preserves correct semantics) but limits optimization. A false negative
     (failing to detect a reference) would cause a correctness bug — so the
     scan errs on the side of breaking fusion
6. Check each step's `decorators()` for chain-compatible decorators (see
   Decorator Classification below)
7. Collapse valid sequences (length ≥ 2) into `FusedPipelineStep`

### Fusion in Both Execution Paths

**StructuralStepEvaluator path**: The evaluator dispatches `FusedPipelineStep`
as a new sealed variant case. At execution time:
1. For each stage: resolve YAML params via `VariableResolver`, call
   `factory.create(resolvedParams, services)` to get a configured
   `StreamingStep` instance
2. Compose `apply()` methods (with inline fusible decorator wrappers)
3. Extract the first step's typed input: read
   `resolvedParams.get(streamingTypeInfo.inputKey())` and cast to the step's
   `inputType()`. This extracts the streaming input from the resolved YAML
   params — e.g., for `StreamingStep<String, InputStream>` with
   `inputKey = "url"`, the evaluator reads `resolvedParams.get("url")` after
   variable resolution (so `"${result.trigger.mediaUrl}"` is already resolved
   to the actual URL string)
4. Pipe through `apply()` chain
5. Wrap final output: `Result.of(Map.of(StreamingStep.OUTPUT_KEY, finalOutput))`

**SWF compiler path**: The `PlaybookCompiler` operates on raw
`Map<String, Object>` YAML — it never sees `ResolvedStep` objects (which live
in `yaml-step-runtime`). Fusion for the SWF path therefore uses a different
mechanism:

The compiler receives an optional `PluginRegistry` reference. When present, it
performs streaming-aware compilation:

1. For each step, look up the action name in the registry and check for
   `Definition.streamingType()`
2. Accumulate consecutive streaming-compatible steps (same type-compatibility
   check as the evaluator path, using `StreamingTypeInfo.inputType()` /
   `outputType()`)
3. Group fusible sequences into a single compound `TaskItem` — a
   `CaseHubCallableTask` that wraps the chain-assembly logic
4. The `CaseHubCallableTaskBuilder` (registered via ServiceLoader) instantiates
   and executes the fused chain at runtime, using the same
   `StreamingStepFactory`-based chain assembly as the evaluator path

When the `PluginRegistry` is absent (e.g., static compilation without runtime
metadata), the compiler passes streaming steps through as individual callable
tasks — no fusion, correct but unoptimized.

**Constraint**: non-serializable types (`InputStream`, `Reader`) are rejected —
the SWF path validates that all types in a fusible chain implement
`Serializable`. `byte[]` is serializable and valid.

## Decorator Classification

Decorators on steps within a fused chain are classified as fusible or
chain-breaking.

### Fusible Decorators

Valid as per-step wrappers within a fused chain. Wrap individual `apply()` calls
inline. **Zero-cost when not present** — no wrapper is inserted if the step has
no decorators.

| Decorator | Inline behavior |
|-----------|----------------|
| `timeout` | Wraps `apply()` with deadline via virtual-thread executor |
| `retry` | Catches exceptions from `apply()`, re-invokes with backoff |
| `delay` | Pauses before `apply()` invocation |
| `transform` | Post-processes individual step output |
| `semaphore` / `mutex` | Acquires before `apply()`, releases in `finally` — structurally identical to `timeout` (acquire/try/finally/release). The `ExecutionScope` reference is available to inline wrappers through the evaluator |

These require **new inline wrapper implementations** operating on the
exception-based error model (exceptions propagate through `Function.andThen()`),
separate from the existing `DecoratorChain` methods which operate on
`DecoratedExecution → Result`.

### Chain-Breaking Decorators

Force a fusion boundary. The step executes independently via the standard
`StepRunner` path. Each decorator's architectural reason for breaking the chain
is documented.

| Decorator | Why it breaks the chain |
|-----------|----------------------|
| `from` | Changes input origin — reads from `OrcChannel`, bypassing the typed pipeline input |
| `background` | Spawns async execution — returns immediately, decouples from the synchronous chain |
| `when` | Conditionally skips execution — returns `Result.of(Map.of())` when false. For heterogeneous-typed steps (`I ≠ O`), skipping breaks the type chain (downstream expects `O`, but only `I` is available). Even for identity-typed steps, the `when` semantics (produce empty result, not pass-through) are incompatible with function composition |
| `on-error` | Fallback output must be typed `O` — the existing `on-error` produces metadata (`Map.of("on-error.caught", message, "on-error.fallback", step)`), which is incompatible with typed streaming output. Defining typed fallback values in YAML for arbitrary `O` types adds complexity with no clear benefit |
| `wait` | Blocks on `OrcSignal` — suspends execution until an external signal fires, incompatible with synchronous function chain |
| `at` | Threshold gate — blocks until a numeric primitive meets a condition. Same suspension semantics as `wait` |
| `forEach` | Changes cardinality — one input produces N executions, incompatible with 1:1 `apply()` model |
| `cancel` | Signal-triggered cancellation — registers a watcher that can interrupt mid-execution. Interruption within a fused chain leaves intermediate state undefined |
| `loop` | Iteration control — re-executes the step N times, producing multiple results |
| `transition` | State machine side effect — fires mid-chain, with ordering implications for state machine consumers that observe the transition before the chain completes |
| `signal` / `publish` | Post-execution side effects with ordering implications — these fire when the step completes, but in a fused chain, the step's result is not yet recorded in the `StepResultStore`. Other steps waiting on the signal would see stale state |

### Chain-Level Decorators

Applied to the entire fused chain via an enclosing block step. If a YAML author
wants to retry the whole pipeline, they wrap it in a block with `retry: 3`.

### Error Model

Within a fused chain, errors propagate as exceptions through `Function.andThen()`
composition. The chain wrapper catches exceptions at the boundary and converts to
`Result.Failure(message, category)` where category is derived from the exception
type. This preserves natural exception propagation for composed functions while
maintaining `Result` semantics for the evaluator, decorator chain, and step
result recording.

**Chain failure diagnostics**: when a step within the fused chain throws, the
exception is wrapped in a `FusedChainException` that records:
- `failedStepName` — the `actionName` of the step that threw
- `failedStepIndex` — zero-based position in the chain
- `chainName` — the `FusedPipelineStep.name()` (outer step name)
- Original exception as the cause

The `Result.Failure` produced at the boundary includes the failing step's
identity in the message (e.g., `"Fused chain 'audio-pipeline' failed at step 2
(denoise): ..."`) and the category. Per-step timing is recorded via lightweight
`System.nanoTime()` instrumentation in the chain wrapper for diagnostics — this
feeds the existing `ActionExecutionEvent` mechanism.

## Merge: Parallel-to-Merge Data Path

When a `ParallelStep` is followed by a merge step:

1. Evaluator executes parallel branches, each producing a `Result`
2. For streaming branches, typed output is extracted from
   `Result.output().get(StreamingStep.OUTPUT_KEY)` — the contract constant
   ensures all streaming steps use the same key
3. Extracted outputs collected into `List<T>`
4. Merge step's `apply(List<T>)` called with collected list
5. Returns `T`, wrapped in `Result` by the evaluator

This is an evaluator-level data path, not a fusion pass concern — the fusion
pass does not fuse across parallel boundaries.

## SWF Durability Constraints

| Type | StructuralStepEvaluator | SWF path |
|------|------------------------|----------|
| `InputStream`, `Reader` | Supported | Rejected (non-serializable) |
| `byte[]` | Supported | Supported (serializable, size-limit enforced) |
| Serializable objects | Supported | Supported |

**`byte[]` size limit on the SWF path**: configurable, default 256 KB. Enforced
at runtime when the chain wrapper produces the final `byte[]` output — if
`byte[].length` exceeds the limit, the chain fails with
`Result.Failure("Fused chain output exceeds SWF size limit: <actual> > <limit> bytes", "SIZE_LIMIT")`.
The limit is configurable via `PlaybookRuntime.Builder.maxSerializedPayloadBytes(int)`.
For the motivating use case (WhatsApp voice notes, up to 16 MB), the chain
should produce a processed result smaller than the raw input (e.g., a
transcription `String`, not the full `byte[]` audio). If large `byte[]` payloads
must flow through the SWF path, use external storage (S3, blob store) with a
reference URI instead of inline serialization.

Non-durable chains (`InputStream`-based) restart from the beginning on failure.
This requires data sources to be replayable (idempotent fetch). Non-replayable
sources (WebSocket streams, one-time webhooks, expiring pre-signed URLs) must
buffer to a replayable store as the first step before entering the fused chain.

## Portability

Streaming steps are `Portability.JAVA` initially. The `Portability` enum already
tracks cross-language compatibility. A TypeScript runtime encountering a streaming
step falls back to the `Action` adapter (via `materialize()`). TypeScript parity
is deferred to a separate issue — TypeScript's structural typing would define an
equivalent interface as a future additive change. Tracked as a GitHub issue to be
filed before implementation begins.

## YAML Surface

### Byte Stream Example

```yaml
steps:
  - media-download:
      url: "${result.trigger.mediaUrl}"
    step: download
    # StreamingStep<String, InputStream>

  - audio-denoise:
      model: gtcrn
    step: denoise
    # StreamingStep<InputStream, InputStream>

  - stt-transcribe:
      language: en
    step: transcript
    # StreamingStep<InputStream, String> — materializes here

  - text-cleanup:
      max-destructiveness: 2
    step: cleaned
    # Regular Action step — Map<String,Object> in/out
```

The compiler fuses download → denoise → transcribe into a single chain.
text-cleanup runs as a standard step on the materialized string output.

### Typed Transform Example

```yaml
steps:
  - sensor-ingest:
      topic: iot-temperature
    step: ingest
    # StreamingStep<Map<String,Object>, SensorEvent> — parses raw map to typed event

  - anomaly-detect:
      threshold: 2.5
    step: detect
    # StreamingStep<SensorEvent, AnnotatedEvent> — per-event anomaly scoring (1:1)

  - alert-format:
      template: high-temp
    step: format
    # StreamingStep<AnnotatedEvent, AlertPayload> — formats for notification

  - notify:
      channel: ops-alerts
    step: send
    # Regular Action step — reads AlertPayload from result map
```

The compiler fuses ingest → detect → format into a single chain. Each
`apply()` call processes one event (1:1 transform). Windowed or batched
processing (N:1, 1:N) is out of scope for `StreamingStep` — the `apply(I) → O`
signature is strictly one-input-one-output. send runs as a standard step.

### Per-Step Decorator Example

```yaml
steps:
  - media-download:
      url: "${result.trigger.mediaUrl}"
    step: download
    timeout: 30s
    # StreamingStep with per-step timeout

  - audio-denoise:
      model: gtcrn
    step: denoise
    # StreamingStep — no decorator, zero overhead

  - stt-transcribe:
      language: en
    step: transcript
    retry: { max: 2, backoff: exponential }
    # StreamingStep with per-step retry
```

The composed function: `timeout(download.apply).andThen(denoise.apply).andThen(retry(transcript.apply))`.
Only download and transcript have decorator wrappers.

### Union Merge Example

```yaml
steps:
  - parallel:
      - left-channel:
          source: left
        step: extract-left
        # StreamingStep<AudioInput, InputStream>
      - right-channel:
          source: right
        step: extract-right
        # StreamingStep<AudioInput, InputStream>

  - stereo-merge:
      strategy: interleave
    step: merge
    # StreamingMerge<InputStream>
```

## Module Structure

All new types live in existing modules:

| Type | Module | Rationale |
|------|--------|-----------|
| `StreamingStep<I,O>` | yaml-plugin-api | Next to Action, Result. Zero-dep. |
| `StreamingMerge<T>` | yaml-plugin-api | Same rationale |
| `StreamingTypeInfo` | yaml-plugin-api | Carried by Definition |
| `StreamingStepFactory<I,O>` | yaml-plugin-api | Used by Definition and fusion |
| `@StreamPlugin` | yaml-plugin-api | Next to @Plugin |
| `FusedPipelineStep` | yaml-step-runtime | ResolvedStep variant |
| `FusedStageDescriptor` | yaml-step-runtime | Fusion pass data |
| Fusion pass | yaml-step-runtime | Pre-evaluation optimization |
| Inline decorator wrappers | yaml-step-runtime | Exception-model decorators |
| `StreamPluginProcessor` | yaml-plugin-processor | APT for @StreamPlugin |
| SWF FusedPipeline handler | playbook-compiler | StepCompiler for fused chains |

No new Maven modules. The `Definition` record in yaml-plugin-api gains
`Optional<StreamingTypeInfo> streamingType()` with default `Optional.empty()`.

## Testing Requirements

Unit tests must demonstrate both data kinds via YAML:

1. **Byte stream pipeline**: download → transform → transcribe chain with
   `InputStream`-typed steps, verifying fused execution and materialization
2. **Typed transform pipeline**: ingest → detect → format chain with typed
   domain objects, verifying type-compatible fusion
3. **Mixed pipeline**: streaming chain followed by standard Action steps,
   verifying materialization boundary
4. **Per-step decorators**: timeout and retry on individual steps within a
   fused chain, verifying zero-cost when absent
5. **Chain-breaking decorators**: verify that `from`, `background`, etc. force
   fusion boundaries with compile-time diagnostics
6. **Union merge**: parallel branches feeding into `StreamingMerge` step
7. **SWF path**: verify serializable types work, non-serializable types are
   rejected at compile time
8. **Variable reference boundary**: verify that `${result.midStep.field}`
   prevents fusion of `midStep`

## References

- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Result.java` — current Result sealed type
- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Action.java` — current Action interface
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java` — decorator wrapping model
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java` — runtime step dispatch
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java` — sealed step hierarchy
- `specs/2026-10-09-durable-playbook-execution-swf-integration.md` — SWF integration spec (#566)
- `datasource-alpha/src/main/java/io/casehub/platform/datasource/alpha/AlphaDataSource.java` — fan-out pattern (no fan-in)
- connectors#188 — real-time inbound channels (motivating use case)
