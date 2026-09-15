# Spring Boot Code Generators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/parent#474 — epic: Spring Boot deployment — persistence, REST, security, and infrastructure adapters
**Issue group:** casehubio/parent#474

**Goal:** Build code generators that produce Spring integration layers from Quarkus source code, plus port Panache persistence to plain JPA.

**Architecture:** 3 Maven plugin generators (rest, graphql, mcp) share a generator-common base extracted from the existing spring-generator. Each generator reads a Quarkus module's Jandex index and produces Spring-equivalent source files. The existing spring-generator is retrofitted to the shared base. 45 Panache files across 3 consumer repos are ported to plain EntityManager.

**Tech Stack:** Maven plugin API, Jandex, Palantir JavaPoet, Spring Boot 3.2+, Spring GraphQL, Spring AI MCP SDK

## Global Constraints

- generator-common packaging: `jar` (library, not plugin)
- All new generators packaging: `maven-plugin`
- JavaPoet dependency: `com.palantir.javapoet` (not archived `com.squareup:javapoet`)
- Jandex `valueWithDefault()` for annotation attribute reads (not `value()` — returns null for defaulted attributes per GE-20260613-095ce5)
- Strip source-only annotations from generated output (per GE-20260416-f316e2)
- Generated code output: `target/generated-sources/<generator-name>/`
- All generators: dual goals `generate` + `verify`
- Platform parent version: `0.2-SNAPSHOT`
- Platform parent groupId: `io.casehub`

---

## Batch 1: Foundation — generator-common + spring-generator retrofit

### Task 1: Create generator-common module with AbstractGeneratorMojo and JandexTypeConverter

**Files:**
- Create: `generator-common/pom.xml`
- Create: `generator-common/src/main/java/io/casehub/platform/generator/AbstractGeneratorMojo.java`
- Create: `generator-common/src/main/java/io/casehub/platform/generator/JandexTypeConverter.java`
- Create: `generator-common/src/main/java/io/casehub/platform/generator/JandexUtils.java`
- Create: `generator-common/src/test/java/io/casehub/platform/generator/JandexTypeConverterTest.java`
- Create: `generator-common/src/test/java/io/casehub/platform/generator/SampleTypes.java`
- Modify: `pom.xml` (parent — add module declaration)

**Interfaces:**
- Produces: `AbstractGeneratorMojo` (abstract base with `quarkusModule`, `outputDirectory`, `project` fields; `loadJandexIndex()` and `addCompileSourceRoot()` methods), `JandexTypeConverter` (`toTypeName(Type)` → `com.palantir.javapoet.TypeName`), `JandexUtils` (annotation helper methods)

- [ ] **Step 1: Create generator-common pom.xml**

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

    <artifactId>casehub-platform-generator-common</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Generator Common</name>
    <description>Shared infrastructure for Maven plugin code generators:
        Jandex index loading, type conversion, and drift verification.</description>

    <properties>
        <version.maven-plugin-api>3.9.9</version.maven-plugin-api>
        <version.maven-plugin-annotations>3.15.2</version.maven-plugin-annotations>
    </properties>

    <dependencies>
        <dependency>
            <groupId>io.smallrye</groupId>
            <artifactId>jandex</artifactId>
        </dependency>
        <dependency>
            <groupId>com.palantir.javapoet</groupId>
            <artifactId>javapoet</artifactId>
        </dependency>
        <dependency>
            <groupId>org.apache.maven</groupId>
            <artifactId>maven-plugin-api</artifactId>
            <version>${version.maven-plugin-api}</version>
            <scope>provided</scope>
        </dependency>
        <dependency>
            <groupId>org.apache.maven.plugin-tools</groupId>
            <artifactId>maven-plugin-annotations</artifactId>
            <version>${version.maven-plugin-annotations}</version>
            <scope>provided</scope>
        </dependency>
        <dependency>
            <groupId>org.apache.maven</groupId>
            <artifactId>maven-project</artifactId>
            <version>2.2.1</version>
            <scope>provided</scope>
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

Add `com.palantir.javapoet:javapoet` to the parent BOM `<dependencyManagement>` with the latest stable version. Add `<module>generator-common</module>` to the parent pom, placed before `spring-generator` (line ~124).

- [ ] **Step 2: Write JandexTypeConverter test**

Create `generator-common/src/test/java/io/casehub/platform/generator/SampleTypes.java`:
```java
package io.casehub.platform.generator;

import java.util.List;
import java.util.Map;
import java.util.Optional;

public class SampleTypes {
    public String simpleString() { return ""; }
    public List<String> parameterized() { return List.of(); }
    public Map<String, List<Integer>> nested() { return Map.of(); }
    public Optional<String> optional() { return Optional.empty(); }
    public void voidReturn() {}
    public int primitiveInt() { return 0; }
    public String[] arrayReturn() { return new String[0]; }
}
```

Create `generator-common/src/test/java/io/casehub/platform/generator/JandexTypeConverterTest.java`:
```java
package io.casehub.platform.generator;

import com.palantir.javapoet.TypeName;
import com.palantir.javapoet.ClassName;
import com.palantir.javapoet.ParameterizedTypeName;
import org.jboss.jandex.Index;
import org.jboss.jandex.Indexer;
import org.jboss.jandex.ClassInfo;
import org.jboss.jandex.DotName;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class JandexTypeConverterTest {

    private static Index index;

    @BeforeAll
    static void buildIndex() throws Exception {
        var indexer = new Indexer();
        indexer.indexClass(SampleTypes.class);
        index = indexer.complete();
    }

    private org.jboss.jandex.Type returnTypeOf(String methodName) {
        ClassInfo ci = index.getClassByName(DotName.createSimple(SampleTypes.class.getName()));
        return ci.methods().stream()
                .filter(m -> m.name().equals(methodName))
                .findFirst().orElseThrow()
                .returnType();
    }

    @Test
    void convertsSimpleClass() {
        TypeName result = JandexTypeConverter.toTypeName(returnTypeOf("simpleString"));
        assertThat(result).isEqualTo(ClassName.get(String.class));
    }

    @Test
    void convertsParameterizedType() {
        TypeName result = JandexTypeConverter.toTypeName(returnTypeOf("parameterized"));
        assertThat(result).isInstanceOf(ParameterizedTypeName.class);
        assertThat(result.toString()).isEqualTo("java.util.List<java.lang.String>");
    }

    @Test
    void convertsNestedParameterizedType() {
        TypeName result = JandexTypeConverter.toTypeName(returnTypeOf("nested"));
        assertThat(result.toString()).isEqualTo("java.util.Map<java.lang.String, java.util.List<java.lang.Integer>>");
    }

    @Test
    void convertsVoid() {
        TypeName result = JandexTypeConverter.toTypeName(returnTypeOf("voidReturn"));
        assertThat(result).isEqualTo(TypeName.VOID);
    }

    @Test
    void convertsPrimitive() {
        TypeName result = JandexTypeConverter.toTypeName(returnTypeOf("primitiveInt"));
        assertThat(result).isEqualTo(TypeName.INT);
    }

    @Test
    void convertsArray() {
        TypeName result = JandexTypeConverter.toTypeName(returnTypeOf("arrayReturn"));
        assertThat(result.toString()).isEqualTo("java.lang.String[]");
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mvn --batch-mode -pl generator-common test -Dtest=JandexTypeConverterTest`
Expected: FAIL — `JandexTypeConverter` class not found

- [ ] **Step 4: Implement JandexTypeConverter**

