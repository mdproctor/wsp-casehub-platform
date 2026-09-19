# REST Client Simulation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #319 — feat: REST client simulation — @RegisterRestClient proxy with strategy dispatch
**Issue group:** #312 (simulation-api), #319 (REST client simulation)

**Goal:** Generate `@Decorator` classes for `@RegisterRestClient` interfaces that delegate to `SimulationStrategy` for simulation and capture, reusing the existing simulation framework.

**Architecture:** A new `RestClientSimulationProcessor` APT in `rest-client-simulation-generator` auto-detects `@RegisterRestClient` interfaces via Jandex, generates decorators with `@RestClient`-qualified delegates, and constructs `RestInvocation` inputs with HTTP metadata from JAX-RS annotations. Foundation types (`RestInvocation`, `RestClientKeyExtractor`) live in `simulation-core`.

**Tech Stack:** Java 21, Jandex (index scanning), CDI `@Decorator`, MicroProfile REST Client (`@RegisterRestClient`, `@RestClient`), JAX-RS annotations

## Global Constraints

- `simulation-api/` must remain zero-dependency — `RestInvocation` goes in `simulation-core`, NOT `simulation-api`
- `simulation-core/` has no CDI — constructor-injected POJOs only
- Generated decorators compile in the consumer module, not in the generator module
- No reactive return type support (Uni/Multi) — pass-through only (D37)
- `@RestClient` FQN: `org.eclipse.microprofile.rest.client.inject.RestClient`
- `@RegisterRestClient` FQN: `org.eclipse.microprofile.rest.client.inject.RegisterRestClient`
- The processor is `jar` packaging with `<proc>none</proc>` (mirrors simulation-generator)
- Follow existing patterns: `SimulationDecoratorProcessor` for code generation, `SimulationDecoratorProcessorTest` for testing

---

## Batch 1: Foundation — simulation-core types

### Task 1: RestInvocation + RestClientKeyExtractor + extractor registration

**Files:**
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/RestInvocation.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/strategy/RestClientKeyExtractor.java`
- Modify: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/DeclarativeExtractorFactory.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/RestInvocationTest.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/strategy/RestClientKeyExtractorTest.java`

**Interfaces:**
- Produces: `RestInvocation(String spiName, String methodName, String httpMethod, String pathTemplate, Map<String, Object> params, Object body)` — used by Task 2's generated decorator code
- Produces: `RestClientKeyExtractor implements KeyExtractor<RestInvocation>` — `extract(RestInvocation) → String`
- Produces: `"rest-client"` key-extractor spec in `DeclarativeExtractorFactory.create(String)`

- [ ] **Step 1: Write RestInvocation test**

```java
package io.casehub.platform.simulation;

import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class RestInvocationTest {

    @Test
    void recordFieldsAreAccessible() {
        var invocation = new RestInvocation(
                "scim", "membersOf", "GET", "/Groups/{id}/Members",
                Map.of("id", "grp-1"), null);

        assertThat(invocation.spiName()).isEqualTo("scim");
        assertThat(invocation.methodName()).isEqualTo("membersOf");
        assertThat(invocation.httpMethod()).isEqualTo("GET");
        assertThat(invocation.pathTemplate()).isEqualTo("/Groups/{id}/Members");
        assertThat(invocation.params()).containsEntry("id", "grp-1");
        assertThat(invocation.body()).isNull();
    }

    @Test
    void bodyIsPreserved() {
        var body = Map.of("displayName", "Test Group");
        var invocation = new RestInvocation(
                "scim", "createGroup", "POST", "/Groups",
                Map.of(), body);

        assertThat(invocation.body()).isEqualTo(body);
    }

    @Test
    void nullHttpMethodIsAllowed() {
        var invocation = new RestInvocation(
                "test", "noAnnotation", null, "/path",
                Map.of(), null);

        assertThat(invocation.httpMethod()).isNull();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=RestInvocationTest -f /Users/mdproctor/claude/casehub/slots/195/platform/pom.xml`
Expected: FAIL — `RestInvocation` class not found

- [ ] **Step 3: Implement RestInvocation**

```java
package io.casehub.platform.simulation;

import java.util.Map;

public record RestInvocation(
        String spiName,
        String methodName,
        String httpMethod,
        String pathTemplate,
        Map<String, Object> params,
        Object body
) {}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=RestInvocationTest -f /Users/mdproctor/claude/casehub/slots/195/platform/pom.xml`
Expected: PASS

- [ ] **Step 5: Write RestClientKeyExtractor test**

