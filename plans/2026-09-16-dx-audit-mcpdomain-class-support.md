# @McpDomain Class Support + Spring Drift Elimination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/parent#489 — DX audit: CaseHub agent/tool developer experience vs Embabel
**Issue group:** #489, #490, #491, #492

**Goal:** Enable `@McpDomain` on implementation classes across all generators, fix SpringModelScanner parity, migrate 2 core POJOs to `@McpDomain`, and wire rest-spring-generator for transport endpoints — eliminating 5 of 6 hand-coded Spring REST controllers.

**Architecture:** Remove interface-only filters in 3 generator scan paths (APT Jandex, APT RoundEnv, shared Jandex scanner). Rename `DomainScanResult` fields for type-agnostic naming. Add class-first scan to `SpringModelScanner`. Annotate `SubscriptionService` and `EventTypeService` with `@McpDomain` + operation annotations. Add `rest-spring-generator` to `platform-spring` build for transport endpoints. Delete replaced hand-coded controllers.

**Tech Stack:** Java 21, Maven, Jandex, JavaPoet (Palantir), google-testing-compile (APT test harness)

## Global Constraints

- `platform-api/` must remain zero-dependency — `@McpDomain`, `@PlatformQuery`, `@PlatformMutation`, `@PathParam`, `@RestMethod`, `@RestPath` are already there
- Pre-release platform — breaking changes (field renames, deleted files) cost nothing
- IntelliJ MCP mandatory for all `.java` file edits — navigate with `ide_*`, edit with `ide_*`, verify with `ide_diagnostics`
- TDD: write failing test → verify failure → implement → verify pass → commit

---

## Batch 1: Generator Foundation — Enable @McpDomain on Classes

### Task 1: DomainScanResult field rename + McpDomainJandexScanner class support

**Files:**
- Modify: `generator-common/src/main/java/io/casehub/platform/generator/DomainScanResult.java`
- Modify: `generator-common/src/main/java/io/casehub/platform/generator/McpDomainJandexScanner.java:42`
- Modify: `graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/SpringGraphqlControllerWriter.java:29-30`
- Modify: `graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/SpringDomainRestControllerWriter.java:46-47`
- Modify: `graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/GraphqlSpringGeneratorMojo.java:37`
- Test: `graphql-spring-generator/src/test/java/io/casehub/platform/graphql/spring/generator/SpringGeneratorWriterTest.java`

**Interfaces:**
- Produces: `DomainScanResult(String domainName, String declaringTypeFqcn, String declaringTypeSimple, String basePath, List<ResolvedOperation> operations)` — renamed record with factory methods `of(domainName, declaringTypeFqcn, declaringTypeSimple)` and `of(domainName, declaringTypeFqcn, declaringTypeSimple, basePath)`

- [ ] **Step 1: Write test for class-based domain scan**

Add a test in `graphql-spring-generator` tests that indexes a concrete class with `@McpDomain` and verifies `McpDomainJandexScanner` picks it up:

```java
@Test
void scanFindsClassWithMcpDomain() throws Exception {
    var indexer = new org.jboss.jandex.Indexer();
    indexer.indexClass(SampleDomainImpl.class); // concrete class with @McpDomain
    var index = indexer.complete();

    var scanner = new McpDomainJandexScanner();
    var results = scanner.scan(index);

    assertThat(results).hasSize(1);
    assertThat(results.get(0).domainName()).isEqualTo("sample-impl");
    assertThat(results.get(0).declaringTypeFqcn()).contains("SampleDomainImpl");
}
```

Create test fixture class `SampleDomainImpl` in test sources:

```java
@McpDomain("sample-impl")
public class SampleDomainImpl {
    @PlatformQuery("Get items")
    public List<String> getItems() { return List.of(); }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl graphql-spring-generator test -Dtest=SpringGeneratorWriterTest#scanFindsClassWithMcpDomain --batch-mode`
Expected: FAIL — `McpDomainJandexScanner` skips non-interface classes; also `declaringTypeFqcn()` method doesn't exist yet.