Create `generator-common/src/main/java/io/casehub/platform/generator/JandexTypeConverter.java`:
```java
package io.casehub.platform.generator;

import com.palantir.javapoet.ArrayTypeName;
import com.palantir.javapoet.ClassName;
import com.palantir.javapoet.ParameterizedTypeName;
import com.palantir.javapoet.TypeName;
import com.palantir.javapoet.WildcardTypeName;
import org.jboss.jandex.ArrayType;
import org.jboss.jandex.ParameterizedType;
import org.jboss.jandex.PrimitiveType;
import org.jboss.jandex.Type;
import org.jboss.jandex.WildcardType;

public final class JandexTypeConverter {

    private JandexTypeConverter() {}

    public static TypeName toTypeName(Type jandexType) {
        return switch (jandexType.kind()) {
            case VOID -> TypeName.VOID;
            case PRIMITIVE -> toPrimitive((PrimitiveType) jandexType);
            case CLASS -> ClassName.bestGuess(jandexType.name().toString());
            case PARAMETERIZED_TYPE -> {
                ParameterizedType pt = jandexType.asParameterizedType();
                ClassName rawType = ClassName.bestGuess(pt.name().toString());
                TypeName[] typeArgs = pt.arguments().stream()
                        .map(JandexTypeConverter::toTypeName)
                        .toArray(TypeName[]::new);
                yield ParameterizedTypeName.get(rawType, typeArgs);
            }
            case ARRAY -> {
                ArrayType at = jandexType.asArrayType();
                yield ArrayTypeName.of(toTypeName(at.constituent()));
            }
            case WILDCARD_TYPE -> {
                WildcardType wt = jandexType.asWildcardType();
                if (wt.superBound() != null) {
                    yield WildcardTypeName.supertypeOf(toTypeName(wt.superBound()));
                } else if (wt.extendsBound() != null
                        && !wt.extendsBound().name().toString().equals("java.lang.Object")) {
                    yield WildcardTypeName.subtypeOf(toTypeName(wt.extendsBound()));
                }
                yield WildcardTypeName.subtypeOf(TypeName.OBJECT);
            }
            default -> ClassName.bestGuess(jandexType.name().toString());
        };
    }

    private static TypeName toPrimitive(PrimitiveType pt) {
        return switch (pt.primitive()) {
            case BOOLEAN -> TypeName.BOOLEAN;
            case BYTE -> TypeName.BYTE;
            case SHORT -> TypeName.SHORT;
            case INT -> TypeName.INT;
            case LONG -> TypeName.LONG;
            case FLOAT -> TypeName.FLOAT;
            case DOUBLE -> TypeName.DOUBLE;
            case CHAR -> TypeName.CHAR;
        };
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn --batch-mode -pl generator-common test -Dtest=JandexTypeConverterTest`
Expected: PASS — all 6 tests green

- [ ] **Step 6: Implement JandexUtils**

Create `generator-common/src/main/java/io/casehub/platform/generator/JandexUtils.java`:
```java
package io.casehub.platform.generator;

import org.jboss.jandex.AnnotationInstance;
import org.jboss.jandex.AnnotationValue;
import org.jboss.jandex.ClassInfo;
import org.jboss.jandex.DotName;
import org.jboss.jandex.IndexView;

import java.util.Optional;

public final class JandexUtils {

    private JandexUtils() {}

    public static Optional<String> annotationStringValue(AnnotationInstance annotation, String name) {
        AnnotationValue val = annotation.valueWithDefault(null, name);
        return val != null ? Optional.ofNullable(val.asString()) : Optional.empty();
    }

    public static Optional<String[]> annotationStringArrayValue(AnnotationInstance annotation, String name) {
        AnnotationValue val = annotation.valueWithDefault(null, name);
        return val != null ? Optional.ofNullable(val.asStringArray()) : Optional.empty();
    }

    public static boolean hasAnnotation(ClassInfo classInfo, DotName annotationName) {
        return classInfo.annotation(annotationName) != null;
    }

    public static boolean hasAnnotation(ClassInfo classInfo, String annotationFqn) {
        return hasAnnotation(classInfo, DotName.createSimple(annotationFqn));
    }
}
```

- [ ] **Step 7: Implement AbstractGeneratorMojo**

Create `generator-common/src/main/java/io/casehub/platform/generator/AbstractGeneratorMojo.java`:
```java
package io.casehub.platform.generator;

import org.apache.maven.plugin.AbstractMojo;
import org.apache.maven.plugin.MojoExecutionException;
import org.apache.maven.plugins.annotations.Parameter;
import org.apache.maven.project.MavenProject;
import org.jboss.jandex.Index;
import org.jboss.jandex.IndexReader;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;

public abstract class AbstractGeneratorMojo extends AbstractMojo {

    @Parameter(required = true)
    protected File quarkusModule;

    @Parameter(defaultValue = "${project}")
    protected MavenProject project;

    protected abstract File getOutputDirectory();

    protected abstract String getGeneratorName();

    protected Index loadJandexIndex() throws MojoExecutionException {
        File jandexIdx = new File(quarkusModule, "target/classes/META-INF/jandex.idx");
        if (!jandexIdx.exists()) {
            throw new MojoExecutionException(
                    "Jandex index not found at " + jandexIdx.getAbsolutePath()
                    + ". Build the Quarkus module first.");
        }
        try (var fis = new FileInputStream(jandexIdx)) {
            return new IndexReader(fis).read();
        } catch (IOException e) {
            throw new MojoExecutionException("Failed to read Jandex index", e);
        }
    }

    protected void registerSourceRoot() {
        project.addCompileSourceRoot(getOutputDirectory().getAbsolutePath());
    }
}
```

- [ ] **Step 8: Compile and verify**

Run: `mvn --batch-mode -pl generator-common compile`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```
git add generator-common/ pom.xml
git commit -m "feat: add generator-common module with AbstractGeneratorMojo and JandexTypeConverter

Shared infrastructure for Maven plugin code generators.
Extracts Jandex loading, type conversion to JavaPoet TypeName,
and annotation utility methods.

Refs casehubio/parent#474"
```

### Task 2: Add AbstractVerifyMojo to generator-common

**Files:**
- Create: `generator-common/src/main/java/io/casehub/platform/generator/AbstractVerifyMojo.java`
- Create: `generator-common/src/test/java/io/casehub/platform/generator/AbstractVerifyMojoTest.java`

**Interfaces:**
- Consumes: `AbstractGeneratorMojo.loadJandexIndex()` from Task 1
- Produces: `AbstractVerifyMojo` (abstract base: `collectSourceTypes(Index)` returns Quarkus types, `collectTargetTypes()` returns Spring types, `execute()` does the gap comparison)

- [ ] **Step 1: Write the failing test**

