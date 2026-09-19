# CaseMemoryStore Simulation Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #320 — CaseMemoryStore simulation adapter
**Issue group:** #320

**Goal:** Generate a `@Decorator` for CaseMemoryStore via the simulation-generator annotation processor — the first Path A consumer of the simulation framework.

**Architecture:** CaseMemoryStore lives in `casehub-neocortex-memory-api` (a peer repo outside this slot), so it cannot be annotated with `@SimulationEligible` directly. The generator is extended to read `META-INF/simulation-eligible.txt` listing files as an alternative registration mechanism. A new `memory-simulation-core` module in platform provides the listing file and has the generator as an annotation processor, producing the `SimulatedCaseMemoryStore` decorator at compile time.

**Tech Stack:** Java 21, Jandex (annotation indexing), Jakarta CDI `@Decorator`, Maven annotation processing

## Global Constraints

- `simulation-api` must remain zero-dependency (pure Java)
- `simulation-generator` must remain a pure annotation processor (no Quarkus runtime)
- Generated decorators go to package `io.casehub.platform.simulation.generated`
- CDI @Decorator must override ALL abstract methods; default methods must delegate to `delegate` (not inherit interface defaults — the decorator IS the CDI bean, so inherited defaults bypass the real backend)
- `memory-simulation-core` follows the `-core` naming pattern (Jakarta CDI annotations are framework-neutral)

---

## Batch 1: Generator enhancements

### Task 1: Default method handling in SimulationDecoratorProcessor

The generator currently generates simulation/capture logic for ALL interface methods including defaults. For interfaces like CaseMemoryStore with many default methods (`storeAll`, `eraseSubject`, `capabilities`, `scan`, etc.), the decorator must:
- **Abstract methods** → full simulation + capture + delegation to delegate
- **Default methods** → simple delegation to `delegate.method(args)` (no simulation/capture)

Default methods MUST still be generated (not inherited from the interface) because the decorator IS the CDI bean — inherited defaults would call `this.store()` which hits the decorator's override correctly, BUT other default methods like `capabilities()` would return the interface default (`Set.of()`) instead of the delegate's real capabilities.

**Files:**
- Modify: `simulation-generator/src/main/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessor.java`
- Create: `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/test/TestSpiWithDefaults.java`
- Modify: `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessorTest.java`

**Interfaces:**
- Produces: Updated `generateFromIndex(IndexView)` that distinguishes abstract vs default methods in generated code

- [ ] **Step 1: Create test interface with default methods**

```java
// simulation-generator/src/test/java/.../test/TestSpiWithDefaults.java
package io.casehub.platform.simulation.generator.test;

import io.casehub.platform.simulation.SimulationEligible;
import java.util.List;

@SimulationEligible(name = "spi-with-defaults")
public interface TestSpiWithDefaults {

    String query(String input);

    void store(String id, String value);

    default List<String> queryAll(List<String> inputs) {
        return inputs.stream().map(this::query).toList();
    }

    default int count() {
        return 0;
    }
}
```

- [ ] **Step 2: Write failing tests for default method handling**

```java
// Add to SimulationDecoratorProcessorTest.java

// In @BeforeAll:
indexer.indexClass(TestSpiWithDefaults.class);

@Test
void abstractMethodsGetSimulationLogic() {
    var processor = new SimulationDecoratorProcessor();
    var sources = processor.generateFromIndex(index);
    String code = findSource(sources, "TestSpiWithDefaults");

    // Abstract methods have simulation strategy check
    assertThat(code).contains("\"spi-with-defaults.query\"");
    assertThat(code).contains("\"spi-with-defaults.store\"");

    // These method bodies contain strategy resolution
    assertThat(occurrences(code, "simulation.strategyFor")).isGreaterThanOrEqualTo(2);
}

@Test
void defaultMethodsDelegateWithoutSimulation() {
    var processor = new SimulationDecoratorProcessor();
    var sources = processor.generateFromIndex(index);
    String code = findSource(sources, "TestSpiWithDefaults");

    // Default methods appear but delegate directly
    assertThat(code).contains("delegate.queryAll(");
    assertThat(code).contains("delegate.count(");

    // The qualified names for default methods should NOT appear
    // (no simulation.strategyFor call for them)
    assertThat(code).doesNotContain("\"spi-with-defaults.queryAll\"");
    assertThat(code).doesNotContain("\"spi-with-defaults.count\"");
}

// Helper
private static int occurrences(String text, String sub) {
    int count = 0, idx = 0;
    while ((idx = text.indexOf(sub, idx)) != -1) { count++; idx += sub.length(); }
    return count;
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode -pl simulation-generator test -Dtest=SimulationDecoratorProcessorTest`
Expected: `defaultMethodsDelegateWithoutSimulation` FAILS (default methods currently get simulation logic)

