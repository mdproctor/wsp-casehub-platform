# Spring Generator Bug Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #385 — Spring generator: skip beans already defined in manual config
**Issue group:** #385

**Goal:** Fix three independent spring-generator bugs: auto-exclude manual beans, preserve generic wildcards, and always wrap Optional params.

**Architecture:** All changes are in `spring-generator/`. Bug 2 adds a `TypeName resolvedType` field to `ConstructorParam` using existing `JandexTypeConverter` from `generator-common/`. Bug 1 extracts the `@Bean` source scanner from `SpringVerifyMojo` into a shared `ManualBeanScanner`. Bug 3 is a one-line conditional removal.

**Tech Stack:** Jandex (bytecode index), JavaPoet (code generation), Maven plugin API

## Global Constraints

- `spring-generator` is a Maven plugin (`maven-plugin` packaging) — no Quarkus runtime
- `generator-common` dependency already exists — `JandexTypeConverter` is available
- Existing tests use Jandex `indexClasses()` helper for scanner tests and direct `ProducerDescriptor` construction for writer tests
- `ConstructorParam` compact constructor (3-arg) must be preserved for backward-compat with existing tests
- `com.palantir.javapoet` is the JavaPoet fork in use (not `com.squareup`)

---

## Batch 1: Type Fidelity Fixes (Bugs 2 + 3)

These are the correctness fixes — after this batch, the generator produces type-correct code for all constructor param kinds.

### Task 1: Add `resolvedType` to ConstructorParam and fix generic wildcard preservation

**Files:**
- Modify: `spring-generator/src/main/java/io/casehub/platform/spring/generator/ProducerDescriptor.java` — add `TypeName resolvedType` to `ConstructorParam`
- Modify: `spring-generator/src/main/java/io/casehub/platform/spring/generator/JandexProducerScanner.java` — compute `resolvedType` via `JandexTypeConverter`, add `resolvedType` to `ParamResolution`
- Modify: `spring-generator/src/main/java/io/casehub/platform/spring/generator/AutoConfigurationWriter.java` — use `resolvedType` in `buildEnhancedBeanMethod`
- Modify: `spring-generator/src/test/java/io/casehub/platform/spring/generator/SampleCorePojos.java` — add `WildcardListPojo` fixture
- Modify: `spring-generator/src/test/java/io/casehub/platform/spring/generator/SampleConstructorBeans.java` — add `wildcardListPojo` producer
- Test: `spring-generator/src/test/java/io/casehub/platform/spring/generator/JandexProducerScannerTest.java`
- Test: `spring-generator/src/test/java/io/casehub/platform/spring/generator/AutoConfigurationWriterTest.java`

**Interfaces:**
- Consumes: `JandexTypeConverter.toTypeName(Type)` from generator-common
- Produces: `ConstructorParam.resolvedType()` — `TypeName` (nullable, null for backward-compat 3-arg constructor)

- [ ] **Step 1: Add wildcard test fixtures**

Add to `SampleCorePojos.java`:

```java
interface GenericInterface<T> {}

class WildcardListPojo {
    private final List<GenericInterface<?>> items;
    public WildcardListPojo(List<GenericInterface<?>> items) {
        this.items = items;
    }
}
```

Add to `SampleConstructorBeans.java`:

```java
@Produces
@DefaultBean
@ApplicationScoped
public WildcardListPojo wildcardListPojo(Instance<GenericInterface<?>> items) {
    return new WildcardListPojo(items.stream().toList());
}
```

- [ ] **Step 2: Write failing scanner test for wildcard preservation**

Add to `JandexProducerScannerTest.java`:

