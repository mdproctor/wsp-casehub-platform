# yaml-core Step Action Plugin API — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/casehub-desiredstate#151 — OrchestrationScope SPI (repurposed to plugin API)
**Issue group:** #151

**Goal:** Create an annotation-driven plugin system for yaml-core step actions — `@StepPlugin` on a Java record generates JSON Schema, typed binder, and registry manifest at compile time via APT.

**Architecture:** Two new modules in casehub-platform: `yaml-plugin-api` (zero-dep, J2CL-safe annotations + SPI types) and `yaml-plugin-processor` (APT that generates schema via PlatformSchemaGenerator, typed binder classes, and META-INF registry manifests). Plugin authors depend only on yaml-plugin-api. The APT follows the established pattern from graphql-generator and simulation-generator: `@SupportedAnnotationTypes("*")`, Jandex for classpath, `Filer` for output, `compile-testing` for tests.

**Tech Stack:** Java 21+, Maven, javax.annotation.processing (APT), Jandex (classpath scanning), victools/jsonschema-generator (via PlatformSchemaGenerator), com.google.testing.compile:compile-testing (APT tests)

## Global Constraints

- yaml-plugin-api must be zero-dep — no Quarkus, no Jackson, no CDI, no platform imports. Pure Java only. J2CL-safe: no java.lang.reflect, no ConcurrentHashMap, no Thread.
- yaml-plugin-processor is build-time only — may depend on schema-generator, Jandex, javapoet.
- All generated code must use direct method calls — no reflection at runtime.
- APT must set `<proc>none</proc>` in maven-compiler-plugin to prevent self-processing.
- GroupId: `io.casehub`. Parent: `casehub-platform-parent` version `0.2-SNAPSHOT`.

---

## Batch 1: Plugin API foundation — yaml-plugin-api module

### Task 1: Create yaml-plugin-api module with annotations and SPI types

**Files:**
- Create: `yaml-plugin-api/pom.xml`
- Create: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StepPlugin.java`
- Create: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Execute.java`
- Create: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Required.java`
- Create: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Optional.java`
- Create: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StepResult.java`
- Create: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/ServiceRegistry.java`
- Modify: `pom.xml` (parent — add module entry)
- Test: `yaml-plugin-api/src/test/java/io/casehub/yaml/plugin/api/StepResultTest.java`

**Interfaces:**
- Produces: `@StepPlugin(String value)` — annotation for plugin records
- Produces: `@Execute` — marks execution method
- Produces: `@Required` — marks required YAML field
- Produces: `@Optional` — marks optional YAML field (with default handling)
- Produces: `StepResult` sealed interface — `Success(Map<String,Object>)`, `Failure(String)`
- Produces: `ServiceRegistry` interface — `<T> T lookup(Class<T> serviceType)`

- [ ] **Step 1: Create pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-yaml-plugin-api</artifactId>
    <name>CaseHub Platform - YAML Plugin API</name>
    <description>Zero-dep annotations and SPI types for yaml-core step action plugins</description>

    <dependencies>
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

Add `<module>yaml-plugin-api</module>` to the `<modules>` section in the parent pom.xml. Place it near the other yaml modules (after `yaml-jackson`).

- [ ] **Step 3: Write StepResult test**

```java
package io.casehub.yaml.plugin.api;

import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class StepResultTest {

    @Test
    void successResult() {
        StepResult result = StepResult.of(Map.of("exitCode", 0, "stdout", "ok"));
        assertThat(result.isSuccess()).isTrue();
        assertThat(result.output()).containsEntry("exitCode", 0);
        assertThat(result.output()).containsEntry("stdout", "ok");
    }

    @Test
    void failureResult() {
        StepResult result = StepResult.failed("connection refused");
        assertThat(result.isSuccess()).isFalse();
        assertThat(result.output()).isEmpty();
        assertThat(result).isInstanceOf(StepResult.Failure.class);
        assertThat(((StepResult.Failure) result).message()).isEqualTo("connection refused");
    }

    @Test
    void successWithEmptyOutput() {
        StepResult result = StepResult.of(Map.of());
        assertThat(result.isSuccess()).isTrue();
        assertThat(result.output()).isEmpty();
    }

    @Test
    void outputIsImmutable() {
        var mutable = new java.util.HashMap<String, Object>();
        mutable.put("key", "value");
        StepResult result = StepResult.of(mutable);
        org.junit.jupiter.api.Assertions.assertThrows(
            UnsupportedOperationException.class,
            () -> result.output().put("another", "value"));
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-plugin-api -Dtest=StepResultTest`
Expected: Compilation failure — StepResult not defined.