```java
package io.casehub.platform.simulation.strategy;

import io.casehub.platform.simulation.RestInvocation;
import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class RestClientKeyExtractorTest {

    private final RestClientKeyExtractor extractor = new RestClientKeyExtractor();

    @Test
    void extractsHttpMethodAndResolvedPath() {
        var invocation = new RestInvocation(
                "scim", "membersOf", "GET", "/Groups/{id}/Members",
                Map.of("id", "grp-1"), null);

        assertThat(extractor.extract(invocation))
                .isEqualTo("GET /Groups/grp-1/Members");
    }

    @Test
    void multiplePathParamsSubstituted() {
        var invocation = new RestInvocation(
                "github", "getFile", "GET", "/repos/{owner}/{repo}/contents/{path}",
                Map.of("owner", "casehubio", "repo", "platform", "path", "README.md"),
                null);

        assertThat(extractor.extract(invocation))
                .isEqualTo("GET /repos/casehubio/platform/contents/README.md");
    }

    @Test
    void nullHttpMethodHandledGracefully() {
        var invocation = new RestInvocation(
                "test", "noAnnotation", null, "/path",
                Map.of(), null);

        assertThat(extractor.extract(invocation))
                .isEqualTo("null /path");
    }

    @Test
    void emptyParamsPreservesTemplate() {
        var invocation = new RestInvocation(
                "test", "list", "GET", "/items",
                Map.of(), null);

        assertThat(extractor.extract(invocation))
                .isEqualTo("GET /items");
    }

    @Test
    void queryParamsNotSubstitutedIntoPath() {
        var invocation = new RestInvocation(
                "scim", "getGroup", "GET", "/Groups/{id}",
                Map.of("id", "grp-1", "attributes", "members"),
                null);

        assertThat(extractor.extract(invocation))
                .isEqualTo("GET /Groups/grp-1");
    }
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=RestClientKeyExtractorTest -f /Users/mdproctor/claude/casehub/slots/195/platform/pom.xml`
Expected: FAIL — `RestClientKeyExtractor` class not found

- [ ] **Step 7: Implement RestClientKeyExtractor**

```java
package io.casehub.platform.simulation.strategy;

import io.casehub.platform.simulation.KeyExtractor;
import io.casehub.platform.simulation.RestInvocation;

public class RestClientKeyExtractor implements KeyExtractor<RestInvocation> {

    @Override
    public String extract(final RestInvocation invocation) {
        String path = invocation.pathTemplate();
        for (var entry : invocation.params().entrySet()) {
            path = path.replace("{" + entry.getKey() + "}", String.valueOf(entry.getValue()));
        }
        return invocation.httpMethod() + " " + path;
    }
}
```

- [ ] **Step 8: Run test to verify it passes**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=RestClientKeyExtractorTest -f /Users/mdproctor/claude/casehub/slots/195/platform/pom.xml`
Expected: PASS

- [ ] **Step 9: Register `rest-client` in DeclarativeExtractorFactory**

In `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/DeclarativeExtractorFactory.java`, add a new case in `create(String)` before the `throw`:

```java
if ("rest-client".equals(spec)) {
    return input -> {
        if (input instanceof io.casehub.platform.simulation.RestInvocation ri) {
            String path = ri.pathTemplate();
            for (var e : ri.params().entrySet()) {
                path = path.replace("{" + e.getKey() + "}", String.valueOf(e.getValue()));
            }
            return ri.httpMethod() + " " + path;
        }
        return String.valueOf(input);
    };
}
```

Note: This delegates to the same logic as `RestClientKeyExtractor` but inline, avoiding a compile-time dependency from simulation-config-core on simulation-core. The `instanceof` check provides a safe fallback for non-RestInvocation inputs.

- [ ] **Step 10: Run all simulation-core and simulation-config-core tests**

Run: `mvn --batch-mode test -pl simulation-core,simulation-config-core -f /Users/mdproctor/claude/casehub/slots/195/platform/pom.xml`
Expected: PASS

- [ ] **Step 11: Commit**

```bash
git add simulation-core/src/main/java/io/casehub/platform/simulation/RestInvocation.java simulation-core/src/main/java/io/casehub/platform/simulation/strategy/RestClientKeyExtractor.java simulation-core/src/test/java/io/casehub/platform/simulation/RestInvocationTest.java simulation-core/src/test/java/io/casehub/platform/simulation/strategy/RestClientKeyExtractorTest.java simulation-config-core/src/main/java/io/casehub/platform/simulation/config/DeclarativeExtractorFactory.java
git commit -m "feat(#319): RestInvocation + RestClientKeyExtractor + rest-client extractor registration