- [ ] **Step 4: Implement default method detection in generator**

In `SimulationDecoratorProcessor.java`, split `generateMethod` into two paths based on whether the method is abstract:

```java
// In generateDecoratorSource, replace the method loop:
for (final MethodInfo method : spiClass.methods()) {
    if (method.isSynthetic()) continue;
    if (java.lang.reflect.Modifier.isAbstract(method.flags())) {
        generateSimulatedMethod(sb, method, spiName);
    } else {
        generateDelegatingMethod(sb, method);
    }
}
```

Rename existing `generateMethod` to `generateSimulatedMethod`. Add new `generateDelegatingMethod`:

```java
private void generateDelegatingMethod(final StringBuilder sb, final MethodInfo method) {
    final String returnType = typeToJava(method.returnType());
    final boolean isVoid = method.returnType().kind() == Type.Kind.VOID;

    final StringBuilder params = new StringBuilder();
    final StringBuilder args = new StringBuilder();
    for (int i = 0; i < method.parameterTypes().size(); i++) {
        if (i > 0) { params.append(", "); args.append(", "); }
        final String paramType = typeToJava(method.parameterTypes().get(i));
        final String paramName = method.parameterName(i) != null ? method.parameterName(i) : "arg" + i;
        params.append(paramType).append(" ").append(paramName);
        args.append(paramName);
    }

    sb.append("    @Override\n");
    sb.append("    public ").append(returnType).append(" ").append(method.name());
    sb.append("(").append(params).append(") {\n");
    if (isVoid) {
        sb.append("        delegate.").append(method.name()).append("(").append(args).append(");\n");
    } else {
        sb.append("        return delegate.").append(method.name()).append("(").append(args).append(");\n");
    }
    sb.append("    }\n\n");
}
```

Also update `collectParameterImports` to scan ALL methods (both abstract and default need their types imported since both are generated).

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode -pl simulation-generator test`
Expected: ALL tests PASS (existing tests unchanged, new tests pass)

- [ ] **Step 6: Commit**

```bash
git add simulation-generator/src/
git commit -m "feat(#320): generator distinguishes abstract vs default methods

Abstract methods get simulation/capture logic. Default methods
delegate to the wrapped bean without simulation — prevents bypassing
the real backend's behavior for capabilities, storeAll, and other
default implementations.

Refs #320

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: META-INF/simulation-eligible.txt listing file support

Extend `SimulationDecoratorProcessor` to read `META-INF/simulation-eligible.txt` from the classpath alongside annotation scanning. Each line maps a fully qualified class name to an SPI name:

```
io.casehub.neocortex.memory.CaseMemoryStore=case-memory-store
```

This enables simulation for SPIs in peer repos (neocortex-memory-api) without requiring those repos to depend on `simulation-api`.

**Files:**
- Modify: `simulation-generator/src/main/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessor.java`
- Create: `simulation-generator/src/test/resources/META-INF/simulation-eligible.txt`
- Create: `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/test/TestUnannotatedSpi.java`
- Modify: `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessorTest.java`

**Interfaces:**
- Consumes: `generateFromIndex(IndexView)` from Task 1
- Produces: Updated `generateFromIndex(IndexView)` that merges annotation scan + listing file entries