- [ ] **Step 3: Rename DomainScanResult fields**

Use `ide_refactor_rename` to rename fields in `DomainScanResult.java`:
- `spiInterfaceFqcn` → `declaringTypeFqcn`
- `spiInterfaceSimple` → `declaringTypeSimple`

This automatically updates all consumers (SpringGraphqlControllerWriter:29-30, SpringDomainRestControllerWriter:46-47, factory methods, test references).

- [ ] **Step 4: Remove interface filter in McpDomainJandexScanner**

In `McpDomainJandexScanner.java`, remove line 42:
```java
// DELETE THIS LINE:
if (!java.lang.reflect.Modifier.isInterface(classInfo.flags())) { continue; }
```

- [ ] **Step 5: Update log message in GraphqlSpringGeneratorMojo**

In `GraphqlSpringGeneratorMojo.java:37`, change:
```java
// FROM:
getLog().info("No @McpDomain interfaces found — skipping generation.");
// TO:
getLog().info("No @McpDomain types found — skipping generation.");
```

And in line 60:
```java
// FROM:
getLog().info("Generated " + count + " Spring classes from "
        + domains.size() + " @McpDomain interface(s)");
// TO:
getLog().info("Generated " + count + " Spring classes from "
        + domains.size() + " @McpDomain type(s)");
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mvn -pl generator-common,graphql-spring-generator test --batch-mode`
Expected: ALL PASS — scanner finds classes, field names match.

- [ ] **Step 7: Verify no compile errors across modules**

Run: `mvn --batch-mode compile -pl generator-common,graphql-spring-generator,graphql-generator`
Expected: BUILD SUCCESS

- [ ] **Step 8: Commit**

```bash
git add generator-common/ graphql-spring-generator/
git commit -m "feat(#490): enable @McpDomain on classes — rename DomainScanResult fields, remove interface filter in shared scanner

Refs casehubio/parent#490"
```

### Task 2: GraphQLResolverProcessor class support (APT)

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java:258-306,456-603`
- Test: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java`

**Interfaces:**
- Consumes: google-testing-compile APT test harness (already used by existing tests)
- Produces: Generated REST + GraphQL sources from `@McpDomain`-annotated classes (same output format as interface-based generation)

- [ ] **Step 1: Write test for RoundEnv class-based domain**

Add test in `GraphQLResolverProcessorTest` that compiles a concrete class with `@McpDomain`:

```java
@Test
void roundEnvScanDiscoversLocalClass() throws Exception {
    var impl = com.google.testing.compile.JavaFileObjects.forSourceString(
            "test.SimpleService",
            """
            package test;
            import io.casehub.platform.api.mcp.McpDomain;
            import io.casehub.platform.api.mcp.PlatformQuery;
            import io.casehub.platform.api.mcp.PlatformMutation;
            import java.util.List;

            @McpDomain("simple")
            public class SimpleService {
                @PlatformQuery("List items")
                public List<String> listItems() { return List.of(); }

                @PlatformMutation("Create item")
                public String createItem(String name) { return name; }
            }
            """);

    var compilation = com.google.testing.compile.Compiler.javac()
            .withProcessors(new GraphQLResolverProcessor())
            .withOptions("-AdomainFilter=simple")
            .compile(impl);

    var restSource = compilation.generatedSourceFile(
            "io.casehub.platform.rest.generated.GeneratedSimpleResource");
    assertThat(restSource).isPresent();

    String restContent = restSource.get().getCharContent(true).toString();
    assertThat(restContent).contains("class GeneratedSimpleResource");
    assertThat(restContent).contains("@Path(\"/api/simple\")");
    assertThat(restContent).contains("import test.SimpleService;");
    assertThat(restContent).contains("SimpleService simpleService;");
    assertThat(restContent).contains("public Response listItems(");
    assertThat(restContent).contains("public Response createItem(");

    var graphqlSource = compilation.generatedSourceFile(
            "io.casehub.platform.graphql.generated.GeneratedSimpleResolver");
    assertThat(graphqlSource).isPresent();

    String gqlContent = graphqlSource.get().getCharContent(true).toString();
    assertThat(gqlContent).contains("class GeneratedSimpleResolver");
    assertThat(gqlContent).contains("SimpleService simpleService;");
    assertThat(gqlContent).contains("@Query");
    assertThat(gqlContent).contains("@Mutation");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl graphql-generator test -Dtest=GraphQLResolverProcessorTest#roundEnvScanDiscoversLocalClass --batch-mode`
