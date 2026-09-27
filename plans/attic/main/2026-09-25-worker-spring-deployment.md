# casehub-worker Spring Boot Deployment — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/casehub-worker#16 — Spring Boot deployment
**Issue group:** casehubio/casehub-worker#16

**Goal:** Extract CDI-coupled beans to framework-neutral core POJOs and
create Spring auto-configuration, making casehub-worker usable from
Spring Boot applications.

**Architecture:** Create `runtime-core/` with blocking `WorkerExecutorCore`
interface and `DefaultWorkerExecutorCore` POJO. Rewire Quarkus
`DefaultWorkerExecutor` to delegate to core. Hand-write
`WorkerAutoConfiguration` in `worker-spring/`. Verify composition in
`spring-integration-test/`.

**Tech Stack:** Java 21, Maven, Spring Boot 4, Jackson, networknt
json-schema-validator

## Global Constraints

- `runtime-core/` must have zero CDI and zero Spring imports
- `api/` is unchanged — already framework-neutral
- `WorkerExecutor` (Uni-based) stays in `runtime/` — Spring uses
  `WorkerExecutorCore` (blocking)
- OTel tracing stays in Quarkus module only
- SmallRye Guard stays in Quarkus module only
- All work in repo: `/Users/mdproctor/claude/casehub/slots/198/casehub-worker`

---

## Batch 1: Foundation — runtime-core module

### Task 1: Create runtime-core module with SchemaValidator and WorkerExecutorCore

**Files:**
- Create: `runtime-core/pom.xml`
- Create: `runtime-core/src/main/java/io/casehub/worker/runtime/core/SchemaValidator.java`
- Create: `runtime-core/src/main/java/io/casehub/worker/runtime/core/WorkerExecutorCore.java`
- Create: `runtime-core/src/main/java/io/casehub/worker/runtime/core/DefaultWorkerExecutorCore.java`
- Create: `runtime-core/src/main/java/io/casehub/worker/runtime/core/MockWorkerExecutorCore.java`
- Test: `runtime-core/src/test/java/io/casehub/worker/runtime/core/DefaultWorkerExecutorCoreTest.java`
- Test: `runtime-core/src/test/java/io/casehub/worker/runtime/core/SchemaValidatorTest.java`
- Test: `runtime-core/src/test/java/io/casehub/worker/runtime/core/MockWorkerExecutorCoreTest.java`
- Modify: `pom.xml` (add module)

**Interfaces:**
- Produces: `WorkerExecutorCore.execute(Worker, Capability, Object) → WorkerResult`
- Produces: `DefaultWorkerExecutorCore(SchemaValidator)` constructor
- Produces: `MockWorkerExecutorCore` — test fixture with `executionCount()`, `lastWorkerName()`, `lastCapabilityName()`, `reset()`
- Produces: `SchemaValidator.validateInput(Capability, Object)`, `validateOutput(Capability, Object)`, `ensureSchemaParsed(String)`

- [ ] **Step 1: Create runtime-core/pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-worker-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-worker-runtime-core</artifactId>

    <name>CaseHub Worker :: Runtime Core</name>
    <description>Framework-neutral worker execution — blocking WorkerExecutorCore,
        SchemaValidator, MockWorkerExecutorCore. Zero CDI, zero Spring.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-worker-api</artifactId>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.core</groupId>
            <artifactId>jackson-databind</artifactId>
        </dependency>
        <dependency>
            <groupId>com.networknt</groupId>
            <artifactId>json-schema-validator</artifactId>
            <version>1.0.83</version>
        </dependency>

        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter-api</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.smallrye</groupId>
                <artifactId>jandex-maven-plugin</artifactId>
                <version>${jandex-maven-plugin.version}</version>
                <executions>
                    <execution>
                        <id>make-index</id>
                        <goals><goal>jandex</goal></goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Add runtime-core to parent pom.xml**

Add `<module>runtime-core</module>` before `runtime` in the modules list.
Add dependency management entry:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-worker-runtime-core</artifactId>
    <version>${project.version}</version>
</dependency>
```

- [ ] **Step 3: Write SchemaValidator (moved from runtime, annotations removed)**

`runtime-core/src/main/java/io/casehub/worker/runtime/core/SchemaValidator.java`:

```java
package io.casehub.worker.runtime.core;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.networknt.schema.JsonSchema;
import com.networknt.schema.JsonSchemaFactory;
import com.networknt.schema.SpecVersion;
import com.networknt.schema.ValidationMessage;
import io.casehub.worker.api.Capability;

import java.util.Optional;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.stream.Collectors;

public class SchemaValidator {

    private static final String EMPTY_SCHEMA = "{}";

    private final ObjectMapper objectMapper = new ObjectMapper();
    private final JsonSchemaFactory schemaFactory =
        JsonSchemaFactory.getInstance(SpecVersion.VersionFlag.V202012);
    private final ConcurrentHashMap<String, JsonSchema> cache = new ConcurrentHashMap<>();

    public void ensureSchemaParsed(String schema) {
        if (EMPTY_SCHEMA.equals(schema)) return;
        cache.computeIfAbsent(schema, this::parseSchema);
    }

    public Optional<String> validateInput(Capability capability, Object input) {
        return validate(capability.inputProjection(), input);
    }

    public Optional<String> validateOutput(Capability capability, Object output) {
        return validate(capability.outputProjection(), output);
    }