- [ ] **Step 1: Create unannotated test interface (no @SimulationEligible)**

```java
// simulation-generator/src/test/java/.../test/TestUnannotatedSpi.java
package io.casehub.platform.simulation.generator.test;

public interface TestUnannotatedSpi {

    String resolve(String key);

    int delete(String key);
}
```

- [ ] **Step 2: Create test listing file**

```
# simulation-generator/src/test/resources/META-INF/simulation-eligible.txt
# Test listing — maps unannotated SPIs for simulation
io.casehub.platform.simulation.generator.test.TestUnannotatedSpi=test-unannotated
```

- [ ] **Step 3: Write failing tests**

```java
// Add to SimulationDecoratorProcessorTest.java

// In @BeforeAll, add to indexer:
indexer.indexClass(TestUnannotatedSpi.class);

@Test
void listingFileRegistersUnannotatedSpi() {
    var processor = new SimulationDecoratorProcessor();
    var sources = processor.generateFromIndex(index);

    var classNames = sources.stream()
            .map(SimulationDecoratorProcessor.GeneratedSource::className)
            .toList();

    assertThat(classNames).anyMatch(n -> n.contains("SimulatedTestUnannotatedSpi"));
}

@Test
void listingFileGeneratedDecoratorHasCorrectQualifiedNames() {
    var processor = new SimulationDecoratorProcessor();
    var sources = processor.generateFromIndex(index);
    String code = findSource(sources, "TestUnannotatedSpi");

    assertThat(code).contains("\"test-unannotated.resolve\"");
    assertThat(code).contains("\"test-unannotated.delete\"");
    assertThat(code).contains("implements TestUnannotatedSpi");
}

@Test
void annotationTakesPrecedenceOverListingFile() {
    // If an interface has both @SimulationEligible and a listing entry,
    // the annotation name wins (no duplicate generation)
    var processor = new SimulationDecoratorProcessor();
    var sources = processor.generateFromIndex(index);

    long testServiceCount = sources.stream()
            .filter(s -> s.className().contains("TestSimpleService"))
            .count();
    assertThat(testServiceCount).isEqualTo(1);
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mvn --batch-mode -pl simulation-generator test -Dtest=SimulationDecoratorProcessorTest#listingFileRegistersUnannotatedSpi`
Expected: FAIL — listing file not read yet

- [ ] **Step 5: Implement listing file support**

Add to `SimulationDecoratorProcessor.java`:

```java
private static final String LISTING_FILE = "META-INF/simulation-eligible.txt";

// New method to load listing file entries
private java.util.Map<String, String> loadListingFile() {
    final var entries = new java.util.LinkedHashMap<String, String>();
    try {
        final ClassLoader cl = getClass().getClassLoader();
        final Enumeration<URL> resources = cl.getResources(LISTING_FILE);
        while (resources.hasMoreElements()) {
            final URL url = resources.nextElement();
            try (var reader = new java.io.BufferedReader(
                    new java.io.InputStreamReader(url.openStream()))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    line = line.strip();
                    if (line.isEmpty() || line.startsWith("#")) continue;
                    final int eq = line.indexOf('=');
                    if (eq < 0) continue;
                    entries.put(line.substring(0, eq).strip(), line.substring(eq + 1).strip());
                }
            }
        }
    } catch (IOException e) {
        if (processingEnv != null) {
            processingEnv.getMessager().printMessage(Diagnostic.Kind.WARNING,
                    "Simulation generator: failed to read listing file: " + e.getMessage());
        }
    }
    return entries;
}
```

Update `generateFromIndex` to merge both sources:

```java
List<GeneratedSource> generateFromIndex(final IndexView index) {
    final List<GeneratedSource> results = new ArrayList<>();
    final Set<String> processedClasses = new HashSet<>();

    // 1. Annotation scan (takes precedence)
    for (final AnnotationInstance ann : index.getAnnotations(SIMULATION_ELIGIBLE)) {
        if (ann.target().kind() != AnnotationTarget.Kind.CLASS) continue;
        final ClassInfo classInfo = ann.target().asClass();
        if (!java.lang.reflect.Modifier.isInterface(classInfo.flags())) continue;

        processedClasses.add(classInfo.name().toString());

        final AnnotationValue nameVal = ann.value("name");
        final String spiName = (nameVal != null && !nameVal.asString().isEmpty())
                ? nameVal.asString()
                : toKebabCase(classInfo.simpleName());

        final String decoratorName = "Simulated" + classInfo.simpleName();
        final String fqcn = GENERATED_PACKAGE + "." + decoratorName;
        final String source = generateDecoratorSource(classInfo, spiName, decoratorName);
        results.add(new GeneratedSource(fqcn, source));
    }

    // 2. Listing file (skips classes already processed via annotation)
    final var listingEntries = loadListingFile();
    for (final var entry : listingEntries.entrySet()) {
        final String className = entry.getKey();
        if (processedClasses.contains(className)) continue;

        final ClassInfo classInfo = index.getClassByName(DotName.createSimple(className));
        if (classInfo == null) {
            if (processingEnv != null) {
                processingEnv.getMessager().printMessage(Diagnostic.Kind.WARNING,
                        "Simulation generator: class " + className
                                + " from listing file not found in Jandex index");
            }
            continue;
        }
        if (!java.lang.reflect.Modifier.isInterface(classInfo.flags())) continue;

        final String spiName = entry.getValue();
        final String decoratorName = "Simulated" + classInfo.simpleName();
        final String fqcn = GENERATED_PACKAGE + "." + decoratorName;
        final String source = generateDecoratorSource(classInfo, spiName, decoratorName);
        results.add(new GeneratedSource(fqcn, source));
    }

    return results;
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode -pl simulation-generator test`
Expected: ALL tests PASS

- [ ] **Step 7: Commit**