```java
@Test
void followsReturnType_wildcardListParam_preservesWildcard() throws IOException {
    Index scanIndex = indexClasses(SampleConstructorBeans.class, SimplePojo.class,
            SampleConfig.class, SampleProperties.class, SomeInterface.class,
            SomeDep.class, ConfigPojo.class, ListPojo.class, OptionalPojo.class,
            FactoryPojo.class, EventConsumerPojo.class, SupplierDepPojo.class,
            GenericInterface.class, WildcardListPojo.class);
    var scanner = new JandexProducerScanner();

    List<ProducerDescriptor> descriptors = scanner.scan(scanIndex);

    var desc = findByMethod(descriptors, "wildcardListPojo");
    assertThat(desc.constructorResolved()).isTrue();
    assertThat(desc.constructorParams()).hasSize(1);
    assertThat(desc.constructorParams().get(0).kind()).isEqualTo(ProducerDescriptor.ParamKind.LIST);
    assertThat(desc.constructorParams().get(0).resolvedType()).isNotNull();
    assertThat(desc.constructorParams().get(0).resolvedType().toString())
            .contains("GenericInterface<?>"); // Full parameterized type with wildcard
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mvn -pl spring-generator test -Dtest="JandexProducerScannerTest#followsReturnType_wildcardListParam_preservesWildcard" --batch-mode -q`
Expected: compilation error — `resolvedType()` method does not exist on `ConstructorParam`

- [ ] **Step 4: Add `resolvedType` field to `ConstructorParam` in `ProducerDescriptor.java`**

Change the `ConstructorParam` record:

```java
public record ConstructorParam(String type, String name, ParamKind kind, TypeName resolvedType) {

    public ConstructorParam(String type, String name, ParamKind kind) {
        this(type, name, kind, null);
    }

    public String simpleType() {
        int dot = type.lastIndexOf('.');
        return dot >= 0 ? type.substring(dot + 1) : type;
    }
}
```

Add import at top of `ProducerDescriptor.java`:

```java
import com.palantir.javapoet.TypeName;
```

- [ ] **Step 5: Add `resolvedType` to `ParamResolution` in `JandexProducerScanner.java`**

Change the `ParamResolution` record:

```java
private record ParamResolution(String type, ProducerDescriptor.ParamKind kind,
                               String configPrefix, String configInterface,
                               TypeName resolvedType) {}
```

Add import:

```java
import io.casehub.platform.generator.JandexTypeConverter;
import com.palantir.javapoet.TypeName;
```

- [ ] **Step 6: Compute `resolvedType` in `resolveParamKind`**

Update each branch in `resolveParamKind()` to compute `resolvedType`:

For LIST:
```java
if (JAVA_LIST.equals(rawName) && !paramType.asParameterizedType().arguments().isEmpty()) {
    Type innerType = paramType.asParameterizedType().arguments().get(0);
    String typeArg = innerType.name().toString();
    TypeName resolved = JandexTypeConverter.toTypeName(innerType);
    return new ParamResolution(typeArg, ProducerDescriptor.ParamKind.LIST, null, null, resolved);
}
```

For OPTIONAL:
```java
if (JAVA_OPTIONAL.equals(rawName) && !paramType.asParameterizedType().arguments().isEmpty()) {
    Type innerType = paramType.asParameterizedType().arguments().get(0);
    String typeArg = innerType.name().toString();
    TypeName resolved = JandexTypeConverter.toTypeName(innerType);
    return new ParamResolution(typeArg, ProducerDescriptor.ParamKind.OPTIONAL, null, null, resolved);
}
```

For CONSUMER:
```java
if (JAVA_CONSUMER.equals(rawName) && !paramType.asParameterizedType().arguments().isEmpty()) {
    Type innerType = paramType.asParameterizedType().arguments().get(0);
    String typeArg = innerType.name().toString();
    TypeName resolved = JandexTypeConverter.toTypeName(innerType);
    return new ParamResolution(typeArg, ProducerDescriptor.ParamKind.EVENT_CONSUMER, null, null, resolved);
}
```

For SUPPLIER:
```java
if (JAVA_SUPPLIER.equals(rawName) && !paramType.asParameterizedType().arguments().isEmpty()) {
    Type innerType = paramType.asParameterizedType().arguments().get(0);
    String typeArg = innerType.name().toString();
    TypeName resolved = JandexTypeConverter.toTypeName(innerType);
    return new ParamResolution(typeArg, ProducerDescriptor.ParamKind.SUPPLIER_DEP, null, null, resolved);
}
```

For CONFIG_PROPERTIES (after findConfigMapping):
```java
if (configResult != null) {
    return new ParamResolution(typeName.toString(),
            ProducerDescriptor.ParamKind.CONFIG_PROPERTIES,
            configResult.prefix, configResult.interfaceName,
            JandexTypeConverter.toTypeName(paramType));
}
```

