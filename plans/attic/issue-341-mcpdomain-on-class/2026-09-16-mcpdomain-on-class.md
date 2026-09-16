# @McpDomain on Class Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #341 — @McpDomain on class — eliminate SPI+impl split for single-implementation domains
**Issue group:** #341

**Goal:** Support `@McpDomain` on concrete classes so that single-implementation domains can skip the SPI interface + default impl ceremony.

**Architecture:** Lift the interface-only gate in four scanner locations (McpDomainJandexScanner, GraphQLResolverProcessor Jandex path, GraphQLResolverProcessor RoundEnv path, GraphQLModelScanner). Rename `DomainScanResult` fields from `spiInterface*` to `source*` with an `isInterface` flag. All existing interface-based domains continue to work unchanged.

**Tech Stack:** Java 21+, Jandex, javax.annotation.processing (APT), CDI/Quarkus, JavaPoet (Spring generators), google-compile-testing (APT tests)

## Global Constraints

- `platform-api/` must remain zero-dependency — no changes needed there (annotation already `@Target(TYPE)`)
- Backward compatible — all existing interface-based `@McpDomain` SPIs must continue to work
- Generated code shape is unchanged — `@Inject SourceType field;` + delegation

---

## Batch 1: Foundation — DomainScanResult rename + McpDomainJandexScanner

### Task 1: Rename DomainScanResult and update McpDomainJandexScanner

**Files:**
- Modify: `generator-common/src/main/java/io/casehub/platform/generator/DomainScanResult.java`
- Modify: `generator-common/src/main/java/io/casehub/platform/generator/McpDomainJandexScanner.java`
- Modify: `generator-common/src/test/java/io/casehub/platform/generator/McpDomainJandexScannerTest.java`
- Create: `generator-common/src/test/java/io/casehub/platform/generator/SampleClassDomain.java`

**Interfaces:**
- Produces: `DomainScanResult(domainName, sourceFqcn, sourceSimple, isInterface, basePath, operations)` — consumed by Spring writers (Task 2) and APT (Task 3)

- [ ] **Step 1: Write the class-based test fixture**

Create `generator-common/src/test/java/io/casehub/platform/generator/SampleClassDomain.java`:

```java
package io.casehub.platform.generator;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.platform.api.mcp.PlatformMutation;
import jakarta.enterprise.context.ApplicationScoped;

@McpDomain("test-class-domain")
@ApplicationScoped
public class SampleClassDomain {

    @PlatformQuery("List class items")
    public java.util.List<String> listItems(String tenancyId) {
        return java.util.List.of();
    }

    @PlatformMutation("Create class item")
    public String createItem(String name) {
        return name;
    }

    public String helperNotExposed() {
        return "not exposed";
    }
}
```

- [ ] **Step 2: Write failing tests for class-based scanning**

Add to `McpDomainJandexScannerTest.java`:

```java
private static Index classIndex;

@BeforeAll
static void buildIndex() throws Exception {
    var indexer = new Indexer();
    indexer.indexClass(SampleMcpDomain.class);
    index = indexer.complete();

    var classIndexer = new Indexer();
    classIndexer.indexClass(SampleClassDomain.class);
    classIndex = classIndexer.complete();
}

@Test
void scansClassBasedDomain() {
    var scanner = new McpDomainJandexScanner();
    List<DomainScanResult> results = scanner.scan(classIndex);

    assertThat(results).hasSize(1);
    assertThat(results.get(0).domainName()).isEqualTo("test-class-domain");
    assertThat(results.get(0).sourceSimple()).isEqualTo("SampleClassDomain");
    assertThat(results.get(0).isInterface()).isFalse();
}

@Test
void classBasedDomainScansOperations() {
    var scanner = new McpDomainJandexScanner();
    DomainScanResult domain = scanner.scan(classIndex).get(0);

    assertThat(domain.operations()).hasSize(2);

    ResolvedOperation query = domain.operations().stream()
            .filter(o -> o.methodName().equals("listItems")).findFirst().orElseThrow();
    assertThat(query.type()).isEqualTo(OperationType.QUERY);

    ResolvedOperation mutation = domain.operations().stream()
            .filter(o -> o.methodName().equals("createItem")).findFirst().orElseThrow();
    assertThat(mutation.type()).isEqualTo(OperationType.MUTATION);
}

@Test
void classBasedDomainExcludesNonAnnotatedMethods() {
    var scanner = new McpDomainJandexScanner();
    DomainScanResult domain = scanner.scan(classIndex).get(0);

    assertThat(domain.operations().stream()
            .noneMatch(o -> o.methodName().equals("helperNotExposed"))).isTrue();
}

@Test
void interfaceDomainHasIsInterfaceTrue() {
    var scanner = new McpDomainJandexScanner();
    DomainScanResult domain = scanner.scan(index).get(0);

    assertThat(domain.isInterface()).isTrue();
}
```

