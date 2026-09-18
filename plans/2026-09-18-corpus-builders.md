# Domain-Specific Corpus Builders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #328 — feat: domain-specific corpus builders — test data factories per SPI
**Issue group:** #328

**Goal:** Make corpus seeding ergonomic with typed convenience factories, auto-key derivation, and LLM-based generation.

**Architecture:** Composition over inheritance — `CorpusSeed<I,O>` (final concrete class in simulation-api) accumulates typed records; per-SPI descriptor classes (static utility classes in simulation-testing) provide domain factories and extractors; `LlmCorpusPopulator` generates entries via LLM with JSON Schema prompts. Generator enhanced to emit `*QN` companion constants classes for compile-time qualified name safety.

**Tech Stack:** Java 21, Maven, JUnit 5, AssertJ, Jandex, Jackson, PlatformSchemaGenerator

## Global Constraints

- simulation-api must remain zero-dependency (no Quarkus, no Jackson, no casehubio imports)
- CorpusSeed lives in simulation-api — depends only on SimulationCorpus, InvocationRecord, KeyExtractor (all in simulation-api)
- simulation-testing depends on simulation-api + platform-api + platform-simulation-core (generated QN constants) + schema-generator + jackson-databind
- agent-simulation-core has no CDI annotations — POJO only
- All qualified name strings in descriptors come from generated `*QN` constants, never hand-authored
- `seedInto(corpus)` is data-only — extractor registration is a separate explicit call

---

## Batch 1: Core types — CorpusSeed and InvocationRecord factories

After this batch: consumers can use `InvocationRecord.of()` and `CorpusSeed` to seed corpora without boilerplate. No descriptors yet — raw usage only.

### Task 1: InvocationRecord.of() convenience factories

**Files:**
- Modify: `simulation-api/src/main/java/io/casehub/platform/simulation/InvocationRecord.java`
- Create: `simulation-api/src/test/java/io/casehub/platform/simulation/InvocationRecordFactoryTest.java`

**Interfaces:**
- Consumes: nothing new
- Produces: `InvocationRecord.of(String tenancyId, I input, O output)` → `InvocationRecord<I, O>`, `InvocationRecord.of(String tenancyId, String key, I input, O output)` → `InvocationRecord<I, O>`

- [ ] **Step 1: Write the failing test**

```java
package io.casehub.platform.simulation;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class InvocationRecordFactoryTest {

    @Test
    void ofWithoutKeyDefaultsKeyToNull() {
        InvocationRecord<String, Integer> record = InvocationRecord.of("tenant-1", "hello", 42);
        assertThat(record.tenancyId()).isEqualTo("tenant-1");
        assertThat(record.input()).isEqualTo("hello");
        assertThat(record.output()).isEqualTo(42);
        assertThat(record.key()).isNull();
        assertThat(record.recordedAt()).isNotNull();
    }

    @Test
    void ofWithKeyPreservesKey() {
        InvocationRecord<String, Integer> record = InvocationRecord.of("tenant-1", "my-key", "hello", 42);
        assertThat(record.tenancyId()).isEqualTo("tenant-1");
        assertThat(record.key()).isEqualTo("my-key");
        assertThat(record.input()).isEqualTo("hello");
        assertThat(record.output()).isEqualTo(42);
        assertThat(record.recordedAt()).isNotNull();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl simulation-api -Dtest=InvocationRecordFactoryTest`
Expected: FAIL — `of` method not found

- [ ] **Step 3: Add factory methods to InvocationRecord**

Use `ide_insert_member` to add to `InvocationRecord.java`:

```java
public static <I, O> InvocationRecord<I, O> of(String tenancyId, I input, O output) {
    return new InvocationRecord<>(tenancyId, null, input, output, java.time.Instant.now());
}

public static <I, O> InvocationRecord<I, O> of(String tenancyId, String key, I input, O output) {
    return new InvocationRecord<>(tenancyId, key, input, output, java.time.Instant.now());
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl simulation-api -Dtest=InvocationRecordFactoryTest`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add simulation-api/src/main/java/io/casehub/platform/simulation/InvocationRecord.java simulation-api/src/test/java/io/casehub/platform/simulation/InvocationRecordFactoryTest.java
git commit -m "feat(#328): add InvocationRecord.of() convenience factories

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: CorpusSeed<I,O> — typed corpus accumulator