For PLAIN (default return):
```java
return new ParamResolution(typeName.toString(), ProducerDescriptor.ParamKind.PLAIN, null, null,
        JandexTypeConverter.toTypeName(paramType));
```

- [ ] **Step 7: Thread `resolvedType` into `ConstructorParam` creation**

In the `scan()` method, where `ConstructorParam` is created (around line 162), pass `resolvedType` from `ParamResolution`:

```java
ctorParams.add(new ProducerDescriptor.ConstructorParam(
        result2.type, pName, result2.kind, result2.resolvedType));
```

- [ ] **Step 8: Update `AutoConfigurationWriter.buildEnhancedBeanMethod()` to use `resolvedType`**

Add a helper method to `AutoConfigurationWriter`:

```java
private TypeName resolveType(ProducerDescriptor.ConstructorParam cp) {
    return cp.resolvedType() != null ? cp.resolvedType() : toClassName(cp.type());
}
```

Then update each case in the switch to use `resolveType(cp)`:

LIST case:
```java
case LIST -> {
    ParameterizedTypeName listType = ParameterizedTypeName.get(
            ClassName.get(java.util.List.class), resolveType(cp));
    builder.addParameter(listType, cp.name());
    paramNames.add(cp.name());
}
```

OPTIONAL case (keep existing conditional — Bug 3 fix is in Task 2):
```java
case OPTIONAL -> {
    ParameterizedTypeName providerType = ParameterizedTypeName.get(
            OBJECT_PROVIDER, resolveType(cp));
    builder.addParameter(providerType, cp.name());
    if (d.hasFactoryMethod()) {
        paramNames.add("java.util.Optional.ofNullable(" + cp.name() + ".getIfAvailable())");
    } else {
        paramNames.add(cp.name() + ".getIfAvailable()");
    }
}
```

SUPPLIER_DEP case:
```java
case SUPPLIER_DEP -> {
    ParameterizedTypeName providerType = ParameterizedTypeName.get(
            OBJECT_PROVIDER, resolveType(cp));
    builder.addParameter(providerType, cp.name());
    paramNames.add(cp.name() + ".getIfAvailable() != null ? " + cp.name() + "::getObject : null");
}
```

PLAIN case:
```java
case PLAIN -> {
    builder.addParameter(resolveType(cp), cp.name());
    paramNames.add(cp.name());
}
```

CONFIG_PROPERTIES case — no change (already uses `propsRecordType`).

EVENT_CONSUMER case — no change (no parameter emitted, just lambda).

Add import:
```java
import com.palantir.javapoet.TypeName;
```

- [ ] **Step 9: Run scanner test to verify it passes**

Run: `mvn -pl spring-generator test -Dtest="JandexProducerScannerTest#followsReturnType_wildcardListParam_preservesWildcard" --batch-mode -q`
Expected: PASS

- [ ] **Step 10: Write failing writer test for wildcard in generated code**

Add to `AutoConfigurationWriterTest.java`:

```java
@Test
void enhancedPath_wildcardListParam_preservesGenericWildcard() {
    ParameterizedTypeName wildcardType = ParameterizedTypeName.get(
            ClassName.get("io.casehub", "GenericInterface"),
            WildcardTypeName.subtypeOf(Object.class));
    var desc = enhancedDescriptor("registry", "io.casehub.Registry",
            List.of(new ProducerDescriptor.ConstructorParam(
                    "io.casehub.GenericInterface", "items",
                    ProducerDescriptor.ParamKind.LIST, wildcardType)),
            false, false);

    String source = autoConfigSource(writer.generate("io.casehub.spring",
            "TestAutoConfiguration", List.of(desc)));

    assertThat(source).contains("List<GenericInterface<?>> items");
    assertThat(source).contains("return new Registry(items);");
}
```

Add imports to test class:
```java
import com.palantir.javapoet.ClassName;
import com.palantir.javapoet.ParameterizedTypeName;
import com.palantir.javapoet.WildcardTypeName;
```

- [ ] **Step 11: Run writer test to verify it passes**