Expected: FAIL — `scanRoundEnvironment()` filters out classes.

- [ ] **Step 3: Enable class scanning in scanRoundEnvironment**

In `GraphQLResolverProcessor.java`, modify `scanRoundEnvironment()` at line 470:

```java
// FROM:
if (element.getKind() != javax.lang.model.element.ElementKind.INTERFACE) {continue;}
// TO:
if (element.getKind() != javax.lang.model.element.ElementKind.INTERFACE
    && element.getKind() != javax.lang.model.element.ElementKind.CLASS) {continue;}
```

- [ ] **Step 4: Enable class scanning in scanAnnotatedInterfaces (Jandex path)**

Rename the method and remove the interface filter at line 264:

```java
// Rename method: scanAnnotatedInterfaces → scanAnnotatedTypes
// DELETE line 264:
if (!java.lang.reflect.Modifier.isInterface(classInfo.flags())) {continue;}
```

Update the call site in `process()` at line 88:
```java
// FROM:
Map<String, DomainOperations> jandexDomains =
        index != null ? scanAnnotatedInterfaces(index) : new HashMap<>();
// TO:
Map<String, DomainOperations> jandexDomains =
        index != null ? scanAnnotatedTypes(index) : new HashMap<>();
```

- [ ] **Step 5: Run all tests**

Run: `mvn -pl graphql-generator test --batch-mode`
Expected: ALL PASS — both new and existing tests.

- [ ] **Step 6: Commit**

```bash
git add graphql-generator/
git commit -m "feat(#490): enable @McpDomain on classes in APT processor

Remove interface-only filter in both Jandex and RoundEnv scan paths.
Rename scanAnnotatedInterfaces → scanAnnotatedTypes.

Refs casehubio/parent#490"
```

## Batch 2: SpringModelScanner Class Scanning Parity

### Task 3: Add class-first scan to SpringModelScanner

**Files:**
- Modify: `mcp-spring/src/main/java/io/casehub/platform/mcp/spring/SpringModelScanner.java:47-101`
- Test: `mcp-spring/src/test/java/io/casehub/platform/mcp/spring/SpringModelScannerTest.java`

**Interfaces:**
- Consumes: `DomainModelRegistry`, `ApplicationContext`, `ApplicationEventPublisher` (existing Spring beans)
- Produces: `DomainModel` entries in `DomainModelRegistry` for class-based `@McpDomain` beans

- [ ] **Step 1: Write test for class-based @McpDomain bean**

Check if `SpringModelScannerTest` exists. If it does, add a test case. If not, create it:

```java
@Test
void scanFindsClassWithMcpDomain() {
    // Create a mock ApplicationContext with a bean whose CLASS has @McpDomain
    // (not its interface)
    var context = mock(ApplicationContext.class);
    var registry = new DomainModelRegistry();
    var publisher = mock(ApplicationEventPublisher.class);

    when(context.getBeanDefinitionNames()).thenReturn(new String[]{"testService"});
    when(context.getType("testService")).thenReturn((Class) TestMcpDomainService.class);

    var scanner = new SpringModelScanner(context, registry, publisher);
    scanner.scan();

    assertThat(registry.all()).hasSize(1);
    assertThat(registry.all().get(0).domain()).isEqualTo("test-class-domain");
    assertThat(registry.all().get(0).operations()).hasSize(1);
}

@McpDomain("test-class-domain")
static class TestMcpDomainService {
    @PlatformQuery("Get data")
    public String getData() { return "test"; }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl mcp-spring test -Dtest=SpringModelScannerTest#scanFindsClassWithMcpDomain --batch-mode`
