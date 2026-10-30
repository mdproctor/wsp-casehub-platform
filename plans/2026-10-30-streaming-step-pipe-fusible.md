# Streaming Step — Pipe-Fusible Data Pipelines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #680 — Streaming step type for playbook engine — pipe-fusible data pipelines

**Goal:** Add `StreamingStep<I,O>` to the playbook step engine so the compiler can fuse type-compatible consecutive steps into a single `Function.andThen()` chain at Java speed.

**Architecture:** New types in yaml-plugin-api (`StreamingStep`, `StreamingMerge`, `@StreamPlugin`, `StreamingTypeInfo`). The `Definition` record gains an 8th component. A new APT in yaml-plugin-processor generates code from `@StreamPlugin`. In yaml-step-runtime, a fusion pass detects consecutive streaming steps and collapses them into `FusedPipelineStep` (new `ResolvedStep` variant). The `StructuralStepEvaluator` dispatches fused chains via composed `Function.andThen()`. The playbook-compiler handles SWF-path fusion with serializable-type validation.

**Tech Stack:** Java 21, yaml-plugin-api (zero-dep), yaml-plugin-processor (Jandex + JavaPoet APT), yaml-step-runtime (Quarkus), playbook-compiler (SWF SDK)

## Global Constraints

- yaml-plugin-api must remain zero-dependency — no Quarkus, no JPA, no casehubio imports. Pure Java only
- yaml-plugin-api must remain J2CL-safe for non-streaming types. StreamingStep is `Portability.JAVA`
- Streaming type tokens must be non-generic concrete classes — no parameterized types
- `InputStream`-based chains are non-durable — rejected by the SWF compilation path
- All new types use `java.util.concurrent` locks — never `synchronized` (virtual thread pinning)
- `StreamingStep.OUTPUT_KEY = "output"` is the contract constant for Result wrapping

---

## Batch 1: API Foundation (yaml-plugin-api)

### Task 1: StreamingStep interface, StreamingMerge, StreamingTypeInfo, @StreamPlugin, Definition change

**Files:**
- Create: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StreamingStep.java`
- Create: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StreamingMerge.java`
- Create: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StreamingTypeInfo.java`
- Create: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StreamingStepFactory.java`
- Create: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StreamPlugin.java`
- Modify: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Definition.java` — add 8th component
- Test: `yaml-plugin-api/src/test/java/io/casehub/yaml/plugin/api/StreamingStepTest.java`
- Test: `yaml-plugin-api/src/test/java/io/casehub/yaml/plugin/api/DefinitionTest.java`

**Interfaces:**
- Consumes: `Result`, `Action`, `ServiceRegistry`, `Portability` — existing types
- Produces: `StreamingStep<I,O>` (interface: `inputType()`, `outputType()`, `apply(I)→O`, `materialize()`), `StreamingMerge<T>` (interface: `mergeType()`, `merge(List<T>)→T`), `StreamingTypeInfo` (record: `inputType`, `outputType`, `inputKey`, `factory`), `StreamingStepFactory<I,O>` (functional interface: `create(Map, ServiceRegistry)→StreamingStep`), `@StreamPlugin(name)` annotation, `Definition` with 8th `Optional<StreamingTypeInfo> streamingType` component

- [ ] **Step 1: Write failing tests for StreamingStep interface**

```java
package io.casehub.yaml.plugin.api;

import org.junit.jupiter.api.Test;
import java.io.InputStream;
import java.io.ByteArrayInputStream;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class StreamingStepTest {

    @Test
    void typeTokensReflectGenericParameters() {
        StreamingStep<String, InputStream> step = new StreamingStep<>() {
            @Override public Class<String> inputType() { return String.class; }
            @Override public Class<InputStream> outputType() { return InputStream.class; }
            @Override public InputStream apply(String input) {
                return new ByteArrayInputStream(input.getBytes());
            }
        };
        assertEquals(String.class, step.inputType());
        assertEquals(InputStream.class, step.outputType());
    }

    @Test
    void applyTransformsInput() {
        StreamingStep<String, Integer> step = new StreamingStep<>() {
            @Override public Class<String> inputType() { return String.class; }
            @Override public Class<Integer> outputType() { return Integer.class; }
            @Override public Integer apply(String input) { return input.length(); }
        };
        assertEquals(5, step.apply("hello"));
    }

    @Test
    void materializeDefaultThrowsForHandWrittenImpls() {
        StreamingStep<String, String> step = new StreamingStep<>() {
            @Override public Class<String> inputType() { return String.class; }
            @Override public Class<String> outputType() { return String.class; }
            @Override public String apply(String input) { return input.toUpperCase(); }
        };
        assertThrows(UnsupportedOperationException.class,
            () -> step.materialize(Map.of(), new MapServiceRegistry()));
    }

    @Test
    void outputKeyConstantIsOutput() {
        assertEquals("output", StreamingStep.OUTPUT_KEY);
    }

    @Test
    void typeCompatibilityCheckViaIsAssignableFrom() {
        StreamingStep<InputStream, InputStream> step1 = new StreamingStep<>() {
            @Override public Class<InputStream> inputType() { return InputStream.class; }
            @Override public Class<InputStream> outputType() { return InputStream.class; }
            @Override public InputStream apply(InputStream in) { return in; }
        };
        StreamingStep<InputStream, String> step2 = new StreamingStep<>() {
            @Override public Class<InputStream> inputType() { return InputStream.class; }
            @Override public Class<String> outputType() { return String.class; }
            @Override public String apply(InputStream in) { return "transcribed"; }
        };
        assertTrue(step2.inputType().isAssignableFrom(step1.outputType()),
            "step2 should accept step1's output type");
    }
}
```

- [ ] **Step 2: Write failing tests for StreamingMerge**