Refs #319"
```

---

## Batch 2: Processor — rest-client-simulation-generator module

### Task 2: Module scaffolding + RestClientSimulationProcessor + tests

**Files:**
- Create: `rest-client-simulation-generator/pom.xml`
- Create: `rest-client-simulation-generator/src/main/java/io/casehub/platform/simulation/restclient/generator/RestClientSimulationProcessor.java`
- Create: `rest-client-simulation-generator/src/main/resources/META-INF/services/javax.annotation.processing.Processor`
- Create: `rest-client-simulation-generator/src/test/java/io/casehub/platform/simulation/restclient/generator/test/TestRestClient.java`
- Create: `rest-client-simulation-generator/src/test/java/io/casehub/platform/simulation/restclient/generator/test/TestNoConfigKeyClient.java`
- Create: `rest-client-simulation-generator/src/test/java/io/casehub/platform/simulation/restclient/generator/test/TestMixedClient.java`
- Create: `rest-client-simulation-generator/src/test/java/io/casehub/platform/simulation/restclient/generator/RestClientSimulationProcessorTest.java`
- Modify: `pom.xml` (parent — add module)

**Interfaces:**
- Consumes: `RestInvocation(String, String, String, String, Map<String,Object>, Object)` from Task 1 — used in generated code strings
- Consumes: `KeyExtractor<RestInvocation>` from Task 1 — referenced by generated code
- Produces: `RestClientSimulationProcessor.generateFromIndex(IndexView) → List<GeneratedSource>` — mirrors base generator API
- Produces: Generated `@Decorator` classes with `@RestClient` delegate and `RestInvocation` construction

- [ ] **Step 1: Create pom.xml**

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

    <artifactId>casehub-platform-rest-client-simulation-generator</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: REST Client Simulation Generator</name>
    <description>Annotation processor that scans @RegisterRestClient on interfaces
        (via Jandex indexes from dependency JARs) and generates @Decorator Java source files
        with @RestClient-qualified delegates and RestInvocation inputs.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-api</artifactId>
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
        <!-- Test interfaces need JAX-RS and MicroProfile REST Client annotations -->
        <dependency>
            <groupId>jakarta.ws.rs</groupId>
            <artifactId>jakarta.ws.rs-api</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.eclipse.microprofile.rest.client</groupId>
            <artifactId>microprofile-rest-client-api</artifactId>
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

Add `<module>rest-client-simulation-generator</module>` after `<module>simulation-generator</module>` in the parent pom.xml's `<modules>` section.

- [ ] **Step 3: Create service registration file**

File: `rest-client-simulation-generator/src/main/resources/META-INF/services/javax.annotation.processing.Processor`

```
io.casehub.platform.simulation.restclient.generator.RestClientSimulationProcessor
```

- [ ] **Step 4: Create test REST client interfaces**

`TestRestClient.java` — full-featured test interface:

```java
package io.casehub.platform.simulation.restclient.generator.test;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.QueryParam;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

@RegisterRestClient(configKey = "test-api")
@Path("/api")
public interface TestRestClient {

    @GET
    @Path("/items/{id}")
    String getItem(@PathParam("id") String id);

    @POST
    @Path("/items")
    String createItem(String body);

    @GET
    @Path("/items")
    String listItems(@QueryParam("page") int page, @QueryParam("size") int size);

    @GET
    @Path("/items/{id}/details")
    String getItemDetails(@PathParam("id") String id, @QueryParam("expand") String expand);

    default String healthCheck() {
        return "ok";
    }
}
```

`TestNoConfigKeyClient.java` — tests kebab-case fallback:

```java
package io.casehub.platform.simulation.restclient.generator.test;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

@RegisterRestClient
@Path("/health")
public interface TestNoConfigKeyClient {

    @GET
    String check();
}
```

`TestMixedClient.java` — tests skip when @SimulationEligible present:

```java
package io.casehub.platform.simulation.restclient.generator.test;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import io.casehub.platform.simulation.SimulationEligible;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

@SimulationEligible(name = "mixed-spi")
@RegisterRestClient(configKey = "mixed")
@Path("/mixed")
public interface TestMixedClient {

    @GET
    String get();
}
```

- [ ] **Step 5: Write processor test**

```java
package io.casehub.platform.simulation.restclient.generator;