    private Optional<String> validate(String schemaString, Object data) {
        if (EMPTY_SCHEMA.equals(schemaString)) { return Optional.empty(); }
        JsonSchema schema = cache.computeIfAbsent(schemaString, this::parseSchema);
        JsonNode node = objectMapper.valueToTree(data);
        Set<ValidationMessage> errors = schema.validate(node);
        if (errors.isEmpty()) { return Optional.empty(); }
        String message = errors.stream()
                               .map(ValidationMessage::getMessage)
                               .collect(Collectors.joining("\n"));
        return Optional.of(message);
    }

    private JsonSchema parseSchema(String schemaString) {
        try {
            JsonNode schemaNode = objectMapper.readTree(schemaString);
            return schemaFactory.getSchema(schemaNode);
        } catch (Exception e) {
            throw new IllegalArgumentException(
                "Malformed JSON Schema: " + e.getMessage(), e);
        }
    }
}
```

- [ ] **Step 4: Write WorkerExecutorCore interface**

`runtime-core/src/main/java/io/casehub/worker/runtime/core/WorkerExecutorCore.java`:

```java
package io.casehub.worker.runtime.core;

import io.casehub.worker.api.Capability;
import io.casehub.worker.api.Worker;
import io.casehub.worker.api.WorkerResult;

public interface WorkerExecutorCore {
    WorkerResult execute(Worker worker, Capability capability, Object input);
}
```

- [ ] **Step 5: Write DefaultWorkerExecutorCore**

`runtime-core/src/main/java/io/casehub/worker/runtime/core/DefaultWorkerExecutorCore.java`:

```java
package io.casehub.worker.runtime.core;

import io.casehub.worker.api.Capability;
import io.casehub.worker.api.Worker;
import io.casehub.worker.api.WorkerFunction;
import io.casehub.worker.api.WorkerOutcome;
import io.casehub.worker.api.WorkerResult;

import java.util.Objects;
import java.util.Optional;
import java.util.function.BiFunction;

public class DefaultWorkerExecutorCore implements WorkerExecutorCore {

    private final SchemaValidator schemaValidator;