- [ ] **Step 5: Implement all API types**

**StepPlugin.java:**
```java
package io.casehub.yaml.plugin.api;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
public @interface StepPlugin {
    String value();
    String description() default "";
}
```

**Execute.java:**
```java
package io.casehub.yaml.plugin.api;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface Execute {
}
```

**Required.java:**
```java
package io.casehub.yaml.plugin.api;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target({ElementType.RECORD_COMPONENT, ElementType.FIELD, ElementType.PARAMETER})
@Retention(RetentionPolicy.RUNTIME)
public @interface Required {
}
```

**Optional.java:**
```java
package io.casehub.yaml.plugin.api;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target({ElementType.RECORD_COMPONENT, ElementType.FIELD, ElementType.PARAMETER})
@Retention(RetentionPolicy.RUNTIME)
public @interface Optional {
}
```

**StepResult.java:**
```java
package io.casehub.yaml.plugin.api;

import java.util.Map;

public sealed interface StepResult permits StepResult.Success, StepResult.Failure {

    boolean isSuccess();
    Map<String, Object> output();

    record Success(Map<String, Object> output) implements StepResult {
        public Success {
            output = Map.copyOf(output);
        }
        @Override public boolean isSuccess() { return true; }
    }

    record Failure(String message) implements StepResult {
        @Override public boolean isSuccess() { return false; }
        @Override public Map<String, Object> output() { return Map.of(); }
    }

    static StepResult of(Map<String, Object> output) { return new Success(output); }
    static StepResult failed(String message) { return new Failure(message); }
}
```

**ServiceRegistry.java:**
```java
package io.casehub.yaml.plugin.api;

public interface ServiceRegistry {
    <T> T lookup(Class<T> serviceType);
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mvn --batch-mode test -pl yaml-plugin-api -Dtest=StepResultTest`
Expected: 4 tests PASS.

- [ ] **Step 7: Commit**

```bash
git add yaml-plugin-api/ pom.xml
git commit -m "feat: yaml-plugin-api module — annotations, StepResult, ServiceRegistry

Refs casehubio/casehub-desiredstate#151"
```

---

## Batch 2: APT processor — schema + binder + registry generation

### Task 2: Create yaml-plugin-processor module with APT skeleton and compile-time validation

**Files:**
- Create: `yaml-plugin-processor/pom.xml`
- Create: `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/StepPluginProcessor.java`
- Create: `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/PluginModel.java`
- Create: `yaml-plugin-processor/src/main/resources/META-INF/services/javax.annotation.processing.Processor`
- Test: `yaml-plugin-processor/src/test/java/io/casehub/yaml/plugin/processor/StepPluginProcessorTest.java`
- Test: `yaml-plugin-processor/src/test/resources/test-plugins/ValidPlugin.java`
- Test: `yaml-plugin-processor/src/test/resources/test-plugins/MissingExecutePlugin.java`
- Test: `yaml-plugin-processor/src/test/resources/test-plugins/WrongReturnTypePlugin.java`
- Modify: `pom.xml` (parent — add module entry)

**Interfaces:**
- Consumes: `@StepPlugin`, `@Execute`, `@Required`, `@Optional`, `StepResult`, `ServiceRegistry` from yaml-plugin-api
- Produces: `StepPluginProcessor` — APT that validates plugin classes at compile time
- Produces: `PluginModel` — internal record capturing plugin metadata (name, record class, fields, execute method, service params)

- [ ] **Step 1: Create pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-yaml-plugin-processor</artifactId>
    <name>CaseHub Platform - YAML Plugin Processor</name>
    <description>APT generating schema, binder, and registry for @StepPlugin records</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-yaml-plugin-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-schema-generator</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.smallrye</groupId>
            <artifactId>jandex</artifactId>
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
            <groupId>com.google.testing.compile</groupId>
            <artifactId>compile-testing</artifactId>
            <version>0.21.0</version>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <artifactId>maven-compiler-plugin</artifactId>
                <configuration>
                    <proc>none</proc>
                </configuration>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Add module to parent pom.xml**