```java
package io.casehub.yaml.plugin.api;

import org.junit.jupiter.api.Test;
import java.io.InputStream;
import java.io.SequenceInputStream;
import java.io.ByteArrayInputStream;
import java.util.Collections;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class StreamingMergeTest {

    @Test
    void mergeTypeDeclaresMergedType() {
        StreamingMerge<InputStream> merge = new StreamingMerge<>() {
            @Override public Class<InputStream> mergeType() { return InputStream.class; }
            @Override public InputStream merge(List<InputStream> inputs) {
                return new SequenceInputStream(Collections.enumeration(inputs));
            }
        };
        assertEquals(InputStream.class, merge.mergeType());
    }

    @Test
    void mergeAcceptsMultipleInputs() {
        StreamingMerge<String> merge = new StreamingMerge<>() {
            @Override public Class<String> mergeType() { return String.class; }
            @Override public String merge(List<String> inputs) {
                return String.join("|", inputs);
            }
        };
        assertEquals("a|b|c", merge.merge(List.of("a", "b", "c")));
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-plugin-api -Dtest="StreamingStepTest,StreamingMergeTest" -DfailIfNoTests=false`
Expected: compilation failure (types don't exist yet)

- [ ] **Step 4: Create StreamingStep interface**

```java
package io.casehub.yaml.plugin.api;

import java.util.Map;

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

- [ ] **Step 5: Create StreamingMerge interface**

```java
package io.casehub.yaml.plugin.api;

import java.util.List;

public interface StreamingMerge<T> {

    Class<T> mergeType();

    T merge(List<T> inputs);
}
```

- [ ] **Step 6: Create StreamingStepFactory functional interface**

```java
package io.casehub.yaml.plugin.api;

import java.util.Map;

@FunctionalInterface
public interface StreamingStepFactory<I, O> {

    StreamingStep<I, O> create(Map<String, Object> resolvedParams, ServiceRegistry services);
}
```

- [ ] **Step 7: Create StreamingTypeInfo record**

```java
package io.casehub.yaml.plugin.api;

import java.util.Objects;

public record StreamingTypeInfo(
    Class<?> inputType,
    Class<?> outputType,
    String inputKey,
    StreamingStepFactory<?, ?> factory
) {
    public StreamingTypeInfo {
        Objects.requireNonNull(inputType, "inputType");
        Objects.requireNonNull(outputType, "outputType");
        Objects.requireNonNull(inputKey, "inputKey");
        Objects.requireNonNull(factory, "factory");
    }
}
```

- [ ] **Step 8: Create @StreamPlugin annotation**

```java
package io.casehub.yaml.plugin.api;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
public @interface StreamPlugin {
    String name();
}
```

- [ ] **Step 9: Write failing test for Definition 8th component**

```java
package io.casehub.yaml.plugin.api;

import org.junit.jupiter.api.Test;
import java.util.Map;
import java.util.Optional;
import static org.junit.jupiter.api.Assertions.*;

class DefinitionStreamingTest {

    @Test
    void definitionWithoutStreamingTypeDefaultsToEmpty() {
        Definition def = new Definition("test", "desc",
            Map.of(), Map.of(), Portability.JAVA,
            (params, services) -> Result.of(Map.of()), "steps");
        assertEquals(Optional.empty(), def.streamingType());
    }

    @Test
    void definitionWithStreamingTypeCarriesMetadata() {
        StreamingTypeInfo info = new StreamingTypeInfo(
            String.class, Integer.class, "input",
            (params, services) -> new StreamingStep<>() {
                @Override public Class<String> inputType() { return String.class; }
                @Override public Class<Integer> outputType() { return Integer.class; }
                @Override public Integer apply(String s) { return s.length(); }
            });
        Definition def = Definition.builder("test", "desc")
            .execute((params, services) -> Result.of(Map.of()))
            .streamingType(info)
            .build();
        assertTrue(def.streamingType().isPresent());
        assertEquals(String.class, def.streamingType().get().inputType());
        assertEquals(Integer.class, def.streamingType().get().outputType());
        assertEquals("input", def.streamingType().get().inputKey());
    }

    @Test
    void builderDefaultsStreamingTypeToEmpty() {
        Definition def = Definition.builder("test", "desc")
            .execute((params, services) -> Result.of(Map.of()))
            .build();
        assertEquals(Optional.empty(), def.streamingType());
    }
}
```

- [ ] **Step 10: Modify Definition record — add 8th component**

Modify `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Definition.java`:
- Add `Optional<StreamingTypeInfo> streamingType` as 8th record component
- Add secondary constructor without `streamingType` (defaults to `Optional.empty()`)
- Add `streamingType(StreamingTypeInfo)` to Builder, defaulting to `Optional.empty()`
- Update `build()` to include `streamingType`

Use `ide_replace_member` for the record definition. Update `Builder` class with `ide_edit_member`.

- [ ] **Step 11: Fix all callers of Definition canonical constructor**

Search for all `new Definition(` calls that now need the 8th parameter. Key callers:
- `yaml-plugin-processor/...RegistryEmitter.java` — APT-generated code
- `yaml-step-runtime/...catalog/PluginScanner.java` — runtime scanner
- `yaml-step-runtime/...catalog/Walker.java` — step resolution
- Test files in yaml-plugin-api, yaml-step-runtime

For callers using the Builder, no change needed (Builder defaults to `Optional.empty()`).
For callers using the canonical constructor, switch to the 7-arg secondary constructor.

Use `ide_find_references` on the `Definition` constructor to find all call sites.

- [ ] **Step 12: Run tests to verify all pass**

Run: `mvn --batch-mode test -pl yaml-plugin-api`
Expected: all tests PASS

- [ ] **Step 13: Compile entire project to verify no breakage**

Run: `mvn --batch-mode compile -DskipTests`
Expected: BUILD SUCCESS (Definition constructor migration complete)

- [ ] **Step 14: Commit**

```bash
git add yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StreamingStep.java \
       yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StreamingMerge.java \
       yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StreamingStepFactory.java \
       yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StreamingTypeInfo.java \
       yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StreamPlugin.java \
       yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Definition.java \
       yaml-plugin-api/src/test/java/io/casehub/yaml/plugin/api/StreamingStepTest.java \
       yaml-plugin-api/src/test/java/io/casehub/yaml/plugin/api/StreamingMergeTest.java \
       yaml-plugin-api/src/test/java/io/casehub/yaml/plugin/api/DefinitionStreamingTest.java
git commit -m "feat(api): add StreamingStep, StreamingMerge, @StreamPlugin and Definition streaming support

Refs #680"
```

---

## Batch 2: APT Code Generation (yaml-plugin-processor)

### Task 2: @StreamPlugin annotation processor

**Files:**
- Create: `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/StreamPluginProcessor.java`
- Create: `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/StreamBinderEmitter.java`
- Modify: `yaml-plugin-processor/src/main/resources/META-INF/services/javax.annotation.processing.Processor` — add StreamPluginProcessor
- Test: `yaml-plugin-processor/src/test/java/io/casehub/yaml/plugin/processor/StreamPluginProcessorTest.java`

**Interfaces:**
- Consumes: `StreamingStep<I,O>`, `StreamingStepFactory<I,O>`, `StreamingTypeInfo`, `@StreamPlugin`, `@Execute`, `Result`, `Action`, `ServiceRegistry`, `Definition`, `Portability` from yaml-plugin-api
- Produces: APT that generates from `@StreamPlugin` records: (1) `<Name>StreamingStep implements StreamingStep<I,O>` with `apply()`, `materialize()`, type tokens; (2) `<Name>Action implements Action` delegating through `materialize()`; (3) JSON manifest `META-INF/yaml-plugins/<name>.json` with streaming type metadata

- [ ] **Step 1: Write failing test for StreamPluginProcessor**

Create a test that compiles a `@StreamPlugin` record and verifies the generated source files exist:

```java
package io.casehub.yaml.plugin.processor;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import javax.tools.*;
import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class StreamPluginProcessorTest {

    @TempDir Path tempDir;

    @Test
    void generatesStreamingStepAndActionFromStreamPlugin() throws Exception {
        String source = """
            package test;
            import io.casehub.yaml.plugin.api.*;
            import java.io.InputStream;
            import java.io.ByteArrayInputStream;

            @StreamPlugin(name = "uppercase")
            public record UppercasePlugin() {
                @Execute
                public String apply(String input) {
                    return input.toUpperCase();
                }
            }
            """;

        Path sourceFile = tempDir.resolve("test/UppercasePlugin.java");
        Files.createDirectories(sourceFile.getParent());
        Files.writeString(sourceFile, source);

        JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
        try (StandardJavaFileManager fm = compiler.getStandardFileManager(null, null, null)) {
            fm.setLocation(StandardLocation.CLASS_OUTPUT, List.of(tempDir.toFile()));
            fm.setLocation(StandardLocation.SOURCE_OUTPUT, List.of(tempDir.toFile()));

            Iterable<? extends JavaFileObject> units = fm.getJavaFileObjects(sourceFile.toFile());
            JavaCompiler.CompilationTask task = compiler.getTask(null, fm, null,
                List.of("-proc:only", "-processor",
                    "io.casehub.yaml.plugin.processor.StreamPluginProcessor"),
                null, units);
            assertTrue(task.call(), "Compilation should succeed");
        }

        assertTrue(Files.exists(tempDir.resolve("test/UppercasePluginStreamingStep.java")),
            "Should generate StreamingStep implementation");
        assertTrue(Files.exists(tempDir.resolve("test/UppercasePluginAction.java")),
            "Should generate Action adapter");
    }

    @Test
    void generatedStreamingStepHasCorrectTypeTokens() throws Exception {
        // Compile @StreamPlugin with InputStream input, String output
        // Verify generated code has inputType()=InputStream.class, outputType()=String.class
        String source = """
            package test;
            import io.casehub.yaml.plugin.api.*;
            import java.io.InputStream;

            @StreamPlugin(name = "transcribe")
            public record TranscribePlugin(@Optional String language) {
                @Execute
                public String apply(InputStream audio) {
                    return "transcribed";
                }
            }
            """;

        Path sourceFile = tempDir.resolve("test/TranscribePlugin.java");
        Files.createDirectories(sourceFile.getParent());
        Files.writeString(sourceFile, source);

        JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
        try (StandardJavaFileManager fm = compiler.getStandardFileManager(null, null, null)) {
            fm.setLocation(StandardLocation.CLASS_OUTPUT, List.of(tempDir.toFile()));
            fm.setLocation(StandardLocation.SOURCE_OUTPUT, List.of(tempDir.toFile()));

            Iterable<? extends JavaFileObject> units = fm.getJavaFileObjects(sourceFile.toFile());
            JavaCompiler.CompilationTask task = compiler.getTask(null, fm, null,
                List.of("-proc:only", "-processor",
                    "io.casehub.yaml.plugin.processor.StreamPluginProcessor"),
                null, units);
            assertTrue(task.call());
        }

        String generated = Files.readString(
            tempDir.resolve("test/TranscribePluginStreamingStep.java"));
        assertTrue(generated.contains("InputStream.class"),
            "inputType should be InputStream.class");
        assertTrue(generated.contains("String.class"),
            "outputType should be String.class");
        assertTrue(generated.contains("implements StreamingStep<InputStream, String>"));
    }

    @Test
    void rejectsVoidReturnType() throws Exception {
        String source = """
            package test;
            import io.casehub.yaml.plugin.api.*;

            @StreamPlugin(name = "bad")
            public record BadPlugin() {
                @Execute
                public void apply(String input) {}
            }
            """;

        Path sourceFile = tempDir.resolve("test/BadPlugin.java");
        Files.createDirectories(sourceFile.getParent());
        Files.writeString(sourceFile, source);

        JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
        DiagnosticCollector<JavaFileObject> diagnostics = new DiagnosticCollector<>();
        try (StandardJavaFileManager fm = compiler.getStandardFileManager(null, null, null)) {
            fm.setLocation(StandardLocation.CLASS_OUTPUT, List.of(tempDir.toFile()));
            fm.setLocation(StandardLocation.SOURCE_OUTPUT, List.of(tempDir.toFile()));

            Iterable<? extends JavaFileObject> units = fm.getJavaFileObjects(sourceFile.toFile());
            JavaCompiler.CompilationTask task = compiler.getTask(null, fm, diagnostics,
                List.of("-proc:only", "-processor",
                    "io.casehub.yaml.plugin.processor.StreamPluginProcessor"),
                null, units);
            task.call();
        }

        boolean hasError = diagnostics.getDiagnostics().stream()
            .anyMatch(d -> d.getKind() == Diagnostic.Kind.ERROR
                && d.getMessage(null).contains("void"));
        assertTrue(hasError, "Should reject void return type");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-plugin-processor -Dtest="StreamPluginProcessorTest" -DfailIfNoTests=false`
Expected: compilation failure (StreamPluginProcessor doesn't exist)

- [ ] **Step 3: Implement StreamPluginProcessor**

Create `StreamPluginProcessor.java` — an `AbstractProcessor` that:
1. Reads `@StreamPlugin` annotation on records
2. Finds the `@Execute` method
3. Validates: at least 1 param, non-void return, non-Result return, first param is non-generic concrete class
4. Infers `I` (first param type) and `O` (return type), `inputKey` (first param name, kebab-cased)
5. Delegates to `StreamBinderEmitter` for code generation

Model the structure on the existing `StepPluginProcessor.java` at `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/StepPluginProcessor.java`.

- [ ] **Step 4: Implement StreamBinderEmitter**

Create `StreamBinderEmitter.java` that generates two source files:

**`<Name>StreamingStep.java`:**
```java
public final class <Name>StreamingStep implements StreamingStep<I, O> {
    private final <RecordFields>;
    private final <ServiceDeps>;

    public <Name>StreamingStep(<RecordFields>, <ServiceDeps>) { ... }

    @Override public Class<I> inputType() { return I.class; }
    @Override public Class<O> outputType() { return O.class; }
    @Override public O apply(I input) { return new <Name>(<recordFields>).apply(input, <serviceDeps>); }

    @Override public Result materialize(Map<String, Object> params, ServiceRegistry services) {
        I input = (I) params.get("<inputKey>");
        <resolve services>
        O output = apply(input);
        return Result.of(Map.of(OUTPUT_KEY, output));
    }
}
```

**`<Name>Action.java`:**
```java
public final class <Name>Action implements Action {
    @Override public Result execute(Map<String, Object> params, ServiceRegistry services) {
        return new <Name>StreamingStep(<extractRecordFields>, <lookupServices>).materialize(params, services);
    }
}
```

Follow the existing `BinderEmitter.java` pattern for kebab-case param extraction and service injection.

- [ ] **Step 5: Generate registry manifest with StreamingTypeInfo**

Extend or create a manifest emitter that writes `META-INF/yaml-plugins/<name>.json` including:
```json
{
  "name": "<name>",
  "portability": "JAVA",
  "capability": "steps",
  "streaming": {
    "inputType": "<fully.qualified.I>",
    "outputType": "<fully.qualified.O>",
    "inputKey": "<kebab-key>"
  }
}
```

The `PluginScanner` will read this to populate `StreamingTypeInfo` on the `Definition`.

- [ ] **Step 6: Register processor in META-INF/services**

Modify `yaml-plugin-processor/src/main/resources/META-INF/services/javax.annotation.processing.Processor`:
Add `io.casehub.yaml.plugin.processor.StreamPluginProcessor` on a new line.

- [ ] **Step 7: Run tests to verify all pass**

Run: `mvn --batch-mode test -pl yaml-plugin-processor`
Expected: all tests PASS

- [ ] **Step 8: Commit**

```bash
git add yaml-plugin-processor/
git commit -m "feat(apt): @StreamPlugin annotation processor generates StreamingStep + Action

Refs #680"
```

---

## Batch 3: Fusion Engine (yaml-step-runtime)

### Task 3: FusedPipelineStep sealed variant + FusedChainException + inline decorator wrappers

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java` — add 13th variant
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/FusedStageDescriptor.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/FusedChainException.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/InlineDecoratorWrappers.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/InlineDecoratorWrappersTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/FusedChainExceptionTest.java`

**Interfaces:**
- Consumes: `ResolvedStep` (sealed hierarchy), `StreamingStepFactory`, `StreamingStep`, `Result` from yaml-plugin-api
- Produces: `ResolvedStep.FusedPipelineStep` (record: name, List<FusedStageDescriptor>, decorators), `FusedStageDescriptor` (record: stepName, actionName, params, decorators, factory), `FusedChainException` (extends RuntimeException: failedStepName, failedActionName, failedStepIndex, chainName), `InlineDecoratorWrappers` (static utility: timeout, retry, delay, semaphore wrapping for apply() calls)

- [ ] **Step 1: Write failing tests for FusedPipelineStep**

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.step.catalog.ResolvedStep;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class FusedPipelineStepTest {

    @Test
    void fusedPipelineStepIsResolvedStep() {
        var descriptor = new FusedStageDescriptor(
            "denoise", "audio-denoise", Map.of(), Map.of(),
            (params, services) -> null);
        var fused = new ResolvedStep.FusedPipelineStep(
            "transcript", List.of(descriptor), Map.of());
        assertInstanceOf(ResolvedStep.class, fused);
        assertEquals("transcript", fused.name());
        assertEquals(1, fused.stages().size());
    }
}
```

- [ ] **Step 2: Write failing tests for FusedChainException**

```java
package io.casehub.yaml.step.eval;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class FusedChainExceptionTest {

    @Test
    void capturesChainDiagnostics() {
        var cause = new RuntimeException("denoise failed");
        var ex = new FusedChainException("denoise", "audio-denoise", 1, "transcript", cause);
        assertEquals("denoise", ex.failedStepName());
        assertEquals("audio-denoise", ex.failedActionName());
        assertEquals(1, ex.failedStepIndex());
        assertEquals("transcript", ex.chainName());
        assertSame(cause, ex.getCause());
        assertTrue(ex.getMessage().contains("denoise"));
        assertTrue(ex.getMessage().contains("audio-denoise"));
    }
}
```

- [ ] **Step 3: Write failing tests for inline decorator wrappers**

```java
package io.casehub.yaml.step.eval;

import org.junit.jupiter.api.Test;
import java.time.Duration;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Function;
import static org.junit.jupiter.api.Assertions.*;

class InlineDecoratorWrappersTest {

    @Test
    void timeoutPassesThroughWhenFast() {
        Function<String, String> wrapped = InlineDecoratorWrappers.withTimeout(
            s -> s.toUpperCase(), Duration.ofSeconds(5));
        assertEquals("HELLO", wrapped.apply("hello"));
    }

    @Test
    void timeoutThrowsWhenSlow() {
        Function<String, String> wrapped = InlineDecoratorWrappers.withTimeout(
            s -> { Thread.sleep(5000); return s; }, Duration.ofMillis(50));
        assertThrows(FusedChainException.class, () -> wrapped.apply("hello"));
    }

    @Test
    void retryRetriesOnException() {
        AtomicInteger attempts = new AtomicInteger();
        Function<String, String> wrapped = InlineDecoratorWrappers.withRetry(
            s -> {
                if (attempts.incrementAndGet() < 3) throw new RuntimeException("fail");
                return s.toUpperCase();
            }, 3, Duration.ofMillis(10), "fixed");
        assertEquals("HELLO", wrapped.apply("hello"));
        assertEquals(3, attempts.get());
    }

    @Test
    void retryExhaustsAndThrows() {
        Function<String, String> wrapped = InlineDecoratorWrappers.withRetry(
            s -> { throw new RuntimeException("always fails"); },
            2, Duration.ofMillis(10), "fixed");
        assertThrows(RuntimeException.class, () -> wrapped.apply("hello"));
    }

    @Test
    void delayPausesBeforeExecution() {
        long start = System.nanoTime();
        Function<String, String> wrapped = InlineDecoratorWrappers.withDelay(
            s -> s.toUpperCase(), Duration.ofMillis(100));
        wrapped.apply("hello");
        long elapsed = (System.nanoTime() - start) / 1_000_000;
        assertTrue(elapsed >= 90, "Should delay at least 90ms, was " + elapsed);
    }

    @Test
    void noDecoratorHasZeroCost() {
        Function<String, String> identity = s -> s.toUpperCase();
        // No wrapper — direct function, no wrapping overhead
        assertEquals("HELLO", identity.apply("hello"));
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="FusedPipelineStepTest,FusedChainExceptionTest,InlineDecoratorWrappersTest" -DfailIfNoTests=false`
Expected: compilation failure

- [ ] **Step 5: Add FusedPipelineStep to ResolvedStep sealed hierarchy**

Modify `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java`:
- Add `ResolvedStep.FusedPipelineStep` to the `permits` clause
- Add the record inside the sealed interface

```java
record FusedPipelineStep(
    String name,
    List<FusedStageDescriptor> stages,
    Map<String, Object> decorators
) implements ResolvedStep {
    public FusedPipelineStep {
        stages     = List.copyOf(stages);
        decorators = Map.copyOf(decorators);
    }
}
```

Use `ide_edit_member` to add the permits entry and the record.

- [ ] **Step 6: Create FusedStageDescriptor record**

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.plugin.api.StreamingStepFactory;
import java.util.Map;

public record FusedStageDescriptor(
    String stepName,
    String actionName,
    Map<String, Object> params,
    Map<String, Object> decorators,
    StreamingStepFactory<?, ?> factory
) {
    public FusedStageDescriptor {
        params     = Map.copyOf(params);
        decorators = Map.copyOf(decorators);
    }
}
```

- [ ] **Step 7: Create FusedChainException**

```java
package io.casehub.yaml.step.eval;

public final class FusedChainException extends RuntimeException {

    private final String failedStepName;
    private final String failedActionName;
    private final int failedStepIndex;
    private final String chainName;

    public FusedChainException(String failedStepName, String failedActionName,
                               int failedStepIndex, String chainName, Throwable cause) {
        super("Fused chain '" + chainName + "' failed at step " + failedStepIndex
              + " (" + failedStepName + " / " + failedActionName + "): " + cause.getMessage(),
              cause);
        this.failedStepName   = failedStepName;
        this.failedActionName = failedActionName;
        this.failedStepIndex  = failedStepIndex;
        this.chainName        = chainName;
    }

    public String failedStepName()   { return failedStepName; }
    public String failedActionName() { return failedActionName; }
    public int failedStepIndex()     { return failedStepIndex; }
    public String chainName()        { return chainName; }
}
```

- [ ] **Step 8: Create InlineDecoratorWrappers utility**

```java
package io.casehub.yaml.step.eval;

import java.time.Duration;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.locks.LockSupport;
import java.util.function.Function;

public final class InlineDecoratorWrappers {

    private InlineDecoratorWrappers() {}

    public static <I, O> Function<I, O> withTimeout(Function<I, O> inner, Duration timeout) {
        return input -> {
            try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
                Future<O> future = executor.submit(() -> inner.apply(input));
                return future.get(timeout.toMillis(), TimeUnit.MILLISECONDS);
            } catch (TimeoutException e) {
                throw new RuntimeException("Timeout after " + timeout, e);
            } catch (java.util.concurrent.ExecutionException e) {
                if (e.getCause() instanceof RuntimeException re) throw re;
                throw new RuntimeException(e.getCause());
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new RuntimeException("Interrupted", e);
            }
        };
    }

    public static <I, O> Function<I, O> withRetry(Function<I, O> inner,
            int maxRetries, Duration delay, String backoff) {
        return input -> {
            RuntimeException last = null;
            for (int attempt = 0; attempt <= maxRetries; attempt++) {
                try {
                    return inner.apply(input);
                } catch (RuntimeException e) {
                    last = e;
                    if (attempt < maxRetries) {
                        long delayMs = computeDelay(delay.toMillis(), backoff, attempt);
                        LockSupport.parkNanos(delayMs * 1_000_000);
                    }
                }
            }
            throw last;
        };
    }

    public static <I, O> Function<I, O> withDelay(Function<I, O> inner, Duration delay) {
        return input -> {
            LockSupport.parkNanos(delay.toNanos());
            return inner.apply(input);
        };
    }

    private static long computeDelay(long baseMs, String backoff, int attempt) {
        return switch (backoff) {
            case "exponential" -> baseMs * (1L << attempt);
            case "exponential-with-jitter" -> {
                long exp = baseMs * (1L << attempt);
                yield exp + (long) (Math.random() * exp);
            }
            default -> baseMs;
        };
    }
}
```

- [ ] **Step 9: Run tests to verify all pass**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="FusedPipelineStepTest,FusedChainExceptionTest,InlineDecoratorWrappersTest"`
Expected: all tests PASS

- [ ] **Step 10: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java \
       yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/FusedStageDescriptor.java \
       yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/FusedChainException.java \
       yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/InlineDecoratorWrappers.java \
       yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/FusedPipelineStepTest.java \
       yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/FusedChainExceptionTest.java \
       yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/InlineDecoratorWrappersTest.java
git commit -m "feat(runtime): FusedPipelineStep, FusedChainException, inline decorator wrappers

Refs #680"
```

### Task 4: Fusion pass algorithm + StructuralStepEvaluator dispatch + merge data path

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/FusionPass.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java` — add FusedPipelineStep case to `dispatchStep()`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java` — invoke fusion pass after step resolution
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/FusionPassTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/FusedChainEvaluationTest.java`

**Interfaces:**
- Consumes: `ResolvedStep` (all variants), `FusedPipelineStep`, `FusedStageDescriptor`, `PluginRegistry`, `Definition`, `StreamingTypeInfo`, `StreamingStep`, `StreamingStepFactory`, `InlineDecoratorWrappers`, `FusedChainException`, `StreamingMerge` from earlier tasks
- Produces: `FusionPass.fuse(List<ResolvedStep>, PluginRegistry) → List<ResolvedStep>` (replaces fusible sequences with `FusedPipelineStep`), evaluator dispatch for `FusedPipelineStep` (chain assembly, execution, resource cleanup), merge data path (parallel-to-merge evaluation)

- [ ] **Step 1: Write failing tests for FusionPass**

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.plugin.api.*;
import io.casehub.yaml.step.catalog.ResolvedStep;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import static org.junit.jupiter.api.Assertions.*;

class FusionPassTest {

    private Definition streamingDef(String name, Class<?> in, Class<?> out) {
        return Definition.builder(name, name)
            .execute((p, s) -> Result.of(Map.of()))
            .streamingType(new StreamingTypeInfo(in, out, "input",
                (params, svc) -> new StreamingStep<>() {
                    @Override public Class inputType() { return in; }
                    @Override public Class outputType() { return out; }
                    @Override public Object apply(Object input) { return input; }
                }))
            .build();
    }

    private Definition nonStreamingDef(String name) {
        return Definition.builder(name, name)
            .execute((p, s) -> Result.of(Map.of()))
            .build();
    }

    @Test
    void fusesConsecutiveCompatibleStreamingSteps() {
        var registry = new MapPluginRegistry();
        registry.register(streamingDef("download", String.class, byte[].class));
        registry.register(streamingDef("denoise", byte[].class, byte[].class));
        registry.register(streamingDef("transcribe", byte[].class, String.class));

        List<ResolvedStep> steps = List.of(
            new ResolvedStep.PluginStep("download", "download", Map.of(), Map.of()),
            new ResolvedStep.PluginStep("denoise", "denoise", Map.of(), Map.of()),
            new ResolvedStep.PluginStep("transcribe", "transcribe", Map.of(), Map.of()));

        List<ResolvedStep> fused = FusionPass.fuse(steps, registry);
        assertEquals(1, fused.size());
        assertInstanceOf(ResolvedStep.FusedPipelineStep.class, fused.get(0));
        var pipeline = (ResolvedStep.FusedPipelineStep) fused.get(0);
        assertEquals(3, pipeline.stages().size());
        assertEquals("transcribe", pipeline.name());
    }

    @Test
    void doesNotFuseIncompatibleTypes() {
        var registry = new MapPluginRegistry();
        registry.register(streamingDef("step1", String.class, Integer.class));
        registry.register(streamingDef("step2", String.class, String.class));

        List<ResolvedStep> steps = List.of(
            new ResolvedStep.PluginStep("s1", "step1", Map.of(), Map.of()),
            new ResolvedStep.PluginStep("s2", "step2", Map.of(), Map.of()));

        List<ResolvedStep> fused = FusionPass.fuse(steps, registry);
        assertEquals(2, fused.size());
        assertInstanceOf(ResolvedStep.PluginStep.class, fused.get(0));
        assertInstanceOf(ResolvedStep.PluginStep.class, fused.get(1));
    }

    @Test
    void nonStreamingStepBreaksChain() {
        var registry = new MapPluginRegistry();
        registry.register(streamingDef("step1", String.class, String.class));
        registry.register(nonStreamingDef("step2"));
        registry.register(streamingDef("step3", String.class, String.class));

        List<ResolvedStep> steps = List.of(
            new ResolvedStep.PluginStep("s1", "step1", Map.of(), Map.of()),
            new ResolvedStep.PluginStep("s2", "step2", Map.of(), Map.of()),
            new ResolvedStep.PluginStep("s3", "step3", Map.of(), Map.of()));

        List<ResolvedStep> fused = FusionPass.fuse(steps, registry);
        assertEquals(3, fused.size());
    }

    @Test
    void chainBreakingDecoratorPreventsFusion() {
        var registry = new MapPluginRegistry();
        registry.register(streamingDef("step1", String.class, String.class));
        registry.register(streamingDef("step2", String.class, String.class));

        List<ResolvedStep> steps = List.of(
            new ResolvedStep.PluginStep("s1", "step1", Map.of(), Map.of()),
            new ResolvedStep.PluginStep("s2", "step2", Map.of(),
                Map.of("background", true)));

        List<ResolvedStep> fused = FusionPass.fuse(steps, registry);
        assertEquals(2, fused.size());
    }

    @Test
    void variableReferenceBreaksChainAtReferencedStep() {
        var registry = new MapPluginRegistry();
        registry.register(streamingDef("step1", String.class, String.class));
        registry.register(streamingDef("step2", String.class, String.class));
        registry.register(streamingDef("step3", String.class, String.class));

        List<ResolvedStep> steps = List.of(
            new ResolvedStep.PluginStep("s1", "step1", Map.of(), Map.of()),
            new ResolvedStep.PluginStep("s2", "step2", Map.of(), Map.of()),
            new ResolvedStep.PluginStep("s3", "step3",
                Map.of("ref", "${result.s1.output}"), Map.of()));

        // s1 is referenced by s3, so s1 cannot be fused (it's not the last step)
        List<ResolvedStep> fused = FusionPass.fuse(steps, registry);
        // s1 standalone, s2+s3 fused (s2 is not referenced)
        assertEquals(2, fused.size());
    }

    @Test
    void singleStreamingStepIsNotFused() {
        var registry = new MapPluginRegistry();
        registry.register(streamingDef("step1", String.class, String.class));

        List<ResolvedStep> steps = List.of(
            new ResolvedStep.PluginStep("s1", "step1", Map.of(), Map.of()));

        List<ResolvedStep> fused = FusionPass.fuse(steps, registry);
        assertEquals(1, fused.size());
        assertInstanceOf(ResolvedStep.PluginStep.class, fused.get(0));
    }

    @Test
    void fusibleDecoratorsDoNotBreakChain() {
        var registry = new MapPluginRegistry();
        registry.register(streamingDef("step1", String.class, String.class));
        registry.register(streamingDef("step2", String.class, String.class));

        List<ResolvedStep> steps = List.of(
            new ResolvedStep.PluginStep("s1", "step1", Map.of(),
                Map.of("timeout", "30s")),
            new ResolvedStep.PluginStep("s2", "step2", Map.of(),
                Map.of("retry", Map.of("max", 3))));

        List<ResolvedStep> fused = FusionPass.fuse(steps, registry);
        assertEquals(1, fused.size());
        assertInstanceOf(ResolvedStep.FusedPipelineStep.class, fused.get(0));
    }
}
```

- [ ] **Step 2: Write failing tests for fused chain evaluation**

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.condition.ConditionEvaluator;
import io.casehub.yaml.plugin.api.*;
import io.casehub.yaml.step.catalog.ResolvedStep;
import org.junit.jupiter.api.Test;
import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.util.List;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class FusedChainEvaluationTest {

    private final ConditionEvaluator conditionEvaluator = expr -> Boolean.parseBoolean(expr);

    @Test
    void evaluatesTypedTransformChain() {
        StreamingStepFactory<String, Integer> factory1 = (p, s) -> new StreamingStep<>() {
            @Override public Class<String> inputType() { return String.class; }
            @Override public Class<Integer> outputType() { return Integer.class; }
            @Override public Integer apply(String input) { return input.length(); }
        };
        StreamingStepFactory<Integer, String> factory2 = (p, s) -> new StreamingStep<>() {
            @Override public Class<Integer> inputType() { return Integer.class; }
            @Override public Class<String> outputType() { return String.class; }
            @Override public String apply(Integer input) { return "length=" + input; }
        };

        var stages = List.of(
            new FusedStageDescriptor("measure", "measure", Map.of("input", "hello"), Map.of(),
                (StreamingStepFactory) factory1),
            new FusedStageDescriptor("format", "format", Map.of(), Map.of(),
                (StreamingStepFactory) factory2));
        var fused = new ResolvedStep.FusedPipelineStep("format", stages, Map.of());

        var evaluator = new StructuralStepEvaluator(conditionEvaluator);
        // Use a StepRunner that handles the fused dispatch
        Result result = evaluator.evaluate(fused,
            new io.casehub.yaml.core.resolver.VariableResolver(List.of()),
            (step, resolver) -> Result.of(Map.of()));

        assertTrue(result.isSuccess());
        assertEquals("length=5", result.output().get(StreamingStep.OUTPUT_KEY));
    }

    @Test
    void inputStreamChainClosesOnFailure() {
        var closed = new java.util.concurrent.atomic.AtomicBoolean(false);
        StreamingStepFactory<String, InputStream> factory1 = (p, s) -> new StreamingStep<>() {
            @Override public Class<String> inputType() { return String.class; }
            @Override public Class<InputStream> outputType() { return InputStream.class; }
            @Override public InputStream apply(String input) {
                return new ByteArrayInputStream(input.getBytes()) {
                    @Override public void close() { closed.set(true); }
                };
            }
        };
        StreamingStepFactory<InputStream, String> factory2 = (p, s) -> new StreamingStep<>() {
            @Override public Class<InputStream> inputType() { return InputStream.class; }
            @Override public Class<String> outputType() { return String.class; }
            @Override public String apply(InputStream input) {
                throw new RuntimeException("transcription failed");
            }
        };

        var stages = List.of(
            new FusedStageDescriptor("download", "download",
                Map.of("url", "http://example.com"), Map.of(),
                (StreamingStepFactory) factory1),
            new FusedStageDescriptor("transcribe", "transcribe", Map.of(), Map.of(),
                (StreamingStepFactory) factory2));
        var fused = new ResolvedStep.FusedPipelineStep("transcribe", stages, Map.of());

        var evaluator = new StructuralStepEvaluator(conditionEvaluator);
        Result result = evaluator.evaluate(fused,
            new io.casehub.yaml.core.resolver.VariableResolver(List.of()),
            (step, resolver) -> Result.of(Map.of()));

        assertFalse(result.isSuccess());
        assertTrue(closed.get(), "InputStream should be closed on chain failure");
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="FusionPassTest,FusedChainEvaluationTest" -DfailIfNoTests=false`
Expected: compilation failure

- [ ] **Step 4: Implement FusionPass**

Create `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/FusionPass.java`:

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.plugin.api.*;
import io.casehub.yaml.step.catalog.ResolvedStep;
import java.util.*;
import java.util.regex.Pattern;

public final class FusionPass {

    private static final Set<String> CHAIN_BREAKING_DECORATORS = Set.of(
        "from", "background", "when", "on-error", "wait", "at",
        "forEach", "cancel", "loop", "transition", "signal", "publish",
        "semaphore", "mutex", "transform");

    private static final Pattern RESULT_REF = Pattern.compile(
        "\\$\\{result\\.([a-zA-Z0-9_-]+)");

    private FusionPass() {}

    public static List<ResolvedStep> fuse(List<ResolvedStep> steps, PluginRegistry registry) {
        if (steps.size() < 2) return steps;

        Set<String> referencedNames = collectReferencedNames(steps);
        List<ResolvedStep> result = new ArrayList<>();
        List<ResolvedStep.PluginStep> candidate = new ArrayList<>();
        List<StreamingTypeInfo> candidateTypes = new ArrayList<>();

        for (ResolvedStep step : steps) {
            if (step instanceof ResolvedStep.PluginStep plugin) {
                Optional<Definition> defOpt = registry.resolve(plugin.actionName());
                if (defOpt.isPresent() && defOpt.get().streamingType().isPresent()) {
                    StreamingTypeInfo typeInfo = defOpt.get().streamingType().get();

                    if (candidate.isEmpty()) {
                        candidate.add(plugin);
                        candidateTypes.add(typeInfo);
                    } else if (isCompatible(candidateTypes.get(candidateTypes.size() - 1), typeInfo)
                               && !hasChainBreakingDecorator(plugin)
                               && !isReferencedNonLast(plugin.name(), referencedNames)) {
                        candidate.add(plugin);
                        candidateTypes.add(typeInfo);
                    } else {
                        flushCandidate(candidate, candidateTypes, referencedNames, result);
                        candidate.add(plugin);
                        candidateTypes.add(typeInfo);
                    }
                    continue;
                }
            }
            flushCandidate(candidate, candidateTypes, referencedNames, result);
            result.add(step);
        }
        flushCandidate(candidate, candidateTypes, referencedNames, result);
        return List.copyOf(result);
    }

    // ... (private methods for isCompatible, hasChainBreakingDecorator,
    //  isReferencedNonLast, collectReferencedNames, flushCandidate)
}
```

The full implementation follows the spec's algorithm (steps 1-7) with the variable reference scan, decorator classification, and type compatibility via `isAssignableFrom()`.

- [ ] **Step 5: Add FusedPipelineStep dispatch to StructuralStepEvaluator**

Modify `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java`:
- Add case `FusedPipelineStep` to the `dispatchStep()` switch at line 103
- Implement `evaluateFusedPipeline()` method:
  1. Resolve params via VariableResolver for each stage
  2. Create StreamingStep instances via factories
  3. Compose via Function.andThen() with inline decorators
  4. Extract first input via inputKey
  5. Execute chain, track last intermediate for resource cleanup
  6. Catch exceptions → FusedChainException → Result.Failure
  7. Close AutoCloseable intermediates on failure

Use `ide_insert_member` for the new method and `ide_edit_member` for the switch case.

- [ ] **Step 6: Integrate fusion pass into step resolution**

Modify `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java`:
- After resolving steps, call `FusionPass.fuse(resolvedSteps, registry)` before returning
- The Walker already has access to the PluginRegistry

- [ ] **Step 7: Run tests to verify all pass**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="FusionPassTest,FusedChainEvaluationTest"`
Expected: all tests PASS

- [ ] **Step 8: Run full yaml-step-runtime test suite**

Run: `mvn --batch-mode test -pl yaml-step-runtime`
Expected: all existing tests PASS (no regressions from ResolvedStep sealed change)

- [ ] **Step 9: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(runtime): fusion pass, StructuralStepEvaluator dispatch, resource cleanup

Refs #680"
```

---

## Batch 4: SWF Compiler + Integration Tests

### Task 5: PlaybookCompiler streaming-aware compilation

**Files:**
- Modify: `playbook-compiler/src/main/java/io/casehub/yaml/step/compiler/PlaybookCompiler.java` — accept optional PluginRegistry, detect fusible sequences
- Create: `playbook-compiler/src/main/java/io/casehub/yaml/step/compiler/FusedPipelineCompiler.java`
- Test: `playbook-compiler/src/test/java/io/casehub/yaml/step/compiler/FusedPipelineCompilerTest.java`

**Interfaces:**
- Consumes: `PlaybookCompiler`, `StepCompiler`, `CompilationContext`, `PluginRegistry`, `Definition`, `StreamingTypeInfo`, `FusionPass` from earlier tasks
- Produces: SWF `TaskItem` wrapping fused streaming chains, serializable-type validation for SWF path

- [ ] **Step 1: Write failing test for SWF streaming compilation**

```java
package io.casehub.yaml.step.compiler;

import io.casehub.yaml.plugin.api.*;
import org.junit.jupiter.api.Test;
import java.util.Map;
import java.util.Optional;
import static org.junit.jupiter.api.Assertions.*;

class FusedPipelineCompilerTest {

    @Test
    void compilesSerializableStreamingChainToSingleTaskItem() {
        // Register streaming steps with serializable types (String → byte[] → String)
        // Compile a YAML with 3 consecutive streaming steps
        // Verify: produces 1 TaskItem (not 3)
    }

    @Test
    void rejectsNonSerializableTypesInSwfPath() {
        // Register a streaming step with InputStream type
        // Compile via SWF path
        // Verify: compile-time diagnostic error
    }

    @Test
    void fallsBackWithoutPluginRegistry() {
        // Compile without PluginRegistry
        // Plugin steps produce ERROR diagnostic (existing behavior)
        // No fusion occurs
    }
}
```

- [ ] **Step 2: Implement FusedPipelineCompiler**

Create a `StepCompiler` implementation that handles the fused chain case. Register it in `PlaybookCompiler` when a `PluginRegistry` is provided. The compiler:
1. Validates all types in the chain implement `Serializable`
2. Emits a single `TaskItem` wrapping a `CaseHubCallableTask`
3. The task, at SWF runtime, assembles and executes the chain

- [ ] **Step 3: Modify PlaybookCompiler to accept optional PluginRegistry**

Add a constructor or builder method accepting `Optional<PluginRegistry>`. When present, the compiler performs streaming-aware compilation in `compileStep()`:
1. Identify plugin steps via registry fallback lookup
2. Detect fusible sequences using same type-compatibility logic
3. Delegate to `FusedPipelineCompiler` for chain compilation

- [ ] **Step 4: Run tests**

Run: `mvn --batch-mode test -pl playbook-compiler`
Expected: all tests PASS

- [ ] **Step 5: Commit**

```bash
git add playbook-compiler/
git commit -m "feat(compiler): SWF-path streaming chain compilation with serializable validation

Refs #680"
```

### Task 6: Integration tests — YAML-driven byte stream and typed transform pipelines

**Files:**
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/ByteStreamPipelineTest.java`
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/TypedTransformPipelineTest.java`
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/StreamingMergePipelineTest.java`
- Create: `yaml-step-runtime/src/test/resources/playbooks/byte-stream-pipeline.yaml`
- Create: `yaml-step-runtime/src/test/resources/playbooks/typed-transform-pipeline.yaml`
- Create: `yaml-step-runtime/src/test/resources/playbooks/streaming-merge-pipeline.yaml`

**Interfaces:**
- Consumes: all types from Tasks 1-5
- Produces: end-to-end validation of both stream kinds via YAML, merge pipeline, per-step decorators, chain-breaking decorator boundaries, variable reference boundaries, resource cleanup

- [ ] **Step 1: Create test streaming step implementations**

Create test-only `@StreamPlugin` records for both stream kinds:

```java
// Byte stream steps
@StreamPlugin(name = "test-download")
public record TestDownloadPlugin() {
    @Execute
    public InputStream apply(String url) {
        return new ByteArrayInputStream(("downloaded:" + url).getBytes());
    }
}

@StreamPlugin(name = "test-transform-bytes")
public record TestTransformBytesPlugin() {
    @Execute
    public InputStream apply(InputStream input) {
        byte[] data = input.readAllBytes();
        return new ByteArrayInputStream(new String(data).toUpperCase().getBytes());
    }
}

@StreamPlugin(name = "test-transcribe")
public record TestTranscribePlugin() {
    @Execute
    public String apply(InputStream audio) {
        return "transcribed:" + new String(audio.readAllBytes());
    }
}

// Typed transform steps
public record SensorEvent(String sensorId, double temperature, long timestamp) {}
public record AnnotatedEvent(SensorEvent event, boolean anomaly) {}
public record AlertPayload(String message, String severity) {}

@StreamPlugin(name = "test-ingest")
public record TestIngestPlugin() {
    @Execute
    public SensorEvent apply(String rawPayload) {
        return new SensorEvent("s1", Double.parseDouble(rawPayload), System.currentTimeMillis());
    }
}

@StreamPlugin(name = "test-detect")
public record TestDetectPlugin(@Optional Double threshold) {
    @Execute
    public AnnotatedEvent apply(SensorEvent event) {
        double t = threshold != null ? threshold : 2.5;
        return new AnnotatedEvent(event, event.temperature() > t);
    }
}

@StreamPlugin(name = "test-format")
public record TestFormatPlugin() {
    @Execute
    public AlertPayload apply(AnnotatedEvent event) {
        return new AlertPayload("Temp: " + event.event().temperature(),
            event.anomaly() ? "HIGH" : "LOW");
    }
}
```

- [ ] **Step 2: Create YAML test playbooks**

`byte-stream-pipeline.yaml`:
```yaml
steps:
  - test-download:
      url: "http://example.com/audio.wav"
    step: download

  - test-transform-bytes: {}
    step: transform

  - test-transcribe: {}
    step: transcript

  - log:
      message: "${result.transcript.output}"
    step: log-result
```

`typed-transform-pipeline.yaml`:
```yaml
steps:
  - test-ingest:
      raw-payload: "42.5"
    step: ingest

  - test-detect:
      threshold: 40.0
    step: detect

  - test-format: {}
    step: format
```

`streaming-merge-pipeline.yaml`:
```yaml
steps:
  - parallel:
      - test-download:
          url: "http://left.com"
        step: left
      - test-download:
          url: "http://right.com"
        step: right

  - test-concat-merge: {}
    step: merged
```

- [ ] **Step 3: Write ByteStreamPipelineTest**

```java
package io.casehub.yaml.step.eval;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ByteStreamPipelineTest {

    @Test
    void fusesDownloadTransformTranscribeChain() {
        // Load byte-stream-pipeline.yaml
        // Register test streaming steps
        // Run through StructuralStepEvaluator
        // Verify: 3 streaming steps fused into 1 FusedPipelineStep
        // Verify: result contains transcribed output
        // Verify: log step receives materialized string
    }

    @Test
    void closesInputStreamOnMidChainFailure() {
        // Register a failing transform step
        // Verify: InputStream from download is closed
    }

    @Test
    void perStepTimeoutWrapsIndividualApply() {
        // Add timeout: 30s to download step
        // Verify: chain still fuses (timeout is fusible)
        // Verify: slow download times out without affecting other steps
    }

    @Test
    void chainBreakingDecoratorProducesSeparateSteps() {
        // Add background: true to transform step
        // Verify: download is standalone, transform is standalone, transcribe is standalone
    }
}
```

- [ ] **Step 4: Write TypedTransformPipelineTest**

```java
package io.casehub.yaml.step.eval;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class TypedTransformPipelineTest {

    @Test
    void fusesIngestDetectFormatChain() {
        // Load typed-transform-pipeline.yaml
        // Register test typed transform steps
        // Run through StructuralStepEvaluator
        // Verify: 3 steps fused into 1 FusedPipelineStep
        // Verify: result contains AlertPayload with anomaly=true
    }

    @Test
    void variableReferenceOnFirstStepBreaksFusion() {
        // Add a 4th step that references ${result.ingest.output}
        // Verify: ingest is standalone, detect+format fused
    }
}
```

- [ ] **Step 5: Write StreamingMergePipelineTest**

```java
package io.casehub.yaml.step.eval;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class StreamingMergePipelineTest {

    @Test
    void mergesParallelBranchOutputs() {
        // Register StreamingMerge<InputStream> that concatenates
        // Run streaming-merge-pipeline.yaml
        // Verify: merge step receives List of 2 InputStreams
        // Verify: merged output contains both branch contents
    }
}
```

- [ ] **Step 6: Implement tests with full assertions**

Fill in the test bodies with actual step registration, YAML loading, evaluator wiring, and assertions. Use the existing test patterns from `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/StructuralStepEvaluatorTest.java` for test structure.

- [ ] **Step 7: Run all integration tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="ByteStreamPipelineTest,TypedTransformPipelineTest,StreamingMergePipelineTest"`
Expected: all tests PASS

- [ ] **Step 8: Run full project test suite**

Run: `mvn --batch-mode test`
Expected: BUILD SUCCESS — no regressions across all modules

- [ ] **Step 9: Commit**

```bash
git add yaml-step-runtime/src/test/ playbook-compiler/src/test/
git commit -m "test: integration tests for byte stream, typed transform, and merge pipelines

Refs #680"
```

---

## References

- [2026-10-30-streaming-step-pipe-fusible-design.md] — design spec this plan implements
- [yaml-plugin-api/.../Definition.java] — 7-component record, needs 8th
- [yaml-plugin-api/.../Action.java:6] — current @FunctionalInterface
- [yaml-plugin-api/.../Result.java:5] — sealed Success/Failure
- [yaml-plugin-api/.../PluginRegistry.java] — register/resolve contract
- [yaml-plugin-processor/.../StepPluginProcessor.java] — APT pattern to follow
- [yaml-plugin-processor/.../BinderEmitter.java] — code generation pattern
- [yaml-step-runtime/.../ResolvedStep.java] — 12-variant sealed hierarchy
- [yaml-step-runtime/.../StructuralStepEvaluator.java:103] — dispatchStep switch
- [yaml-step-runtime/.../DecoratorChain.java:56] — apply() decorator wrapping
- [yaml-step-runtime/.../CatalogStepRunner.java] — registry→action lookup
- [yaml-step-runtime/.../Walker.java] — step resolution pipeline
- [playbook-compiler/.../PlaybookCompiler.java] — StepCompiler registry
- [GitHub #680] — streaming step type issue
- [GitHub #566] — durable playbook execution SWF integration