**Files:**
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/CorpusSeed.java`
- Create: `simulation-api/src/test/java/io/casehub/platform/simulation/CorpusSeedTest.java`

**Interfaces:**
- Consumes: `InvocationRecord.of()` (Task 1), `SimulationCorpus.seed()`, `KeyExtractor<I>`
- Produces: `CorpusSeed(String qualifiedName, String defaultTenancyId)`, `.withKeyExtractor(KeyExtractor<I>)` → `CorpusSeed<I,O>`, `.withOutputMapper(Function<I,O>)` → `CorpusSeed<I,O>`, `.add(I input, O output)` → `CorpusSeed<I,O>`, `.add(String key, I input, O output)` → `CorpusSeed<I,O>`, `.add(String tenancyId, String key, I input, O output)` → `CorpusSeed<I,O>`, `.add(I input)` → `CorpusSeed<I,O>` (requires outputMapper), `.seedInto(SimulationCorpus<I,O>)` → void, `.build()` → `List<InvocationRecord<I,O>>`, `.qualifiedName()` → String, `.keyExtractor()` → `KeyExtractor<I>`

- [ ] **Step 1: Write the failing tests**

```java
package io.casehub.platform.simulation;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Function;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class CorpusSeedTest {

    @Test
    void addAccumulatesRecords() {
        var seed = new CorpusSeed<String, Integer>("spi.method", "tenant-1");
        seed.add("hello", 1);
        seed.add("world", 2);

        List<InvocationRecord<String, Integer>> records = seed.build();
        assertThat(records).hasSize(2);
        assertThat(records.get(0).tenancyId()).isEqualTo("tenant-1");
        assertThat(records.get(0).input()).isEqualTo("hello");
        assertThat(records.get(0).output()).isEqualTo(1);
        assertThat(records.get(0).key()).isNull();
    }

    @Test
    void withKeyExtractorAutoDerivesKeys() {
        var seed = new CorpusSeed<String, Integer>("spi.method", "tenant-1")
            .withKeyExtractor(String::toUpperCase);
        seed.add("hello", 1);

        assertThat(seed.build().get(0).key()).isEqualTo("HELLO");
    }

    @Test
    void addWithExplicitKeyOverridesExtractor() {
        var seed = new CorpusSeed<String, Integer>("spi.method", "tenant-1")
            .withKeyExtractor(String::toUpperCase);
        seed.add("my-key", "hello", 1);

        assertThat(seed.build().get(0).key()).isEqualTo("my-key");
    }

    @Test
    void addWithTenantOverridesDefault() {
        var seed = new CorpusSeed<String, Integer>("spi.method", "tenant-1");
        seed.add("tenant-2", "key", "hello", 1);

        assertThat(seed.build().get(0).tenancyId()).isEqualTo("tenant-2");
    }

    @Test
    void withOutputMapperEnablesSingleArgAdd() {
        var seed = new CorpusSeed<String, String>("spi.method", "tenant-1")
            .withOutputMapper(s -> s.toUpperCase());
        seed.add("hello");

        assertThat(seed.build().get(0).output()).isEqualTo("HELLO");
    }

    @Test
    void addWithoutOutputMapperThrows() {
        var seed = new CorpusSeed<String, String>("spi.method", "tenant-1");

        assertThatThrownBy(() -> seed.add("hello"))
            .isInstanceOf(IllegalStateException.class)
            .hasMessageContaining("withOutputMapper");
    }

    @Test
    void outputMapperAndKeyExtractorBothOperateOnRawInput() {
        var seed = new CorpusSeed<String, String>("spi.method", "tenant-1")
            .withKeyExtractor(String::toUpperCase)
            .withOutputMapper(s -> "out:" + s);
        seed.add("hello");

        var record = seed.build().get(0);
        assertThat(record.key()).isEqualTo("HELLO");
        assertThat(record.output()).isEqualTo("out:hello");
    }

    @Test
    void seedIntoCallsCorpusSeed() {
        var seed = new CorpusSeed<String, Integer>("spi.method", "tenant-1");
        seed.add("hello", 1);

        var seeded = new AtomicReference<List<InvocationRecord<String, Integer>>>();
        SimulationCorpus<String, Integer> corpus = new SimulationCorpus<>() {
            @Override public Optional<Integer> lookupByKey(String qn, String key) { return Optional.empty(); }
            @Override public Optional<Integer> lookupByIndex(String qn, int index) { return Optional.empty(); }
            @Override public List<InvocationRecord<String, Integer>> list(String qn) { return List.of(); }
            @Override public List<InvocationRecord<String, Integer>> listByTenant(String qn, String t) { return List.of(); }
            @Override public void record(String qn, String t, String i, Integer o) {}
            @Override public void record(String qn, String t, String k, String i, Integer o) {}
            @Override public void seed(String qn, List<InvocationRecord<String, Integer>> records) { seeded.set(records); }
            @Override public void clear(String qn) {}
            @Override public int size(String qn) { return 0; }
        };

        seed.seedInto(corpus);
        assertThat(seeded.get()).hasSize(1);
        assertThat(seeded.get().get(0).input()).isEqualTo("hello");
    }

    @Test
    void qualifiedNameAndKeyExtractorAccessible() {
        KeyExtractor<String> extractor = String::length;
        var seed = new CorpusSeed<String, Integer>("spi.method", "tenant-1")
            .withKeyExtractor(extractor);

        assertThat(seed.qualifiedName()).isEqualTo("spi.method");
        assertThat(seed.keyExtractor()).isSameAs(extractor);
    }

    @Test
    void buildReturnsImmutableCopy() {
        var seed = new CorpusSeed<String, Integer>("spi.method", "tenant-1");
        seed.add("hello", 1);
        List<InvocationRecord<String, Integer>> built = seed.build();

        seed.add("world", 2);
        assertThat(built).hasSize(1);
    }

    @Test
    void addReturnsSeedForChaining() {
        var seed = new CorpusSeed<String, Integer>("spi.method", "tenant-1");
        var result = seed.add("hello", 1).add("world", 2);
        assertThat(result).isSameAs(seed);
        assertThat(seed.build()).hasSize(2);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-api -Dtest=CorpusSeedTest`
Expected: FAIL — CorpusSeed class not found

- [ ] **Step 3: Implement CorpusSeed**

Create `simulation-api/src/main/java/io/casehub/platform/simulation/CorpusSeed.java`:

```java
package io.casehub.platform.simulation;

import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.function.Function;

public final class CorpusSeed<I, O> {

    private final String qualifiedName;
    private final String defaultTenancyId;
    private final List<InvocationRecord<I, O>> records = new ArrayList<>();
    private KeyExtractor<I> keyExtractor;
    private Function<I, O> outputMapper;

    public CorpusSeed(String qualifiedName, String defaultTenancyId) {
        this.qualifiedName = Objects.requireNonNull(qualifiedName);
        this.defaultTenancyId = Objects.requireNonNull(defaultTenancyId);
    }

    public CorpusSeed<I, O> withKeyExtractor(KeyExtractor<I> extractor) {
        this.keyExtractor = extractor;
        return this;
    }

    public CorpusSeed<I, O> withOutputMapper(Function<I, O> mapper) {
        this.outputMapper = mapper;
        return this;
    }

    public CorpusSeed<I, O> add(I input, O output) {
        String key = keyExtractor != null ? keyExtractor.extract(input) : null;
        records.add(InvocationRecord.of(defaultTenancyId, key, input, output));
        return this;
    }

    public CorpusSeed<I, O> add(String key, I input, O output) {
        records.add(InvocationRecord.of(defaultTenancyId, key, input, output));
        return this;
    }

    public CorpusSeed<I, O> add(String tenancyId, String key, I input, O output) {
        records.add(InvocationRecord.of(tenancyId, key, input, output));
        return this;
    }

    public CorpusSeed<I, O> add(I input) {
        if (outputMapper == null) {
            throw new IllegalStateException(
                "add(input) requires withOutputMapper() — call add(input, output) instead");
        }
        return add(input, outputMapper.apply(input));
    }

    public void seedInto(SimulationCorpus<I, O> corpus) {
        corpus.seed(qualifiedName, List.copyOf(records));
    }

    public List<InvocationRecord<I, O>> build() {
        return List.copyOf(records);
    }

    public String qualifiedName() {
        return qualifiedName;
    }

    public KeyExtractor<I> keyExtractor() {
        return keyExtractor;
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-api -Dtest=CorpusSeedTest`
Expected: PASS (all 10 tests)

- [ ] **Step 5: Run full simulation-api tests**

Run: `mvn --batch-mode test -pl simulation-api`
Expected: PASS (no regressions)

- [ ] **Step 6: Commit**

```bash
git add simulation-api/src/main/java/io/casehub/platform/simulation/CorpusSeed.java simulation-api/src/test/java/io/casehub/platform/simulation/CorpusSeedTest.java
git commit -m "feat(#328): add CorpusSeed<I,O> typed corpus accumulator

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: Generator enhancement — QN companion constants

After this batch: `SimulationDecoratorProcessor` generates `*QN` constants classes alongside decorators. Rebuilding platform-simulation-core produces `AccessControlProviderQN`, `NotificationStoreQN`, etc.

### Task 3: Generate qualified name constants classes

**Files:**
- Modify: `simulation-generator/src/main/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessor.java`
- Modify: `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessorTest.java`

**Interfaces:**
- Consumes: Jandex `ClassInfo`, `MethodInfo`, `spiName` (existing)
- Produces: generated `*QN` classes in `io.casehub.platform.simulation.generated` package. Each class: `public final class <SpiSimpleName>QN { public static final String <METHOD_NAME_UPPER> = "<spiName>.<methodName>"; ... private <SpiSimpleName>QN() {} }`

- [ ] **Step 1: Write the failing test**

Add to `SimulationDecoratorProcessorTest.java`:

```java
@Test
void generatesQNConstantsClassForAnnotatedInterface() {
    final var processor = new SimulationDecoratorProcessor();
    final List<SimulationDecoratorProcessor.GeneratedSource> sources = processor.generateFromIndex(index);

    final List<String> classNames = sources.stream()
            .map(SimulationDecoratorProcessor.GeneratedSource::className)
            .toList();

    assertThat(classNames).anyMatch(n -> n.contains("TestSimpleServiceQN"));
}

@Test
void qnConstantsClassContainsMethodConstants() {
    final var processor = new SimulationDecoratorProcessor();
    final List<SimulationDecoratorProcessor.GeneratedSource> sources = processor.generateFromIndex(index);

    final String code = findSource(sources, "TestSimpleServiceQN");

    assertThat(code).contains("public static final String LOOKUP = \"test-service.lookup\"");
    assertThat(code).contains("public static final String SAVE = \"test-service.save\"");
    assertThat(code).contains("public static final String COUNT = \"test-service.count\"");
    assertThat(code).contains("private TestSimpleServiceQN()");
}

@Test
void qnConstantsClassGeneratedForListingFileEntries() {
    final var processor = new SimulationDecoratorProcessor();
    final List<SimulationDecoratorProcessor.GeneratedSource> sources = processor.generateFromIndex(index);

    final List<String> classNames = sources.stream()
            .map(SimulationDecoratorProcessor.GeneratedSource::className)
            .toList();

    assertThat(classNames).anyMatch(n -> n.contains("TestUnannotatedSpiQN"));
}

@Test
void qnListingFileClassHasCorrectConstants() {
    final var processor = new SimulationDecoratorProcessor();
    final List<SimulationDecoratorProcessor.GeneratedSource> sources = processor.generateFromIndex(index);

    final String code = findSource(sources, "TestUnannotatedSpiQN");

    assertThat(code).contains("public static final String RESOLVE = \"test-unannotated.resolve\"");
    assertThat(code).contains("public static final String DELETE = \"test-unannotated.delete\"");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-generator -Dtest=SimulationDecoratorProcessorTest`
Expected: FAIL — no QN classes generated

- [ ] **Step 3: Add generateQNSource method to SimulationDecoratorProcessor**

Use `ide_insert_member` to add after `generateDecoratorSource`:

```java
private String generateQNSource(final ClassInfo spiClass, final String spiName) {
    final StringBuilder sb = new StringBuilder();
    final String qnClassName = spiClass.simpleName() + "QN";

    sb.append("package ").append(GENERATED_PACKAGE).append(";\n\n");
    sb.append("// GENERATED by SimulationDecoratorProcessor — do not edit\n");
    sb.append("public final class ").append(qnClassName).append(" {\n\n");

    for (final MethodInfo method : spiClass.methods()) {
        if (method.isSynthetic()) continue;
        final String constName = method.name().toUpperCase();
        final String qualifiedName = spiName + "." + method.name();
        sb.append("    public static final String ").append(constName)
          .append(" = \"").append(qualifiedName).append("\";\n");
    }

    sb.append("\n    private ").append(qnClassName).append("() {}\n");
    sb.append("}\n");
    return sb.toString();
}
```

- [ ] **Step 4: Wire QN generation into generateFromIndex**

In the `generateFromIndex` method, after each `generateDecoratorSource` call, also generate the QN class. Modify both the annotation-scanned loop and the listing-file loop to add a second `GeneratedSource`:

After the line `results.add(new GeneratedSource(fqcn, source));` in the annotation loop, add:
```java
final String qnName = GENERATED_PACKAGE + "." + classInfo.simpleName() + "QN";
final String qnSource = generateQNSource(classInfo, spiName);
results.add(new GeneratedSource(qnName, qnSource));
```

Same pattern in the listing-file loop after its `results.add(...)`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-generator -Dtest=SimulationDecoratorProcessorTest`
Expected: PASS (all tests including new QN tests)

- [ ] **Step 6: Rebuild platform-simulation-core to verify QN generation end-to-end**

Run: `mvn --batch-mode install -pl simulation-generator && mvn --batch-mode compile -pl platform-simulation-core`
Expected: BUILD SUCCESS — generated QN classes appear in `platform-simulation-core/target/generated-sources/`

Verify: `find platform-simulation-core/target -name "*QN.java" -type f` should list 11 QN classes (one per SPI in simulation-eligible.txt).

- [ ] **Step 7: Commit**

```bash
git add simulation-generator/src/main/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessor.java simulation-generator/src/test/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessorTest.java
git commit -m "feat(#328): generator emits *QN qualified name constants classes

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 3: simulation-testing module and descriptors

After this batch: consumers can add `simulation-testing` as a test dependency and use the per-SPI descriptor mini-DSLs. LLM corpus generation available.

### Task 4: simulation-testing module scaffolding + AclCorpus descriptor

**Files:**
- Create: `simulation-testing/pom.xml`
- Modify: `pom.xml` (parent — add `<module>simulation-testing</module>`)
- Create: `simulation-testing/src/main/java/io/casehub/platform/simulation/testing/AclCorpus.java`
- Create: `simulation-testing/src/test/java/io/casehub/platform/simulation/testing/AclCorpusTest.java`

**Interfaces:**
- Consumes: `CorpusSeed` (Task 2), `AccessControlProviderQN` (Task 3 — generated in platform-simulation-core), `ResourceId`, `AclAction` (platform-api)
- Produces: `AclCorpus.canAccess(String tenancyId)` → `CorpusSeed<Object[], Boolean>`, `AclCorpus.check(String actorId, ResourceId resourceId, AclAction action)` → `Object[]`, `AclCorpus.resource(String type, String id)` → `ResourceId`, `AclCorpus.canAccessExtractor()` → `KeyExtractor<Object[]>`

- [ ] **Step 1: Create module pom.xml**

Create `simulation-testing/pom.xml`:

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

    <artifactId>casehub-platform-simulation-testing</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Simulation Testing</name>
    <description>Per-SPI corpus descriptor classes and LLM corpus populator.
        Test-scope convenience for seeding simulation corpora with typed domain data.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-platform-simulation-core</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-schema-generator</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.core</groupId>
            <artifactId>jackson-databind</artifactId>
        </dependency>

        <!-- Test -->
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

</project>
```

- [ ] **Step 2: Add module to parent pom.xml**

Add `<module>simulation-testing</module>` after `<module>platform-simulation-core</module>` in the parent pom.xml modules list. This ensures build order: simulation-generator → platform-simulation-core (generates QN) → simulation-testing (imports QN).

- [ ] **Step 3: Write the failing AclCorpus test**

```java
package io.casehub.platform.simulation.testing;

import io.casehub.platform.api.acl.AclAction;
import io.casehub.platform.api.acl.ResourceId;
import io.casehub.platform.simulation.CorpusSeed;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class AclCorpusTest {

    @Test
    void canAccessReturnsPreConfiguredSeed() {
        CorpusSeed<Object[], Boolean> seed = AclCorpus.canAccess("tenant-1");
        assertThat(seed.qualifiedName()).isEqualTo("access-control-provider.canAccess");
        assertThat(seed.keyExtractor()).isNotNull();
    }

    @Test
    void checkConstructsObjectArray() {
        Object[] input = AclCorpus.check("admin", new ResourceId("case", "c-1"), AclAction.WRITE);
        assertThat(input).hasSize(3);
        assertThat(input[0]).isEqualTo("admin");
        assertThat(input[1]).isEqualTo(new ResourceId("case", "c-1"));
        assertThat(input[2]).isEqualTo(AclAction.WRITE);
    }

    @Test
    void resourceConstructsResourceId() {
        ResourceId id = AclCorpus.resource("case", "c-1");
        assertThat(id.type()).isEqualTo("case");
        assertThat(id.id()).isEqualTo("c-1");
    }

    @Test
    void keyExtractorDerivesConsistentKey() {
        Object[] input = AclCorpus.check("admin", AclCorpus.resource("case", "c-1"), AclAction.WRITE);
        String key = AclCorpus.canAccessExtractor().extract(input);
        assertThat(key).isEqualTo("admin:case:c-1:WRITE");
    }

    @Test
    void endToEndSeedAccumulation() {
        var seed = AclCorpus.canAccess("hospital-a");
        seed.add(AclCorpus.check("admin", AclCorpus.resource("case", "c-1"), AclAction.WRITE), true);
        seed.add(AclCorpus.check("nurse", AclCorpus.resource("case", "c-1"), AclAction.READ), true);

        assertThat(seed.build()).hasSize(2);
        assertThat(seed.build().get(0).output()).isTrue();
        assertThat(seed.build().get(1).output()).isTrue();
    }
}
```

- [ ] **Step 4: Implement AclCorpus**

Create `simulation-testing/src/main/java/io/casehub/platform/simulation/testing/AclCorpus.java` with the code from the spec (lines 145-165).

- [ ] **Step 5: Run tests**

Run: `mvn --batch-mode test -pl simulation-testing -Dtest=AclCorpusTest`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add simulation-testing/ pom.xml
git commit -m "feat(#328): add simulation-testing module with AclCorpus descriptor

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 5: Remaining SPI descriptors — Model, Notification, Preference, Credential

**Files:**
- Create: `simulation-testing/src/main/java/io/casehub/platform/simulation/testing/ModelCorpus.java`
- Create: `simulation-testing/src/main/java/io/casehub/platform/simulation/testing/NotificationCorpus.java`
- Create: `simulation-testing/src/main/java/io/casehub/platform/simulation/testing/PreferenceCorpus.java`
- Create: `simulation-testing/src/main/java/io/casehub/platform/simulation/testing/CredentialCorpus.java`
- Create: `simulation-testing/src/test/java/io/casehub/platform/simulation/testing/ModelCorpusTest.java`
- Create: `simulation-testing/src/test/java/io/casehub/platform/simulation/testing/NotificationCorpusTest.java`
- Create: `simulation-testing/src/test/java/io/casehub/platform/simulation/testing/PreferenceCorpusTest.java`
- Create: `simulation-testing/src/test/java/io/casehub/platform/simulation/testing/CredentialCorpusTest.java`

**Interfaces:**
- Consumes: `CorpusSeed` (Task 2), `*QN` constants (Task 3), platform-api types (ModelDescriptor, NotificationInput, Notification, SettingsScope, Preferences, etc.)
- Produces: Per-SPI typed `CorpusSeed` factories, domain fixture factories, default key extractors. See spec lines 170-270 for full signatures.

- [ ] **Step 1: Write failing tests for all 4 descriptors**

One test class per descriptor. Each tests: factory returns correctly typed CorpusSeed with right QN, domain fixtures construct valid objects, key extractor produces expected keys, end-to-end seed accumulation works. Follow the AclCorpusTest pattern from Task 4.

Key test cases per descriptor:
- **ModelCorpus**: `resolveById()` returns `CorpusSeed<String, Optional<ModelDescriptor>>`, `found()` wraps in Optional, `model()` creates valid ModelDescriptor with required fields
- **NotificationCorpus**: `store()` returns CorpusSeed with output mapper, `add(input)` (single-arg) produces notification from input, `fromInput()` generates id/status/timestamps
- **PreferenceCorpus**: `resolve()` returns `CorpusSeed<SettingsScope, Preferences>`, `scope()` creates SettingsScope with Path, `preferences()` creates MapPreferences
- **CredentialCorpus**: `resolve()` returns `CorpusSeed<String, Map<String, String>>`, `credential()` creates maps with 1 or 2 entries

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-testing`
Expected: FAIL — classes not found

- [ ] **Step 3: Implement all 4 descriptors**

Create each class following the spec examples:
- `ModelCorpus.java` (spec lines 173-192)
- `NotificationCorpus.java` (spec lines 199-221)
- `PreferenceCorpus.java` (spec lines 229-245)
- `CredentialCorpus.java` (spec lines 253-269)

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-testing`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add simulation-testing/src/
git commit -m "feat(#328): add Model, Notification, Preference, Credential corpus descriptors

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 6: LlmCorpusPopulator

**Files:**
- Create: `simulation-testing/src/main/java/io/casehub/platform/simulation/testing/LlmCorpusPopulator.java`
- Create: `simulation-testing/src/test/java/io/casehub/platform/simulation/testing/LlmCorpusPopulatorTest.java`

**Interfaces:**
- Consumes: `CorpusSeed` (Task 2), `PlatformSchemaGenerator.generate(Class<?>)` (schema-generator), `ObjectMapper` (jackson)
- Produces: `LlmCorpusPopulator(Function<String,String> llmFunction, ObjectMapper objectMapper)`, `.populate(CorpusSeed<I,O> seed, Class<I> inputType, Class<O> outputType, int count, String domainContext)` → void, `.populate(CorpusSeed<I,O> seed, Class<I> inputType, Class<R> rawOutputType, Function<R,O> outputAdapter, int count, String domainContext)` → void

- [ ] **Step 1: Write the failing tests**

```java
package io.casehub.platform.simulation.testing;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.casehub.platform.simulation.CorpusSeed;
import org.junit.jupiter.api.Test;
import java.util.concurrent.atomic.AtomicReference;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class LlmCorpusPopulatorTest {

    private final ObjectMapper objectMapper = new ObjectMapper();

    @Test
    void populateParsesJsonArrayAndAddsToSeed() {
        var promptCapture = new AtomicReference<String>();
        var populator = new LlmCorpusPopulator(
            prompt -> {
                promptCapture.set(prompt);
                return "[{\"input\": \"hello\", \"output\": 42}, {\"input\": \"world\", \"output\": 99}]";
            },
            objectMapper);

        var seed = new CorpusSeed<String, Integer>("spi.method", "tenant-1");
        populator.populate(seed, String.class, Integer.class, 2, "Test context");

        assertThat(seed.build()).hasSize(2);
        assertThat(seed.build().get(0).input()).isEqualTo("hello");
        assertThat(seed.build().get(0).output()).isEqualTo(42);
    }

    @Test
    void promptContainsSchemaAndContext() {
        var promptCapture = new AtomicReference<String>();
        var populator = new LlmCorpusPopulator(
            prompt -> { promptCapture.set(prompt); return "[]"; },
            objectMapper);

        var seed = new CorpusSeed<String, Integer>("spi.method", "tenant-1");
        populator.populate(seed, String.class, Integer.class, 5, "Healthcare domain");

        assertThat(promptCapture.get()).contains("Healthcare domain");
        assertThat(promptCapture.get()).contains("5");
        assertThat(promptCapture.get()).contains("\"type\"");
    }

    @Test
    void existingEntriesIncludedAsExamples() {
        var promptCapture = new AtomicReference<String>();
        var populator = new LlmCorpusPopulator(
            prompt -> { promptCapture.set(prompt); return "[]"; },
            objectMapper);

        var seed = new CorpusSeed<String, Integer>("spi.method", "tenant-1");
        seed.add("example", 1);
        populator.populate(seed, String.class, Integer.class, 5, "Context");

        assertThat(promptCapture.get()).contains("example");
    }

    @Test
    void outputAdapterTransformsRawOutput() {
        var populator = new LlmCorpusPopulator(
            prompt -> "[{\"input\": \"hello\", \"output\": 42}]",
            objectMapper);

        var seed = new CorpusSeed<String, String>("spi.method", "tenant-1");
        populator.populate(seed, String.class, Integer.class,
            i -> "wrapped:" + i, 1, "Context");

        assertThat(seed.build().get(0).output()).isEqualTo("wrapped:42");
    }

    @Test
    void invalidJsonThrowsUnchecked() {
        var populator = new LlmCorpusPopulator(
            prompt -> "not valid json",
            objectMapper);

        var seed = new CorpusSeed<String, Integer>("spi.method", "tenant-1");

        assertThatThrownBy(() ->
            populator.populate(seed, String.class, Integer.class, 1, "Context"))
            .isInstanceOf(java.io.UncheckedIOException.class);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-testing -Dtest=LlmCorpusPopulatorTest`
Expected: FAIL — class not found

- [ ] **Step 3: Implement LlmCorpusPopulator**

Create `simulation-testing/src/main/java/io/casehub/platform/simulation/testing/LlmCorpusPopulator.java` following the spec (lines 346-398). Key implementation details:
- `buildPrompt()`: concatenate JSON Schema for input/output types + serialized existing entries + count + domain context into a structured prompt
- Response parsing: `objectMapper.readTree(response)` then iterate JSON array, `treeToValue()` each entry
- Both overloads: convenience (identity adapter) and full (with `outputAdapter`)

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-testing -Dtest=LlmCorpusPopulatorTest`
Expected: PASS

- [ ] **Step 5: Run all simulation-testing tests**

Run: `mvn --batch-mode test -pl simulation-testing`
Expected: PASS (all descriptor + populator tests)

- [ ] **Step 6: Commit**

```bash
git add simulation-testing/src/main/java/io/casehub/platform/simulation/testing/LlmCorpusPopulator.java simulation-testing/src/test/java/io/casehub/platform/simulation/testing/LlmCorpusPopulatorTest.java
git commit -m "feat(#328): add LlmCorpusPopulator with JSON Schema prompting and few-shot support

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 4: Agent integration and documentation

After this batch: AgentCorpus available in agent-simulation-core, simulation guide updated, end-to-end integration verified. Feature complete.

### Task 7: AgentCorpus descriptor + AgentProviderQN

**Files:**
- Create: `agent-simulation-core/src/main/java/io/casehub/platform/agent/simulation/AgentProviderQN.java`
- Create: `agent-simulation-core/src/main/java/io/casehub/platform/agent/simulation/AgentCorpus.java`
- Modify: `agent-simulation-core/src/main/java/io/casehub/platform/agent/simulation/SimulatedAgentBackend.java` (use `AgentProviderQN.INVOKE` instead of private string)
- Create: `agent-simulation-core/src/test/java/io/casehub/platform/agent/simulation/AgentCorpusTest.java`

**Interfaces:**
- Consumes: `CorpusSeed` (Task 2), `AgentSimulationInput`, `AgentEvent.TextDelta`, `SimulatedAgentBackend.defaultKeyExtractor()` (existing)
- Produces: `AgentProviderQN.INVOKE` = `"agent-provider.invoke"`, `AgentCorpus.invoke(String tenancyId)` → `CorpusSeed<AgentSimulationInput, List<AgentEvent>>`, `AgentCorpus.input(String systemPrompt, String userPrompt)` → `AgentSimulationInput`, `AgentCorpus.textResponse(String text)` → `List<AgentEvent>`, `AgentCorpus.llmFunction(AgentProvider)` → `Function<String, String>`

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.platform.agent.simulation;

import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.simulation.CorpusSeed;
import org.junit.jupiter.api.Test;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class AgentCorpusTest {

    @Test
    void invokeReturnsPreConfiguredSeed() {
        CorpusSeed<AgentSimulationInput, List<AgentEvent>> seed = AgentCorpus.invoke("tenant-1");
        assertThat(seed.qualifiedName()).isEqualTo("agent-provider.invoke");
        assertThat(seed.keyExtractor()).isNotNull();
    }

    @Test
    void inputCreatesAgentSimulationInput() {
        AgentSimulationInput input = AgentCorpus.input("system", "user");
        assertThat(input.systemPrompt()).isEqualTo("system");
        assertThat(input.userPrompt()).isEqualTo("user");
        assertThat(input.model()).isNull();
    }

    @Test
    void textResponseCreatesTextDeltaList() {
        List<AgentEvent> events = AgentCorpus.textResponse("hello");
        assertThat(events).hasSize(1);
        assertThat(events.get(0)).isInstanceOf(AgentEvent.TextDelta.class);
        assertThat(((AgentEvent.TextDelta) events.get(0)).text()).isEqualTo("hello");
    }

    @Test
    void qnConstantMatchesSimulatedBackend() {
        assertThat(AgentProviderQN.INVOKE).isEqualTo("agent-provider.invoke");
    }

    @Test
    void endToEndSeedAccumulation() {
        var seed = AgentCorpus.invoke("hospital-a");
        seed.add(AgentCorpus.input("Triage agent", "Patient has chest pain"),
                 AgentCorpus.textResponse("Priority 1 — cardiac consult"));

        assertThat(seed.build()).hasSize(1);
        assertThat(seed.build().get(0).input().systemPrompt()).isEqualTo("Triage agent");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-simulation-core -Dtest=AgentCorpusTest`
Expected: FAIL — AgentCorpus/AgentProviderQN not found

- [ ] **Step 3: Create AgentProviderQN**

Create `agent-simulation-core/src/main/java/io/casehub/platform/agent/simulation/AgentProviderQN.java`:

```java
package io.casehub.platform.agent.simulation;

public final class AgentProviderQN {
    public static final String INVOKE = "agent-provider.invoke";
    private AgentProviderQN() {}
}
```

- [ ] **Step 4: Create AgentCorpus**

Create `agent-simulation-core/src/main/java/io/casehub/platform/agent/simulation/AgentCorpus.java` following the spec (lines 286-314).

- [ ] **Step 5: Update SimulatedAgentBackend to use AgentProviderQN.INVOKE**

Use `ide_replace_member` or Edit to change line 18 of `SimulatedAgentBackend.java`:
```java
// Before: private static final String QN_INVOKE = "agent-provider.invoke";
// After — remove the private constant, use AgentProviderQN.INVOKE in the method body
```

Replace usages of `QN_INVOKE` with `AgentProviderQN.INVOKE`.

- [ ] **Step 6: Run all agent-simulation-core tests**

Run: `mvn --batch-mode test -pl agent-simulation-core`
Expected: PASS (new + existing tests)

- [ ] **Step 7: Commit**

```bash
git add agent-simulation-core/src/
git commit -m "feat(#328): add AgentCorpus descriptor and AgentProviderQN constants

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 8: Documentation update + full build verification

**Files:**
- Modify: `docs/guides/simulation-guide.md` (add Corpus Builders section)
- Modify: `CLAUDE.md` (add simulation-testing module description)

**Interfaces:**
- Consumes: all prior tasks
- Produces: updated documentation, verified full build

- [ ] **Step 1: Add Corpus Builders section to simulation-guide.md**

Add a new section after the existing "Corpus Population" section covering:
- CorpusSeed pattern (add → seedInto → registerExtractor)
- Per-SPI descriptors (static import mini-DSL)
- Available descriptors table (5 SPIs)
- LLM hybrid pattern (few-shot + populate)
- One complete example per common pattern (ACL, Model, Notification)

- [ ] **Step 2: Add simulation-testing to CLAUDE.md module table**

Add to the modules table:
```
| `simulation-testing/` | `casehub-platform-simulation-testing` | Per-SPI corpus descriptor classes (AclCorpus, ModelCorpus, NotificationCorpus, PreferenceCorpus, CredentialCorpus) + LlmCorpusPopulator. Test-scope convenience for seeding simulation corpora with typed domain data. Depends on simulation-api + platform-api + platform-simulation-core (generated QN constants) + schema-generator + jackson-databind. No agent-api dependency — LLM function adapter in agent-simulation-core. No quarkus:build goal |
```

- [ ] **Step 3: Run full project build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and all tests pass

- [ ] **Step 4: Commit**

```bash
git add docs/guides/simulation-guide.md CLAUDE.md
git commit -m "docs(#328): add corpus builders section to simulation guide, update CLAUDE.md modules

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## References

- [2026-09-18-corpus-builders-design.md] — design spec this plan implements
- [SimulationDecoratorProcessor.java:186-194] — Object[] input packing for multi-param methods
- [SimulationDecoratorProcessor.java:171] — qualified name construction (spiName + "." + method.name())
- [InvocationRecord.java] — existing record to modify with factory methods
- [SimulationCorpus.java] — SPI consumed by CorpusSeed.seedInto()
- [KeyExtractor.java] — functional interface used by withKeyExtractor()
- [SimulatedAgentBackend.java:18] — private QN_INVOKE constant to replace with AgentProviderQN
- [PlatformSchemaGenerator.java] — JSON Schema generation for LLM prompts
- [platform-simulation-core/META-INF/simulation-eligible.txt] — 11 listed SPIs
- Decisions D55-D67 in decisions.md
- [GitHub #328] — focal issue
- [GitHub #347] — follow-on: pattern-based synthesis
- [GitHub #348] — follow-on: data catalogue