Also update the existing `scansDomainName` test to use the new accessor:

```java
assertThat(results.get(0).sourceSimple()).isEqualTo("SampleMcpDomain");
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl generator-common -Dtest=McpDomainJandexScannerTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation failures (field names changed, `isInterface` not found)

- [ ] **Step 4: Update DomainScanResult**

Modify `DomainScanResult.java`:

```java
public record DomainScanResult(
        String domainName,
        String sourceFqcn,
        String sourceSimple,
        boolean isInterface,
        String basePath,
        List<ResolvedOperation> operations
) {
    public static DomainScanResult of(String domainName, String sourceFqcn,
                                       String sourceSimple, boolean isInterface) {
        return new DomainScanResult(domainName, sourceFqcn, sourceSimple,
                                    isInterface, null, new ArrayList<>());
    }

    public static DomainScanResult of(String domainName, String sourceFqcn,
                                       String sourceSimple, boolean isInterface,
                                       String basePath) {
        return new DomainScanResult(domainName, sourceFqcn, sourceSimple,
                                    isInterface, basePath, new ArrayList<>());
    }

    public String resolvedBasePath() {
        return basePath != null && !basePath.isEmpty() ? basePath : "/api/" + domainName;
    }
}
```

- [ ] **Step 5: Update McpDomainJandexScanner to accept classes**

In `McpDomainJandexScanner.java`, replace line 42:

```java
// Remove: if (!java.lang.reflect.Modifier.isInterface(classInfo.flags())) { continue; }
// Replace with:
boolean isIface = java.lang.reflect.Modifier.isInterface(classInfo.flags());
```

Update the `DomainScanResult.of()` call on line 51-52 to pass `isIface`:

```java
DomainScanResult domain = domains.computeIfAbsent(domainName,
        d -> DomainScanResult.of(d, classInfo.name().toString(), classInfo.simpleName(), isIface, finalBasePath));
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl generator-common -Dtest=McpDomainJandexScannerTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: all tests PASS

- [ ] **Step 7: Commit**

```bash
git add generator-common/src/main/java/io/casehub/platform/generator/DomainScanResult.java generator-common/src/main/java/io/casehub/platform/generator/McpDomainJandexScanner.java generator-common/src/test/java/io/casehub/platform/generator/McpDomainJandexScannerTest.java generator-common/src/test/java/io/casehub/platform/generator/SampleClassDomain.java
git commit -m "feat(#341): DomainScanResult rename + McpDomainJandexScanner accepts classes

Rename spiInterfaceFqcn/spiInterfaceSimple to sourceFqcn/sourceSimple.
Add isInterface flag. Remove interface-only gate from scanner.

Refs #341

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: Update Spring generator consumers

**Files:**
- Modify: `graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/SpringGraphqlControllerWriter.java`
- Modify: `graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/SpringDomainRestControllerWriter.java`
- Modify: `graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/GraphqlSpringGeneratorMojo.java`
- Modify: `graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/GraphqlSpringVerifyMojo.java`
- Modify: `graphql-spring-generator/src/test/java/io/casehub/platform/graphql/spring/generator/SpringGeneratorWriterTest.java`

**Interfaces:**
- Consumes: `DomainScanResult.sourceFqcn()`, `DomainScanResult.sourceSimple()` (from Task 1)

- [ ] **Step 1: Run existing Spring generator tests to see compilation failures**

Run: `mvn --batch-mode test -pl graphql-spring-generator -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation errors — `spiInterfaceFqcn()` and `spiInterfaceSimple()` no longer exist

- [ ] **Step 2: Update SpringGraphqlControllerWriter**

In `SpringGraphqlControllerWriter.java`, update line 29-30:

```java
// Before:
ClassName spiType = ClassName.bestGuess(domain.spiInterfaceFqcn());
String fieldName = GeneratorUtils.decapitalize(domain.spiInterfaceSimple());

// After:
ClassName spiType = ClassName.bestGuess(domain.sourceFqcn());
String fieldName = GeneratorUtils.decapitalize(domain.sourceSimple());
```

- [ ] **Step 3: Update SpringDomainRestControllerWriter**

In `SpringDomainRestControllerWriter.java`, update the same pattern (search for `spiInterfaceFqcn` and `spiInterfaceSimple` references):

