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