Add `<module>yaml-plugin-processor</module>` to `<modules>` after `yaml-plugin-api`.

- [ ] **Step 3: Create APT service registration**

Write `yaml-plugin-processor/src/main/resources/META-INF/services/javax.annotation.processing.Processor`:
```
io.casehub.yaml.plugin.processor.StepPluginProcessor
```

- [ ] **Step 4: Write compile-time validation test**

```java
package io.casehub.yaml.plugin.processor;

import com.google.testing.compile.Compilation;
import com.google.testing.compile.JavaFileObjects;
import org.junit.jupiter.api.Test;

import static com.google.testing.compile.CompilationSubject.assertThat;
import static com.google.testing.compile.Compiler.javac;

class StepPluginProcessorTest {

    @Test
    void validPluginCompiles() {
        Compilation compilation = javac()
            .withProcessors(new StepPluginProcessor())
            .compile(JavaFileObjects.forResource("test-plugins/ValidPlugin.java"));
        assertThat(compilation).succeededWithoutWarnings();
    }

    @Test
    void missingExecuteMethodFails() {
        Compilation compilation = javac()
            .withProcessors(new StepPluginProcessor())
            .compile(JavaFileObjects.forResource("test-plugins/MissingExecutePlugin.java"));
        assertThat(compilation).failed();
        assertThat(compilation).hadErrorContaining("@StepPlugin class must have exactly one @Execute method");
    }

    @Test
    void wrongReturnTypeFails() {
        Compilation compilation = javac()
            .withProcessors(new StepPluginProcessor())
            .compile(JavaFileObjects.forResource("test-plugins/WrongReturnTypePlugin.java"));
        assertThat(compilation).failed();
        assertThat(compilation).hadErrorContaining("@Execute method must return StepResult");
    }
}
```

- [ ] **Step 5: Create test fixtures**

**test-plugins/ValidPlugin.java:**
```java
package test.plugins;

import io.casehub.yaml.plugin.api.*;
import java.util.Map;

@StepPlugin("test-action")
public record ValidPlugin(@Required String name, @Optional int count) {
    @Execute
    public StepResult run() {
        return StepResult.of(Map.of("name", name, "count", count));
    }
}
```

**test-plugins/MissingExecutePlugin.java:**
```java
package test.plugins;

import io.casehub.yaml.plugin.api.*;

@StepPlugin("missing-execute")
public record MissingExecutePlugin(@Required String name) {
    // No @Execute method — should fail
}
```

**test-plugins/WrongReturnTypePlugin.java:**
```java
package test.plugins;

import io.casehub.yaml.plugin.api.*;

@StepPlugin("wrong-return")
public record WrongReturnTypePlugin(@Required String name) {
    @Execute
    public void run() {
        // Returns void — should fail
    }
}
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-plugin-processor -Dtest=StepPluginProcessorTest`
Expected: Compilation failure — StepPluginProcessor not defined.

- [ ] **Step 7: Implement PluginModel**

```java
package io.casehub.yaml.plugin.processor;

import javax.lang.model.element.ExecutableElement;
import javax.lang.model.element.RecordComponentElement;
import javax.lang.model.element.TypeElement;
import java.util.List;

record PluginModel(
    String name,
    String description,
    TypeElement pluginClass,
    List<RecordComponentElement> fields,
    ExecutableElement executeMethod,
    List<ServiceParam> serviceParams
) {
    record ServiceParam(String typeName, String qualifiedTypeName) {}
}
```

- [ ] **Step 8: Implement StepPluginProcessor — compile-time validation**