    public DefaultWorkerExecutorCore(SchemaValidator schemaValidator) {
        this.schemaValidator = schemaValidator;
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    @Override
    public WorkerResult execute(Worker worker, Capability capability, Object input) {
        Objects.requireNonNull(capability, "capability");
        if (!worker.capabilities().contains(capability.name())) {
            throw new IllegalArgumentException(
                    "Capability '" + capability.name() + "' not in worker '"
                    + worker.name() + "' capabilities: " + worker.capabilities());
        }

        WorkerFunction<?, ?> fn = worker.function();
        Class<?> inputType = fn.inputType();
        if (!inputType.isInstance(input)) {
            throw new IllegalArgumentException(
                    "Input type mismatch: expected " + inputType.getName()
                    + ", got " + (input == null ? "null" : input.getClass().getName()));
        }

        schemaValidator.ensureSchemaParsed(capability.inputProjection());
        schemaValidator.ensureSchemaParsed(capability.outputProjection());

        Optional<String> inputError = schemaValidator.validateInput(capability, input);
        if (inputError.isPresent()) {
            return WorkerResult.failed(inputError.get());
        }

        try {
            WorkerResult result = dispatch(worker, input);
            if (result.outcome() instanceof WorkerOutcome.Success) {
                Optional<String> outputError = schemaValidator.validateOutput(capability, result.output());
                outputError.ifPresent(err ->
                    org.jboss.logging.Logger.getLogger(DefaultWorkerExecutorCore.class)
                        .warnf("Output schema violation for worker '%s' capability '%s': %s",
                               worker.name(), capability.name(), err));
            }
            return result;
        } catch (Exception e) {
            Throwable root = e.getCause() != null ? e.getCause() : e;
            String message = root.getMessage();
            if (message == null) { message = root.getClass().getName(); }
            return WorkerResult.failed(message);
        }
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private WorkerResult dispatch(Worker worker, Object input) {
        if (worker.function() instanceof WorkerFunction.Sync sync) {
            return (WorkerResult) ((BiFunction) sync.fn()).apply(input, null);
        }
        throw new UnsupportedOperationException(
                "Unsupported function type: " + worker.function().getClass().getName());
    }
}
```

Note: uses `org.jboss.logging.Logger` for output validation warnings —
this is a transitive dependency from the platform BOM, not a CDI
dependency. If the BOM doesn't provide it, replace with
`java.util.logging.Logger`.

- [ ] **Step 6: Write MockWorkerExecutorCore**

`runtime-core/src/main/java/io/casehub/worker/runtime/core/MockWorkerExecutorCore.java`:

```java
package io.casehub.worker.runtime.core;

import io.casehub.worker.api.Capability;
import io.casehub.worker.api.Worker;
import io.casehub.worker.api.WorkerFunction;
import io.casehub.worker.api.WorkerResult;

import java.util.Objects;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.BiFunction;

public class MockWorkerExecutorCore implements WorkerExecutorCore {

    private final AtomicInteger executionCount = new AtomicInteger(0);
    private final AtomicReference<String> lastWorkerName = new AtomicReference<>();
    private final AtomicReference<String> lastCapabilityName = new AtomicReference<>();

    @SuppressWarnings({"unchecked", "rawtypes"})
    @Override
    public WorkerResult execute(Worker worker, Capability capability, Object input) {
        Objects.requireNonNull(capability, "capability");
        if (!worker.capabilities().contains(capability.name())) {
            throw new IllegalArgumentException(
                    "Capability '" + capability.name() + "' not in worker '"
                    + worker.name() + "' capabilities: " + worker.capabilities());
        }
        executionCount.incrementAndGet();
        lastWorkerName.set(worker.name());
        lastCapabilityName.set(capability.name());

        if (worker.function() instanceof WorkerFunction.Sync sync) {
            if (!sync.inputType().isInstance(input)) {
                throw new IllegalArgumentException(
                        "Input type mismatch: expected " + sync.inputType().getName()
                        + ", got " + (input == null ? "null" : input.getClass().getName()));
            }
            try {
                return (WorkerResult) ((BiFunction) sync.fn()).apply(input, null);
            } catch (Exception e) {
                String message = e.getMessage();
                if (message == null) { message = e.getClass().getName(); }
                return WorkerResult.failed(message);
            }
        }
        throw new UnsupportedOperationException(
                "MockWorkerExecutorCore supports Sync functions only, got: "
                + worker.function().getClass().getName());
    }

    public int executionCount()        { return executionCount.get(); }
    public String lastWorkerName()     { return lastWorkerName.get(); }
    public String lastCapabilityName() { return lastCapabilityName.get(); }

    public void reset() {
        executionCount.set(0);
        lastWorkerName.set(null);
        lastCapabilityName.set(null);
    }
}
```

- [ ] **Step 7: Write DefaultWorkerExecutorCoreTest**

Port all non-Guard/non-timeout tests from `WorkerExecutorTest`. These
tests already construct via `new` — adapt to use `DefaultWorkerExecutorCore`
directly instead of `DefaultWorkerExecutor` + `.await().indefinitely()`.

`runtime-core/src/test/java/io/casehub/worker/runtime/core/DefaultWorkerExecutorCoreTest.java`:

```java
package io.casehub.worker.runtime.core;

import io.casehub.worker.api.Capability;
import io.casehub.worker.api.Worker;
import io.casehub.worker.api.WorkerFunction;
import io.casehub.worker.api.WorkerOutcome;
import io.casehub.worker.api.WorkerResult;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class DefaultWorkerExecutorCoreTest {

    private static final String REQUIRE_NAME_SCHEMA = """
            {
              "type": "object",
              "properties": { "name": { "type": "string" } },
              "required": ["name"]
            }""";
    private static final String REQUIRE_RESULT_SCHEMA = """
            {
              "type": "object",
              "properties": { "result": { "type": "number" } },
              "required": ["result"]
            }""";

    private final DefaultWorkerExecutorCore executor =
            new DefaultWorkerExecutorCore(new SchemaValidator());

    private static Capability cap(String name) {
        return Capability.of(name, "{}", "{}");
    }

    private static Capability cap(String name, String inputSchema, String outputSchema) {
        return Capability.of(name, inputSchema, outputSchema);
    }

    @Test
    void execute_successfulWorker() {
        Worker worker = Worker.builder()
                .name("greet").capabilityName("greet")
                .function(new WorkerFunction.Sync<>(Map.class, Map.class,
                    (input, scope) -> WorkerResult.of(Map.of("greeting", "hello " + input.get("name")))))
                .build();

        WorkerResult result = executor.execute(worker, cap("greet"), Map.of("name", "world"));
        assertThat(result.outcome()).isInstanceOf(WorkerOutcome.Success.class);
        assertThat((Map<String, Object>) result.output()).containsEntry("greeting", "hello world");
    }

    @Test
    void execute_workerThrows_returnsFailed() {
        Worker worker = Worker.builder()
                .name("throws").capabilityName("boom")
                .function(new WorkerFunction.Sync<>(Map.class, Map.class,
                    (input, scope) -> { throw new IllegalStateException("bad state"); }))
                .build();

        WorkerResult result = executor.execute(worker, cap("boom"), Map.of());
        assertThat(result.outcome()).isInstanceOf(WorkerOutcome.Failed.class);
        assertThat(((WorkerOutcome.Failed<?>) result.outcome()).reason()).isEqualTo("bad state");
    }

    @Test
    void execute_nullCapability_throwsNPE() {
        Worker worker = Worker.builder()
                .name("w").capabilityName("c")
                .function(new WorkerFunction.Sync<>(Map.class, Map.class,
                    (input, scope) -> WorkerResult.of(Map.of())))
                .build();

        assertThatThrownBy(() -> executor.execute(worker, null, Map.of()))
                .isInstanceOf(NullPointerException.class)
                .hasMessageContaining("capability");
    }

    @Test
    void execute_capabilityNotInWorker_throwsIAE() {
        Worker worker = Worker.builder()
                .name("w").capabilityName("supported")
                .function(new WorkerFunction.Sync<>(Map.class, Map.class,
                    (input, scope) -> WorkerResult.of(Map.of())))
                .build();

        assertThatThrownBy(() -> executor.execute(worker, cap("unsupported"), Map.of()))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("unsupported");
    }

    @Test
    void execute_inputTypeMismatch_throwsIAE() {
        Worker worker = Worker.builder()
                .name("typed").capabilityName("process")
                .<TestPojo>fn().apply(pojo -> WorkerResult.of(Map.of()))
                .build();

        assertThatThrownBy(() -> executor.execute(worker, cap("process"), Map.of("name", "alice")))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("TestPojo");
    }

    @Test
    void execute_invalidInput_returnsFailed_functionNeverCalled() {
        AtomicInteger callCount = new AtomicInteger(0);
        Worker worker = Worker.builder()
                .name("strict").capabilityName("validate")
                .function(new WorkerFunction.Sync<>(Map.class, Map.class, (input, scope) -> {
                    callCount.incrementAndGet();
                    return WorkerResult.of(Map.of());
                }))
                .build();

        WorkerResult result = executor.execute(worker,
                cap("validate", REQUIRE_NAME_SCHEMA, "{}"), Map.of("age", 30));

        assertThat(result.outcome()).isInstanceOf(WorkerOutcome.Failed.class);
        assertThat(((WorkerOutcome.Failed<?>) result.outcome()).reason()).contains("name");
        assertThat(callCount.get()).isZero();
    }

    @Test
    void execute_validInput_invalidOutput_returnsSuccessWithWarning() {
        Worker worker = Worker.builder()
                .name("bad-output").capabilityName("compute")
                .function(new WorkerFunction.Sync<>(Map.class, Map.class,
                    (input, scope) -> WorkerResult.of(Map.of("result", "not-a-number"))))
                .build();

        WorkerResult result = executor.execute(worker,
                cap("compute", "{}", REQUIRE_RESULT_SCHEMA), Map.of());

        assertThat(result.outcome()).isInstanceOf(WorkerOutcome.Success.class);
    }

    @Test
    void execute_emptySchemas_noValidation() {
        Worker worker = Worker.builder()
                .name("legacy").capabilityName("old")
                .function(new WorkerFunction.Sync<>(Map.class, Map.class,
                    (input, scope) -> WorkerResult.of(Map.of("anything", "goes"))))
                .build();

        WorkerResult result = executor.execute(worker, cap("old"), Map.of("random", 42));
        assertThat(result.outcome()).isInstanceOf(WorkerOutcome.Success.class);
    }

    @Test
    void execute_syncWorker_completesSuccessfully() {
        Worker worker = Worker.builder()
                .name("sync").capabilityName("fetch")
                .function(input -> WorkerResult.of(Map.of("fetched", true)))
                .build();

        WorkerResult result = executor.execute(worker, cap("fetch"), Map.of());
        assertThat(result.outcome()).isInstanceOf(WorkerOutcome.Success.class);
        assertThat((Map<String, Object>) result.output()).containsEntry("fetched", true);
    }

    @Test
    void execute_malformedSchema_throwsIAE() {
        Worker worker = Worker.builder()
                .name("broken").capabilityName("bad")
                .function(new WorkerFunction.Sync<>(Map.class, Map.class,
                    (input, scope) -> WorkerResult.of(Map.of())))
                .build();

        assertThatThrownBy(() -> executor.execute(worker,
                cap("bad", "not valid json", "{}"), Map.of()))
                .isInstanceOf(IllegalArgumentException.class);
    }

    record TestPojo(String name, int age) {}
}
```

- [ ] **Step 8: Write SchemaValidatorTest**

Port the `schemaValidator_validatesPojoInput` test from `WorkerExecutorTest`:

`runtime-core/src/test/java/io/casehub/worker/runtime/core/SchemaValidatorTest.java`:

```java
package io.casehub.worker.runtime.core;

import io.casehub.worker.api.Capability;
import org.junit.jupiter.api.Test;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SchemaValidatorTest {

    private static final String REQUIRE_NAME_SCHEMA = """
            {
              "type": "object",
              "properties": { "name": { "type": "string" } },
              "required": ["name"]
            }""";

    private final SchemaValidator validator = new SchemaValidator();

    @Test
    void validatesPojoInput() {
        Capability cap = Capability.of("test", REQUIRE_NAME_SCHEMA, "{}");
        validator.ensureSchemaParsed(cap.inputProjection());

        record TestPojo(String name, int age) {}

        Optional<String> valid = validator.validateInput(cap, new TestPojo("alice", 30));
        assertThat(valid).isEmpty();

        Optional<String> invalid = validator.validateInput(cap, new TestPojo(null, 30));
        assertThat(invalid).isPresent();
    }

    @Test
    void emptySchema_skipsValidation() {
        Capability cap = Capability.of("test", "{}", "{}");
        Optional<String> result = validator.validateInput(cap, "anything");
        assertThat(result).isEmpty();
    }

    @Test
    void malformedSchema_throwsIAE() {
        assertThatThrownBy(() -> validator.ensureSchemaParsed("not json"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("Malformed JSON Schema");
    }
}
```

- [ ] **Step 9: Write MockWorkerExecutorCoreTest**

`runtime-core/src/test/java/io/casehub/worker/runtime/core/MockWorkerExecutorCoreTest.java`:

```java
package io.casehub.worker.runtime.core;

import io.casehub.worker.api.Capability;
import io.casehub.worker.api.Worker;
import io.casehub.worker.api.WorkerOutcome;
import io.casehub.worker.api.WorkerResult;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class MockWorkerExecutorCoreTest {

    private final MockWorkerExecutorCore mock = new MockWorkerExecutorCore();

    @Test
    void tracksExecutions() {
        Worker worker = Worker.builder()
                .name("test").capabilityName("cap")
                .function(input -> WorkerResult.of(Map.of("ok", true)))
                .build();

        mock.execute(worker, Capability.of("cap", "{}", "{}"), Map.of());

        assertThat(mock.executionCount()).isEqualTo(1);
        assertThat(mock.lastWorkerName()).isEqualTo("test");
        assertThat(mock.lastCapabilityName()).isEqualTo("cap");
    }

    @Test
    void resetClearsState() {
        Worker worker = Worker.builder()
                .name("test").capabilityName("cap")
                .function(input -> WorkerResult.of(Map.of()))
                .build();

        mock.execute(worker, Capability.of("cap", "{}", "{}"), Map.of());
        mock.reset();

        assertThat(mock.executionCount()).isZero();
        assertThat(mock.lastWorkerName()).isNull();
    }
}
```

- [ ] **Step 10: Build and run tests**

Run: `mvn --batch-mode -pl runtime-core test`
Expected: All tests pass, module compiles with zero CDI/Spring imports.

- [ ] **Step 11: Commit**

```bash
git add runtime-core/ pom.xml
git commit -m "feat(#16): extract runtime-core — SchemaValidator, WorkerExecutorCore, DefaultWorkerExecutorCore, MockWorkerExecutorCore

Framework-neutral POJOs with blocking interface. Zero CDI, zero Spring.
Refs casehubio/casehub-worker#16"
```

## Batch 2: Rewiring — Quarkus modules delegate to core

### Task 2: Rewire DefaultWorkerExecutor to delegate to DefaultWorkerExecutorCore

**Files:**
- Modify: `runtime/pom.xml` (add runtime-core dependency)
- Modify: `runtime/src/main/java/io/casehub/worker/runtime/DefaultWorkerExecutor.java`
- Delete: `runtime/src/main/java/io/casehub/worker/runtime/SchemaValidator.java` (moved to core)
- Modify: `runtime/src/test/java/io/casehub/worker/runtime/WorkerExecutorTest.java` (keep only Guard/timeout tests)
- Delete: `runtime/src/test/java/io/casehub/worker/runtime/SchemaValidatorTest.java` (if exists — schema tests now in core)

**Interfaces:**
- Consumes: `DefaultWorkerExecutorCore(SchemaValidator)` from Task 1
- Consumes: `SchemaValidator` from Task 1
- Produces: `DefaultWorkerExecutor(DefaultWorkerExecutorCore)` constructor (CDI-injected)

- [ ] **Step 1: Add runtime-core dependency to runtime/pom.xml**

Add to dependencies:
```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-worker-runtime-core</artifactId>
</dependency>
```

- [ ] **Step 2: Delete SchemaValidator from runtime/**

Use `ide_refactor_safe_delete` on
`runtime/src/main/java/io/casehub/worker/runtime/SchemaValidator.java`.
If IDE is unavailable, `git rm` the file — no other runtime/ files
import it after the rewiring.

- [ ] **Step 3: Rewrite DefaultWorkerExecutor to delegate to core**

`runtime/src/main/java/io/casehub/worker/runtime/DefaultWorkerExecutor.java`:

```java
package io.casehub.worker.runtime;

import io.casehub.platform.api.governance.ExecutionPolicy;
import io.casehub.platform.api.governance.RetryPolicy;
import io.casehub.worker.api.Capability;
import io.casehub.worker.api.Worker;
import io.casehub.worker.api.WorkerResult;
import io.casehub.worker.runtime.core.DefaultWorkerExecutorCore;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.context.Scope;
import io.smallrye.faulttolerance.api.Guard;
import io.smallrye.mutiny.Uni;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.time.temporal.ChronoUnit;
import java.util.concurrent.ConcurrentHashMap;

@ApplicationScoped
public class DefaultWorkerExecutor implements WorkerExecutor {

    private static final String INSTRUMENTATION_NAME = "io.casehub.worker";

    private final DefaultWorkerExecutorCore core;
    private final ConcurrentHashMap<ExecutionPolicy, Guard> guardCache = new ConcurrentHashMap<>();

    @Inject
    public DefaultWorkerExecutor(DefaultWorkerExecutorCore core) {
        this.core = core;
    }

    @Override
    public Uni<WorkerResult> execute(Worker worker, Capability capability, Object input) {
        Span span = GlobalOpenTelemetry.getTracer(INSTRUMENTATION_NAME)
                .spanBuilder("worker.execute")
                .setAttribute(AttributeKey.stringKey("worker.name"), worker.name())
                .setAttribute(AttributeKey.stringKey("worker.capability"), capability.name())
                .startSpan();

        try (Scope ignored = span.makeCurrent()) {
            Uni<WorkerResult> action = Uni.createFrom().item(() ->
                    core.execute(worker, capability, input));

            Guard guard = guardCache.computeIfAbsent(
                    worker.executionPolicy(), this::buildGuard);
            Uni<WorkerResult> guarded;
            try {
                guarded = guard.call(() -> action, Uni.class);
            } catch (RuntimeException e) {
                span.end();
                throw e;
            } catch (Exception e) {
                span.end();
                throw new RuntimeException(e);
            }

            return guarded
                    .onFailure(org.eclipse.microprofile.faulttolerance.exceptions.TimeoutException.class)
                    .recoverWithItem(e -> WorkerResult.expired(e.getMessage()))
                    .onFailure().recoverWithItem(e -> {
                        span.setStatus(StatusCode.ERROR, e.getMessage());
                        span.recordException(e);
                        Throwable root = e.getCause() != null ? e.getCause() : e;
                        String message = root.getMessage();
                        if (message == null) { message = root.getClass().getName(); }
                        return WorkerResult.failed(message);
                    })
                    .onTermination().invoke((result, failure, cancelled) -> {
                        if (result != null) {
                            span.setAttribute(AttributeKey.stringKey("worker.outcome"),
                                    result.outcome().getClass().getSimpleName());
                        }
                        span.end();
                    });
        }
    }

    private Guard buildGuard(ExecutionPolicy policy) {
        var builder = Guard.create();
        if (policy.timeoutMs() != null) {
            builder.withTimeout().duration(policy.timeoutMs(), ChronoUnit.MILLIS).done();
        }
        RetryPolicy retry = policy.retries();
        if (retry != null && retry.maxAttempts() != null && retry.maxAttempts() > 1) {
            var rb = builder.withRetry()
                    .maxRetries(retry.maxAttempts() - 1)
                    .delay(retry.delayMs() != null ? retry.delayMs() : 0, ChronoUnit.MILLIS);
            if (retry.backoffStrategy() != null) {
                switch (retry.backoffStrategy()) {
                    case EXPONENTIAL -> {
                        var eb = rb.withExponentialBackoff();
                        if (retry.maxDelayMs() != null) {
                            eb.maxDelay(retry.maxDelayMs(), ChronoUnit.MILLIS);
                        }
                        eb.done();
                    }
                    case EXPONENTIAL_WITH_JITTER -> {
                        var eb = rb.withExponentialBackoff();
                        if (retry.maxDelayMs() != null) {
                            eb.maxDelay(retry.maxDelayMs(), ChronoUnit.MILLIS);
                        }
                        eb.done();
                        rb.jitter(retry.delayMs() != null ? retry.delayMs() : 200, ChronoUnit.MILLIS);
                    }
                    default -> {}
                }
            }
            rb.done();
        }
        return builder.build();
    }
}
```

- [ ] **Step 4: Trim WorkerExecutorTest to Guard/timeout tests only**

Keep only these tests in `runtime/src/test/java/io/casehub/worker/runtime/WorkerExecutorTest.java`:
- `execute_retriesTransientFailures`
- `execute_exhaustsRetries_returnsFailed`
- `execute_timeout_returnsExpired`

Update the constructor: `new DefaultWorkerExecutor(new DefaultWorkerExecutorCore(new SchemaValidator()))`.
Remove all other tests (now covered by `DefaultWorkerExecutorCoreTest`).

```java
package io.casehub.worker.runtime;

import io.casehub.platform.api.governance.ExecutionPolicy;
import io.casehub.platform.api.governance.RetryPolicy;
import io.casehub.worker.api.Capability;
import io.casehub.worker.api.Worker;
import io.casehub.worker.api.WorkerFunction;
import io.casehub.worker.api.WorkerOutcome;
import io.casehub.worker.api.WorkerResult;
import io.casehub.worker.runtime.core.DefaultWorkerExecutorCore;
import io.casehub.worker.runtime.core.SchemaValidator;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;

class WorkerExecutorTest {

    private final DefaultWorkerExecutor executor =
            new DefaultWorkerExecutor(new DefaultWorkerExecutorCore(new SchemaValidator()));

    private static Capability cap(String name) {
        return Capability.of(name, "{}", "{}");
    }

    @Test
    void execute_retriesTransientFailures() {
        AtomicInteger attempts = new AtomicInteger(0);
        Worker worker = Worker.builder()
                .name("flaky").capabilityName("process")
                .function(new WorkerFunction.Sync<>(Map.class, Map.class, (input, scope) -> {
                    if (attempts.incrementAndGet() < 3) {
                        throw new RuntimeException("transient");
                    }
                    return WorkerResult.of(Map.of("recovered", true));
                }))
                .executionPolicy(new ExecutionPolicy(null, new RetryPolicy(3, 10)))
                .build();

        var result = executor.execute(worker, cap("process"), Map.of()).await().indefinitely();
        assertThat(result.outcome()).isInstanceOf(WorkerOutcome.Success.class);
        assertThat(attempts.get()).isEqualTo(3);
    }

    @Test
    void execute_exhaustsRetries_returnsFailed() {
        Worker worker = Worker.builder()
                .name("broken").capabilityName("fail")
                .function(new WorkerFunction.Sync<>(Map.class, Map.class, (input, scope) -> {
                    throw new RuntimeException("permanent");
                }))
                .executionPolicy(new ExecutionPolicy(null, new RetryPolicy(2, 10)))
                .build();

        var result = executor.execute(worker, cap("fail"), Map.of()).await().indefinitely();
        assertThat(result.outcome()).isInstanceOf(WorkerOutcome.Failed.class);
        assertThat(((WorkerOutcome.Failed<?>) result.outcome()).reason()).isEqualTo("permanent");
    }

    @Test
    void execute_timeout_returnsExpired() {
        Worker worker = Worker.builder()
                .name("slow").capabilityName("crawl")
                .function(new WorkerFunction.Sync<>(Map.class, Map.class, (input, scope) -> {
                    try { Thread.sleep(500); } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                    return WorkerResult.of(Map.of());
                }))
                .executionPolicy(new ExecutionPolicy(50, new RetryPolicy(1, 0)))
                .build();

        var result = executor.execute(worker, cap("crawl"), Map.of()).await().indefinitely();
        assertThat(result.outcome()).isInstanceOf(WorkerOutcome.Expired.class);
    }
}
```

- [ ] **Step 5: Build and run all tests**

Run: `mvn --batch-mode -pl runtime-core,runtime test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add runtime/ runtime-core/
git commit -m "feat(#16): rewire DefaultWorkerExecutor to delegate to core

SchemaValidator moved to runtime-core. DefaultWorkerExecutor now wraps
DefaultWorkerExecutorCore with Uni/Guard/OTel. Core tests in runtime-core,
Guard/timeout tests remain in runtime.
Refs casehubio/casehub-worker#16"
```

### Task 3: Rewire testing module to use core mock

**Files:**
- Modify: `testing/pom.xml` (add runtime-core dependency)
- Modify: `testing/src/main/java/io/casehub/worker/testing/MockWorkerExecutor.java`
- Modify: `testing/src/test/java/io/casehub/worker/testing/MockWorkerExecutorTest.java`

**Interfaces:**
- Consumes: `MockWorkerExecutorCore` from Task 1
- Consumes: `WorkerExecutorCore` from Task 1

- [ ] **Step 1: Add runtime-core dependency to testing/pom.xml**

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-worker-runtime-core</artifactId>
</dependency>
```

- [ ] **Step 2: Rewrite MockWorkerExecutor to delegate to MockWorkerExecutorCore**

```java
package io.casehub.worker.testing;

import io.casehub.worker.api.Capability;
import io.casehub.worker.api.Worker;
import io.casehub.worker.api.WorkerResult;
import io.casehub.worker.runtime.WorkerExecutor;
import io.casehub.worker.runtime.core.MockWorkerExecutorCore;
import io.smallrye.mutiny.Uni;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;

@DefaultBean
@ApplicationScoped
public class MockWorkerExecutor implements WorkerExecutor {

    private final MockWorkerExecutorCore core = new MockWorkerExecutorCore();

    @Override
    public Uni<WorkerResult> execute(Worker worker, Capability capability, Object input) {
        return Uni.createFrom().item(() -> core.execute(worker, capability, input));
    }

    public int executionCount()        { return core.executionCount(); }
    public String lastWorkerName()     { return core.lastWorkerName(); }
    public String lastCapabilityName() { return core.lastCapabilityName(); }
    public void reset()                { core.reset(); }
}
```

- [ ] **Step 3: Update MockWorkerExecutorTest**

Verify delegation works — tests should pass unchanged since the
public API is identical.

- [ ] **Step 4: Build and run all tests**

Run: `mvn --batch-mode test`
Expected: All tests pass across all modules.

- [ ] **Step 5: Commit**

```bash
git add testing/
git commit -m "feat(#16): rewire MockWorkerExecutor to delegate to MockWorkerExecutorCore

Refs casehubio/casehub-worker#16"
```

## Batch 3: Spring — auto-configuration + integration test + docs

### Task 4: Create worker-spring auto-configuration module

**Files:**
- Create: `worker-spring/pom.xml`
- Create: `worker-spring/src/main/java/io/casehub/worker/spring/WorkerAutoConfiguration.java`
- Create: `worker-spring/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`
- Modify: `pom.xml` (add module + dependency management)

**Interfaces:**
- Consumes: `DefaultWorkerExecutorCore(SchemaValidator)` from Task 1
- Consumes: `SchemaValidator` from Task 1
- Produces: Spring beans `SchemaValidator`, `WorkerExecutorCore`

- [ ] **Step 1: Create worker-spring/pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-worker-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-worker-spring</artifactId>

    <name>CaseHub Worker :: Spring</name>
    <description>Spring Boot auto-configuration for casehub-worker.
        Produces WorkerExecutorCore and SchemaValidator beans.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-worker-runtime-core</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-autoconfigure</artifactId>
        </dependency>

        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
</project>
```

- [ ] **Step 2: Add worker-spring to parent pom.xml**

Add `<module>worker-spring</module>` after `testing` in the modules list.
Add dependency management entry:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-worker-spring</artifactId>
    <version>${project.version}</version>
</dependency>
```

- [ ] **Step 3: Write WorkerAutoConfiguration**

`worker-spring/src/main/java/io/casehub/worker/spring/WorkerAutoConfiguration.java`:

```java
package io.casehub.worker.spring;

import io.casehub.worker.runtime.core.DefaultWorkerExecutorCore;
import io.casehub.worker.runtime.core.SchemaValidator;
import io.casehub.worker.runtime.core.WorkerExecutorCore;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;

@AutoConfiguration
public class WorkerAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    public SchemaValidator schemaValidator() {
        return new SchemaValidator();
    }

    @Bean
    @ConditionalOnMissingBean
    public WorkerExecutorCore workerExecutorCore(SchemaValidator schemaValidator) {
        return new DefaultWorkerExecutorCore(schemaValidator);
    }
}
```

- [ ] **Step 4: Create AutoConfiguration.imports**

`worker-spring/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`:

```
io.casehub.worker.spring.WorkerAutoConfiguration
```

- [ ] **Step 5: Build**

Run: `mvn --batch-mode -pl worker-spring compile`
Expected: Compiles successfully.

- [ ] **Step 6: Commit**

```bash
git add worker-spring/ pom.xml
git commit -m "feat(#16): add worker-spring auto-configuration module

@AutoConfiguration producing SchemaValidator + WorkerExecutorCore beans.
@ConditionalOnMissingBean for consumer overrides.
Refs casehubio/casehub-worker#16"
```

### Task 5: Create spring-integration-test module

**Files:**
- Create: `spring-integration-test/pom.xml`
- Create: `spring-integration-test/src/test/java/io/casehub/worker/spring/WorkerSpringIntegrationTest.java`
- Modify: `pom.xml` (add module)

**Interfaces:**
- Consumes: `WorkerAutoConfiguration` from Task 4
- Consumes: `WorkerExecutorCore`, `SchemaValidator` from Task 1

- [ ] **Step 1: Create spring-integration-test/pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-worker-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-worker-spring-integration-test</artifactId>

    <name>CaseHub Worker :: Spring Integration Test</name>
    <description>E2E Spring Boot composition gate — verifies auto-config wires correctly.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-worker-spring</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
</project>
```

- [ ] **Step 2: Add spring-integration-test to parent pom.xml**

Add `<module>spring-integration-test</module>` after `worker-spring`.
Add dependency management entry:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-worker-spring-integration-test</artifactId>
    <version>${project.version}</version>
    <scope>test</scope>
</dependency>
```

- [ ] **Step 3: Write WorkerSpringIntegrationTest**

`spring-integration-test/src/test/java/io/casehub/worker/spring/WorkerSpringIntegrationTest.java`:

```java
package io.casehub.worker.spring;

import io.casehub.worker.api.Capability;
import io.casehub.worker.api.Worker;
import io.casehub.worker.api.WorkerOutcome;
import io.casehub.worker.api.WorkerResult;
import io.casehub.worker.runtime.core.SchemaValidator;
import io.casehub.worker.runtime.core.WorkerExecutorCore;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.test.context.SpringBootTest;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest
class WorkerSpringIntegrationTest {

    @SpringBootApplication
    static class TestApp {}

    @Autowired
    private WorkerExecutorCore workerExecutorCore;

    @Autowired
    private SchemaValidator schemaValidator;

    @Test
    void autoConfigurationComposes() {
        assertThat(workerExecutorCore).isNotNull();
        assertThat(schemaValidator).isNotNull();
    }

    @Test
    void executesSyncWorker() {
        Worker worker = Worker.builder()
                .name("spring-test").capabilityName("greet")
                .function(input -> WorkerResult.of(Map.of("hello", "spring")))
                .build();

        WorkerResult result = workerExecutorCore.execute(
                worker, Capability.of("greet", "{}", "{}"), Map.of());

        assertThat(result.outcome()).isInstanceOf(WorkerOutcome.Success.class);
        assertThat((Map<String, Object>) result.output()).containsEntry("hello", "spring");
    }
}
```

- [ ] **Step 4: Run integration test**

Run: `mvn --batch-mode -pl spring-integration-test test`
Expected: Both tests pass — auto-config composes, worker executes.

- [ ] **Step 5: Commit**

```bash
git add spring-integration-test/ pom.xml
git commit -m "feat(#16): add spring-integration-test — verifies auto-config composition

@SpringBootTest confirms WorkerExecutorCore and SchemaValidator beans
are created and functional.
Refs casehubio/casehub-worker#16"
```

### Task 6: Update documentation and CLAUDE.md

**Files:**
- Modify: `docs/guides/consumer-guide.md` (add Spring Boot section)
- Modify: `CLAUDE.md` (add new modules)

**Interfaces:**
- None — documentation only

- [ ] **Step 1: Read current consumer-guide.md**

Read `docs/guides/consumer-guide.md` to understand existing structure.

- [ ] **Step 2: Add Spring Boot section to consumer guide**

Append a "## Spring Boot" section after the existing content:

```markdown
## Spring Boot

### Dependency

Add `casehub-worker-spring` to your Spring Boot application:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-worker-spring</artifactId>
</dependency>
```

### Usage

`WorkerAutoConfiguration` auto-creates `WorkerExecutorCore` and
`SchemaValidator` beans. Inject and use:

```java
@Autowired
private WorkerExecutorCore executor;

Worker worker = Worker.builder()
    .name("greet").capabilityName("greet")
    .function(input -> WorkerResult.of(Map.of("hello", "world")))
    .build();

WorkerResult result = executor.execute(worker,
    Capability.of("greet", "{}", "{}"), Map.of());
```

### Overriding Defaults

Both beans use `@ConditionalOnMissingBean` — define your own
`SchemaValidator` or `WorkerExecutorCore` bean to override.

### Fault Tolerance

The Spring path provides raw execution without built-in
timeout/retry/circuit-breaker (the Quarkus module uses SmallRye Guard
for this). For Spring, use Spring Retry or Resilience4j as a separate
concern around `WorkerExecutorCore.execute()`.
```

- [ ] **Step 3: Update CLAUDE.md with new modules**

Add entries for `runtime-core`, `worker-spring`, `spring-integration-test`
to the module table or description section.

- [ ] **Step 4: Run full build**

Run: `mvn --batch-mode install`
Expected: All modules build and all tests pass.

- [ ] **Step 5: Commit**

```bash
git add docs/ CLAUDE.md
git commit -m "docs(#16): update consumer guide and CLAUDE.md for Spring Boot modules

Refs casehubio/casehub-worker#16"
```

## References

- [2026-09-25-worker-spring-deployment-design.md] — design spec
- [runtime/src/main/java/io/casehub/worker/runtime/DefaultWorkerExecutor.java] — primary extraction target
- [runtime/src/main/java/io/casehub/worker/runtime/SchemaValidator.java] — moved to core
- [runtime/src/test/java/io/casehub/worker/runtime/WorkerExecutorTest.java] — tests to split
- [testing/src/main/java/io/casehub/worker/testing/MockWorkerExecutor.java] — rewired to core mock
- [casehubio/casehub-worker#16] — focal issue