Create `generator-common/src/test/java/io/casehub/platform/generator/AbstractVerifyMojoTest.java`:
```java
package io.casehub.platform.generator;

import org.apache.maven.plugin.MojoExecutionException;
import org.jboss.jandex.Index;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class AbstractVerifyMojoTest {

    @TempDir
    Path tempDir;

    private TestVerifyMojo createMojo(Set<String> sourceTypes, Set<String> targetTypes) {
        return new TestVerifyMojo(sourceTypes, targetTypes);
    }

    @Test
    void passesWhenAllSourceTypesHaveTargets() throws Exception {
        var mojo = createMojo(Set.of("FooService", "BarService"), Set.of("FooService", "BarService"));
        mojo.execute();
    }

    @Test
    void failsWhenSourceTypeHasNoTarget() {
        var mojo = createMojo(Set.of("FooService", "BarService"), Set.of("FooService"));
        assertThatThrownBy(mojo::execute)
                .isInstanceOf(MojoExecutionException.class)
                .hasMessageContaining("DRIFT DETECTED")
                .hasMessageContaining("BarService");
    }

    @Test
    void allowsExtraTargetTypes() throws Exception {
        var mojo = createMojo(Set.of("FooService"), Set.of("FooService", "ManualBean"));
        mojo.execute();
    }

    static class TestVerifyMojo extends AbstractVerifyMojo {
        private final Set<String> sourceTypes;
        private final Set<String> targetTypes;

        TestVerifyMojo(Set<String> sourceTypes, Set<String> targetTypes) {
            this.sourceTypes = sourceTypes;
            this.targetTypes = targetTypes;
        }

        @Override protected Set<String> collectSourceTypes(Index index) { return sourceTypes; }
        @Override protected Set<String> collectTargetTypes() { return targetTypes; }
        @Override protected File getOutputDirectory() { return new File("target"); }
        @Override protected String getGeneratorName() { return "test"; }
        @Override protected Index loadJandexIndex() { return Index.of(); }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode -pl generator-common test -Dtest=AbstractVerifyMojoTest`
Expected: FAIL — `AbstractVerifyMojo` not found

- [ ] **Step 3: Implement AbstractVerifyMojo**

Create `generator-common/src/main/java/io/casehub/platform/generator/AbstractVerifyMojo.java`:
```java
package io.casehub.platform.generator;

import org.apache.maven.plugin.MojoExecutionException;
import org.jboss.jandex.Index;

import java.util.LinkedHashSet;
import java.util.Set;

public abstract class AbstractVerifyMojo extends AbstractGeneratorMojo {

    protected abstract Set<String> collectSourceTypes(Index index);

    protected abstract Set<String> collectTargetTypes();

    @Override
    public void execute() throws MojoExecutionException {
        Index index = loadJandexIndex();

        Set<String> sourceTypes = collectSourceTypes(index);
        Set<String> targetTypes = collectTargetTypes();

        Set<String> gaps = new LinkedHashSet<>(sourceTypes);
        gaps.removeAll(targetTypes);

        Set<String> extras = new LinkedHashSet<>(targetTypes);
        extras.removeAll(sourceTypes);

        if (!gaps.isEmpty()) {
            throw new MojoExecutionException(
                    "DRIFT DETECTED — Quarkus types with no Spring equivalent: "
                    + gaps + ". Add Spring equivalents or update the generator.");
        }

        if (!extras.isEmpty()) {
            getLog().info("Spring-only types (manual additions): " + extras);
        }

        getLog().info("Drift verification passed: " + sourceTypes.size()
                + " source types, " + targetTypes.size() + " target types.");
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode -pl generator-common test -Dtest=AbstractVerifyMojoTest`
Expected: PASS — all 3 tests green

- [ ] **Step 5: Run all generator-common tests**

Run: `mvn --batch-mode -pl generator-common test`
Expected: PASS — all tests green

- [ ] **Step 6: Commit**

```
git add generator-common/
git commit -m "feat: add AbstractVerifyMojo drift detection framework

Provides gap analysis: collects source types from Quarkus Jandex,
target types from Spring generated+hand-written sources, fails
build on unmatched source types.

Refs casehubio/parent#474"
```

### Task 3: Retrofit spring-generator to use generator-common

**Files:**
- Modify: `spring-generator/pom.xml` (add generator-common dependency)
- Modify: `spring-generator/src/main/java/io/casehub/platform/spring/generator/SpringGeneratorMojo.java` (extend AbstractGeneratorMojo)
- Modify: `spring-generator/src/main/java/io/casehub/platform/spring/generator/SpringVerifyMojo.java` (extend AbstractVerifyMojo)
- Test: `spring-generator/src/test/java/io/casehub/platform/spring/generator/JandexProducerScannerTest.java` (existing — must still pass)
- Test: `spring-generator/src/test/java/io/casehub/platform/spring/generator/AutoConfigurationWriterTest.java` (existing — must still pass)

**Interfaces:**
- Consumes: `AbstractGeneratorMojo`, `AbstractVerifyMojo`, `JandexTypeConverter` from Tasks 1-2
- Produces: Validates generator-common works against a known-good generator. Establishes the pattern for new generators.

- [ ] **Step 1: Add generator-common dependency to spring-generator pom**

Add to `spring-generator/pom.xml` dependencies:
```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-generator-common</artifactId>
    <version>${project.version}</version>
</dependency>
```

- [ ] **Step 2: Refactor SpringGeneratorMojo to extend AbstractGeneratorMojo**

Replace `SpringGeneratorMojo` to extend `AbstractGeneratorMojo` instead of `AbstractMojo`. Remove duplicated fields (`quarkusModule`, `project`). Keep `outputDirectory` and implement `getOutputDirectory()`. Use `loadJandexIndex()` instead of inline Jandex loading. Keep `deriveSpringPackage()` and `deriveConfigClassName()` — these are spring-generator-specific.

```java
package io.casehub.platform.spring.generator;

import io.casehub.platform.generator.AbstractGeneratorMojo;
import org.apache.maven.plugin.MojoExecutionException;
import org.apache.maven.plugins.annotations.LifecyclePhase;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;
import org.jboss.jandex.Index;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

@Mojo(name = "generate", defaultPhase = LifecyclePhase.GENERATE_SOURCES)
public class SpringGeneratorMojo extends AbstractGeneratorMojo {

    @Parameter(defaultValue = "${project.build.directory}/generated-sources/spring-generator")
    private File outputDirectory;

    @Override
    protected File getOutputDirectory() { return outputDirectory; }

    @Override
    protected String getGeneratorName() { return "spring-generator"; }

    @Override
    public void execute() throws MojoExecutionException {
        Index index = loadJandexIndex();

        var scanner = new JandexProducerScanner();
        List<ProducerDescriptor> descriptors = scanner.scan(index);

        if (descriptors.isEmpty()) {
            getLog().info("No @Produces methods found — skipping generation.");
            return;
        }

        try {
            String sourcePackage = deriveSpringPackage(descriptors.get(0).producerClassName());
            String configClassName = deriveConfigClassName(quarkusModule.getName());

            var writer = new AutoConfigurationWriter();
            String source = writer.generate(sourcePackage, configClassName, descriptors);

            Path sourceDir = outputDirectory.toPath()
                    .resolve(sourcePackage.replace('.', '/'));
            Files.createDirectories(sourceDir);
            Files.writeString(sourceDir.resolve(configClassName + ".java"), source);

            Path metaInf = outputDirectory.toPath()
                    .resolve("META-INF/spring");
            Files.createDirectories(metaInf);
            Files.writeString(
                    metaInf.resolve("org.springframework.boot.autoconfigure.AutoConfiguration.imports"),
                    writer.generateImportsFile(sourcePackage, configClassName));

            registerSourceRoot();

            getLog().info("Generated " + configClassName + " with " + descriptors.size()
                    + " @Bean method(s)");

        } catch (IOException e) {
            throw new MojoExecutionException("Failed to generate Spring auto-configuration", e);
        }
    }

    private String deriveSpringPackage(String quarkusClassName) {
        int lastDot = quarkusClassName.lastIndexOf('.');
        String basePackage = lastDot >= 0 ? quarkusClassName.substring(0, lastDot) : quarkusClassName;
        if (basePackage.endsWith(".quarkus")) {
            basePackage = basePackage.substring(0, basePackage.length() - ".quarkus".length());
        }
        return basePackage + ".spring";
    }

    String deriveConfigClassName(String moduleName) {
        String[] parts = moduleName.replace("platform-", "").split("-");
        var sb = new StringBuilder();
        for (String part : parts) {
            if (!part.isEmpty()) {
                sb.append(Character.toUpperCase(part.charAt(0)));
                sb.append(part.substring(1));
            }
        }
        sb.append("AutoConfiguration");
        return sb.toString();
    }
}
```