Expected: FAIL — scanner only checks interfaces.

- [ ] **Step 3: Add class-first scan**

In `SpringModelScanner.scan()`, add class-first scan BEFORE the existing interface loop (before line 59):

```java
void scan() {
    Map<String, List<OperationDescriptor>> domainOps = new LinkedHashMap<>();

    // Pass 1: class-level @McpDomain (matches GraphQLModelScanner behavior)
    for (String beanName : context.getBeanDefinitionNames()) {
        Class<?> beanType;
        try {
            beanType = context.getType(beanName);
        } catch (Exception e) {
            continue;
        }
        if (beanType == null) continue;

        McpDomain mcpDomain = findMcpDomain(beanType);
        if (mcpDomain == null) continue;
        if (ModelEnricher.class.isAssignableFrom(beanType)) continue;

        String domain = mcpDomain.value();
        domainOps.computeIfAbsent(domain, k -> new ArrayList<>());
        for (Method method : beanType.getDeclaredMethods()) {
            if (Modifier.isStatic(method.getModifiers())) continue;
            if (method.isAnnotationPresent(PlatformQuery.class)) {
                String desc = method.getAnnotation(PlatformQuery.class).value();
                domainOps.get(domain).add(
                        buildOperation(method, beanType,
                                OperationDescriptor.OperationType.QUERY, desc));
            } else if (method.isAnnotationPresent(PlatformMutation.class)) {
                String desc = method.getAnnotation(PlatformMutation.class).value();
                domainOps.get(domain).add(
                        buildOperation(method, beanType,
                                OperationDescriptor.OperationType.MUTATION, desc));
            }
        }
    }

    // Pass 2: interface-level @McpDomain (existing code — skip already-registered domains)
    for (String beanName : context.getBeanDefinitionNames()) {
        Class<?> beanType;
        try {
            beanType = context.getType(beanName);
        } catch (Exception e) {
            continue;
        }
        if (beanType == null) continue;

        for (Class<?> iface : beanType.getInterfaces()) {
            McpDomain mcpDomain = iface.getAnnotation(McpDomain.class);
            if (mcpDomain == null) continue;

            String domain = mcpDomain.value();
            if (domainOps.containsKey(domain)) continue; // already registered by class scan

            domainOps.computeIfAbsent(domain, k -> new ArrayList<>());
            for (Method method : iface.getDeclaredMethods()) {
                if (Modifier.isStatic(method.getModifiers())) continue;
                if (method.isAnnotationPresent(PlatformQuery.class)) {
                    String desc = method.getAnnotation(PlatformQuery.class).value();
                    domainOps.get(domain).add(
                            buildOperation(method, beanType,
                                    OperationDescriptor.OperationType.QUERY, desc));
                } else if (method.isAnnotationPresent(PlatformMutation.class)) {
                    String desc = method.getAnnotation(PlatformMutation.class).value();
                    domainOps.get(domain).add(
                            buildOperation(method, beanType,
                                    OperationDescriptor.OperationType.MUTATION, desc));
                }
            }
        }
    }

    // ... rest of method unchanged (enricher resolution, registration, event publishing)
```

- [ ] **Step 4: Run all tests**

Run: `mvn -pl mcp-spring test --batch-mode`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add mcp-spring/
git commit -m "feat(#492): add class-first @McpDomain scan to SpringModelScanner

Two-pass scan: class-level first, interface fallback second.
Matches GraphQLModelScanner's behavior for Quarkus/Spring parity.