```java
ClassName spiType = ClassName.bestGuess(domain.sourceFqcn());
String fieldName = GeneratorUtils.decapitalize(domain.sourceSimple());
```

- [ ] **Step 4: Update GraphqlSpringGeneratorMojo log message**

In `GraphqlSpringGeneratorMojo.java`, update any log messages referencing "interface":

```java
// Before:
getLog().info("Generated " + count + " Spring classes from "
        + domains.size() + " @McpDomain interface(s)");

// After:
getLog().info("Generated " + count + " Spring classes from "
        + domains.size() + " @McpDomain domain(s)");
```

- [ ] **Step 5: Update GraphqlSpringVerifyMojo if needed**

Check for any `spiInterfaceFqcn`/`spiInterfaceSimple` references and update to `sourceFqcn`/`sourceSimple`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl graphql-spring-generator -Dsurefire.failIfNoSpecifiedTests=false`
Expected: all tests PASS (existing interface-based SampleDomainSpi continues to work)

- [ ] **Step 7: Commit**

```bash
git add graphql-spring-generator/
git commit -m "feat(#341): update Spring generators for DomainScanResult rename

Refs #341

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 2: APT — GraphQLResolverProcessor class support

### Task 3: Update GraphQLResolverProcessor to accept classes

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java`
- Modify: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java`

**Interfaces:**
- Consumes: None new — internal changes only

- [ ] **Step 1: Write failing APT test for class-based domain**

Add to `GraphQLResolverProcessorTest.java`:

```java
@Test
void classBasedDomainGeneratesRestResource() throws Exception {
    var cls = com.google.testing.compile.JavaFileObjects.forSourceString(
            "test.StatusService",
            """
            package test;
            import io.casehub.platform.api.mcp.*;
            import jakarta.enterprise.context.ApplicationScoped;

            @McpDomain("status")
            @ApplicationScoped
            public class StatusService {
                @PlatformQuery("Get system status")
                public String getStatus() { return "ok"; }

                @PlatformMutation("Reset status")
                public void resetStatus(String reason) {}
            }
            """);

    var compilation = com.google.testing.compile.Compiler.javac()
            .withProcessors(new GraphQLResolverProcessor())
            .withOptions("-AdomainFilter=status")
            .compile(cls);

    var restSource = compilation.generatedSourceFile(
            "io.casehub.platform.rest.generated.GeneratedStatusResource");
    assertThat(restSource).isPresent();

    String restContent = restSource.get().getCharContent(true).toString();
    assertThat(restContent).contains("@Path(\"/api/status\")");
    assertThat(restContent).contains("import test.StatusService;");
    assertThat(restContent).contains("StatusService statusService;");
    assertThat(restContent).contains("statusService.getStatus()");

    var graphqlSource = compilation.generatedSourceFile(
            "io.casehub.platform.graphql.generated.GeneratedStatusResolver");
    assertThat(graphqlSource).isPresent();

    String gqlContent = graphqlSource.get().getCharContent(true).toString();
    assertThat(gqlContent).contains("@GraphQLApi");
    assertThat(gqlContent).contains("import test.StatusService;");
    assertThat(gqlContent).contains("StatusService statusService;");
}

@Test
void classWithoutScopeEmitsWarning() throws Exception {
    var cls = com.google.testing.compile.JavaFileObjects.forSourceString(
            "test.UnscopedService",
            """
            package test;
            import io.casehub.platform.api.mcp.*;

            @McpDomain("unscoped")
            public class UnscopedService {
                @PlatformQuery("Get data")
                public String getData() { return "data"; }
            }
            """);

    var compilation = com.google.testing.compile.Compiler.javac()
            .withProcessors(new GraphQLResolverProcessor())
            .withOptions("-AdomainFilter=unscoped", "-AgenerateGraphQL=false")
            .compile(cls);

    assertThat(compilation.warnings()).anySatisfy(diag ->
            assertThat(diag.getMessage(null)).contains("without a visible CDI scope annotation"));

    // Should still generate the resource despite the warning
    assertThat(compilation.generatedSourceFile(
            "io.casehub.platform.rest.generated.GeneratedUnscopedResource")).isPresent();
}

@Test
void classWithScopeNoWarning() throws Exception {
    var cls = com.google.testing.compile.JavaFileObjects.forSourceString(
            "test.ScopedService",
            """
            package test;
            import io.casehub.platform.api.mcp.*;
            import jakarta.enterprise.context.ApplicationScoped;

            @McpDomain("scoped")
            @ApplicationScoped
            public class ScopedService {
                @PlatformQuery("Get data")
                public String getData() { return "data"; }
            }
            """);

    var compilation = com.google.testing.compile.Compiler.javac()
            .withProcessors(new GraphQLResolverProcessor())
            .withOptions("-AdomainFilter=scoped", "-AgenerateGraphQL=false")
            .compile(cls);

    assertThat(compilation.warnings()).noneSatisfy(diag ->
            assertThat(diag.getMessage(null)).contains("without a visible CDI scope annotation"));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=GraphQLResolverProcessorTest#classBasedDomainGeneratesRestResource -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — class-based domain is skipped by the interface-only gate

- [ ] **Step 3: Update scanAnnotatedInterfaces → scanAnnotatedDomains**

In `GraphQLResolverProcessor.java`:

Rename method `scanAnnotatedInterfaces` to `scanAnnotatedDomains` (line 258).

Remove the interface gate on line 264:
```java
// Remove: if (!java.lang.reflect.Modifier.isInterface(classInfo.flags())) {continue;}
```

Update the call site on line 88:
```java
// Before:
Map<String, DomainOperations> jandexDomains =
        index != null ? scanAnnotatedInterfaces(index) : new HashMap<>();