Run: `mvn -pl spring-generator test -Dtest="AutoConfigurationWriterTest#enhancedPath_wildcardListParam_preservesGenericWildcard" --batch-mode -q`
Expected: PASS (implementation already done in Step 8)

- [ ] **Step 12: Run all existing tests to verify no regressions**

Run: `mvn -pl spring-generator test --batch-mode -q`
Expected: ALL PASS — the backward-compat 3-arg `ConstructorParam` constructor ensures existing tests compile unchanged

- [ ] **Step 13: Commit**

```bash
git add spring-generator/
git commit -m "fix(#385): preserve generic wildcards in spring-generator constructor params

Add TypeName resolvedType field to ConstructorParam. Use JandexTypeConverter
to compute full JavaPoet types including wildcards, parameterized types, and
arrays. Writer uses resolvedType for code generation, falling back to string-
based toClassName when null (backward compat).

Refs #385

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: Fix Optional wrapping for non-factory constructors

**Files:**
- Modify: `spring-generator/src/main/java/io/casehub/platform/spring/generator/AutoConfigurationWriter.java` — remove `hasFactoryMethod()` conditional
- Test: `spring-generator/src/test/java/io/casehub/platform/spring/generator/AutoConfigurationWriterTest.java` — update existing test + add explicit non-factory test

**Interfaces:**
- Consumes: `ConstructorParam` with `ParamKind.OPTIONAL` from Task 1
- Produces: Generated code always wraps with `Optional.ofNullable()`

- [ ] **Step 1: Update existing writer test to expect `Optional.ofNullable` wrapping**

The existing test `enhancedPath_optionalParam_emitsObjectProvider` currently asserts:
```java
assertThat(source).contains("return new Router(manifest.getIfAvailable());");
```

Change to:
```java
assertThat(source).contains("return new Router(java.util.Optional.ofNullable(manifest.getIfAvailable()));");
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl spring-generator test -Dtest="AutoConfigurationWriterTest#enhancedPath_optionalParam_emitsObjectProvider" --batch-mode -q`
Expected: FAIL — currently emits `manifest.getIfAvailable()` without wrapping

- [ ] **Step 3: Fix the OPTIONAL case in `buildEnhancedBeanMethod`**

Remove the `if (d.hasFactoryMethod())` conditional. Change:

```java
case OPTIONAL -> {
    ParameterizedTypeName providerType = ParameterizedTypeName.get(
            OBJECT_PROVIDER, resolveType(cp));
    builder.addParameter(providerType, cp.name());
    if (d.hasFactoryMethod()) {
        paramNames.add("java.util.Optional.ofNullable(" + cp.name() + ".getIfAvailable())");
    } else {
        paramNames.add(cp.name() + ".getIfAvailable()");
    }
}
```

To:

```java
case OPTIONAL -> {
    ParameterizedTypeName providerType = ParameterizedTypeName.get(
            OBJECT_PROVIDER, resolveType(cp));
    builder.addParameter(providerType, cp.name());
    paramNames.add("java.util.Optional.ofNullable(" + cp.name() + ".getIfAvailable())");
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -pl spring-generator test -Dtest="AutoConfigurationWriterTest#enhancedPath_optionalParam_emitsObjectProvider" --batch-mode -q`
Expected: PASS

- [ ] **Step 5: Run all tests**

Run: `mvn -pl spring-generator test --batch-mode -q`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add spring-generator/
git commit -m "fix(#385): always wrap Optional params with Optional.ofNullable()

Remove hasFactoryMethod() conditional in OPTIONAL case — ParamKind.OPTIONAL
means the constructor takes Optional<T>, so wrapping is always needed.
Previously, non-factory constructors got raw getIfAvailable() causing type
mismatch.

Refs #385

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 2: Manual Bean Exclusion (Bug 1)

This is the safety net — after this batch, hand-written `@Bean` methods in the consuming module suppress duplicate generation.

### Task 3: Extract `ManualBeanScanner` and filter descriptors in `SpringGeneratorMojo`

**Files:**
- Create: `spring-generator/src/main/java/io/casehub/platform/spring/generator/ManualBeanScanner.java`
- Modify: `spring-generator/src/main/java/io/casehub/platform/spring/generator/SpringGeneratorMojo.java` — add `sourceDir`, filter descriptors
- Modify: `spring-generator/src/main/java/io/casehub/platform/spring/generator/SpringVerifyMojo.java` — refactor to use `ManualBeanScanner`
- Test: `spring-generator/src/test/java/io/casehub/platform/spring/generator/ManualBeanScannerTest.java`

**Interfaces:**
- Consumes: Nothing from prior tasks
- Produces: `ManualBeanScanner.scan(Path sourceDir)` → `Set<String>` of simple type names

- [ ] **Step 1: Write failing test for ManualBeanScanner**

Create `ManualBeanScannerTest.java`:

```java
package io.casehub.platform.spring.generator;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class ManualBeanScannerTest {

    @TempDir
    Path tempDir;

    @Test
    void findsReturnTypesFromBeanMethods() throws IOException {
        Path javaFile = tempDir.resolve("CommonManualConfig.java");
        Files.writeString(javaFile, """
                package io.casehub.engine.common.spring;

                import org.springframework.context.annotation.Bean;
                import org.springframework.context.annotation.Configuration;

                @Configuration
                public class CommonManualConfig {

                    @Bean
                    public BridgeResolver bridgeResolver(List<ContextBridge<?>> bridges) {
                        return new BridgeResolver(bridges);
                    }

                    @Bean
                    public JudgmentNodeExecutor judgmentNodeExecutor(Optional<JudgmentScheduler> scheduler) {
                        return new JudgmentNodeExecutor(scheduler);
                    }
                }
                """);

        Set<String> types = ManualBeanScanner.scan(tempDir);

        assertThat(types).containsExactlyInAnyOrder("BridgeResolver", "JudgmentNodeExecutor");
    }

    @Test
    void ignoresFilesWithoutBeanAnnotation() throws IOException {
        Path javaFile = tempDir.resolve("SomeUtil.java");
        Files.writeString(javaFile, """
                package io.casehub.engine.common.spring;

                public class SomeUtil {
                    public String helper() { return "ok"; }
                }
                """);

        Set<String> types = ManualBeanScanner.scan(tempDir);

        assertThat(types).isEmpty();
    }

    @Test
    void handlesNonExistentDirectory() throws IOException {
        Path missing = tempDir.resolve("nonexistent");

        Set<String> types = ManualBeanScanner.scan(missing);

        assertThat(types).isEmpty();
    }

    @Test
    void scansRecursively() throws IOException {
        Path subDir = tempDir.resolve("sub/package");
        Files.createDirectories(subDir);
        Path javaFile = subDir.resolve("DeepConfig.java");
        Files.writeString(javaFile, """
                package io.casehub.engine.common.spring.sub;

                import org.springframework.context.annotation.Bean;

                public class DeepConfig {
                    @Bean
                    public DataRefRegistry dataRefRegistry() {
                        return new DataRefRegistry();
                    }
                }
                """);

        Set<String> types = ManualBeanScanner.scan(tempDir);

        assertThat(types).containsExactly("DataRefRegistry");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl spring-generator test -Dtest="ManualBeanScannerTest" --batch-mode -q`
Expected: compilation error — `ManualBeanScanner` class does not exist

- [ ] **Step 3: Implement `ManualBeanScanner`**

Create `ManualBeanScanner.java`:

```java
package io.casehub.platform.spring.generator;

import java.io.IOException;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.HashSet;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class ManualBeanScanner {

    private static final Pattern BEAN_RETURN_TYPE = Pattern.compile(
            "public\\s+([\\w.]+)\\s*(?:<[^>]*>)?\\s+\\w+\\s*\\(");

    private ManualBeanScanner() {}

    public static Set<String> scan(Path sourceDir) throws IOException {
        Set<String> types = new HashSet<>();
        if (!Files.exists(sourceDir)) {
            return types;
        }
        Files.walkFileTree(sourceDir, new SimpleFileVisitor<>() {
            @Override
            public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) throws IOException {
                if (file.toString().endsWith(".java")) {
                    String content = Files.readString(file);
                    if (content.contains("@Bean")) {
                        Matcher m = BEAN_RETURN_TYPE.matcher(content);
                        while (m.find()) {
                            String type = m.group(1);
                            int dot = type.lastIndexOf('.');
                            types.add(dot >= 0 ? type.substring(dot + 1) : type);
                        }
                    }
                }
                return FileVisitResult.CONTINUE;
            }
        });
        return types;
    }
}
```

Note the regex improvement: `public\\s+([\\w.]+)\\s*(?:<[^>]*>)?\\s+\\w+\\s*\\(` — adds an optional `(?:<[^>]*>)?` after the type name to handle generic return types like `ContextBridge<?>`. The captured group 1 is still the simple type name without generics.

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -pl spring-generator test -Dtest="ManualBeanScannerTest" --batch-mode -q`
Expected: ALL PASS

- [ ] **Step 5: Add `sourceDir` and filtering to `SpringGeneratorMojo`**

Add the parameter:
```java
@Parameter(defaultValue = "${project.basedir}/src/main/java")
private File sourceDir;
```

In `execute()`, after scanning descriptors and before passing to writer, add filtering:

```java
List<ProducerDescriptor> descriptors = scanner.scan(scanIndex, resolveIndex);

// Filter out beans already defined in hand-written source
Set<String> manualBeanTypes = ManualBeanScanner.scan(sourceDir.toPath());
if (!manualBeanTypes.isEmpty()) {
    descriptors = descriptors.stream()
            .filter(d -> {
                boolean excluded = manualBeanTypes.contains(d.returnTypeSimpleName())
                        || manualBeanTypes.contains(d.effectiveReturnTypeSimpleName());
                if (excluded) {
                    getLog().info("Skipping " + d.effectiveReturnTypeSimpleName()
                            + " — already defined in manual config");
                }
                return !excluded;
            })
            .toList();
}
```

- [ ] **Step 6: Refactor `SpringVerifyMojo` to use `ManualBeanScanner`**

Replace the inline `collectBeanReturnTypes` method and `BEAN_RETURN_TYPE` field. Change `collectTargetTypes()`:

```java
@Override
protected Set<String> collectTargetTypes() {
    Set<String> types = new HashSet<>();
    try {
        types.addAll(ManualBeanScanner.scan(sourceDir.toPath()));
        types.addAll(ManualBeanScanner.scan(outputDirectory.toPath()));
    } catch (IOException e) {
        getLog().warn("Failed to scan Spring sources: " + e.getMessage());
    }
    return types;
}
```

Remove the `BEAN_RETURN_TYPE` field and `collectBeanReturnTypes` method.

- [ ] **Step 7: Run all tests**

Run: `mvn -pl spring-generator test --batch-mode -q`
Expected: ALL PASS

- [ ] **Step 8: Run full module build**

Run: `mvn -pl spring-generator install --batch-mode -q`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```bash
git add spring-generator/
git commit -m "fix(#385): auto-exclude beans already defined in manual config

Extract ManualBeanScanner from SpringVerifyMojo — scans consuming module's
src/main/java for @Bean return types. SpringGeneratorMojo filters descriptors
against manual bean types before passing to writer. Prevents generated code
from duplicating hand-written beans.

Refs #385

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 3: Full Build Verification

### Task 4: Verify full platform build

**Files:** None modified — verification only

- [ ] **Step 1: Run full platform build**

Run: `mvn --batch-mode install -DskipTests -q`
Expected: BUILD SUCCESS — no compilation errors across all modules that consume spring-generator

- [ ] **Step 2: Run spring-generator tests one final time**

Run: `mvn -pl spring-generator test --batch-mode`
Expected: ALL PASS with test output visible

- [ ] **Step 3: Commit any CLAUDE.md updates if module table changed**

No new modules added — skip unless CLAUDE.md needed updating.

## References

- [2026-09-22-spring-gen-manual-config-design.md] — design spec this plan implements
- `spring-generator/src/main/java/.../JandexProducerScanner.java` — scanner with resolveParamKind
- `spring-generator/src/main/java/.../AutoConfigurationWriter.java` — writer with buildEnhancedBeanMethod
- `spring-generator/src/main/java/.../SpringVerifyMojo.java` — existing @Bean scan pattern
- `generator-common/src/main/java/.../JandexTypeConverter.java` — Jandex→JavaPoet type conversion
- GitHub #385 — issue with engine CI impact