```bash
git add simulation-generator/src/
git commit -m "feat(#320): generator reads META-INF/simulation-eligible.txt

SPIs in peer repos (e.g. CaseMemoryStore in neocortex-memory-api)
cannot depend on simulation-api for @SimulationEligible. The listing
file maps FQCN=spi-name, resolved via Jandex index. Annotation takes
precedence when both are present.

Refs #320

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 2: CaseMemoryStore simulation module

### Task 3: Create memory-simulation-core module

New module that:
1. Lists CaseMemoryStore in `META-INF/simulation-eligible.txt`
2. Has simulation-generator as an annotation processor
3. Depends on neocortex-memory-api (provides CaseMemoryStore Jandex index)
4. The generated `SimulatedCaseMemoryStore` decorator is compiled into this module's JAR

**Files:**
- Create: `memory-simulation-core/pom.xml`
- Create: `memory-simulation-core/src/main/resources/META-INF/simulation-eligible.txt`
- Modify: `pom.xml` (root — add module)

**Interfaces:**
- Consumes: `SimulationDecoratorProcessor` listing file support from Task 2
- Produces: `io.casehub.platform.simulation.generated.SimulatedCaseMemoryStore` (generated at compile time)

- [ ] **Step 1: Create module pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-memory-simulation-core</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Memory Simulation Core</name>
    <description>Generated @Decorator for CaseMemoryStore simulation.
        Path A consumer — decorator generated by simulation-generator from
        META-INF/simulation-eligible.txt listing. Add to classpath to enable
        simulation/capture for CaseMemoryStore.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-neocortex-memory-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-core</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>jakarta.enterprise</groupId>
            <artifactId>jakarta.enterprise.cdi-api</artifactId>
        </dependency>
        <dependency>
            <groupId>jakarta.interceptor</groupId>
            <artifactId>jakarta.interceptor-api</artifactId>
        </dependency>

        <!-- Test -->
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-inmem</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-testing</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
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
                <artifactId>maven-compiler-plugin</artifactId>
                <configuration>
                    <annotationProcessorPaths>
                        <path>
                            <groupId>io.casehub</groupId>
                            <artifactId>casehub-platform-simulation-generator</artifactId>
                            <version>${project.version}</version>
                        </path>
                        <path>
                            <groupId>io.casehub</groupId>
                            <artifactId>casehub-platform-simulation-api</artifactId>
                            <version>${project.version}</version>
                        </path>
                    </annotationProcessorPaths>
                </configuration>
            </plugin>
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

- [ ] **Step 2: Create listing file**

```
# memory-simulation-core/src/main/resources/META-INF/simulation-eligible.txt
io.casehub.neocortex.memory.CaseMemoryStore=case-memory-store
```

- [ ] **Step 3: Add module to root pom.xml**

Add `<module>memory-simulation-core</module>` after `simulation-config` in the `<modules>` section.

- [ ] **Step 4: Compile to verify decorator generation**

Run: `mvn --batch-mode -pl memory-simulation-core compile`
Expected: Compiles successfully. Log message: `Simulation generator: generated io.casehub.platform.simulation.generated.SimulatedCaseMemoryStore`

Verify the generated source exists:
```bash
find memory-simulation-core/target/generated-sources -name "SimulatedCaseMemoryStore.java"
```

- [ ] **Step 5: Inspect generated decorator for correctness**

Read the generated file and verify:
- `@Decorator` and `@Priority(APPLICATION + 200)` annotations present
- `implements CaseMemoryStore`
- `store(MemoryInput)` has simulation strategy check + capture
- `query(MemoryQuery)` has simulation strategy check + capture
- `erase(EraseRequest)` has simulation strategy check + capture
- `storeAll(...)` delegates to `delegate.storeAll(...)` (no simulation)
- `capabilities()` delegates to `delegate.capabilities()` (no simulation)
- `eraseSubject(...)` delegates to `delegate.eraseSubject(...)` (no simulation)
- All other default methods delegate without simulation

If the generated code has issues, fix the generator and re-run.

- [ ] **Step 6: Commit**

```bash
git add memory-simulation-core/ pom.xml
git commit -m "feat(#320): memory-simulation-core module — generated CaseMemoryStore decorator

New module with META-INF/simulation-eligible.txt listing.
SimulatedCaseMemoryStore @Decorator generated at compile time.
Abstract methods (store/query/erase) get simulation/capture.
Default methods delegate to wrapped bean.

Refs #320

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4: Integration test — CaseMemoryStore simulation end-to-end

Plain JUnit test that manually wires the generated decorator with a mock backend, SimulationRuntime, and InMemorySimulationCorpus. Verifies:
1. Strategy resolution intercepts `query()` and returns corpus data
2. Capture mode records `store()` invocations to corpus
3. Passthrough mode delegates to backend when no strategy configured
4. Default methods delegate to backend without simulation

**Files:**
- Create: `memory-simulation-core/src/test/java/io/casehub/platform/simulation/memory/SimulatedCaseMemoryStoreTest.java`

**Interfaces:**
- Consumes: `io.casehub.platform.simulation.generated.SimulatedCaseMemoryStore` from Task 3
- Consumes: `SimulationRuntime` from simulation-core
- Consumes: `InMemorySimulationCorpus` from simulation-inmem

- [ ] **Step 1: Write test class with helper setup**

