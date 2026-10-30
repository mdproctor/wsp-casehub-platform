# Streaming Step Type — Pipe-Fusible Data Pipelines

**Issue:** #680
**Date:** 2026-10-30

## Goal

Add a typed streaming step interface to the playbook step engine that enables
pipe-fusible data pipelines. When consecutive steps implement `StreamingStep<I,O>`
with compatible types, the compiler fuses them into a single execution chain —
data flows through via `Function.andThen()` composition at Java speed, without
materializing to `Map<String, Object>` at each step boundary.

Two stream kinds are supported with the same API shape:
- **Byte streams**: continuous binary data (`InputStream`, `byte[]`) for audio,
  images, documents
- **Event streams**: sequences of timestamped objects with properties, processed
  as a typed pipeline

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
    Class<I> inputType();
    Class<O> outputType();
    O apply(I input);

    default Result materialize(Map<String, Object> params, ServiceRegistry services) {
        throw new UnsupportedOperationException("APT-generated override");
    }
}
```

- `inputType()` / `outputType()` — runtime type tokens compensating for generic
  erasure. The fusion pass uses these for type compatibility checks via
  `isAssignableFrom()`
- `apply(I) → O` — the streaming transform. Composed via `Function.andThen()`
  in fused chains
- `materialize()` — bridges streaming to non-streaming execution. The APT
  generates this: extract typed `I` from params, call `apply()`, wrap output in
  `Result.of(Map.of("output", result))`. This is the boundary between the
  streaming and `Action`-compatible worlds

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
   steps become fusion boundaries)
6. Check each step's `decorators()` for chain-compatible decorators (see
   Decorator Classification below)
7. Collapse valid sequences (length ≥ 2) into `FusedPipelineStep`

### Fusion in Both Execution Paths

**StructuralStepEvaluator path**: The evaluator dispatches `FusedPipelineStep`
as a new sealed variant case. At execution time:
1. For each stage: resolve YAML params via `VariableResolver`, call
   `factory.create(resolvedParams, services)` to get a configured
   `StreamingStep` instance
2. Compose `apply()` methods (with inline fusible decorator wrappers per D3)
3. Execute: feed first step's typed input, pipe through `apply()` chain
4. Wrap final output: `Result.of(Map.of("output", finalOutput))`

**SWF compiler path**: The `PlaybookCompiler` handles `FusedPipelineStep` by
emitting a single compound `TaskItem` that wraps the entire chain as one
callable task. The SWF SDK's `CallableTaskBuilder` delegates to the same
chain-assembly logic. **Constraint**: non-serializable types (`InputStream`,
`Reader`) are rejected — the SWF path validates that all types in a fusible
chain implement `Serializable`. `byte[]` is serializable and valid.

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
| `on-error` | Catches exceptions, maps to fallback output |
| `delay` | Pauses before `apply()` invocation |
| `when` | Conditionally skips `apply()` (pass-through) |
| `transform` | Post-processes individual step output |

These require **new inline wrapper implementations** operating on the
exception-based error model (exceptions propagate through `Function.andThen()`),
separate from the existing `DecoratorChain` methods which operate on
`DecoratedExecution → Result`.

### Chain-Breaking Decorators

Force a fusion boundary. The step executes independently via the standard
`StepRunner` path.

| Decorator | Why it breaks the chain |
|-----------|----------------------|
| `from` | Changes input origin (reads from `OrcChannel`) |
| `background` | Spawns async execution |
| `semaphore` / `mutex` | Concurrency control (`OrcSemaphore`) |
| `wait` | Blocks on `OrcSignal` |
| `at` | Threshold gate |
| `forEach` | Changes cardinality |
| `cancel` | Signal-triggered cancellation |
| `loop` | Iteration control |
| `transition` | State machine side effect |
| `signal` / `publish` | Post-execution side effects |

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

## Merge: Parallel-to-Merge Data Path

When a `ParallelStep` is followed by a merge step:

1. Evaluator executes parallel branches, each producing a `Result`
2. For streaming branches, typed output is extracted from
   `Result.output().get("output")`
3. Extracted outputs collected into `List<T>`
4. Merge step's `apply(List<T>)` called with collected list
5. Returns `T`, wrapped in `Result` by the evaluator

This is an evaluator-level data path, not a fusion pass concern — the fusion
pass does not fuse across parallel boundaries.

## SWF Durability Constraints

| Type | StructuralStepEvaluator | SWF path |
|------|------------------------|----------|
| `InputStream`, `Reader` | Supported | Rejected (non-serializable) |
| `byte[]` | Supported | Supported (serializable, size-limit aware) |
| Serializable objects | Supported | Supported |

Non-durable chains (`InputStream`-based) restart from the beginning on failure.
This requires data sources to be replayable (idempotent fetch). Non-replayable
sources (WebSocket streams, one-time webhooks, expiring pre-signed URLs) must
buffer to a replayable store as the first step before entering the fused chain.

## Portability

Streaming steps are `Portability.JAVA` initially. The `Portability` enum already
tracks cross-language compatibility. A TypeScript runtime encountering a streaming
step falls back to the `Action` adapter (via `materialize()`). TypeScript parity
is deferred — TypeScript's structural typing would define an equivalent interface
as a future additive change.

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

### Event Stream Example

```yaml
steps:
  - sensor-ingest:
      topic: iot-temperature
    step: ingest
    # StreamingStep<Map<String,Object>, SensorEvent>

  - anomaly-detect:
      threshold: 2.5
      window: 30s
    step: detect
    # StreamingStep<SensorEvent, AnnotatedEvent>

  - alert-format:
      template: high-temp
    step: format
    # StreamingStep<AnnotatedEvent, AlertPayload>

  - notify:
      channel: ops-alerts
    step: send
    # Regular Action step — reads AlertPayload from result map
```

The compiler fuses ingest → detect → format into a single chain. send runs
as a standard step.

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

Unit tests must demonstrate both stream kinds via YAML:

1. **Byte stream pipeline**: download → transform → transcribe chain with
   `InputStream`-typed steps, verifying fused execution and materialization
2. **Event stream pipeline**: ingest → detect → format chain with typed event
   objects, verifying type-compatible fusion
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