Refs casehubio/parent#492"
```

## Batch 3: Core POJO Migration — @McpDomain on Subscription Services

### Task 4: Annotate SubscriptionService + EventTypeService with @McpDomain

**Files:**
- Modify: `subscriptions-core/src/main/java/io/casehub/platform/subscription/SubscriptionService.java`
- Modify: `subscriptions-core/src/main/java/io/casehub/platform/subscription/EventTypeService.java`
- Delete: `subscriptions/src/main/java/io/casehub/platform/subscription/rest/SubscriptionResource.java` (use `ide_refactor_safe_delete`)
- Delete: `subscriptions/src/main/java/io/casehub/platform/subscription/rest/EventTypeResource.java` (use `ide_refactor_safe_delete`)
- Test: `subscriptions-core/src/test/java/io/casehub/platform/subscription/SubscriptionServiceTest.java` (verify annotations present)

**Interfaces:**
- Consumes: `@McpDomain`, `@PlatformQuery`, `@PlatformMutation`, `@PathParam`, `@RestMethod`, `@RestPath` from `platform-api`
- Produces: Annotated core POJOs that APT and Spring generators can scan

- [ ] **Step 1: Write test verifying @McpDomain annotation presence**

Add test in `SubscriptionServiceTest.java`:

```java
@Test
void classCarriesMcpDomainAnnotation() {
    McpDomain ann = SubscriptionService.class.getAnnotation(McpDomain.class);
    assertThat(ann).isNotNull();
    assertThat(ann.value()).isEqualTo("subscriptions");
    assertThat(ann.basePath()).isEqualTo("/subscriptions");
}