```java
package io.casehub.platform.simulation.memory;

import io.casehub.neocortex.memory.*;
import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.identity.PrincipalId;
import io.casehub.platform.simulation.*;
import io.casehub.platform.simulation.inmem.InMemorySimulationCorpus;
import io.casehub.platform.simulation.generated.SimulatedCaseMemoryStore;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;

class SimulatedCaseMemoryStoreTest {

    private InMemorySimulationCorpus<Object, Object> corpus;
    private SimulationRuntime runtime;
    private StubCaseMemoryStore delegate;
    private SimulatedCaseMemoryStore decorator;

    // Minimal stub backend
    static class StubCaseMemoryStore implements CaseMemoryStore {
        final List<MemoryInput> stored = new ArrayList<>();

        @Override
        public String store(MemoryInput input) {
            stored.add(input);
            return "stub-id-" + stored.size();
        }

        @Override
        public List<Memory> query(MemoryQuery query) {
            return List.of(new Memory("m1", Subject.of("user", "e1"),
                    MemoryDomain.of("test"), query.tenantId(), null,
                    "stub response", Map.of(), Instant.now(),
                    null, null, null, null, null, Set.of()));
        }

        @Override
        public int erase(EraseRequest request) {
            return 1;
        }

        @Override
        public Set<MemoryCapability> capabilities() {
            return Set.of(MemoryCapability.CHRONOLOGICAL_ORDER,
                    MemoryCapability.DOMAIN_SCOPED);
        }
    }

    static class StubPrincipal implements CurrentPrincipal {
        @Override public String actorId() { return "test-actor"; }
        @Override public String tenancyId() { return "tenant-1"; }
        @Override public PrincipalId principalId() { return PrincipalId.of("test-actor"); }
    }

    @BeforeEach
    void setUp() {
        corpus = new InMemorySimulationCorpus<>();
        delegate = new StubCaseMemoryStore();
    }
}
```

- [ ] **Step 2: Write test — strategy intercepts query**

```java
@Test
void queryWithStrategyReturnsCorpusData() {
    var config = new MapSimulationConfig(
            Map.of("case-memory-store.query", "sequential"));
    runtime = new SimulationRuntime(config, corpus);

    var expectedMemory = new Memory("sim-1", Subject.of("user", "e1"),
            MemoryDomain.of("test"), "tenant-1", null,
            "simulated response", Map.of(), Instant.now(),
            null, null, null, null, null, Set.of());
    corpus.seed("case-memory-store.query",
            List.of(new InvocationRecord<>("tenant-1", null,
                    null, List.of(expectedMemory), Instant.now())));

    decorator = createDecorator();

    var query = new MemoryQuery(
            List.of(Subject.of("user", "e1")),
            MemoryDomain.of("test"), "tenant-1", null, null,
            10, null, MemoryOrder.CHRONOLOGICAL, null);

    List<Memory> result = decorator.query(query);

    assertThat(result).hasSize(1);
    assertThat(result.get(0).text()).isEqualTo("simulated response");
    assertThat(delegate.stored).isEmpty(); // delegate not called
}
```

- [ ] **Step 3: Write test — passthrough without strategy**

```java
@Test
void queryWithoutStrategyDelegatesToBackend() {
    var config = new MapSimulationConfig(Map.of());
    runtime = new SimulationRuntime(config, corpus);
    decorator = createDecorator();

    var query = new MemoryQuery(
            List.of(Subject.of("user", "e1")),
            MemoryDomain.of("test"), "tenant-1", null, null,
            10, null, MemoryOrder.CHRONOLOGICAL, null);

    List<Memory> result = decorator.query(query);

    assertThat(result).hasSize(1);
    assertThat(result.get(0).text()).isEqualTo("stub response");
}
```

- [ ] **Step 4: Write test — capture mode records invocations**

```java
@Test
void storeWithCaptureRecordsToCorpus() {
    var config = new MapSimulationConfig(Map.of(),
            Set.of("case-memory-store.store"));
    runtime = new SimulationRuntime(config, corpus);
    decorator = createDecorator();

    var input = new MemoryInput(
            Subject.of("user", "e1"), MemoryDomain.of("test"),
            "tenant-1", null, "test memory",
            Map.of(), null, null, null, null, null, null);

    String id = decorator.store(input);

    assertThat(id).isEqualTo("stub-id-1");
    assertThat(delegate.stored).hasSize(1);
    assertThat(corpus.list("case-memory-store.store")).hasSize(1);
}
```

- [ ] **Step 5: Write test — default methods delegate to backend**