```java
package io.casehub.yaml.plugin.processor;

import io.casehub.yaml.plugin.api.Execute;
import io.casehub.yaml.plugin.api.StepPlugin;
import io.casehub.yaml.plugin.api.StepResult;

import javax.annotation.processing.AbstractProcessor;
import javax.annotation.processing.RoundEnvironment;
import javax.annotation.processing.SupportedAnnotationTypes;
import javax.lang.model.SourceVersion;
import javax.lang.model.element.Element;
import javax.lang.model.element.ElementKind;
import javax.lang.model.element.ExecutableElement;
import javax.lang.model.element.RecordComponentElement;
import javax.lang.model.element.TypeElement;
import javax.lang.model.type.TypeMirror;
import javax.tools.Diagnostic;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;

@SupportedAnnotationTypes("*")
public class StepPluginProcessor extends AbstractProcessor {

    private boolean processed;

    @Override
    public SourceVersion getSupportedSourceVersion() {
        return SourceVersion.latestSupported();
    }

    @Override
    public boolean process(Set<? extends TypeElement> annotations, RoundEnvironment roundEnv) {
        if (processed || roundEnv.processingOver()) return false;
        processed = true;

        for (Element element : roundEnv.getElementsAnnotatedWith(StepPlugin.class)) {
            if (element.getKind() != ElementKind.RECORD) {
                error(element, "@StepPlugin must be applied to a record");
                continue;
            }
            TypeElement typeElement = (TypeElement) element;
            StepPlugin annotation = typeElement.getAnnotation(StepPlugin.class);

            PluginModel model = validate(typeElement, annotation);
            if (model != null) {
                generate(model);
            }
        }
        return false;
    }

    private PluginModel validate(TypeElement typeElement, StepPlugin annotation) {
        List<ExecutableElement> executeMethods = new ArrayList<>();
        for (Element enclosed : typeElement.getEnclosedElements()) {
            if (enclosed.getAnnotation(Execute.class) != null) {
                executeMethods.add((ExecutableElement) enclosed);
            }
        }

        if (executeMethods.isEmpty()) {
            error(typeElement, "@StepPlugin class must have exactly one @Execute method");
            return null;
        }
        if (executeMethods.size() > 1) {
            error(typeElement, "@StepPlugin class must have exactly one @Execute method, found " + executeMethods.size());
            return null;
        }

        ExecutableElement executeMethod = executeMethods.get(0);
        TypeMirror returnType = executeMethod.getReturnType();
        if (!returnType.toString().equals(StepResult.class.getCanonicalName())) {
            error(executeMethod, "@Execute method must return StepResult, found " + returnType);
            return null;
        }

        List<RecordComponentElement> fields = new ArrayList<>(typeElement.getRecordComponents());

        List<PluginModel.ServiceParam> serviceParams = new ArrayList<>();
        for (var param : executeMethod.getParameters()) {
            serviceParams.add(new PluginModel.ServiceParam(
                param.asType().toString(),
                param.asType().toString()));
        }

        return new PluginModel(
            annotation.value(),
            annotation.description(),
            typeElement,
            fields,
            executeMethod,
            serviceParams);
    }

    private void generate(PluginModel model) {
        // Generation implemented in Task 3
    }

    private void error(Element element, String message) {
        processingEnv.getMessager().printMessage(Diagnostic.Kind.ERROR, message, element);
    }
}
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-plugin-processor -Dtest=StepPluginProcessorTest`
Expected: 3 tests PASS.

- [ ] **Step 10: Commit**

```bash
git add yaml-plugin-processor/ pom.xml
git commit -m "feat: yaml-plugin-processor APT skeleton — compile-time validation

Validates @StepPlugin records: must have exactly one @Execute method
returning StepResult. Uses compile-testing for APT unit tests.

Refs casehubio/casehub-desiredstate#151"
```

### Task 3: APT generates JSON Schema, typed binder, and registry manifest

**Files:**
- Create: `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/SchemaEmitter.java`
- Create: `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/BinderEmitter.java`
- Create: `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/RegistryEmitter.java`
- Modify: `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/StepPluginProcessor.java` (wire generation)
- Test: `yaml-plugin-processor/src/test/java/io/casehub/yaml/plugin/processor/GenerationTest.java`

**Interfaces:**
- Consumes: `PluginModel` from Task 2, `PlatformSchemaGenerator` from schema-generator
- Produces: Generated schema at `META-INF/yaml-plugins/<name>.schema.json`
- Produces: Generated binder class `<PluginClass>Binder` with `invoke(Map<String,Object>, ServiceRegistry) → StepResult`
- Produces: Generated registry entry at `META-INF/yaml-plugins/<name>.json`