@Test
void methodsCarryOperationAnnotations() {
    assertThat(SubscriptionService.class.getDeclaredMethods())
            .filteredOn(m -> m.isAnnotationPresent(PlatformQuery.class)
                          || m.isAnnotationPresent(PlatformMutation.class))
            .hasSizeGreaterThanOrEqualTo(7); // create, list, getById, update, delete, enable, disable
}
```

Add test in `EventTypeServiceTest.java`:

```java
@Test
void classCarriesMcpDomainAnnotation() {
    McpDomain ann = EventTypeService.class.getAnnotation(McpDomain.class);
    assertThat(ann).isNotNull();
    assertThat(ann.value()).isEqualTo("subscription-event-types");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl subscriptions-core test -Dtest="SubscriptionServiceTest#classCarriesMcpDomainAnnotation+EventTypeServiceTest#classCarriesMcpDomainAnnotation" --batch-mode`
Expected: FAIL — annotations not yet present.

- [ ] **Step 3: Annotate SubscriptionService**

Add annotations to `SubscriptionService.java`:

```java
import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PathParam;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.platform.api.mcp.RestMethod;
import io.casehub.platform.api.mcp.RestPath;
import io.casehub.platform.api.mcp.HttpMethod;

@McpDomain(value = "subscriptions", basePath = "/subscriptions")
public class SubscriptionService {
    // ... constructor unchanged ...

    @PlatformMutation("Create a subscription")
    public Subscription create(SubscriptionInput input) { ... }

    @PlatformQuery("List subscriptions")
    public SubscriptionPage list(Boolean enabled, SubscriptionScope scope,
                                  String cursor, int limit) { ... }

    @PlatformQuery("Get subscription by ID")
    public Optional<Subscription> getById(@PathParam String id) { ... }

    @PlatformMutation("Update a subscription")
    @RestMethod(HttpMethod.PATCH)
    public Optional<Subscription> update(@PathParam String id,
                                          SubscriptionUpdate update) { ... }

    @PlatformMutation("Delete a subscription")
    @RestMethod(HttpMethod.DELETE)
    public boolean delete(@PathParam String id) { ... }

    @PlatformMutation("Enable a subscription")
    @RestMethod(HttpMethod.PATCH)
    @RestPath("/{id}/enable")
    public Optional<Subscription> enable(@PathParam String id) { ... }

    @PlatformMutation("Disable a subscription")
    @RestMethod(HttpMethod.PATCH)
    @RestPath("/{id}/disable")
    public Optional<Subscription> disable(@PathParam String id) { ... }

    // ... private methods unchanged ...
}
```

- [ ] **Step 4: Annotate EventTypeService**

```java
import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformQuery;

@McpDomain(value = "subscription-event-types", basePath = "/subscriptions/event-types")
public class EventTypeService {
    // ... constructor unchanged ...

    @PlatformQuery("List available subscription event types")
    public Set<EventTypeDescriptor> listEventTypes() { ... }
}
```

- [ ] **Step 5: Run annotation tests to verify they pass**

Run: `mvn -pl subscriptions-core test --batch-mode`
Expected: ALL PASS

- [ ] **Step 6: Delete hand-written Quarkus REST resources**

Use `ide_refactor_safe_delete` for:
- `subscriptions/src/main/java/io/casehub/platform/subscription/rest/SubscriptionResource.java`
- `subscriptions/src/main/java/io/casehub/platform/subscription/rest/EventTypeResource.java`

Then verify with `ide_diagnostics` on the `subscriptions` module — no references should break.

- [ ] **Step 7: Build subscriptions modules**

Run: `mvn -pl subscriptions-core,subscriptions compile --batch-mode`
Expected: BUILD SUCCESS — deleted resources replaced by APT-generated equivalents.

- [ ] **Step 8: Commit**

```bash
git add subscriptions-core/ subscriptions/
git commit -m "feat(#490): annotate SubscriptionService + EventTypeService with @McpDomain

Move @McpDomain from SPI-interface pattern to class-level annotations
on core POJOs. Delete hand-written Quarkus REST resources — now
generated by APT processor.

Refs casehubio/parent#490"
```

## Batch 4: Spring Build Config + Drift Elimination

### Task 5: Wire generators in platform-spring and delete hand-coded controllers

**Files:**
- Modify: `platform-spring/pom.xml`
- Delete: `platform-spring/src/main/java/io/casehub/platform/spring/rest/SubscriptionRestController.java`
- Delete: `platform-spring/src/main/java/io/casehub/platform/spring/rest/EventTypeRestController.java`
- Delete: `platform-spring/src/main/java/io/casehub/platform/spring/rest/WebhookRestController.java`
- Delete: `platform-spring/src/main/java/io/casehub/platform/spring/rest/CallbackDispatchRestController.java`
- Delete: `platform-spring/src/main/java/io/casehub/platform/spring/rest/EngagementCallbackRestController.java`
- Modify: `platform-spring/src/main/java/io/casehub/platform/spring/rest/RestControllersAutoConfiguration.java`

**Interfaces:**
- Consumes: `graphql-spring-generator` (generates from @McpDomain), `rest-spring-generator` (generates from @Path)
- Produces: Generated Spring controllers replacing 5 hand-coded ones

- [ ] **Step 1: Add subscriptions-core to graphql-spring-generator config**

In `platform-spring/pom.xml`, add `subscriptions-core` to the `graphql-spring-generator` `<quarkusModules>`:

```xml
<quarkusModules>
    <quarkusModule>${project.basedir}/../platform-api</quarkusModule>
    <quarkusModule>${project.basedir}/../preferences-editor-core</quarkusModule>
    <quarkusModule>${project.basedir}/../callback-api</quarkusModule>
    <quarkusModule>${project.basedir}/../llm-config-core</quarkusModule>
    <quarkusModule>${project.basedir}/../subscriptions-core</quarkusModule>
</quarkusModules>
```

- [ ] **Step 2: Add rest-spring-generator plugin execution**

Add to `platform-spring/pom.xml` `<plugins>` section:

```xml
<plugin>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-rest-spring-generator</artifactId>
    <version>${project.version}</version>
    <executions>
        <execution>
            <id>generate</id>
            <goals><goal>generate</goal></goals>
            <configuration>
                <quarkusModules>
                    <quarkusModule>${project.basedir}/../streams-webhook</quarkusModule>
                    <quarkusModule>${project.basedir}/../callback-client</quarkusModule>
                    <quarkusModule>${project.basedir}/../notification-dispatch</quarkusModule>
                </quarkusModules>
            </configuration>
        </execution>
        <execution>
            <id>verify-rest-drift</id>
            <goals><goal>verify</goal></goals>
            <phase>verify</phase>
            <configuration>
                <quarkusModules>
                    <quarkusModule>${project.basedir}/../streams-webhook</quarkusModule>
                    <quarkusModule>${project.basedir}/../callback-client</quarkusModule>
                    <quarkusModule>${project.basedir}/../notification-dispatch</quarkusModule>
                </quarkusModules>
            </configuration>
        </execution>
    </executions>
</plugin>
```

- [ ] **Step 3: Delete 5 hand-coded Spring REST controllers**

Use `ide_refactor_safe_delete` for each:
1. `platform-spring/src/main/java/io/casehub/platform/spring/rest/SubscriptionRestController.java`
2. `platform-spring/src/main/java/io/casehub/platform/spring/rest/EventTypeRestController.java`
3. `platform-spring/src/main/java/io/casehub/platform/spring/rest/WebhookRestController.java`
4. `platform-spring/src/main/java/io/casehub/platform/spring/rest/CallbackDispatchRestController.java`
5. `platform-spring/src/main/java/io/casehub/platform/spring/rest/EngagementCallbackRestController.java`

- [ ] **Step 4: Clean up RestControllersAutoConfiguration**

Remove bean definitions for services now covered by generators:
- Remove `SubscriptionService` bean (now produced via `spring-generator` from subscriptions Quarkus CDI wiring)
- Remove `EventTypeService` bean (same)
- Remove `CallbackDispatcher` bean (now produced via `spring-generator`)

Keep bean definitions for services that are NOT generated by any generator (if any remain). If the file becomes empty, delete it and remove its `@AutoConfiguration` import registration.

- [ ] **Step 5: Build platform-spring to verify generators produce correct output**

Run: `mvn -pl platform-spring compile --batch-mode`
Expected: BUILD SUCCESS — generators produce Spring controllers, no compile errors.

If build fails due to missing Jandex indexes, ensure the source modules (subscriptions-core, streams-webhook, callback-client, notification-dispatch) have the `jandex-maven-plugin` configured to produce `META-INF/jandex.idx`.

- [ ] **Step 6: Run platform-spring tests**

Run: `mvn -pl platform-spring test --batch-mode`
Expected: ALL PASS

- [ ] **Step 7: Full build verification**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS across entire platform — all generators run, all verify goals pass, all tests pass.

- [ ] **Step 8: Commit**

```bash
git add platform-spring/
git commit -m "feat(#490): eliminate hand-coded Spring REST controllers via generators

- Add subscriptions-core to graphql-spring-generator config
- Add rest-spring-generator for webhook, callback, engagement endpoints
- Delete 5 hand-coded Spring REST controllers
- Clean up RestControllersAutoConfiguration

Only PreferenceSchemaRestController remains hand-coded (ETag logic).

Refs casehubio/parent#490"
```

---

## References

- [2026-09-16-dx-audit-mcpdomain-class-support-design.md](../specs/issue-489-dx-audit/2026-09-16-dx-audit-mcpdomain-class-support-design.md) — design spec
- `graphql-generator/GraphQLResolverProcessor.java:264,470` — interface-only filters (APT)
- `generator-common/McpDomainJandexScanner.java:42` — interface-only filter (shared scanner)
- `generator-common/DomainScanResult.java` — field renaming (`spiInterface*` → `declaringType*`)
- `mcp-spring/SpringModelScanner.java:59` — interface-only scan (Spring runtime)
- `mcp/GraphQLModelScanner.java:55-102` — two-pass reference implementation (Quarkus runtime)
- `subscriptions-core/SubscriptionService.java` — core POJO migration target
- `subscriptions-core/EventTypeService.java` — core POJO migration target
- `subscriptions/rest/SubscriptionResource.java` — hand-written Quarkus resource to delete
- `platform-spring/pom.xml` — generator config
- `platform-spring/rest/` — 5 hand-coded Spring controllers to delete
- issue-295 decisions (unified API generation)
- issue-469 decisions (core extraction)
- issue-474 decisions (Spring generators)
- casehubio/parent#489, #490, #491, #492