```java
@Test
void capabilitiesDelegatesToBackend() {
    var config = new MapSimulationConfig(Map.of());
    runtime = new SimulationRuntime(config, corpus);
    decorator = createDecorator();

    Set<MemoryCapability> caps = decorator.capabilities();

    assertThat(caps).containsExactlyInAnyOrder(
            MemoryCapability.CHRONOLOGICAL_ORDER,
            MemoryCapability.DOMAIN_SCOPED);
}
```

- [ ] **Step 6: Add helper — MapSimulationConfig + createDecorator**

```java
// Inner class for test config
static class MapSimulationConfig implements SimulationConfig {
    private final Map<String, String> strategies;
    private final Set<String> captures;

    MapSimulationConfig(Map<String, String> strategies) {
        this(strategies, Set.of());
    }

    MapSimulationConfig(Map<String, String> strategies, Set<String> captures) {
        this.strategies = strategies;
        this.captures = captures;
    }

    @Override
    public Optional<String> strategyFor(String qualifiedName) {
        return Optional.ofNullable(strategies.get(qualifiedName));
    }

    @Override
    public boolean captureEnabled(String qualifiedName) {
        return captures.contains(qualifiedName);
    }

    @Override
    public Optional<ExhaustionPolicy> exhaustionPolicy(String qualifiedName) {
        return Optional.empty();
    }
}

// Reflective helper to wire the generated decorator without CDI
private SimulatedCaseMemoryStore createDecorator() {
    try {
        var ctor = SimulatedCaseMemoryStore.class.getDeclaredConstructor();
        ctor.setAccessible(true);
        var instance = ctor.newInstance();

        var delegateField = SimulatedCaseMemoryStore.class.getDeclaredField("delegate");
        delegateField.setAccessible(true);
        delegateField.set(instance, delegate);

        var simField = SimulatedCaseMemoryStore.class.getDeclaredField("simulation");
        simField.setAccessible(true);
        simField.set(instance, runtime);

        var principalField = SimulatedCaseMemoryStore.class.getDeclaredField("currentPrincipal");
        principalField.setAccessible(true);
        principalField.set(instance, new StubPrincipal());

        return instance;
    } catch (Exception e) {
        throw new RuntimeException("Failed to create decorator", e);
    }
}
```

- [ ] **Step 7: Run tests**

Run: `mvn --batch-mode -pl memory-simulation-core test`
Expected: ALL tests PASS

- [ ] **Step 8: Commit**

```bash
git add memory-simulation-core/src/test/
git commit -m "test(#320): SimulatedCaseMemoryStore integration tests

Verifies strategy interception, capture recording, passthrough
delegation, and default method delegation for generated decorator.

Refs #320

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 9: Update CLAUDE.md and simulation guide**

Add `memory-simulation-core` module entry to CLAUDE.md `## Modules` section.
Add listing file mechanism to `docs/guides/simulation-guide.md`.

- [ ] **Step 10: Full build verification**

Run: `mvn --batch-mode install`
Expected: Full build passes including all existing tests

- [ ] **Step 11: Final commit**

```bash
git add CLAUDE.md docs/guides/simulation-guide.md
git commit -m "docs(#320): add memory-simulation-core to CLAUDE.md, listing file to guide

Refs #320

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## References

- [2026-09-15-simulation-service-design.md] — design spec (Path A decorator, generator architecture)
- [decisions.md] — D4 (generated @Decorator), D6 (NoOps untouched), D7 (key extraction)
- [SimulationDecoratorProcessor.java] — existing generator
- [CallbackDecoratorProcessor.java] — sibling generator precedent
- [CaseMemoryStore.java (neocortex-memory-api)] — target SPI interface
- [InMemoryMemoryStore.java] — reference implementation (method signatures)
- [SimulationRuntime.java] — strategy resolution runtime
- [neocortex#56] — CaseMemoryStore migration from platform-api to neocortex-memory-api
- [GE-20260818-2589ee] — CDI @Decorator must implement all abstract methods
- [GitHub #320] — focal issue