- [ ] **Step 3: Refactor SpringVerifyMojo to extend AbstractVerifyMojo**

Replace `SpringVerifyMojo` to extend `AbstractVerifyMojo`. Implement `collectSourceTypes()` and `collectTargetTypes()`.

```java
package io.casehub.platform.spring.generator;

import io.casehub.platform.generator.AbstractVerifyMojo;
import org.apache.maven.plugins.annotations.LifecyclePhase;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;
import org.jboss.jandex.Index;

import java.io.File;
import java.io.IOException;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

@Mojo(name = "verify", defaultPhase = LifecyclePhase.VERIFY)
public class SpringVerifyMojo extends AbstractVerifyMojo {

    private static final Pattern BEAN_RETURN_TYPE = Pattern.compile(
            "public\\s+([\\w.]+)\\s+\\w+\\s*\\(");

    @Parameter(defaultValue = "${project.build.directory}/generated-sources/spring-generator")
    private File outputDirectory;

    @Parameter(defaultValue = "${project.basedir}/src/main/java")
    private File sourceDir;

    @Override
    protected File getOutputDirectory() { return outputDirectory; }

    @Override
    protected String getGeneratorName() { return "spring-generator"; }

    @Override
    protected Set<String> collectSourceTypes(Index index) {
        var scanner = new JandexProducerScanner();
        List<ProducerDescriptor> quarkusProducers = scanner.scan(index);
        Set<String> types = new HashSet<>();
        for (ProducerDescriptor d : quarkusProducers) {
            types.add(d.returnTypeSimpleName());
        }
        return types;
    }

    @Override
    protected Set<String> collectTargetTypes() {
        Set<String> types = new HashSet<>();
        try {
            collectBeanReturnTypes(sourceDir.toPath(), types);
            collectBeanReturnTypes(outputDirectory.toPath(), types);
        } catch (IOException e) {
            getLog().warn("Failed to scan Spring sources: " + e.getMessage());
        }
        return types;
    }

    private void collectBeanReturnTypes(Path dir, Set<String> types) throws IOException {
        if (!Files.exists(dir)) { return; }
        Files.walkFileTree(dir, new SimpleFileVisitor<>() {
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
    }
}
```

- [ ] **Step 4: Run existing spring-generator tests**

Run: `mvn --batch-mode -pl spring-generator test`
Expected: PASS — all existing tests still green. No regressions from the refactoring.

- [ ] **Step 5: Run full build including platform-spring (consumer)**

Run: `mvn --batch-mode -pl generator-common,spring-generator,platform-spring install`
Expected: BUILD SUCCESS — the generator still produces correct output for the consumer module, and the verify goal still passes.

- [ ] **Step 6: Commit**

```
git add spring-generator/ generator-common/
git commit -m "refactor: retrofit spring-generator to use generator-common base classes

SpringGeneratorMojo extends AbstractGeneratorMojo (shared Jandex loading).
SpringVerifyMojo extends AbstractVerifyMojo (shared drift detection).
All existing tests pass, platform-spring consumer still builds.

Refs casehubio/parent#474"
```

---

## Batch 2: REST Generator

### Task 4: Create rest-spring-generator with RestResourceScanner and RestControllerWriter

**Files:**
- Create: `rest-spring-generator/pom.xml`
- Create: `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/RestResourceScanner.java`
- Create: `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/RestResourceDescriptor.java`
- Create: `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/RestMethodDescriptor.java`
- Create: `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/RestControllerWriter.java`
- Create: `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/RestGeneratorMojo.java`
- Create: `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/RestVerifyMojo.java`
- Create: `rest-spring-generator/src/test/java/io/casehub/platform/rest/spring/generator/SampleResource.java`
- Create: `rest-spring-generator/src/test/java/io/casehub/platform/rest/spring/generator/SampleCore.java`
- Create: `rest-spring-generator/src/test/java/io/casehub/platform/rest/spring/generator/RestResourceScannerTest.java`
- Create: `rest-spring-generator/src/test/java/io/casehub/platform/rest/spring/generator/RestControllerWriterTest.java`
- Modify: `pom.xml` (parent — add module)

**Interfaces:**
- Consumes: `AbstractGeneratorMojo`, `AbstractVerifyMojo`, `JandexTypeConverter`, `JandexUtils` from Tasks 1-2
- Produces: `RestResourceScanner.scan(Index)` → `List<RestResourceDescriptor>`, `RestControllerWriter.generate(RestResourceDescriptor)` → `JavaFile`

- [ ] **Step 1: Create rest-spring-generator pom.xml**

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

    <artifactId>casehub-platform-rest-spring-generator</artifactId>
    <packaging>maven-plugin</packaging>
    <name>CaseHub Platform :: REST Spring Generator</name>
    <description>Maven plugin that generates Spring MVC @RestController classes from
        JAX-RS @Path resources via Jandex index scanning.</description>

    <properties>
        <version.maven-plugin-annotations>3.15.2</version.maven-plugin-annotations>
    </properties>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-generator-common</artifactId>
            <version>${project.version}</version>
        </dependency>

        <!-- Maven Plugin API (provided by generator-common transitively, but explicit for clarity) -->
        <dependency>
            <groupId>org.apache.maven.plugin-tools</groupId>
            <artifactId>maven-plugin-annotations</artifactId>
            <version>${version.maven-plugin-annotations}</version>
            <scope>provided</scope>
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
        <dependency>
            <groupId>jakarta.ws.rs</groupId>
            <artifactId>jakarta.ws.rs-api</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>jakarta.inject</groupId>
            <artifactId>jakarta.inject-api</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-plugin-plugin</artifactId>
                <version>${version.maven-plugin-annotations}</version>
                <configuration>
                    <goalPrefix>rest-spring-gen</goalPrefix>
                </configuration>
            </plugin>
        </plugins>
    </build>
</project>
```

Add `<module>rest-spring-generator</module>` to parent pom, after `spring-generator`.

- [ ] **Step 2: Write SampleResource and SampleCore test fixtures**

Create `rest-spring-generator/src/test/java/io/casehub/platform/rest/spring/generator/SampleCore.java`:
```java
package io.casehub.platform.rest.spring.generator;

import java.util.List;
import java.util.Optional;

public class SampleCore {
    public List<String> listItems(String tenancyId) { return List.of(); }
    public Optional<String> getItem(String id) { return Optional.empty(); }
    public String createItem(String body) { return ""; }
    public void deleteItem(String id) {}
}
```

Create `rest-spring-generator/src/test/java/io/casehub/platform/rest/spring/generator/SampleResource.java`:
```java
package io.casehub.platform.rest.spring.generator;

import jakarta.inject.Inject;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import java.util.List;
import java.util.Optional;

@Path("/items")
@Produces(MediaType.APPLICATION_JSON)
@Consumes(MediaType.APPLICATION_JSON)
public class SampleResource {

    @Inject
    SampleCore core;

    @GET
    public List<String> listItems(@QueryParam("tenancyId") String tenancyId) {
        return core.listItems(tenancyId);
    }

    @GET
    @Path("/{id}")
    public Optional<String> getItem(@PathParam("id") String id) {
        return core.getItem(id);
    }