- [ ] **Step 1: Write generation test**

```java
package io.casehub.yaml.plugin.processor;

import com.google.testing.compile.Compilation;
import com.google.testing.compile.JavaFileObjects;
import org.junit.jupiter.api.Test;

import static com.google.testing.compile.CompilationSubject.assertThat;
import static com.google.testing.compile.Compiler.javac;

class GenerationTest {

    @Test
    void generatesBinderForValidPlugin() {
        Compilation compilation = javac()
            .withProcessors(new StepPluginProcessor())
            .compile(JavaFileObjects.forResource("test-plugins/ValidPlugin.java"));
        assertThat(compilation).succeededWithoutWarnings();
        assertThat(compilation).generatedSourceFile("test.plugins.ValidPluginBinder");
    }

    @Test
    void generatesRegistryManifest() {
        Compilation compilation = javac()
            .withProcessors(new StepPluginProcessor())
            .compile(JavaFileObjects.forResource("test-plugins/ValidPlugin.java"));
        assertThat(compilation).succeededWithoutWarnings();
        assertThat(compilation).generatedFile(
            javax.tools.StandardLocation.CLASS_OUTPUT,
            "META-INF/yaml-plugins/test-action.json");
    }

    @Test
    void generatesSchemaFile() {
        Compilation compilation = javac()
            .withProcessors(new StepPluginProcessor())
            .compile(JavaFileObjects.forResource("test-plugins/ValidPlugin.java"));
        assertThat(compilation).succeededWithoutWarnings();
        assertThat(compilation).generatedFile(
            javax.tools.StandardLocation.CLASS_OUTPUT,
            "META-INF/yaml-plugins/test-action.schema.json");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-plugin-processor -Dtest=GenerationTest`
Expected: FAIL — no generated files.

- [ ] **Step 3: Implement SchemaEmitter**

```java
package io.casehub.yaml.plugin.processor;

import io.casehub.yaml.plugin.api.Required;

import javax.annotation.processing.Filer;
import javax.lang.model.element.RecordComponentElement;
import javax.tools.FileObject;
import javax.tools.StandardLocation;
import java.io.IOException;
import java.io.PrintWriter;
import java.util.List;

class SchemaEmitter {

    void emit(PluginModel model, Filer filer) throws IOException {
        FileObject file = filer.createResource(
            StandardLocation.CLASS_OUTPUT,
            "",
            "META-INF/yaml-plugins/" + model.name() + ".schema.json");

        try (PrintWriter w = new PrintWriter(file.openWriter())) {
            w.println("{");
            w.println("  \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",");
            w.println("  \"type\": \"object\",");
            w.println("  \"properties\": {");

            List<RecordComponentElement> fields = model.fields();
            for (int i = 0; i < fields.size(); i++) {
                RecordComponentElement field = fields.get(i);
                String name = field.getSimpleName().toString();
                String jsonType = toJsonType(field.asType().toString());
                w.print("    \"" + name + "\": { \"type\": \"" + jsonType + "\" }");
                if (i < fields.size() - 1) w.print(",");
                w.println();
            }

            w.println("  },");
            w.print("  \"required\": [");
            List<String> requiredFields = fields.stream()
                .filter(f -> f.getAnnotation(Required.class) != null)
                .map(f -> "\"" + f.getSimpleName() + "\"")
                .toList();
            w.print(String.join(", ", requiredFields));
            w.println("],");
            w.println("  \"additionalProperties\": false");
            w.println("}");
        }
    }

    private String toJsonType(String javaType) {
        return switch (javaType) {
            case "java.lang.String" -> "string";
            case "int", "long", "java.lang.Integer", "java.lang.Long" -> "integer";
            case "double", "float", "java.lang.Double", "java.lang.Float" -> "number";
            case "boolean", "java.lang.Boolean" -> "boolean";
            default -> {
                if (javaType.startsWith("java.util.List")) yield "array";
                if (javaType.startsWith("java.util.Map")) yield "object";
                yield "object";
            }
        };
    }
}
```

- [ ] **Step 4: Implement BinderEmitter**