import org.jboss.jandex.Index;
import org.jboss.jandex.IndexView;
import org.jboss.jandex.Indexer;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import io.casehub.platform.simulation.restclient.generator.test.TestRestClient;
import io.casehub.platform.simulation.restclient.generator.test.TestNoConfigKeyClient;
import io.casehub.platform.simulation.restclient.generator.test.TestMixedClient;
import io.casehub.platform.simulation.restclient.generator.RestClientSimulationProcessor.GeneratedSource;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class RestClientSimulationProcessorTest {

    private static IndexView index;

    @BeforeAll
    static void buildIndex() throws Exception {
        Indexer indexer = new Indexer();
        indexer.indexClass(TestRestClient.class);
        indexer.indexClass(TestNoConfigKeyClient.class);
        indexer.indexClass(TestMixedClient.class);
        indexer.indexClass(
                io.casehub.platform.simulation.SimulationEligible.class);
        indexer.indexClass(
                org.eclipse.microprofile.rest.client.inject.RegisterRestClient.class);
        index = indexer.complete();
    }

    @Test
    void generatesDecoratorForRegisterRestClient() {
        var processor = new RestClientSimulationProcessor();
        List<GeneratedSource> sources = processor.generateFromIndex(index);

        assertThat(sources).hasSize(2);
        assertThat(sources.stream().map(GeneratedSource::className))
                .containsExactlyInAnyOrder(
                        "io.casehub.platform.simulation.generated.SimulatedTestRestClient",
                        "io.casehub.platform.simulation.generated.SimulatedTestNoConfigKeyClient");
    }

    @Test
    void skipsInterfaceWithSimulationEligible() {
        var processor = new RestClientSimulationProcessor();
        List<GeneratedSource> sources = processor.generateFromIndex(index);

        assertThat(sources.stream().map(GeneratedSource::className))
                .doesNotContain(
                        "io.casehub.platform.simulation.generated.SimulatedTestMixedClient");
    }

    @Test
    void generatedDecoratorHasRestClientQualifier() {
        var source = findSource("TestRestClient");

        assertThat(source).contains("@Inject @Delegate @RestClient");
        assertThat(source).contains(
                "import org.eclipse.microprofile.rest.client.inject.RestClient;");
    }

    @Test
    void generatedDecoratorHasDecoratorAnnotations() {
        var source = findSource("TestRestClient");

        assertThat(source).contains("@Decorator");
        assertThat(source).contains("@Priority(jakarta.interceptor.Interceptor.Priority.APPLICATION + 200)");
        assertThat(source).contains("implements TestRestClient");
    }

    @Test
    void generatedDecoratorImportsRestInvocation() {
        var source = findSource("TestRestClient");

        assertThat(source).contains("import io.casehub.platform.simulation.RestInvocation;");
        assertThat(source).contains("import java.util.Map;");
    }

    @Test
    void methodUsesRestInvocationWithHttpMetadata() {
        var source = findSource("TestRestClient");

        assertThat(source).contains("new RestInvocation(");
        assertThat(source).contains("\"test-api\"");
        assertThat(source).contains("\"getItem\"");
        assertThat(source).contains("\"GET\"");
        assertThat(source).contains("\"/api/items/{id}\"");
    }

    @Test
    void qualifiedNameUsesConfigKey() {
        var source = findSource("TestRestClient");

        assertThat(source).contains("\"test-api.getItem\"");
        assertThat(source).contains("\"test-api.createItem\"");
        assertThat(source).contains("\"test-api.listItems\"");
    }

    @Test
    void postMethodDetected() {
        var source = findSource("TestRestClient");

        assertThat(source).contains("\"POST\"");
    }

    @Test
    void pathParamsInParamsMap() {
        var source = findSource("TestRestClient");

        assertThat(source).contains("\"id\", id");
    }

    @Test
    void queryParamsInParamsMap() {
        var source = findSource("TestRestClient");

        assertThat(source).contains("\"page\", page");
        assertThat(source).contains("\"size\", size");
    }

    @Test
    void bodyParameterDetected() {
        var source = findSource("TestRestClient");

        assertThat(source).contains(", body)");
    }

    @Test
    void defaultMethodDelegatesWithoutSimulation() {
        var source = findSource("TestRestClient");

        assertThat(source).contains("return delegate.healthCheck()");
        int healthIdx = source.indexOf("healthCheck");
        String healthSection = source.substring(healthIdx, source.indexOf("}", healthIdx) + 1);
        assertThat(healthSection).doesNotContain("RestInvocation");
        assertThat(healthSection).doesNotContain("strategyFor");
    }

    @Test
    void noConfigKeyUsesKebabCasedClassName() {
        var source = findSource("TestNoConfigKeyClient");

        assertThat(source).contains("\"test-no-config-key-client.check\"");
    }

    @Test
    void simulationFlowPresent() {
        var source = findSource("TestRestClient");

        assertThat(source).contains("simulation.strategyFor(qualifiedName)");
        assertThat(source).contains("strategy.get().canResolve(input)");
        assertThat(source).contains("strategy.get().resolve(input)");
        assertThat(source).contains("simulation.captureEnabled(qualifiedName)");
        assertThat(source).contains("simulation.capture(qualifiedName, currentPrincipal.tenancyId(), input,");
    }

    private static String findSource(String spiName) {
        var processor = new RestClientSimulationProcessor();
        List<GeneratedSource> sources = processor.generateFromIndex(index);
        return sources.stream()
                .filter(s -> s.className().contains(spiName))
                .findFirst()
                .map(GeneratedSource::sourceCode)
                .orElseThrow(() -> new AssertionError("No source for " + spiName));
    }
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `mvn --batch-mode test -pl rest-client-simulation-generator -Dtest=RestClientSimulationProcessorTest -f /Users/mdproctor/claude/casehub/slots/195/platform/pom.xml`
Expected: FAIL — `RestClientSimulationProcessor` class not found

- [ ] **Step 7: Implement RestClientSimulationProcessor**

```java
package io.casehub.platform.simulation.restclient.generator;

import io.casehub.platform.simulation.generator.SimulationDecoratorProcessor.GeneratedSource;
import org.jboss.jandex.*;

import javax.annotation.processing.*;
import javax.lang.model.SourceVersion;
import javax.lang.model.element.TypeElement;
import javax.tools.Diagnostic;
import java.io.*;
import java.util.*;

@SupportedAnnotationTypes("*")
public class RestClientSimulationProcessor extends AbstractProcessor {

    @Override
    public SourceVersion getSupportedSourceVersion() {
        return SourceVersion.latestSupported();
    }

    private static final DotName REGISTER_REST_CLIENT =
            DotName.createSimple("org.eclipse.microprofile.rest.client.inject.RegisterRestClient");
    private static final DotName SIMULATION_ELIGIBLE =
            DotName.createSimple("io.casehub.platform.simulation.SimulationEligible");
    private static final DotName PATH = DotName.createSimple("jakarta.ws.rs.Path");
    private static final DotName PATH_PARAM = DotName.createSimple("jakarta.ws.rs.PathParam");
    private static final DotName QUERY_PARAM = DotName.createSimple("jakarta.ws.rs.QueryParam");
    private static final DotName HEADER_PARAM = DotName.createSimple("jakarta.ws.rs.HeaderParam");

    private static final Set<DotName> HTTP_METHODS = Set.of(
            DotName.createSimple("jakarta.ws.rs.GET"),
            DotName.createSimple("jakarta.ws.rs.POST"),
            DotName.createSimple("jakarta.ws.rs.PUT"),
            DotName.createSimple("jakarta.ws.rs.DELETE"),
            DotName.createSimple("jakarta.ws.rs.PATCH"));

    private static final String GENERATED_PACKAGE = "io.casehub.platform.simulation.generated";

    private boolean processed = false;

    @Override
    public boolean process(Set<? extends TypeElement> annotations, RoundEnvironment roundEnv) {
        if (processed || roundEnv.processingOver()) return false;
        processed = true;

        IndexView index = loadCombinedIndex();
        if (index == null) return false;

        List<GeneratedSource> sources = generateFromIndex(index);
        for (GeneratedSource source : sources) {
            writeSourceFile(source);
        }
        return false;
    }

    List<GeneratedSource> generateFromIndex(IndexView index) {
        List<GeneratedSource> results = new ArrayList<>();

        for (AnnotationInstance ann : index.getAnnotations(REGISTER_REST_CLIENT)) {
            if (ann.target().kind() != AnnotationTarget.Kind.CLASS) continue;
            ClassInfo classInfo = ann.target().asClass();
            if (!java.lang.reflect.Modifier.isInterface(classInfo.flags())) continue;
            if (classInfo.hasAnnotation(SIMULATION_ELIGIBLE)) continue;

            AnnotationValue configKeyVal = ann.value("configKey");
            String spiName = (configKeyVal != null && !configKeyVal.asString().isEmpty())
                    ? configKeyVal.asString()
                    : toKebabCase(classInfo.simpleName());

            String classPath = resolveClassPath(classInfo);
            String decoratorName = "Simulated" + classInfo.simpleName();
            String fqcn = GENERATED_PACKAGE + "." + decoratorName;
            String source = generateDecoratorSource(classInfo, spiName, decoratorName, classPath);
            results.add(new GeneratedSource(fqcn, source));
        }

        return results;
    }

    private String resolveClassPath(ClassInfo classInfo) {
        AnnotationInstance pathAnn = classInfo.annotation(PATH);
        return pathAnn != null ? pathAnn.value().asString() : "";
    }

    private String generateDecoratorSource(ClassInfo spiClass, String spiName,
                                           String decoratorName, String classPath) {
        StringBuilder sb = new StringBuilder();
        String spiSimpleName = spiClass.simpleName();
        String spiFullName = spiClass.name().toString();

        sb.append("package ").append(GENERATED_PACKAGE).append(";\n\n");

        sb.append("import jakarta.decorator.Decorator;\n");
        sb.append("import jakarta.decorator.Delegate;\n");
        sb.append("import jakarta.annotation.Priority;\n");
        sb.append("import jakarta.inject.Inject;\n");
        sb.append("import org.eclipse.microprofile.rest.client.inject.RestClient;\n");
        sb.append("import io.casehub.platform.simulation.SimulationRuntime;\n");
        sb.append("import io.casehub.platform.simulation.SimulationStrategy;\n");
        sb.append("import io.casehub.platform.simulation.RestInvocation;\n");
        sb.append("import io.casehub.platform.api.identity.CurrentPrincipal;\n");
        sb.append("import java.util.Map;\n");
        sb.append("import java.util.LinkedHashMap;\n");
        sb.append("import ").append(spiFullName).append(";\n");

        Set<String> paramImports = collectParameterImports(spiClass);
        for (String imp : paramImports) {
            sb.append("import ").append(imp).append(";\n");
        }

        sb.append("\n");
        sb.append("// GENERATED by RestClientSimulationProcessor — do not edit\n");
        sb.append("@Decorator\n");
        sb.append("@Priority(jakarta.interceptor.Interceptor.Priority.APPLICATION + 200)\n");
        sb.append("@SuppressWarnings({\"unchecked\", \"rawtypes\"})\n");
        sb.append("public class ").append(decoratorName);
        sb.append(" implements ").append(spiSimpleName).append(" {\n\n");

        sb.append("    @Inject @Delegate @RestClient ").append(spiSimpleName).append(" delegate;\n");
        sb.append("    @Inject SimulationRuntime simulation;\n");
        sb.append("    @Inject CurrentPrincipal currentPrincipal;\n\n");

        for (MethodInfo method : spiClass.methods()) {
            if (method.isSynthetic()) continue;
            if (java.lang.reflect.Modifier.isAbstract(method.flags())) {
                generateSimulatedMethod(sb, method, spiName, classPath);
            } else {
                generateDelegatingMethod(sb, method);
            }
        }

        sb.append("}\n");
        return sb.toString();
    }

    private void generateSimulatedMethod(StringBuilder sb, MethodInfo method,
                                         String spiName, String classPath) {
        String returnType = typeToJava(method.returnType());
        boolean isVoid = method.returnType().kind() == Type.Kind.VOID;
        String qualifiedName = spiName + "." + method.name();

        String httpMethod = resolveHttpMethod(method);
        String methodPath = resolveMethodPath(method);
        String fullPath = classPath + methodPath;

        StringBuilder params = new StringBuilder();
        StringBuilder args = new StringBuilder();
        for (int i = 0; i < method.parameterTypes().size(); i++) {
            if (i > 0) { params.append(", "); args.append(", "); }
            String paramType = typeToJava(method.parameterTypes().get(i));
            String paramName = method.parameterName(i) != null ? method.parameterName(i) : "arg" + i;
            params.append(paramType).append(" ").append(paramName);
            args.append(paramName);
        }

        sb.append("    @Override\n");
        sb.append("    public ").append(returnType).append(" ").append(method.name());
        sb.append("(").append(params).append(") {\n");

        sb.append("        String qualifiedName = \"").append(qualifiedName).append("\";\n");

        // Build params map
        sb.append("        Map<String, Object> paramsMap = new LinkedHashMap<>();\n");
        String bodyParamName = null;
        for (int i = 0; i < method.parameterTypes().size(); i++) {
            String paramName = method.parameterName(i) != null ? method.parameterName(i) : "arg" + i;
            AnnotationInstance pathParam = findParamAnnotation(method, i, PATH_PARAM);
            AnnotationInstance queryParam = findParamAnnotation(method, i, QUERY_PARAM);
            AnnotationInstance headerParam = findParamAnnotation(method, i, HEADER_PARAM);

            if (pathParam != null) {
                String key = pathParam.value().asString();
                sb.append("        paramsMap.put(\"").append(key).append("\", ").append(paramName).append(");\n");
            } else if (queryParam != null) {
                String key = queryParam.value().asString();
                sb.append("        paramsMap.put(\"").append(key).append("\", ").append(paramName).append(");\n");
            } else if (headerParam != null) {
                String key = headerParam.value().asString();
                sb.append("        paramsMap.put(\"").append(key).append("\", ").append(paramName).append(");\n");
            } else {
                bodyParamName = paramName;
            }
        }

        sb.append("        RestInvocation input = new RestInvocation(\"")
                .append(spiName).append("\", \"").append(method.name()).append("\", ");
        if (httpMethod != null) {
            sb.append("\"").append(httpMethod).append("\"");
        } else {
            sb.append("null");
        }
        sb.append(", \"").append(fullPath).append("\", paramsMap, ");
        sb.append(bodyParamName != null ? bodyParamName : "null");
        sb.append(");\n");

        sb.append("        java.util.Optional<SimulationStrategy<Object, Object>> strategy = simulation.strategyFor(qualifiedName);\n");
        sb.append("        if (strategy.isPresent() && strategy.get().canResolve(input)) {\n");
        if (isVoid) {
            sb.append("            strategy.get().resolve(input);\n");
            sb.append("            return;\n");
        } else {
            sb.append("            return (").append(returnType).append(") strategy.get().resolve(input);\n");
        }
        sb.append("        }\n");

        if (isVoid) {
            sb.append("        delegate.").append(method.name()).append("(").append(args).append(");\n");
            sb.append("        if (simulation.captureEnabled(qualifiedName)) {\n");
            sb.append("            simulation.capture(qualifiedName, currentPrincipal.tenancyId(), input, null);\n");
            sb.append("        }\n");
        } else {
            sb.append("        ").append(returnType).append(" result = delegate.")
                    .append(method.name()).append("(").append(args).append(");\n");
            sb.append("        if (simulation.captureEnabled(qualifiedName)) {\n");
            sb.append("            simulation.capture(qualifiedName, currentPrincipal.tenancyId(), input, result);\n");
            sb.append("        }\n");
            sb.append("        return result;\n");
        }

        sb.append("    }\n\n");
    }

    private void generateDelegatingMethod(StringBuilder sb, MethodInfo method) {
        String returnType = typeToJava(method.returnType());
        boolean isVoid = method.returnType().kind() == Type.Kind.VOID;

        StringBuilder params = new StringBuilder();
        StringBuilder args = new StringBuilder();
        for (int i = 0; i < method.parameterTypes().size(); i++) {
            if (i > 0) { params.append(", "); args.append(", "); }
            String paramType = typeToJava(method.parameterTypes().get(i));
            String paramName = method.parameterName(i) != null ? method.parameterName(i) : "arg" + i;
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

    private String resolveHttpMethod(MethodInfo method) {
        for (DotName httpDot : HTTP_METHODS) {
            if (method.hasAnnotation(httpDot)) {
                return httpDot.local();
            }
        }
        return null;
    }

    private String resolveMethodPath(MethodInfo method) {
        AnnotationInstance pathAnn = method.annotation(PATH);
        return pathAnn != null ? pathAnn.value().asString() : "";
    }

    private AnnotationInstance findParamAnnotation(MethodInfo method, int paramIndex, DotName annName) {
        for (AnnotationInstance ann : method.annotations()) {
            if (ann.name().equals(annName)
                    && ann.target().kind() == AnnotationTarget.Kind.METHOD_PARAMETER
                    && ann.target().asMethodParameter().position() == paramIndex) {
                return ann;
            }
        }
        return null;
    }

    private Set<String> collectParameterImports(ClassInfo spiClass) {
        Set<String> imports = new HashSet<>();
        for (MethodInfo method : spiClass.methods()) {
            if (method.isSynthetic()) continue;
            for (Type paramType : method.parameterTypes()) {
                addTypeImport(imports, paramType);
            }
            if (method.returnType().kind() != Type.Kind.VOID) {
                addTypeImport(imports, method.returnType());
            }
        }
        return imports;
    }

    private void addTypeImport(Set<String> imports, Type type) {
        switch (type.kind()) {
            case CLASS -> {
                String name = type.name().toString();
                if (!name.startsWith("java.lang.") || name.indexOf('.', 10) > 0) {
                    imports.add(name);
                }
            }
            case PARAMETERIZED_TYPE -> {
                imports.add(type.asParameterizedType().name().toString());
                for (Type arg : type.asParameterizedType().arguments()) {
                    addTypeImport(imports, arg);
                }
            }
            case ARRAY -> addTypeImport(imports, type.asArrayType().constituent());
            default -> {}
        }
    }

    static String toKebabCase(String camelCase) {
        if (camelCase == null || camelCase.isEmpty()) return camelCase;
        StringBuilder result = new StringBuilder();
        for (int i = 0; i < camelCase.length(); i++) {
            char c = camelCase.charAt(i);
            if (Character.isUpperCase(c)) {
                if (i > 0) {
                    boolean prevUpper = Character.isUpperCase(camelCase.charAt(i - 1));
                    boolean nextLower = (i + 1 < camelCase.length())
                            && Character.isLowerCase(camelCase.charAt(i + 1));
                    if (!prevUpper || nextLower) {
                        result.append('-');
                    }
                }
                result.append(Character.toLowerCase(c));
            } else {
                result.append(c);
            }
        }
        return result.toString();
    }

    private String typeToJava(Type type) {
        return switch (type.kind()) {
            case VOID -> "void";
            case PRIMITIVE -> type.asPrimitiveType().primitive().name().toLowerCase();
            case CLASS -> type.asClassType().name().local();
            case PARAMETERIZED_TYPE -> {
                StringBuilder sb = new StringBuilder(type.asParameterizedType().name().local());
                sb.append("<");
                List<Type> args = type.asParameterizedType().arguments();
                for (int i = 0; i < args.size(); i++) {
                    if (i > 0) sb.append(", ");
                    sb.append(typeToJava(args.get(i)));
                }
                sb.append(">");
                yield sb.toString();
            }
            case ARRAY -> typeToJava(type.asArrayType().constituent()) + "[]";
            default -> type.name().toString();
        };
    }

    private IndexView loadCombinedIndex() {
        // Same approach as SimulationDecoratorProcessor — load from classpath JARs
        List<IndexView> indexes = new ArrayList<>();
        try {
            Enumeration<java.net.URL> resources =
                    getClass().getClassLoader().getResources("META-INF/jandex.idx");
            while (resources.hasMoreElements()) {
                java.net.URL url = resources.nextElement();
                try (InputStream is = url.openStream()) {
                    indexes.add(new org.jboss.jandex.IndexReader(is).read());
                }
            }
        } catch (IOException e) {
            if (processingEnv != null) {
                processingEnv.getMessager().printMessage(Diagnostic.Kind.WARNING,
                        "REST client simulation generator: failed to load Jandex indexes: " + e.getMessage());
            }
            return null;
        }
        return indexes.isEmpty() ? null : org.jboss.jandex.CompositeIndex.create(indexes);
    }

    private void writeSourceFile(GeneratedSource source) {
        if (processingEnv == null) return;
        try {
            var file = processingEnv.getFiler()
                    .createSourceFile(source.className());
            try (Writer writer = file.openWriter()) {
                writer.write(source.sourceCode());
            }
        } catch (IOException e) {
            processingEnv.getMessager().printMessage(Diagnostic.Kind.ERROR,
                    "REST client simulation generator: failed to write " + source.className() + ": " + e.getMessage());
        }
    }
}
```

Note: The processor reuses `GeneratedSource` from `SimulationDecoratorProcessor`. If that record is not visible (package-private), create a local `GeneratedSource` record instead:

```java
record GeneratedSource(String className, String sourceCode) {}
```

- [ ] **Step 8: Run test to verify it passes**

Run: `mvn --batch-mode test -pl rest-client-simulation-generator -Dtest=RestClientSimulationProcessorTest -f /Users/mdproctor/claude/casehub/slots/195/platform/pom.xml`
Expected: PASS

- [ ] **Step 9: Run full simulation module tests**

Run: `mvn --batch-mode test -pl simulation-api,simulation-core,simulation-generator,simulation-config-core,rest-client-simulation-generator -f /Users/mdproctor/claude/casehub/slots/195/platform/pom.xml`
Expected: PASS

- [ ] **Step 10: Commit**

```bash
git add rest-client-simulation-generator/ pom.xml
git commit -m "feat(#319): RestClientSimulationProcessor — @RegisterRestClient decorator generation

Generates @Decorator classes for @RegisterRestClient interfaces with
@RestClient-qualified delegates and RestInvocation inputs. Reads JAX-RS
annotations for HTTP metadata. Skips @SimulationEligible interfaces.

Refs #319"
```

---

## Batch 3: Documentation

### Task 3: Update simulation-guide.md + CLAUDE.md

**Files:**
- Modify: `docs/guides/simulation-guide.md` — add REST Client Simulation section
- Modify: `CLAUDE.md` — add `rest-client-simulation-generator` module entry

**Interfaces:**
- Consumes: all types and patterns from Tasks 1-2

- [ ] **Step 1: Add REST Client Simulation section to simulation-guide.md**

After the existing "Event Simulation" section, add:

```markdown
## REST Client Simulation

Simulates `@RegisterRestClient` interfaces — external HTTP APIs that may not be
available during scenario execution.

### Quick Start

Add the processor and runtime dependencies to the module containing or depending
on the REST client interface:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-rest-client-simulation-generator</artifactId>
    <scope>provided</scope>
</dependency>
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-simulation-core</artifactId>
</dependency>
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-simulation-config</artifactId>
</dependency>
```

The processor auto-detects `@RegisterRestClient` interfaces in the Jandex index
and generates `@Decorator` classes with `@RestClient`-qualified delegates.

### Configuration

```properties
# Simulate ScimClient.membersOf with key-lookup strategy
casehub.simulation.scim.membersOf.strategy=key-lookup
casehub.simulation.scim.membersOf.key-extractor=rest-client

# Capture real responses from ScimClient.getGroup
casehub.simulation.scim.getGroup.capture=true
```

The spi name is the `configKey` from `@RegisterRestClient` (e.g., `scim` for
`@RegisterRestClient(configKey = "scim")`), or the kebab-cased interface name
if no configKey is set.

### RestInvocation

All REST client method calls are wrapped in a `RestInvocation` record:

```java
RestInvocation(
    String spiName,       // "scim"
    String methodName,    // "membersOf"
    String httpMethod,    // "GET"
    String pathTemplate,  // "/Groups/{id}/Members"
    Map<String, Object> params,  // {id: "grp-1"}
    Object body           // null (or request body POJO)
)
```

### Key Extraction

The built-in `rest-client` key extractor produces keys like
`GET /Groups/grp-1/Members` — HTTP method + resolved path template.

### Limitations

- Reactive return types (`Uni<T>`, `Multi<T>`) are passed through to the real
  client without simulation or capture.
- Interfaces annotated with both `@SimulationEligible` and `@RegisterRestClient`
  are handled by the base `SimulationDecoratorProcessor`, not this processor.
```

- [ ] **Step 2: Add module entry to CLAUDE.md**

In the `## Modules` section, after the `simulation-config/` entry, add:

```markdown
| `rest-client-simulation-generator/` | `casehub-platform-rest-client-simulation-generator` | Annotation processor — scans @RegisterRestClient interfaces via Jandex, generates @Decorator classes with @RestClient-qualified delegates and RestInvocation inputs. Reads JAX-RS annotations for HTTP metadata. Skips @SimulationEligible interfaces. `jar` packaging with `<proc>none</proc>`. No quarkus:build goal |
```

Also update the simulation-core module description to mention RestInvocation:

In the existing simulation-core description, append: `RestInvocation record (REST client invocation context: spiName, methodName, httpMethod, pathTemplate, params, body). RestClientKeyExtractor (httpMethod + resolved path key).`

- [ ] **Step 3: Run full build**

Run: `mvn --batch-mode install -f /Users/mdproctor/claude/casehub/slots/195/platform/pom.xml`
Expected: BUILD SUCCESS

- [ ] **Step 4: Commit**

```bash
git add docs/guides/simulation-guide.md CLAUDE.md
git commit -m "docs(#319): add REST client simulation to guide and CLAUDE.md

Refs #319"
```

---

## References

- [2026-09-16-rest-client-simulation-design.md] — design spec this plan implements
- [simulation-generator/src/main/java/.../SimulationDecoratorProcessor.java] — base generator pattern (lines 73-230)
- [simulation-generator/src/test/java/.../SimulationDecoratorProcessorTest.java] — test pattern
- [simulation-generator/pom.xml] — module structure reference
- [simulation-core/pom.xml] — dependency reference for simulation-core
- [simulation-api/src/main/java/.../KeyExtractor.java] — KeyExtractor<I> interface
- [simulation-config-core/src/main/java/.../DeclarativeExtractorFactory.java] — extractor registration (lines 24-43)
- [simulation-config/src/main/java/.../SimulationConfigBeans.java] — CDI startup wiring
- [GitHub #319] — focal issue
- [D32-D37] — design decisions in decisions.md