    @POST
    public String createItem(String body) {
        return core.createItem(body);
    }

    @DELETE
    @Path("/{id}")
    public void deleteItem(@PathParam("id") String id) {
        core.deleteItem(id);
    }
}
```

- [ ] **Step 3: Write RestResourceScannerTest**

Create `rest-spring-generator/src/test/java/io/casehub/platform/rest/spring/generator/RestResourceScannerTest.java`:
```java
package io.casehub.platform.rest.spring.generator;

import org.jboss.jandex.Index;
import org.jboss.jandex.Indexer;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class RestResourceScannerTest {

    private static Index index;

    @BeforeAll
    static void buildIndex() throws Exception {
        var indexer = new Indexer();
        indexer.indexClass(SampleResource.class);
        indexer.indexClass(SampleCore.class);
        index = indexer.complete();
    }

    @Test
    void scansPathAnnotatedClass() {
        var scanner = new RestResourceScanner();
        List<RestResourceDescriptor> descriptors = scanner.scan(index);

        assertThat(descriptors).hasSize(1);
        RestResourceDescriptor desc = descriptors.get(0);
        assertThat(desc.path()).isEqualTo("/items");
        assertThat(desc.className()).isEqualTo("io.casehub.platform.rest.spring.generator.SampleResource");
    }

    @Test
    void extractsMethods() {
        var scanner = new RestResourceScanner();
        List<RestResourceDescriptor> descriptors = scanner.scan(index);
        RestResourceDescriptor desc = descriptors.get(0);

        assertThat(desc.methods()).hasSize(4);

        RestMethodDescriptor listItems = desc.methods().stream()
                .filter(m -> m.methodName().equals("listItems")).findFirst().orElseThrow();
        assertThat(listItems.httpMethod()).isEqualTo("GET");
        assertThat(listItems.subPath()).isEmpty();

        RestMethodDescriptor getItem = desc.methods().stream()
                .filter(m -> m.methodName().equals("getItem")).findFirst().orElseThrow();
        assertThat(getItem.httpMethod()).isEqualTo("GET");
        assertThat(getItem.subPath()).isEqualTo("/{id}");

        RestMethodDescriptor deleteItem = desc.methods().stream()
                .filter(m -> m.methodName().equals("deleteItem")).findFirst().orElseThrow();
        assertThat(deleteItem.httpMethod()).isEqualTo("DELETE");
    }

    @Test
    void identifiesDelegationTarget() {
        var scanner = new RestResourceScanner();
        List<RestResourceDescriptor> descriptors = scanner.scan(index);
        RestResourceDescriptor desc = descriptors.get(0);

        assertThat(desc.delegateTypeName())
                .isEqualTo("io.casehub.platform.rest.spring.generator.SampleCore");
        assertThat(desc.delegateFieldName()).isEqualTo("core");
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `mvn --batch-mode -pl rest-spring-generator test -Dtest=RestResourceScannerTest`
Expected: FAIL — `RestResourceScanner` not found

- [ ] **Step 5: Implement RestResourceDescriptor and RestMethodDescriptor records**

Create `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/RestMethodDescriptor.java`:
```java
package io.casehub.platform.rest.spring.generator;

import com.palantir.javapoet.TypeName;
import java.util.List;

public record RestMethodDescriptor(
        String methodName,
        String httpMethod,
        String subPath,
        TypeName returnType,
        List<ParameterDescriptor> parameters,
        String[] consumes,
        String[] produces
) {
    public record ParameterDescriptor(
            String name,
            TypeName type,
            ParameterSource source,
            String annotationValue
    ) {}

    public enum ParameterSource {
        PATH, QUERY, HEADER, BODY
    }
}
```

Create `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/RestResourceDescriptor.java`:
```java
package io.casehub.platform.rest.spring.generator;

import java.util.List;

public record RestResourceDescriptor(
        String className,
        String path,
        String delegateTypeName,
        String delegateFieldName,
        List<RestMethodDescriptor> methods,
        String[] classConsumes,
        String[] classProduces
) {}
```

- [ ] **Step 6: Implement RestResourceScanner**

Create `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/RestResourceScanner.java`.

The scanner iterates all classes in the Jandex index annotated with `@Path`. For each class:
1. Skip if interface (`ClassInfo.isInterface()`)
2. Skip if in `*.rest.generated.*` package
3. Skip if annotated with `@RegisterRestClient`
4. Extract class-level `@Path`, `@Consumes`, `@Produces` values
5. Find the injected delegate field (annotated with `@Inject`, or a constructor parameter)
6. For each method with `@GET`/`@POST`/`@PUT`/`@DELETE`/`@PATCH`:
   - Extract method-level `@Path`, `@Consumes`, `@Produces`
   - Extract parameters with `@PathParam`/`@QueryParam`/`@HeaderParam` — body parameter is the one without these annotations
   - Build `RestMethodDescriptor`

Use `JandexUtils.annotationStringValue()` and `JandexTypeConverter.toTypeName()` from generator-common.

Implementation should be ~120 lines. Key DotName constants:
```java
private static final DotName PATH = DotName.createSimple("jakarta.ws.rs.Path");
private static final DotName GET = DotName.createSimple("jakarta.ws.rs.GET");
private static final DotName POST = DotName.createSimple("jakarta.ws.rs.POST");
private static final DotName PUT = DotName.createSimple("jakarta.ws.rs.PUT");
private static final DotName DELETE = DotName.createSimple("jakarta.ws.rs.DELETE");
private static final DotName PATCH = DotName.createSimple("jakarta.ws.rs.PATCH");
private static final DotName PATH_PARAM = DotName.createSimple("jakarta.ws.rs.PathParam");
private static final DotName QUERY_PARAM = DotName.createSimple("jakarta.ws.rs.QueryParam");
private static final DotName HEADER_PARAM = DotName.createSimple("jakarta.ws.rs.HeaderParam");
private static final DotName INJECT = DotName.createSimple("jakarta.inject.Inject");
private static final DotName REGISTER_REST_CLIENT = DotName.createSimple(
        "org.eclipse.microprofile.rest.client.inject.RegisterRestClient");
private static final DotName CONSUMES = DotName.createSimple("jakarta.ws.rs.Consumes");
private static final DotName PRODUCES = DotName.createSimple("jakarta.ws.rs.Produces");
```

- [ ] **Step 7: Run test to verify it passes**

Run: `mvn --batch-mode -pl rest-spring-generator test -Dtest=RestResourceScannerTest`
Expected: PASS — all 3 tests green

- [ ] **Step 8: Write RestControllerWriterTest**

Create `rest-spring-generator/src/test/java/io/casehub/platform/rest/spring/generator/RestControllerWriterTest.java`:
```java
package io.casehub.platform.rest.spring.generator;

import com.palantir.javapoet.JavaFile;
import org.jboss.jandex.Index;
import org.jboss.jandex.Indexer;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class RestControllerWriterTest {

    @Test
    void generatesRestController() throws Exception {
        var indexer = new Indexer();
        indexer.indexClass(SampleResource.class);
        indexer.indexClass(SampleCore.class);
        Index index = indexer.complete();

        var scanner = new RestResourceScanner();
        List<RestResourceDescriptor> descriptors = scanner.scan(index);
        RestResourceDescriptor desc = descriptors.get(0);

        var writer = new RestControllerWriter();
        JavaFile javaFile = writer.generate(desc, "io.casehub.platform.rest.spring.generator.spring");

        String source = javaFile.toString();

        assertThat(source).contains("@RestController");
        assertThat(source).contains("@RequestMapping(\"/items\")");
        assertThat(source).contains("@GetMapping");
        assertThat(source).contains("@PostMapping");
        assertThat(source).contains("@DeleteMapping(\"/{id}\")");
        assertThat(source).contains("ResponseEntity");
        assertThat(source).contains("SampleCore");
        assertThat(source).contains("@PathVariable");
        assertThat(source).contains("@RequestParam");
    }

    @Test
    void mapsVoidReturnToNoContent() throws Exception {
        var indexer = new Indexer();
        indexer.indexClass(SampleResource.class);
        indexer.indexClass(SampleCore.class);
        Index index = indexer.complete();

        var scanner = new RestResourceScanner();
        RestResourceDescriptor desc = scanner.scan(index).get(0);

        var writer = new RestControllerWriter();
        String source = writer.generate(desc, "test.spring").toString();

        assertThat(source).contains("ResponseEntity.noContent().build()");
    }

    @Test
    void mapsOptionalReturnToOkOrNotFound() throws Exception {
        var indexer = new Indexer();
        indexer.indexClass(SampleResource.class);
        indexer.indexClass(SampleCore.class);
        Index index = indexer.complete();

        var scanner = new RestResourceScanner();
        RestResourceDescriptor desc = scanner.scan(index).get(0);

        var writer = new RestControllerWriter();
        String source = writer.generate(desc, "test.spring").toString();

        assertThat(source).contains(".map(ResponseEntity::ok)");
        assertThat(source).contains("ResponseEntity.notFound().build()");
    }
}
```

- [ ] **Step 9: Implement RestControllerWriter**

Create `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/RestControllerWriter.java`.

Uses JavaPoet to build a `TypeSpec` for each `RestResourceDescriptor`:
- Class annotation: `@RestController`, `@RequestMapping(path)`, optional `@Produces`/`@Consumes`
- Constructor with delegate injection
- Methods mapped from JAX-RS to Spring MVC annotations
- Return type wrapping: void→`ResponseEntity.noContent()`, Optional→`.map(ResponseEntity::ok).orElse(notFound)`, other→`ResponseEntity.ok(result)`
- Parameters: `@PathVariable`, `@RequestParam`, `@RequestHeader`, `@RequestBody`

`generate(RestResourceDescriptor, String targetPackage)` → `JavaFile`

- [ ] **Step 10: Run test to verify it passes**

Run: `mvn --batch-mode -pl rest-spring-generator test`
Expected: PASS — all tests green

- [ ] **Step 11: Implement RestGeneratorMojo and RestVerifyMojo**

Create `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/RestGeneratorMojo.java`:
```java
package io.casehub.platform.rest.spring.generator;

import io.casehub.platform.generator.AbstractGeneratorMojo;
import com.palantir.javapoet.JavaFile;
import org.apache.maven.plugin.MojoExecutionException;
import org.apache.maven.plugins.annotations.LifecyclePhase;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;
import org.jboss.jandex.Index;

import java.io.File;
import java.io.IOException;
import java.util.List;

@Mojo(name = "generate", defaultPhase = LifecyclePhase.GENERATE_SOURCES)
public class RestGeneratorMojo extends AbstractGeneratorMojo {

    @Parameter(defaultValue = "${project.build.directory}/generated-sources/rest-spring-generator")
    private File outputDirectory;

    @Override
    protected File getOutputDirectory() { return outputDirectory; }

    @Override
    protected String getGeneratorName() { return "rest-spring-generator"; }

    @Override
    public void execute() throws MojoExecutionException {
        Index index = loadJandexIndex();

        var scanner = new RestResourceScanner();
        List<RestResourceDescriptor> descriptors = scanner.scan(index);

        if (descriptors.isEmpty()) {
            getLog().info("No @Path resources found — skipping generation.");
            return;
        }

        try {
            var writer = new RestControllerWriter();
            int count = 0;
            for (RestResourceDescriptor desc : descriptors) {
                String targetPackage = deriveSpringPackage(desc.className());
                JavaFile javaFile = writer.generate(desc, targetPackage);
                javaFile.writeTo(outputDirectory);
                count++;
            }

            registerSourceRoot();
            getLog().info("Generated " + count + " @RestController class(es)");

        } catch (IOException e) {
            throw new MojoExecutionException("Failed to generate REST controllers", e);
        }
    }

    private String deriveSpringPackage(String quarkusClassName) {
        int lastDot = quarkusClassName.lastIndexOf('.');
        String basePackage = lastDot >= 0 ? quarkusClassName.substring(0, lastDot) : quarkusClassName;
        return basePackage.replace(".quarkus.", ".spring.").replace(".rest.", ".rest.spring.");
    }
}
```

Create `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/RestVerifyMojo.java`:
```java
package io.casehub.platform.rest.spring.generator;

import io.casehub.platform.generator.AbstractVerifyMojo;
import org.apache.maven.plugins.annotations.LifecyclePhase;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;
import org.jboss.jandex.Index;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

@Mojo(name = "verify", defaultPhase = LifecyclePhase.VERIFY)
public class RestVerifyMojo extends AbstractVerifyMojo {

    @Parameter(defaultValue = "${project.build.directory}/generated-sources/rest-spring-generator")
    private File outputDirectory;

    @Parameter(defaultValue = "${project.basedir}/src/main/java")
    private File sourceDir;

    @Override
    protected File getOutputDirectory() { return outputDirectory; }

    @Override
    protected String getGeneratorName() { return "rest-spring-generator"; }

    @Override
    protected Set<String> collectSourceTypes(Index index) {
        var scanner = new RestResourceScanner();
        return scanner.scan(index).stream()
                .map(RestResourceDescriptor::className)
                .map(this::simpleClassName)
                .collect(Collectors.toSet());
    }

    @Override
    protected Set<String> collectTargetTypes() {
        Set<String> types = new HashSet<>();
        collectControllerTypes(sourceDir.toPath(), types);
        collectControllerTypes(outputDirectory.toPath(), types);
        return types;
    }

    private void collectControllerTypes(Path dir, Set<String> types) {
        if (!Files.exists(dir)) { return; }
        try (var walk = Files.walk(dir)) {
            walk.filter(p -> p.toString().endsWith(".java"))
                .forEach(p -> {
                    try {
                        String content = Files.readString(p);
                        if (content.contains("@RestController")) {
                            String fileName = p.getFileName().toString();
                            types.add(fileName.replace(".java", "")
                                    .replace("Controller", "Resource")
                                    .replace("Spring", ""));
                        }
                    } catch (IOException ignored) {}
                });
        } catch (IOException ignored) {}
    }

    private String simpleClassName(String fqn) {
        int dot = fqn.lastIndexOf('.');
        return dot >= 0 ? fqn.substring(dot + 1) : fqn;
    }
}
```

- [ ] **Step 12: Run full build**

Run: `mvn --batch-mode -pl generator-common,rest-spring-generator install`
Expected: BUILD SUCCESS

- [ ] **Step 13: Commit**

```
git add rest-spring-generator/ pom.xml
git commit -m "feat: add rest-spring-generator — JAX-RS to Spring MVC code generator

Scans @Path resources via Jandex, generates @RestController classes
that delegate to core POJOs. Handles @PathParam→@PathVariable,
@QueryParam→@RequestParam, @HeaderParam→@RequestHeader mappings.
ResponseEntity wrapping: void→noContent, Optional→ok/notFound.
Input filters: skip interfaces, @RegisterRestClient, generated packages.

Refs casehubio/parent#474"
```

### Task 5: Add @Provider mapping to rest-spring-generator

**Files:**
- Create: `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/ProviderScanner.java`
- Create: `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/ProviderDescriptor.java`
- Create: `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/ProviderWriter.java`
- Create: `rest-spring-generator/src/test/java/io/casehub/platform/rest/spring/generator/SampleExceptionMapper.java`
- Create: `rest-spring-generator/src/test/java/io/casehub/platform/rest/spring/generator/ProviderScannerTest.java`
- Create: `rest-spring-generator/src/test/java/io/casehub/platform/rest/spring/generator/ProviderWriterTest.java`
- Modify: `rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/RestGeneratorMojo.java` (add Provider generation)

**Interfaces:**
- Consumes: `JandexTypeConverter`, `JandexUtils` from generator-common
- Produces: `ProviderScanner.scan(Index)` → `List<ProviderDescriptor>`, `ProviderWriter.generate(ProviderDescriptor)` → `JavaFile`

- [ ] **Step 1: Write SampleExceptionMapper test fixture**

```java
package io.casehub.platform.rest.spring.generator;

import jakarta.ws.rs.core.Response;
import jakarta.ws.rs.ext.ExceptionMapper;
import jakarta.ws.rs.ext.Provider;

@Provider
public class SampleExceptionMapper implements ExceptionMapper<IllegalArgumentException> {
    @Override
    public Response toResponse(IllegalArgumentException exception) {
        return Response.status(400).entity(exception.getMessage()).build();
    }
}
```

- [ ] **Step 2: Write ProviderScannerTest**

Test that `ProviderScanner.scan(Index)` finds `ExceptionMapper` implementations, extracts the exception type parameter, and classifies the provider kind.

- [ ] **Step 3: Run test to verify it fails**

Run: `mvn --batch-mode -pl rest-spring-generator test -Dtest=ProviderScannerTest`
Expected: FAIL

- [ ] **Step 4: Implement ProviderDescriptor, ProviderScanner, ProviderWriter**

`ProviderDescriptor` record with `className`, `providerKind` (EXCEPTION_MAPPER, REQUEST_FILTER, RESPONSE_FILTER, PARAM_CONVERTER), `targetType` (the exception class or converted type), `priority`.

`ProviderScanner` scans for classes implementing `ExceptionMapper`, `ContainerRequestFilter`, `ContainerResponseFilter`, `ParamConverterProvider`.

`ProviderWriter` generates:
- `ExceptionMapper<T>` → `@ControllerAdvice` class with `@ExceptionHandler(T.class)` method
- `ContainerRequestFilter` → Spring `Filter` or `HandlerInterceptor` based on `@Priority`
- `ParamConverterProvider` → Spring `Converter<S,T>` + `@Configuration`

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode -pl rest-spring-generator test`
Expected: PASS

- [ ] **Step 6: Wire ProviderScanner into RestGeneratorMojo**

Add Provider scanning and generation to `RestGeneratorMojo.execute()` — scan for providers, generate Spring equivalents alongside REST controllers.

- [ ] **Step 7: Run full build**

Run: `mvn --batch-mode -pl generator-common,rest-spring-generator install`
Expected: BUILD SUCCESS

- [ ] **Step 8: Commit**

```
git add rest-spring-generator/
git commit -m "feat: add @Provider mapping to rest-spring-generator

ExceptionMapper→@ControllerAdvice, ContainerRequestFilter→Filter/HandlerInterceptor
(based on @Priority), ParamConverterProvider→Converter.

Refs casehubio/parent#474"
```

---

## Batch 3: GraphQL Generator

### Task 6: Create graphql-spring-generator with dual output

**Files:**
- Create: `graphql-spring-generator/pom.xml`
- Create: `graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/McpDomainScanner.java`
- Create: `graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/DomainDescriptor.java`
- Create: `graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/GraphqlControllerWriter.java`
- Create: `graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/RestControllerWriter.java`
- Create: `graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/GraphqlSpringGeneratorMojo.java`
- Create: `graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/GraphqlSpringVerifyMojo.java`
- Create: `graphql-spring-generator/src/test/java/io/casehub/platform/graphql/spring/generator/McpDomainScannerTest.java`
- Create: `graphql-spring-generator/src/test/java/io/casehub/platform/graphql/spring/generator/GraphqlControllerWriterTest.java`
- Modify: `pom.xml` (parent — add module)

**Interfaces:**
- Consumes: `AbstractGeneratorMojo`, `AbstractVerifyMojo`, `JandexTypeConverter` from generator-common
- Produces: `McpDomainScanner.scan(Index)` → `List<DomainDescriptor>`, `GraphqlControllerWriter.generate(DomainDescriptor)` → `JavaFile`, `RestControllerWriter.generate(DomainDescriptor)` → `JavaFile`

This generator mirrors the existing `graphql-generator/GraphQLResolverProcessor.java` architecture: it scans `@McpDomain` interfaces for `@PlatformQuery`/`@PlatformMutation` methods and produces TWO output files per domain:
1. Spring GraphQL `@Controller` with `@QueryMapping`/`@MutationMapping`
2. Spring MVC `@RestController` with `@RequestMapping("/api/{domain}")`

- [ ] **Step 1: Create pom.xml and add module to parent**

Similar structure to rest-spring-generator. Add `spring-graphql` dependency for `@QueryMapping`/`@MutationMapping` annotation references. Add `<module>graphql-spring-generator</module>` to parent pom.

- [ ] **Step 2: Create test fixture — SampleDomainSpi interface**

An interface annotated with `@McpDomain("sample")` containing `@PlatformQuery` and `@PlatformMutation` methods. Use the actual platform-api annotations (add `casehub-platform-api` as test dependency).

- [ ] **Step 3: Write McpDomainScannerTest**

Test that the scanner finds `@McpDomain`-annotated interfaces, extracts domain name, and discovers `@PlatformQuery`/`@PlatformMutation` methods with their parameters and return types.

- [ ] **Step 4: Run test to verify it fails, then implement McpDomainScanner**

The scanner uses DotName constants for `@McpDomain`, `@PlatformQuery`, `@PlatformMutation`. It produces `DomainDescriptor` records containing the domain name, SPI interface name, and list of operations (query/mutation, method name, parameters, return type).

- [ ] **Step 5: Write GraphqlControllerWriterTest**

Test that the writer produces a `@Controller` class with `@QueryMapping` methods for queries and `@MutationMapping` methods for mutations. Verify it injects the SPI interface and delegates.

- [ ] **Step 6: Implement GraphqlControllerWriter and RestControllerWriter**

`GraphqlControllerWriter` → `@Controller` with `@QueryMapping`/`@MutationMapping`
`RestControllerWriter` → `@RestController @RequestMapping("/api/{domain}")` with `@GetMapping`/`@PostMapping`

Both inject the `@McpDomain` SPI interface and delegate method calls.

- [ ] **Step 7: Implement Mojo classes**

`GraphqlSpringGeneratorMojo` extends `AbstractGeneratorMojo` — scans @McpDomain, writes both GraphQL and REST controllers. `GraphqlSpringVerifyMojo` extends `AbstractVerifyMojo` — verifies every @McpDomain interface has Spring equivalents.

- [ ] **Step 8: Run all tests and build**

Run: `mvn --batch-mode -pl generator-common,graphql-spring-generator install`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```
git add graphql-spring-generator/ pom.xml
git commit -m "feat: add graphql-spring-generator — @McpDomain to Spring GraphQL + REST

Scans @McpDomain SPI interfaces, generates Spring GraphQL @Controller
(@QueryMapping/@MutationMapping) and Spring MVC @RestController per domain.
Mirrors existing graphql-generator dual-output architecture.

Refs casehubio/parent#474"
```

---

## Batch 4: MCP Generator

### Task 7: Create mcp-spring-generator for @Tool mapping

**Files:**
- Create: `mcp-spring-generator/pom.xml`
- Create: `mcp-spring-generator/src/main/java/io/casehub/platform/mcp/spring/generator/ToolScanner.java`
- Create: `mcp-spring-generator/src/main/java/io/casehub/platform/mcp/spring/generator/ToolDescriptor.java`
- Create: `mcp-spring-generator/src/main/java/io/casehub/platform/mcp/spring/generator/ToolConfigWriter.java`
- Create: `mcp-spring-generator/src/main/java/io/casehub/platform/mcp/spring/generator/McpSpringGeneratorMojo.java`
- Create: `mcp-spring-generator/src/main/java/io/casehub/platform/mcp/spring/generator/McpSpringVerifyMojo.java`
- Create: `mcp-spring-generator/src/test/java/io/casehub/platform/mcp/spring/generator/ToolScannerTest.java`
- Create: `mcp-spring-generator/src/test/java/io/casehub/platform/mcp/spring/generator/ToolConfigWriterTest.java`
- Modify: `pom.xml` (parent — add module)

**Interfaces:**
- Consumes: `AbstractGeneratorMojo`, `AbstractVerifyMojo`, `JandexTypeConverter` from generator-common
- Produces: `ToolScanner.scan(Index)` → `List<ToolDescriptor>`, `ToolConfigWriter.generate(ToolDescriptor)` → `JavaFile`

Narrowest scope — handles `@Tool` from `io.quarkiverse.mcp.server` only (8 platform files + connectors). Maps to Spring AI `@Tool` annotations.

- [ ] **Step 1: Create pom.xml and add module to parent**

Add `quarkus-mcp-server` as test dependency for `@Tool`/`@ToolArg` annotations. Add `<module>mcp-spring-generator</module>` to parent pom.

- [ ] **Step 2: Create test fixture — SampleTools class with @Tool methods**

- [ ] **Step 3: Write ToolScannerTest, run to verify fails**

- [ ] **Step 4: Implement ToolScanner, ToolDescriptor**

Scanner finds `@Tool`-annotated methods, extracts description, parameters with `@ToolArg`.

- [ ] **Step 5: Write ToolConfigWriterTest, run to verify fails**

- [ ] **Step 6: Implement ToolConfigWriter**

Generates `@Configuration` class that registers `@Tool`-annotated methods as Spring AI tool beans.

- [ ] **Step 7: Implement Mojo classes, run full build**

- [ ] **Step 8: Commit**

```
git add mcp-spring-generator/ pom.xml
git commit -m "feat: add mcp-spring-generator — @Tool to Spring AI MCP SDK

Scans Quarkus MCP Server @Tool methods via Jandex, generates Spring AI
@Tool equivalents in @Configuration classes.

Refs casehubio/parent#474"
```

---

## Batch 5: Panache Porting

### Task 8: Port Panache to plain JPA in ledger (2 files)

**Files:**
- Modify: 2 files in `/Users/mdproctor/claude/casehub/slots/192/ledger` using Panache APIs
- Test: Existing tests must still pass

**Interfaces:**
- Consumes: None (independent refactoring)
- Produces: Framework-neutral JPA persistence in ledger

Start with ledger — smallest scope (2 files), lowest risk. Validates the porting pattern before tackling work and qhorus.

- [ ] **Step 1: Find the 2 Panache files in ledger**

Run: `grep -rl "PanacheRepository\|PanacheEntityBase\|PanacheEntity" /Users/mdproctor/claude/casehub/slots/192/ledger/src/main/java/`

- [ ] **Step 2: For each file, replace Panache APIs with EntityManager**

Apply porting rules:
- `PanacheRepository<E>` → inject `EntityManager`, use JPQL
- `entity.persist()` → `em.persist(entity)`
- `entity.find("field", value)` → `em.createQuery(...)` or `@NamedQuery`
- `PanacheEntityBase` superclass → remove; keep `@Entity`

- [ ] **Step 3: Run ledger tests**

Run: `mvn --batch-mode -f /Users/mdproctor/claude/casehub/slots/192/ledger/pom.xml test`
Expected: PASS — all tests green

- [ ] **Step 4: Commit in ledger repo**

```
git -C /Users/mdproctor/claude/casehub/slots/192/ledger add -A
git -C /Users/mdproctor/claude/casehub/slots/192/ledger commit -m "refactor: port Panache to plain JPA

Replace PanacheRepository with EntityManager + JPQL.
Framework-neutral persistence for Spring Boot compatibility.

Refs casehubio/parent#474"
```

### Task 9: Port Panache to plain JPA in work (21 files)

**Files:**
- Modify: 21 files in `/Users/mdproctor/claude/casehub/slots/100/work` using Panache APIs
- Test: Existing tests must still pass

Same porting pattern as Task 8, applied to the 21 Panache files in work. Larger scope — work methodically through each file, running tests after each group of related changes.

- [ ] **Step 1: Find all Panache files in work**

Run: `grep -rl "PanacheRepository\|PanacheEntityBase\|PanacheEntity" /Users/mdproctor/claude/casehub/slots/100/work/src/main/java/`

- [ ] **Step 2: Port each file, grouped by domain module**

For each file: replace Panache API calls with `EntityManager` + JPQL. Add `@NamedQuery` annotations to entities where appropriate.

- [ ] **Step 3: Run work tests after each group**

Run: `mvn --batch-mode -f /Users/mdproctor/claude/casehub/slots/100/work/pom.xml test`

- [ ] **Step 4: Commit**

### Task 10: Port Panache to plain JPA in qhorus (22 files)

**Files:**
- Modify: 22 files in `/Users/mdproctor/claude/casehub/slots/189/qhorus` using Panache APIs
- Test: Existing tests must still pass

Same porting pattern as Tasks 8-9, applied to the 22 Panache files in qhorus.

- [ ] **Step 1: Find all Panache files in qhorus**

- [ ] **Step 2: Port each file**

- [ ] **Step 3: Run tests**

- [ ] **Step 4: Commit**

---

## References

- [2026-09-14-spring-boot-generators-design.md] — design spec this plan implements
- [spring-generator/SpringGeneratorMojo.java:20-103] — existing Maven plugin pattern
- [spring-generator/SpringVerifyMojo.java:26-113] — existing drift detection
- [spring-generator/JandexProducerScanner.java:14-127] — existing Jandex scanner
- [spring-generator/AutoConfigurationWriter.java:8-104] — existing StringBuilder writer
- [spring-generator/pom.xml] — existing plugin pom structure
- [graphql-generator/GraphQLResolverProcessor.java:146-341] — @McpDomain scanning and dual output
- [platform-spring/pom.xml] — consumer plugin integration
- [GE-20260909-81809c] — Jandex-based Spring auto-config generator technique
- [GE-20260817-8b0648] — APT classloader isolation
- [GE-20260613-095ce5] — Jandex valueWithDefault for defaulted attributes
- [GE-20260416-f316e2] — Strip source-only annotations from generated output
- [GE-20260420-7d28fa] — Panache + plain @Entity runtime failure
- [GE-0138] — Panache SPI return-type conflict
- [casehubio/parent#474] — epic issue
- [casehubio/parent#469] — core extraction (prerequisite)