```java
package io.casehub.yaml.plugin.processor;

import io.casehub.yaml.plugin.api.Required;

import javax.annotation.processing.Filer;
import javax.lang.model.element.RecordComponentElement;
import javax.tools.JavaFileObject;
import java.io.IOException;
import java.io.PrintWriter;
import java.util.List;

class BinderEmitter {

    void emit(PluginModel model, Filer filer) throws IOException {
        String packageName = model.pluginClass().getEnclosingElement().toString();
        String simpleName = model.pluginClass().getSimpleName().toString();
        String binderName = simpleName + "Binder";
        String fqcn = packageName + "." + binderName;

        JavaFileObject file = filer.createSourceFile(fqcn, model.pluginClass());
        try (PrintWriter w = new PrintWriter(file.openWriter())) {
            w.println("package " + packageName + ";");
            w.println();
            w.println("import io.casehub.yaml.plugin.api.ServiceRegistry;");
            w.println("import io.casehub.yaml.plugin.api.StepResult;");
            w.println("import java.util.Map;");
            w.println();
            w.println("public final class " + binderName + " {");
            w.println();
            w.println("    private " + binderName + "() {}");
            w.println();
            w.println("    public static final String PLUGIN_NAME = \"" + model.name() + "\";");
            w.println();

            // Validation method
            w.println("    public static void validate(Map<String, Object> params) {");
            for (RecordComponentElement field : model.fields()) {
                if (field.getAnnotation(Required.class) != null) {
                    String name = field.getSimpleName().toString();
                    w.println("        if (!params.containsKey(\"" + name + "\")) {");
                    w.println("            throw new IllegalArgumentException(");
                    w.println("                \"" + model.name() + ": '" + name + "' is required\");");
                    w.println("        }");
                }
            }
            w.println("    }");
            w.println();

            // Invoke method
            w.println("    public static StepResult invoke(Map<String, Object> params, ServiceRegistry services) {");
            w.println("        validate(params);");
            w.print("        var spec = new " + simpleName + "(");

            List<RecordComponentElement> fields = model.fields();
            for (int i = 0; i < fields.size(); i++) {
                RecordComponentElement field = fields.get(i);
                String name = field.getSimpleName().toString();
                String type = field.asType().toString();
                String cast = castExpression(type, name);
                w.print(cast);
                if (i < fields.size() - 1) w.print(", ");
            }
            w.println(");");

            // Call @Execute method with service params
            w.print("        return spec." + model.executeMethod().getSimpleName() + "(");
            List<PluginModel.ServiceParam> serviceParams = model.serviceParams();
            for (int i = 0; i < serviceParams.size(); i++) {
                w.print("services.lookup(" + serviceParams.get(i).qualifiedTypeName() + ".class)");
                if (i < serviceParams.size() - 1) w.print(", ");
            }
            w.println(");");
            w.println("    }");
            w.println("}");
        }
    }

    private String castExpression(String type, String fieldName) {
        return switch (type) {
            case "int" -> "((Number) params.getOrDefault(\"" + fieldName + "\", 0)).intValue()";
            case "long" -> "((Number) params.getOrDefault(\"" + fieldName + "\", 0L)).longValue()";
            case "double" -> "((Number) params.getOrDefault(\"" + fieldName + "\", 0.0)).doubleValue()";
            case "boolean" -> "(Boolean) params.getOrDefault(\"" + fieldName + "\", false)";
            case "java.lang.String" -> "(String) params.get(\"" + fieldName + "\")";
            default -> "(" + type + ") params.get(\"" + fieldName + "\")";
        };
    }
}
```

- [ ] **Step 5: Implement RegistryEmitter**

```java
package io.casehub.yaml.plugin.processor;

import javax.annotation.processing.Filer;
import javax.tools.FileObject;
import javax.tools.StandardLocation;
import java.io.IOException;
import java.io.PrintWriter;

class RegistryEmitter {

    void emit(PluginModel model, Filer filer) throws IOException {
        FileObject file = filer.createResource(
            StandardLocation.CLASS_OUTPUT,
            "",
            "META-INF/yaml-plugins/" + model.name() + ".json");

        String binderFqcn = model.pluginClass().getEnclosingElement().toString()
            + "." + model.pluginClass().getSimpleName() + "Binder";

        try (PrintWriter w = new PrintWriter(file.openWriter())) {
            w.println("{");
            w.println("  \"name\": \"" + model.name() + "\",");
            w.println("  \"description\": \"" + model.description() + "\",");
            w.println("  \"pluginClass\": \"" + model.pluginClass().getQualifiedName() + "\",");
            w.println("  \"binderClass\": \"" + binderFqcn + "\",");
            w.println("  \"schemaResource\": \"META-INF/yaml-plugins/" + model.name() + ".schema.json\"");
            w.println("}");
        }
    }
}
```

