# Decisions — Issue #680: Streaming Step Type

## D1: StreamingStep interface shape

**Choice:** Standalone `StreamingStep<I,O>` interface with `apply(I) → O`
**Alternatives:**
- StreamingAction<I,O> extends Action — couples streaming and non-streaming contracts, default execute() has to guess how to extract I from Map
- Annotation + reflection — loses type safety and Java-speed goal
**Rationale:** Clean separation of concerns. Steps implement `StreamingStep<I,O>` alongside `Action`. Compiler checks `inputType()`/`outputType()` via `isAssignableFrom()`. `apply()` is composed via `Function.andThen()`. Explicit, type-safe, Java-speed.
**Trade-offs:** Steps that want both streaming and fallback execution must implement two interfaces. The materialize() default method handles the boundary.
**Sources:** yaml-plugin-api Result.java, Action.java — current contracts are Map<String,Object> only
**Exploration:** quick
**Status:** captured

## D2: Fusion detection and chain compilation

**Choice:** Compile-time fusion pass producing `ResolvedStep.FusedPipelineStep`
**Alternatives:**
- Lazy evaluation-time fusion — StructuralStepEvaluator detects on the fly, but SWF path can't use it
- Explicit `pipeline:` YAML block — author declares intent, but requires new syntax and loses auto-detection
**Rationale:** Fits both execution paths (StructuralStepEvaluator and SWF compiler). Fusion pass walks resolved step list after initial resolution, detects consecutive StreamingStep actions with compatible types (outputType assignable to next inputType), collapses into FusedPipelineStep. Standard sealed hierarchy extension pattern.
**Trade-offs:** Type information must be available at resolution time (the step catalog must know which actions implement StreamingStep and what their type parameters are). This means the plugin registry needs to carry streaming type metadata.
**Sources:** ResolvedStep.java (sealed hierarchy), StructuralStepEvaluator.java (dispatch model), PlaybookCompiler step compiler registry
**Exploration:** quick
**Depends on:** D1 (StreamingStep interface provides inputType/outputType)
**Status:** captured

## D3: Decorator application on fused chains

**Choice:** Structural decomposition at YAML-to-executor time
**Alternatives:**
- Merge into chain-level — loses per-step granularity (a timeout on one step becomes chain-wide)
- Break chain at decorator boundaries — defeats fusion when steps have timeouts
**Rationale:** Per-step decorators wrap individual `apply()` calls inline within the composed function. Steps without decorators have zero overhead — no wrapper in the chain. Chain-level decorators come from the first step or surrounding block. The YAML-to-executor pass knows which steps have decorators and builds the composition accordingly.
**Trade-offs:** The composed function is more complex when per-step decorators exist (each decorated step is a mini-wrapper within the chain). But this is compile-time complexity, not runtime cost.
**Sources:** DecoratorChain.java (15 decorator layers, apply() model), StructuralStepEvaluator.java (evaluateInternal decorator wrapping)
**Exploration:** quick
**Depends on:** D2 (fusion pass identifies chains and their per-step decorator sets)
**Status:** captured

## D4: SWF durability constraint for byte streams

**Choice:** Byte-stream (`InputStream`, `byte[]`) fusible chains are rejected by the SWF compilation path; only the StructuralStepEvaluator handles them. Typed object chains with serializable types work in both paths.
**Alternatives:**
- Allow byte streams in SWF with explicit materialization checkpoints — adds complexity, violates the "no materialization in fused chains" goal
- Don't support SWF at all for streaming — loses the "both paths from the start" requirement for serializable types
**Rationale:** You can't serialize/checkpoint a live InputStream for durable execution. The SWF path validates that all types in a fusible chain are serializable. Byte-stream chains are a compile-time error in the SWF path. This is a physical constraint, not a design choice.
**Trade-offs:** Byte-stream processing is non-durable. If a byte-stream pipeline fails mid-way, it restarts from the beginning (no checkpoint/resume). Acceptable for the audio/image use cases.
**Sources:** 2026-10-09-durable-playbook-execution-swf-integration.md spec, user clarification
**Exploration:** quick
**Status:** captured