// After:
Map<String, DomainOperations> jandexDomains =
        index != null ? scanAnnotatedDomains(index) : new HashMap<>();
```

- [ ] **Step 4: Update scanRoundEnvironment to accept classes**

In `scanRoundEnvironment`, change line 470:

```java
// Before:
if (element.getKind() != javax.lang.model.element.ElementKind.INTERFACE) {continue;}

// After:
if (element.getKind() != javax.lang.model.element.ElementKind.INTERFACE
    && element.getKind() != javax.lang.model.element.ElementKind.CLASS) {continue;}
```

- [ ] **Step 5: Add APT scope warning for classes**

After accepting a class element in `scanRoundEnvironment`, add the warning check (after the kind check, before processing methods):

```java
if (element.getKind() == javax.lang.model.element.ElementKind.CLASS) {
    if (!hasVisibleCdiScope(element)) {
        processingEnv.getMessager().printMessage(Diagnostic.Kind.WARNING,
                "@McpDomain on class " + typeElement.getQualifiedName()
                + " without a visible CDI scope annotation. "
                + "The class must be a CDI bean at runtime. "
                + "Note: this check cannot see inherited scopes, stereotypes, "
                + "or scopes added by CDI extensions.",
                element);
    }
}
```

Add the helper method:

```java
private boolean hasVisibleCdiScope(javax.lang.model.element.Element element) {
    for (String scopeAnnotation : List.of(
            "jakarta.enterprise.context.ApplicationScoped",
            "jakarta.enterprise.context.RequestScoped",
            "jakarta.enterprise.context.SessionScoped",
            "jakarta.enterprise.context.Dependent",
            "jakarta.inject.Singleton")) {
        if (findAnnotationMirror(element, scopeAnnotation) != null) {
            return true;
        }
    }
    return false;
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=GraphQLResolverProcessorTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: all tests PASS (existing interface tests + new class tests)

- [ ] **Step 7: Commit**

```bash
git add graphql-generator/
git commit -m "feat(#341): GraphQLResolverProcessor accepts class-based @McpDomain

Rename scanAnnotatedInterfaces → scanAnnotatedDomains.
Accept CLASS + INTERFACE in RoundEnv scan.
Emit WARNING when class lacks visible CDI scope annotation.

Refs #341

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 3: Runtime — GraphQLModelScanner class support

### Task 4: Update GraphQLModelScanner to handle class-based domains

**Files:**
- Modify: `mcp/src/main/java/io/casehub/platform/mcp/GraphQLModelScanner.java`
- Create: `mcp/src/test/java/io/casehub/platform/mcp/ClassBasedDomainService.java`
- Modify: `mcp/src/test/java/io/casehub/platform/mcp/GraphQLModelScannerTest.java`

**Interfaces:**
- Consumes: None new — runtime CDI scanner, independent of compile-time scanners

- [ ] **Step 1: Create the class-based domain test fixture**

Create `mcp/src/test/java/io/casehub/platform/mcp/ClassBasedDomainService.java`:

```java
package io.casehub.platform.mcp;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import jakarta.enterprise.context.ApplicationScoped;

@McpDomain("class-based")
@ApplicationScoped
public class ClassBasedDomainService {

    @PlatformQuery("Get status")
    public String getStatus() {
        return "ok";
    }

    @PlatformMutation("Update status")
    public String updateStatus(String newStatus) {
        return newStatus;
    }

    public String internalHelper() {
        return "not exposed";
    }
}
```

- [ ] **Step 2: Write failing tests**

Add to `GraphQLModelScannerTest.java`:

```java
@Test
void discoversClassBasedDomain() {
    var domain = registry.getDomain("class-based");
    assertThat(domain).isPresent();
    assertThat(domain.get().name()).isEqualTo("class-based");
}

@Test
void classBasedDomainHasQueryOperations() {
    var domain = registry.getDomain("class-based").orElseThrow();
    assertThat(domain.queryCount()).isEqualTo(1);
}

@Test
void classBasedDomainHasMutationOperations() {
    var domain = registry.getDomain("class-based").orElseThrow();
    assertThat(domain.mutationCount()).isEqualTo(1);
}

@Test
void classBasedDomainOperationHasDescription() {
    var getStatus = registry.getOperation("class-based", "getStatus").orElseThrow();
    assertThat(getStatus.summary()).isEqualTo("Get status");
}

@Test
void classBasedDomainNonAnnotatedMethodNotExposed() {
    var helper = registry.getOperation("class-based", "internalHelper");
    assertThat(helper).isEmpty();
}

@Test
void classBasedDomainStoresClassAsResolverClass() {
    var getStatus = registry.getOperation("class-based", "getStatus").orElseThrow();
    assertThat(getStatus.resolverClass()).isEqualTo(ClassBasedDomainService.class);
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl mcp -Dtest=GraphQLModelScannerTest#discoversClassBasedDomain -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — `@McpDomain` on class without `@GraphQLApi` is currently skipped with a warning

- [ ] **Step 4: Update GraphQLModelScanner first pass**

In `GraphQLModelScanner.java`, replace lines 61-66:

```java
// Before:
if (!hasGraphQLApi(beanClass)) {
    if (!ModelEnricher.class.isAssignableFrom(beanClass)) {
        LOG.warnf("@McpDomain on %s without @GraphQLApi — skipping",
                  beanClass.getName());
    }
    continue;
}

// After:
if (!hasGraphQLApi(beanClass)) {
    if (ModelEnricher.class.isAssignableFrom(beanClass)) {
        continue;
    }
    // Class-based @McpDomain — read @PlatformQuery/@PlatformMutation directly
    for (Method method : beanClass.getDeclaredMethods()) {
        if (Modifier.isStatic(method.getModifiers())) { continue; }
        if (method.isAnnotationPresent(PlatformQuery.class)) {
            String desc = method.getAnnotation(PlatformQuery.class).value();
            domainOps.get(domain).add(
                    buildOperationFromMethod(method, beanClass,
                            OperationDescriptor.OperationType.QUERY, desc));
        } else if (method.isAnnotationPresent(PlatformMutation.class)) {
            String desc = method.getAnnotation(PlatformMutation.class).value();
            domainOps.get(domain).add(
                    buildOperationFromMethod(method, beanClass,
                            OperationDescriptor.OperationType.MUTATION, desc));
        }
    }
    continue;
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl mcp -Dtest=GraphQLModelScannerTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: all tests PASS (existing + new class-based tests)

- [ ] **Step 6: Run full build to verify nothing is broken**

Run: `mvn --batch-mode install -DskipTests=false`
Expected: BUILD SUCCESS — all modules compile and tests pass

- [ ] **Step 7: Commit**

```bash
git add mcp/src/main/java/io/casehub/platform/mcp/GraphQLModelScanner.java mcp/src/test/java/io/casehub/platform/mcp/ClassBasedDomainService.java mcp/src/test/java/io/casehub/platform/mcp/GraphQLModelScannerTest.java
git commit -m "feat(#341): GraphQLModelScanner handles class-based @McpDomain

Read @PlatformQuery/@PlatformMutation directly from class methods
when @McpDomain is on a class without @GraphQLApi.

Refs #341

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## References

- [specs/issue-341-mcpdomain-on-class/2026-09-16-mcpdomain-on-class-design.md] — design spec this plan implements
- [generator-common/src/main/java/io/casehub/platform/generator/DomainScanResult.java] — record to rename
- [generator-common/src/main/java/io/casehub/platform/generator/McpDomainJandexScanner.java:42] — interface gate
- [graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java:264,470] — interface gates
- [mcp/src/main/java/io/casehub/platform/mcp/GraphQLModelScanner.java:61-66] — runtime scanner
- [graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/SpringGraphqlControllerWriter.java:29-30] — field name consumer
- [graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/SpringDomainRestControllerWriter.java:46-47] — field name consumer
- [docs/specs/issue-295-unified-api-generation/] — unified API generation context
- [docs/specs/issue-299-graphql-generator-apt-fixes/] — APT fixes context
- [GitHub #341] — focal issue