- [ ] **Step 6: Wire generation into StepPluginProcessor.generate()**

Replace the empty `generate()` method in `StepPluginProcessor`:

```java
    private void generate(PluginModel model) {
        try {
            new SchemaEmitter().emit(model, processingEnv.getFiler());
            new BinderEmitter().emit(model, processingEnv.getFiler());
            new RegistryEmitter().emit(model, processingEnv.getFiler());
        } catch (Exception e) {
            error(model.pluginClass(),
                "Code generation failed for @StepPlugin '" + model.name() + "': " + e.getMessage());
        }
    }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-plugin-processor`
Expected: All 6 tests PASS (3 validation + 3 generation).

- [ ] **Step 8: Commit**

```bash
git add yaml-plugin-processor/
git commit -m "feat: APT generates schema, binder, and registry for @StepPlugin

SchemaEmitter: JSON Schema from record fields with required/optional.
BinderEmitter: typed binder class with validate() + invoke().
RegistryEmitter: META-INF/yaml-plugins/<name>.json manifest.

Refs casehubio/casehub-desiredstate#151"
```

---

## Batch 3: Proof case — assert plugin + integration test

### Task 4: @StepPlugin("assert") proof case and end-to-end test

**Files:**
- Create: `yaml-plugin-api/src/test/java/io/casehub/yaml/plugin/api/AssertActionSpec.java`
- Create: `yaml-plugin-api/src/test/java/io/casehub/yaml/plugin/api/MapServiceRegistry.java`
- Create: `yaml-plugin-processor/src/test/java/io/casehub/yaml/plugin/processor/EndToEndTest.java`
- Create: `yaml-plugin-processor/src/test/resources/test-plugins/AssertPlugin.java`

**Interfaces:**
- Consumes: `@StepPlugin`, `@Execute`, `@Required`, `StepResult`, `ServiceRegistry` from Task 1
- Consumes: Generated `AssertPluginBinder` from Task 3's APT
- Produces: End-to-end verification that annotation → APT → schema + binder → runtime dispatch works

- [ ] **Step 1: Create MapServiceRegistry test fixture**

In `yaml-plugin-api/src/test/java/`:
```java
package io.casehub.yaml.plugin.api;

import java.util.HashMap;
import java.util.Map;

public class MapServiceRegistry implements ServiceRegistry {
    private final Map<Class<?>, Object> services = new HashMap<>();

    public <T> MapServiceRegistry register(Class<T> type, T instance) {
        services.put(type, instance);
        return this;
    }

    @Override
    @SuppressWarnings("unchecked")
    public <T> T lookup(Class<T> serviceType) {
        T service = (T) services.get(serviceType);
        if (service == null) {
            throw new IllegalArgumentException(
                "No service registered for: " + serviceType.getName());
        }
        return service;
    }
}
```

- [ ] **Step 2: Create assert plugin test fixture for APT**

In `yaml-plugin-processor/src/test/resources/test-plugins/AssertPlugin.java`:
```java
package test.plugins;

import io.casehub.yaml.plugin.api.*;
import java.util.Map;

@StepPlugin(value = "assert", description = "Asserts a condition is true")
public record AssertPlugin(@Required String condition) {
    @Execute
    public StepResult run() {
        boolean result = Boolean.parseBoolean(condition);
        if (result) {
            return StepResult.of(Map.of("passed", true));
        }
        return StepResult.failed("Assertion failed: " + condition);
    }
}
```

- [ ] **Step 3: Write end-to-end test**

```java
package io.casehub.yaml.plugin.processor;

import com.google.testing.compile.Compilation;
import com.google.testing.compile.JavaFileObjects;
import org.junit.jupiter.api.Test;

import javax.tools.JavaFileObject;
import javax.tools.StandardLocation;
import java.io.IOException;

import static com.google.testing.compile.CompilationSubject.assertThat;
import static com.google.testing.compile.Compiler.javac;
import static org.assertj.core.api.Assertions.assertThat;

class EndToEndTest {

    @Test
    void assertPluginSchemaHasRequiredCondition() throws IOException {
        Compilation compilation = javac()
            .withProcessors(new StepPluginProcessor())
            .compile(JavaFileObjects.forResource("test-plugins/AssertPlugin.java"));
        assertThat(compilation).succeededWithoutWarnings();

        JavaFileObject schema = compilation.generatedFile(
            StandardLocation.CLASS_OUTPUT,
            "META-INF/yaml-plugins/assert.schema.json").orElseThrow();
        String schemaContent = schema.getCharContent(false).toString();

        assertThat(schemaContent).contains("\"condition\"");
        assertThat(schemaContent).contains("\"required\": [\"condition\"]");
        assertThat(schemaContent).contains("\"type\": \"string\"");
    }

    @Test
    void assertPluginBinderGenerated() {
        Compilation compilation = javac()
            .withProcessors(new StepPluginProcessor())
            .compile(JavaFileObjects.forResource("test-plugins/AssertPlugin.java"));
        assertThat(compilation).succeededWithoutWarnings();
        assertThat(compilation).generatedSourceFile("test.plugins.AssertPluginBinder");
    }

    @Test
    void assertPluginRegistryEntry() throws IOException {
        Compilation compilation = javac()
            .withProcessors(new StepPluginProcessor())
            .compile(JavaFileObjects.forResource("test-plugins/AssertPlugin.java"));
        assertThat(compilation).succeededWithoutWarnings();

        JavaFileObject registry = compilation.generatedFile(
            StandardLocation.CLASS_OUTPUT,
            "META-INF/yaml-plugins/assert.json").orElseThrow();
        String content = registry.getCharContent(false).toString();

        assertThat(content).contains("\"name\": \"assert\"");
        assertThat(content).contains("\"binderClass\": \"test.plugins.AssertPluginBinder\"");
    }

    @Test
    void binderValidatesRequiredField() {
        Compilation compilation = javac()
            .withProcessors(new StepPluginProcessor())
            .compile(JavaFileObjects.forResource("test-plugins/AssertPlugin.java"));
        assertThat(compilation).succeededWithoutWarnings();

        // Verify the generated binder source contains validation
        JavaFileObject binder = compilation.generatedSourceFile(
            "test.plugins.AssertPluginBinder").orElseThrow();
        try {
            String source = binder.getCharContent(false).toString();
            assertThat(source).contains("\"assert: 'condition' is required\"");
            assertThat(source).contains("public static StepResult invoke(");
            assertThat(source).contains("public static void validate(");
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-plugin-processor -Dtest=EndToEndTest`
Expected: 4 tests PASS.

- [ ] **Step 5: Run full build to verify everything compiles together**

Run: `mvn --batch-mode install -pl yaml-plugin-api,yaml-plugin-processor`
Expected: BUILD SUCCESS.

- [ ] **Step 6: Commit**

```bash
git add yaml-plugin-api/ yaml-plugin-processor/
git commit -m "feat: assert plugin proof case — end-to-end APT generation

Verifies schema, binder, and registry generation for @StepPlugin.
MapServiceRegistry test fixture for standalone service lookup.

Refs casehubio/casehub-desiredstate#151"
```

---

## References

- [2026-09-24-yaml-plugin-api-design.md] — design spec this plan implements
- [graphql-generator/GraphQLResolverProcessor.java] — APT pattern: @SupportedAnnotationTypes("*"), Jandex, Filer, compile-testing
- [simulation-generator/SimulationDecoratorProcessor.java] — APT pattern: META-INF output, processed guard
- [schema-generator/PlatformSchemaGenerator.java] — PlatformSchemaGenerator(Module...), generate(Class<?>) → JsonNode
- [yaml-core/orchestration/LoopDirective.java] — sealed config type, stays as engine vocabulary
- [casehubio/casehub-desiredstate#151] — tracking issue
