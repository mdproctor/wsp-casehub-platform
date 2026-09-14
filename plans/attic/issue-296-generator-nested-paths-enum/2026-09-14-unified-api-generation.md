# Unified API Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #295 — epic: unified API generation — REST + GraphQL + MCP from @PlatformQuery/@PlatformMutation
**Issue group:** #295

**Goal:** Harden the graphql-generator APT to produce production-quality REST resources and migrate platform's simple hand-written endpoints to the generated approach.

**Architecture:** The existing `GraphQLResolverProcessor` APT scans Jandex for `@McpDomain` SPI interfaces and generates `@GraphQLApi` resolvers + `@Path` REST resources. We add three new annotations to platform-api (`HttpMethod`, `@RestMethod`, `@PathParam`), enhance the generator with proper HTTP verb mapping, parameter binding, response wrapping, kebab-case paths, and skip detection, then migrate four simple endpoints (delivery channels, digest status, callbacks, notification preferences) to the generated approach.

**Tech Stack:** Java 21, Jandex, javax.annotation.processing APT, JAX-RS (Quarkus REST), CDI, compile-testing 0.21.0

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JAX-RS imports
- Generated REST resources always include `@RunOnVirtualThread` and `@Produces(APPLICATION_JSON)` at class level
- Authorization is enforced at the service layer (`@RolesAllowed` on impl), never on generated endpoints
- Domain names in `@McpDomain` use kebab-case, matching the REST path prefix
- Pre-release — path changes from migration are acceptable (no external consumers)

---

## Batch 1: Foundation — Annotations and Utilities

### Task 1: New annotations in platform-api

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/mcp/HttpMethod.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/mcp/RestMethod.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/mcp/PathParam.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/mcp/RestMethodTest.java`

**Interfaces:**
- Consumes: nothing
- Produces: `HttpMethod` enum (GET/POST/PUT/DELETE/PATCH), `@RestMethod` annotation, `@PathParam` annotation — used by Tasks 3-6 in the generator and Tasks 7-10 in migration SPIs

- [ ] **Step 1: Write test verifying annotation retention and targets**

```java
package io.casehub.platform.api.mcp;

import org.junit.jupiter.api.Test;
import java.lang.annotation.ElementType;
import java.lang.annotation.RetentionPolicy;
import static org.assertj.core.api.Assertions.assertThat;

class RestMethodTest {

    @Test
    void restMethod_hasRuntimeRetention() {
        var retention = RestMethod.class.getAnnotation(java.lang.annotation.Retention.class);
        assertThat(retention.value()).isEqualTo(RetentionPolicy.RUNTIME);
    }

    @Test
    void restMethod_targetsMethod() {
        var target = RestMethod.class.getAnnotation(java.lang.annotation.Target.class);
        assertThat(target.value()).containsExactly(ElementType.METHOD);
    }

    @Test
    void pathParam_hasRuntimeRetention() {
        var retention = PathParam.class.getAnnotation(java.lang.annotation.Retention.class);
        assertThat(retention.value()).isEqualTo(RetentionPolicy.RUNTIME);
    }

    @Test
    void pathParam_targetsParameter() {
        var target = PathParam.class.getAnnotation(java.lang.annotation.Target.class);
        assertThat(target.value()).containsExactly(ElementType.PARAMETER);
    }

    @Test
    void httpMethod_hasAllVerbs() {
        assertThat(HttpMethod.values()).containsExactly(
            HttpMethod.GET, HttpMethod.POST, HttpMethod.PUT,
            HttpMethod.DELETE, HttpMethod.PATCH);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-api -Dtest=RestMethodTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: FAIL — classes not found

- [ ] **Step 3: Create HttpMethod enum**

```java
package io.casehub.platform.api.mcp;

public enum HttpMethod {
    GET, POST, PUT, DELETE, PATCH
}
```

- [ ] **Step 4: Create @RestMethod annotation**

```java
package io.casehub.platform.api.mcp;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface RestMethod {
    HttpMethod value();
}
```

- [ ] **Step 5: Create @PathParam annotation**

```java
package io.casehub.platform.api.mcp;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target(ElementType.PARAMETER)
@Retention(RetentionPolicy.RUNTIME)
public @interface PathParam {
    String value() default "";
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mvn --batch-mode test -pl platform-api -Dtest=RestMethodTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/mcp/HttpMethod.java platform-api/src/main/java/io/casehub/platform/api/mcp/RestMethod.java platform-api/src/main/java/io/casehub/platform/api/mcp/PathParam.java platform-api/src/test/java/io/casehub/platform/api/mcp/RestMethodTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#295): add HttpMethod, @RestMethod, @PathParam annotations to platform-api Refs #295"
```

### Task 2: Generator utilities — toKebabCase and toPascalCase

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java`
- Modify: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java`

**Interfaces:**
- Consumes: nothing
- Produces: `toKebabCase(String)` and `toPascalCase(String)` static methods on `GraphQLResolverProcessor` — used by Tasks 4-6 for path generation and class name generation

- [ ] **Step 1: Write failing tests for toKebabCase and toPascalCase**

Add to `GraphQLResolverProcessorTest.java`:

```java
@Test
void toKebabCase_camelCase() {
    assertThat(GraphQLResolverProcessor.toKebabCase("markAllRead")).isEqualTo("mark-all-read");
}

@Test
void toKebabCase_singleWord() {
    assertThat(GraphQLResolverProcessor.toKebabCase("vendors")).isEqualTo("vendors");
}

@Test
void toKebabCase_consecutiveUppercase() {
    assertThat(GraphQLResolverProcessor.toKebabCase("HTTPMethod")).isEqualTo("http-method");
}

@Test
void toKebabCase_consecutiveUppercaseInMiddle() {
    assertThat(GraphQLResolverProcessor.toKebabCase("listHTTPMethods")).isEqualTo("list-http-methods");
}

@Test
void toKebabCase_alreadyLowercase() {
    assertThat(GraphQLResolverProcessor.toKebabCase("status")).isEqualTo("status");
}

@Test
void toPascalCase_simpleWord() {
    assertThat(GraphQLResolverProcessor.toPascalCase("digest")).isEqualTo("Digest");
}

@Test
void toPascalCase_kebabCase() {
    assertThat(GraphQLResolverProcessor.toPascalCase("delivery-channels")).isEqualTo("DeliveryChannels");
}

@Test
void toPascalCase_multipleHyphens() {
    assertThat(GraphQLResolverProcessor.toPascalCase("notification-preferences")).isEqualTo("NotificationPreferences");
}

@Test
void toPascalCase_alreadyCapitalized() {
    assertThat(GraphQLResolverProcessor.toPascalCase("Digest")).isEqualTo("Digest");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=GraphQLResolverProcessorTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: FAIL — methods not found

- [ ] **Step 3: Implement toKebabCase and toPascalCase**

Add to `GraphQLResolverProcessor.java` (after the existing `escapeJavaString` method, around line 438):

```java
static String toKebabCase(String camelCase) {
    if (camelCase == null || camelCase.isEmpty()) return camelCase;
    StringBuilder sb = new StringBuilder();
    for (int i = 0; i < camelCase.length(); i++) {
        char c = camelCase.charAt(i);
        if (Character.isUpperCase(c)) {
            if (i > 0) {
                char prev = camelCase.charAt(i - 1);
                if (Character.isLowerCase(prev) || Character.isDigit(prev)) {
                    sb.append('-');
                } else if (Character.isUpperCase(prev) && i + 1 < camelCase.length()
                           && Character.isLowerCase(camelCase.charAt(i + 1))) {
                    sb.append('-');
                }
            }
            sb.append(Character.toLowerCase(c));
        } else {
            sb.append(c);
        }
    }
    return sb.toString();
}

static String toPascalCase(String kebab) {
    if (kebab == null || kebab.isEmpty()) return kebab;
    StringBuilder sb = new StringBuilder();
    for (String part : kebab.split("-")) {
        if (!part.isEmpty()) {
            sb.append(Character.toUpperCase(part.charAt(0)));
            if (part.length() > 1) {
                sb.append(part.substring(1));
            }
        }
    }
    return sb.toString();
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=GraphQLResolverProcessorTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#295): add toKebabCase and toPascalCase utilities to generator Refs #295"
```

## Batch 2: Generator Hardening

### Task 3: REST skip detection — independent from GraphQL

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java`
- Modify: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java`

**Interfaces:**
- Consumes: nothing new
- Produces: `scanHandWrittenRestMethods(IndexView)` returning `Set<String>` of `domain:methodName` keys. The existing `scanHandWrittenMethods` is renamed to `scanHandWrittenGraphQLMethods`. The `process()` method passes separate skip sets to each generator.

- [ ] **Step 1: Write compile test for REST/GraphQL skip independence**

Create a compile-testing test in `GraphQLResolverProcessorTest.java` that verifies a hand-written GraphQL resolver does NOT suppress REST generation for the same method:

```java
import com.google.testing.compile.Compilation;
import com.google.testing.compile.Compiler;
import javax.tools.JavaFileObject;
import com.google.testing.compile.JavaFileObjects;

@Test
void restSkipDetection_independentFromGraphQL() throws Exception {
    // SPI interface
    JavaFileObject spiInterface = JavaFileObjects.forSourceString(
        "io.casehub.test.TestApi",
        """
        package io.casehub.test;
        import io.casehub.platform.api.mcp.McpDomain;
        import io.casehub.platform.api.mcp.PlatformQuery;
        @McpDomain("test")
        public interface TestApi {
            @PlatformQuery("List items")
            java.util.List<String> items();
        }
        """);

    // Hand-written GraphQL resolver (has @McpDomain + @GraphQLApi)
    JavaFileObject handWrittenResolver = JavaFileObjects.forSourceString(
        "io.casehub.test.TestResolver",
        """
        package io.casehub.test;
        import io.casehub.platform.api.mcp.McpDomain;
        import org.eclipse.microprofile.graphql.GraphQLApi;
        import org.eclipse.microprofile.graphql.Query;
        @GraphQLApi
        @McpDomain("test")
        public class TestResolver {
            @Query
            public java.util.List<String> items() { return java.util.List.of(); }
        }
        """);

    Compilation compilation = Compiler.javac()
        .withProcessors(new GraphQLResolverProcessor())
        .compile(spiInterface, handWrittenResolver);

    assertThat(compilation.status()).isEqualTo(Compilation.Status.SUCCESS);
    // GraphQL resolver should be skipped (hand-written exists)
    assertThat(compilation.generatedSourceFiles().stream()
        .anyMatch(f -> f.getName().contains("GeneratedTestResolver"))).isFalse();
    // REST resource should NOT be skipped (no hand-written REST resource)
    assertThat(compilation.generatedSourceFiles().stream()
        .anyMatch(f -> f.getName().contains("GeneratedTestResource"))).isTrue();
}
```

Note: This test requires the Jandex indexes from platform-api to be on the classpath. The generator's `loadCombinedIndex()` reads `META-INF/jandex.idx` files. For compile-testing, we need the `McpDomain`/`PlatformQuery` annotations to be indexed. The existing `graphql-generator/pom.xml` already has `casehub-platform-api` as a compile dependency (which includes the Jandex index). The `compile-testing` library runs the processor against the provided source files, but the processor's `loadCombinedIndex()` reads from the classpath — meaning only pre-indexed JARs are scanned. The test source files themselves won't be in the Jandex index.

**Important:** The processor currently loads Jandex indexes from JARs on the processor's classpath. For compile-testing, the `TestApi` interface defined as source won't be in any Jandex index — only classes from JAR dependencies (like `platform-api`) will be indexed. This means we need to either:
(a) Create a test Jandex index fixture file that includes the test SPI, or
(b) Verify the skip detection logic at the unit level by testing `scanHandWrittenRestMethods` directly with a programmatically-built Index.

Approach (b) is simpler and more reliable for unit tests. Use Jandex's `Indexer` class to build an in-memory index from class bytes:

```java
@Test
void scanHandWrittenRestMethods_findsPathAndMcpDomainClass() throws Exception {
    org.jboss.jandex.Indexer indexer = new org.jboss.jandex.Indexer();
    // Index the test classes by loading their bytecode
    // For unit testing, we test the method directly via reflection or by making it package-private
}
```

Given the processor's methods are private, and compile-testing is the established pattern, let's use a hybrid approach: test the end behavior through compile-testing with a pre-built test Jandex index.

Actually, the simplest approach: **refactor the skip detection methods to be package-private (static) and test them directly with programmatic Jandex indexes.** This is the most reliable unit test approach.

- [ ] **Step 2: Refactor process() to decouple skip sets**

In `GraphQLResolverProcessor.java`, change:

1. Rename `scanHandWrittenMethods` → `scanHandWrittenGraphQLMethods` (keep same logic)
2. Add new `scanHandWrittenRestMethods(IndexView index)` — scans for classes with both `@Path` and `@McpDomain`, extracts method names from JAX-RS verb annotations
3. In `process()`, build two separate skip sets and pass the correct one to each generator

Add new DotName constants (after existing ones around line 42):

```java
private static final DotName REST_METHOD = DotName.createSimple("io.casehub.platform.api.mcp.RestMethod");
private static final DotName PATH_PARAM_ANN = DotName.createSimple("io.casehub.platform.api.mcp.PathParam");
private static final DotName PATH = DotName.createSimple("jakarta.ws.rs.Path");
private static final DotName JAX_GET = DotName.createSimple("jakarta.ws.rs.GET");
private static final DotName JAX_POST = DotName.createSimple("jakarta.ws.rs.POST");
private static final DotName JAX_PUT = DotName.createSimple("jakarta.ws.rs.PUT");
private static final DotName JAX_DELETE = DotName.createSimple("jakarta.ws.rs.DELETE");
private static final DotName JAX_PATCH = DotName.createSimple("jakarta.ws.rs.PATCH");
```

New method:

```java
Set<String> scanHandWrittenRestMethods(IndexView index) {
    Set<String> methods = new HashSet<>();
    for (AnnotationInstance pathAnn : index.getAnnotations(PATH)) {
        if (pathAnn.target().kind() != AnnotationTarget.Kind.CLASS) continue;
        ClassInfo classInfo = pathAnn.target().asClass();
        AnnotationInstance mcpDomain = classInfo.annotation(MCP_DOMAIN);
        if (mcpDomain == null) continue;
        String domain = mcpDomain.value().asString();
        for (MethodInfo method : classInfo.methods()) {
            if (method.hasAnnotation(JAX_GET) || method.hasAnnotation(JAX_POST)
                    || method.hasAnnotation(JAX_PUT) || method.hasAnnotation(JAX_DELETE)
                    || method.hasAnnotation(JAX_PATCH)) {
                methods.add(domain + ":" + method.name());
            }
        }
    }
    return methods;
}
```

Update `process()` method (lines 47-71):

```java
@Override
public boolean process(Set<? extends TypeElement> annotations, RoundEnvironment roundEnv) {
    if (processed || roundEnv.processingOver()) {
        return false;
    }
    processed = true;

    IndexView index = loadCombinedIndex();
    if (index == null) {
        return false;
    }

    Set<String> graphqlSkipMethods = scanHandWrittenGraphQLMethods(index);
    Set<String> restSkipMethods = scanHandWrittenRestMethods(index);
    Map<String, DomainOperations> domains = scanAnnotatedInterfaces(index);

    if (domains.isEmpty()) {
        return false;
    }

    for (var entry : domains.entrySet()) {
        generateResolverSource(entry.getKey(), entry.getValue(), graphqlSkipMethods);
        generateRestResourceSource(entry.getKey(), entry.getValue(), restSkipMethods);
    }

    return false;
}
```

Rename `scanHandWrittenMethods` to `scanHandWrittenGraphQLMethods` (no logic change, just rename).

- [ ] **Step 3: Run existing tests to verify no regression**

Run: `mvn --batch-mode test -pl graphql-generator -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#295): decouple REST/GraphQL skip detection in generator Refs #295"
```

### Task 4: HTTP verb mapping, @Consumes, @RunOnVirtualThread, @Produces, kebab-case paths

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java`
- Modify: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java`

**Interfaces:**
- Consumes: `toKebabCase()`, `toPascalCase()` from Task 2; DotName constants from Task 3
- Produces: Enhanced `generateRestResourceSource()` and `generateRestMethod()` with correct HTTP verbs, class-level annotations, and kebab-case paths

- [ ] **Step 1: Write unit tests for OperationInfo HTTP verb resolution**

Add to `GraphQLResolverProcessorTest.java`:

```java
@Test
void httpVerbMapping_defaultQuery_isGET() {
    assertThat(resolveHttpVerb(GraphQLResolverProcessor.OperationType.QUERY, null)).isEqualTo("GET");
}

@Test
void httpVerbMapping_defaultMutation_isPOST() {
    assertThat(resolveHttpVerb(GraphQLResolverProcessor.OperationType.MUTATION, null)).isEqualTo("POST");
}

@Test
void httpVerbMapping_restMethodOverride_DELETE() {
    assertThat(resolveHttpVerb(GraphQLResolverProcessor.OperationType.MUTATION, "DELETE")).isEqualTo("DELETE");
}

@Test
void httpVerbMapping_restMethodOverride_PUT() {
    assertThat(resolveHttpVerb(GraphQLResolverProcessor.OperationType.MUTATION, "PUT")).isEqualTo("PUT");
}

@Test
void httpVerbMapping_restMethodOverride_PATCH() {
    assertThat(resolveHttpVerb(GraphQLResolverProcessor.OperationType.MUTATION, "PATCH")).isEqualTo("PATCH");
}

private static String resolveHttpVerb(GraphQLResolverProcessor.OperationType type, String restMethodOverride) {
    return GraphQLResolverProcessor.resolveHttpVerb(type, restMethodOverride);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=GraphQLResolverProcessorTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: FAIL — `resolveHttpVerb` method not found

- [ ] **Step 3: Add resolveHttpVerb and enhance generateRestResourceSource**

Add static method to `GraphQLResolverProcessor.java`:

```java
static String resolveHttpVerb(OperationType type, String restMethodOverride) {
    if (restMethodOverride != null) {
        return restMethodOverride;
    }
    return type == OperationType.QUERY ? "GET" : "POST";
}
```

Update `OperationInfo` class to carry `restMethodOverride`:

```java
static class OperationInfo {
    final MethodInfo method;
    final ClassInfo declaringClass;
    final OperationType type;
    final String description;
    final String restMethodOverride;
    OperationInfo(MethodInfo method, ClassInfo declaringClass, OperationType type, String description, String restMethodOverride) {
        this.method = method;
        this.declaringClass = declaringClass;
        this.type = type;
        this.description = description;
        this.restMethodOverride = restMethodOverride;
    }
}
```

Update `scanAnnotatedInterfaces` to read `@RestMethod`:

```java
String restMethodOverride = null;
AnnotationInstance restMethodAnn = method.annotation(REST_METHOD);
if (restMethodAnn != null) {
    restMethodOverride = restMethodAnn.value().asEnum();
}
ops.operations.add(new OperationInfo(method, classInfo, OperationType.QUERY, desc, restMethodOverride));
```

Update `generateRestResourceSource` class-level annotations (around line 276-278):

```java
out.println("@Path(\"/api/" + domain + "\")");
out.println("@Produces(MediaType.APPLICATION_JSON)");
out.println("@RunOnVirtualThread");
out.println("@ApplicationScoped");
out.println("public class " + className + " {");
```

Add imports:

```java
out.println("import io.smallrye.common.annotation.RunOnVirtualThread;");
```

Update `generateRestMethod` to use `resolveHttpVerb` and kebab-case:

```java
private void generateRestMethod(PrintWriter out, OperationInfo op) {
    MethodInfo method = op.method;
    String httpVerb = resolveHttpVerb(op.type, op.restMethodOverride);
    String httpAnnotation = "@" + httpVerb;
    String pathSegment = toKebabCase(method.name());

    out.println("    " + httpAnnotation);
    out.println("    @Path(\"/" + pathSegment + "\")");
    // ... rest of method generation
}
```

Also use `toPascalCase` for class name generation (replacing `capitalize`):

```java
String className = "Generated" + toPascalCase(domain) + "Resource";
```

And in `generateResolverSource`:

```java
String className = "Generated" + toPascalCase(domain) + "Resolver";
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=GraphQLResolverProcessorTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#295): HTTP verb mapping, @RunOnVirtualThread, kebab-case paths in generator Refs #295"
```

### Task 5: Parameter binding — @PathParam, body detection, @QueryParam, @Valid

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java`
- Modify: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java`

**Interfaces:**
- Consumes: DotName constants from Task 3, `resolveHttpVerb` from Task 4
- Produces: Enhanced `generateRestMethod()` with correct parameter classification (path, query, body)

- [ ] **Step 1: Write tests for parameter classification**

Add to `GraphQLResolverProcessorTest.java`:

```java
@Test
void isSimpleType_string() {
    assertThat(GraphQLResolverProcessor.isSimpleType("java.lang.String")).isTrue();
}

@Test
void isSimpleType_primitiveWrapper() {
    assertThat(GraphQLResolverProcessor.isSimpleType("java.lang.Integer")).isTrue();
    assertThat(GraphQLResolverProcessor.isSimpleType("java.lang.Long")).isTrue();
    assertThat(GraphQLResolverProcessor.isSimpleType("java.lang.Boolean")).isTrue();
}

@Test
void isSimpleType_uuid() {
    assertThat(GraphQLResolverProcessor.isSimpleType("java.util.UUID")).isTrue();
}

@Test
void isSimpleType_javaTime() {
    assertThat(GraphQLResolverProcessor.isSimpleType("java.time.Instant")).isTrue();
    assertThat(GraphQLResolverProcessor.isSimpleType("java.time.LocalDate")).isTrue();
}

@Test
void isSimpleType_complexType() {
    assertThat(GraphQLResolverProcessor.isSimpleType("io.casehub.platform.api.callback.CallbackRegistrationRequest")).isFalse();
}

@Test
void isSimpleType_enum() {
    // Enums are detected via Jandex, not by name — but for the static check,
    // known platform enums like AclAction are in the index
    assertThat(GraphQLResolverProcessor.isSimpleType("io.casehub.platform.api.acl.AclAction")).isFalse();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=GraphQLResolverProcessorTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: FAIL — `isSimpleType` method not found

- [ ] **Step 3: Implement isSimpleType and update generateRestMethod**

Add to `GraphQLResolverProcessor.java`:

```java
private static final Set<String> SIMPLE_TYPES = Set.of(
    "java.lang.String",
    "java.lang.Integer", "java.lang.Long", "java.lang.Short", "java.lang.Byte",
    "java.lang.Float", "java.lang.Double", "java.lang.Boolean", "java.lang.Character",
    "java.util.UUID"
);

static boolean isSimpleType(String fqcn) {
    if (SIMPLE_TYPES.contains(fqcn)) return true;
    if (fqcn.startsWith("java.time.")) return true;
    return false;
}
```

Update `generateRestMethod` for parameter binding:

```java
private void generateRestMethod(PrintWriter out, OperationInfo op) {
    MethodInfo method = op.method;
    String httpVerb = resolveHttpVerb(op.type, op.restMethodOverride);
    boolean isBodyVerb = httpVerb.equals("POST") || httpVerb.equals("PUT") || httpVerb.equals("PATCH");

    // Classify parameters
    List<String> pathParams = new ArrayList<>();
    int bodyParamIndex = -1;
    int complexCount = 0;

    for (int i = 0; i < method.parameterTypes().size(); i++) {
        if (method.parameterAnnotation(i, PATH_PARAM_ANN) != null) {
            String paramName = method.parameterName(i) != null ? method.parameterName(i) : "arg" + i;
            AnnotationInstance ppAnn = method.parameterAnnotation(i, PATH_PARAM_ANN);
            String pathName = (ppAnn.value() != null && !ppAnn.value().asString().isEmpty())
                ? ppAnn.value().asString() : paramName;
            pathParams.add(pathName);
        } else if (isBodyVerb && !isSimpleType(method.parameterTypes().get(i).name().toString())
                   && !method.parameterTypes().get(i).kind().equals(Type.Kind.PRIMITIVE)) {
            // Check if this is an enum via Jandex
            boolean isEnum = false;
            if (method.parameterTypes().get(i).kind() == Type.Kind.CLASS) {
                // We can't check enum status without the full index here,
                // so we treat unrecognized types as complex
            }
            complexCount++;
            if (bodyParamIndex < 0) {
                bodyParamIndex = i;
            }
        }
    }

    if (complexCount > 1) {
        processingEnv.getMessager().printMessage(Diagnostic.Kind.ERROR,
            "REST generator: method '" + method.name() + "' on domain '" + op.declaringClass.name()
            + "' has " + complexCount + " complex parameters. Wrap them in a single request DTO"
            + " or annotate path parameters with @PathParam.");
        return;
    }

    boolean hasBody = bodyParamIndex >= 0;

    // Build path with @PathParam segments
    StringBuilder pathSuffix = new StringBuilder();
    pathSuffix.append("/").append(toKebabCase(method.name()));
    for (String pp : pathParams) {
        pathSuffix.append("/{").append(pp).append("}");
    }

    out.println("    @" + httpVerb);
    out.println("    @Path(\"" + pathSuffix + "\")");
    if (hasBody) {
        out.println("    @Consumes(MediaType.APPLICATION_JSON)");
    }

    // Build parameter list
    String returnType = "Response";
    StringBuilder params = new StringBuilder();
    for (int i = 0; i < method.parameterTypes().size(); i++) {
        if (i > 0) params.append(", ");
        String paramName = method.parameterName(i) != null ? method.parameterName(i) : "arg" + i;

        if (method.parameterAnnotation(i, PATH_PARAM_ANN) != null) {
            AnnotationInstance ppAnn = method.parameterAnnotation(i, PATH_PARAM_ANN);
            String pathName = (ppAnn.value() != null && !ppAnn.value().asString().isEmpty())
                ? ppAnn.value().asString() : paramName;
            params.append("@jakarta.ws.rs.PathParam(\"").append(pathName).append("\") ");
        } else if (i == bodyParamIndex) {
            params.append("@jakarta.validation.Valid ");
        } else {
            params.append("@QueryParam(\"").append(paramName).append("\") ");
        }
        params.append(typeToJava(method.parameterTypes().get(i)));
        params.append(" ").append(paramName);
    }

    out.println("    public " + returnType + " " + method.name() + "(" + params + ") {");
    // ... delegate and wrap response (Task 6)
}
```

Add `@Consumes` import to the generated file:

```java
out.println("import jakarta.ws.rs.Consumes;");
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=GraphQLResolverProcessorTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#295): parameter binding — @PathParam, body detection, @Valid in generator Refs #295"
```

### Task 6: Response wrapping — void→204, Optional→404, T→200

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java`
- Modify: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java`

**Interfaces:**
- Consumes: Parameter binding from Task 5
- Produces: Complete `generateRestMethod()` with Response wrapping. All generated REST methods return `jakarta.ws.rs.core.Response`.

- [ ] **Step 1: Write tests for response wrapping classification**

Add to `GraphQLResolverProcessorTest.java`:

```java
@Test
void responseWrapping_void_returns204() {
    assertThat(GraphQLResolverProcessor.generateResponseCode("void", "spi.doThing(arg0)"))
        .isEqualTo("spi.doThing(arg0); return Response.noContent().build();");
}

@Test
void responseWrapping_optional_returns200or404() {
    assertThat(GraphQLResolverProcessor.generateResponseCode("Optional<String>", "spi.findItem(arg0)"))
        .isEqualTo("return spi.findItem(arg0).map(v -> Response.ok(v).build()).orElse(Response.status(404).build());");
}

@Test
void responseWrapping_regularType_returns200() {
    assertThat(GraphQLResolverProcessor.generateResponseCode("List<String>", "spi.listItems()"))
        .isEqualTo("return Response.ok(spi.listItems()).build();");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=GraphQLResolverProcessorTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: FAIL — `generateResponseCode` method not found

- [ ] **Step 3: Implement generateResponseCode and wire into generateRestMethod**

Add to `GraphQLResolverProcessor.java`:

```java
static String generateResponseCode(String returnType, String delegateCall) {
    if ("void".equals(returnType)) {
        return delegateCall + "; return Response.noContent().build();";
    }
    if (returnType.startsWith("Optional<")) {
        return "return " + delegateCall + ".map(v -> Response.ok(v).build()).orElse(Response.status(404).build());";
    }
    return "return Response.ok(" + delegateCall + ").build();";
}
```

Update `generateRestMethod` body generation to use this:

```java
String fieldName = decapitalize(op.declaringClass.simpleName());
StringBuilder args = new StringBuilder();
for (int i = 0; i < method.parameterTypes().size(); i++) {
    if (i > 0) args.append(", ");
    args.append(method.parameterName(i) != null ? method.parameterName(i) : "arg" + i);
}

String returnTypeStr = typeToJava(method.returnType());
String delegateCall = fieldName + "." + method.name() + "(" + args + ")";
String responseCode = generateResponseCode(returnTypeStr, delegateCall);

out.println("        " + responseCode);
```

Also check for `Optional` in return type detection. The `typeToJava` method returns `Optional<T>` for parameterized Optional types. To detect Optional, check:

```java
private static boolean isOptionalReturn(Type type) {
    if (type.kind() == Type.Kind.PARAMETERIZED_TYPE) {
        return type.asParameterizedType().name().toString().equals("java.util.Optional");
    }
    return false;
}
```

Add `jakarta.ws.rs.core.Response` to the generated imports:

```java
out.println("import jakarta.ws.rs.core.Response;");
```

- [ ] **Step 4: Run full generator test suite**

Run: `mvn --batch-mode test -pl graphql-generator -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: PASS

- [ ] **Step 5: Run full build to verify no regressions across platform**

Run: `mvn --batch-mode install -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: BUILD SUCCESS

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#295): response wrapping — void→204, Optional→404, T→200 in generator Refs #295"
```

## Batch 3: Platform Migration — Simple Endpoints

### Task 7: Delivery channels migration

**Files:**
- Create: `notifications/src/main/java/io/casehub/platform/notification/rest/DeliveryChannelApi.java`
- Create: `notifications/src/main/java/io/casehub/platform/notification/rest/DeliveryChannelService.java`
- Delete: `notifications/src/main/java/io/casehub/platform/notification/rest/DeliveryChannelResource.java` (use `ide_refactor_safe_delete`)
- Modify: `notifications/src/test/java/io/casehub/platform/notification/rest/DeliveryChannelResourceTest.java`
- Modify: `notifications/pom.xml`

**Interfaces:**
- Consumes: Generator from Batch 2 (generates REST + GraphQL from @McpDomain SPI)
- Produces: `DeliveryChannelApi` interface, `DeliveryChannelService` implementation, generated REST endpoint at `/api/delivery-channels/list-channels`

- [ ] **Step 1: Add graphql-generator to notifications pom.xml**

Add `<annotationProcessorPaths>` to the `maven-compiler-plugin` configuration. The notifications pom currently has no compiler plugin config, so add it inside the existing `<plugins>` block in `<build>`:

```xml
<plugin>
    <artifactId>maven-compiler-plugin</artifactId>
    <configuration>
        <annotationProcessorPaths>
            <path>
                <groupId>io.casehub</groupId>
                <artifactId>casehub-platform-graphql-generator</artifactId>
                <version>${project.version}</version>
            </path>
            <path>
                <groupId>io.casehub</groupId>
                <artifactId>casehub-platform-api</artifactId>
                <version>${project.version}</version>
            </path>
        </annotationProcessorPaths>
    </configuration>
</plugin>
```

Both the generator JAR and the platform-api JAR (for the Jandex index containing annotation definitions) are needed.

- [ ] **Step 2: Create DeliveryChannelApi SPI interface**

```java
package io.casehub.platform.notification.rest;

import io.casehub.platform.api.delivery.DeliveryChannelDescriptor;
import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformQuery;

import java.util.Set;

@McpDomain("delivery-channels")
public interface DeliveryChannelApi {

    @PlatformQuery("List all registered delivery channels")
    Set<DeliveryChannelDescriptor> listChannels();
}
```

- [ ] **Step 3: Create DeliveryChannelService implementation**

```java
package io.casehub.platform.notification.rest;

import io.casehub.platform.api.delivery.DeliveryChannelDescriptor;
import io.casehub.platform.api.delivery.DeliveryChannelRegistry;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.util.Set;

@ApplicationScoped
public class DeliveryChannelService implements DeliveryChannelApi {

    private final DeliveryChannelRegistry channelRegistry;

    @Inject
    public DeliveryChannelService(DeliveryChannelRegistry channelRegistry) {
        this.channelRegistry = channelRegistry;
    }

    @Override
    public Set<DeliveryChannelDescriptor> listChannels() {
        return channelRegistry.discover();
    }
}
```

- [ ] **Step 4: Delete hand-written DeliveryChannelResource**

Use `ide_refactor_safe_delete` on `DeliveryChannelResource.java`.

- [ ] **Step 5: Update test to use new path**

In `DeliveryChannelResourceTest.java`, change the GET path from `/notifications/channels` to `/api/delivery-channels/list-channels`:

```java
@Test
void getChannels_returnsRegisteredChannels() {
    given()
        .when().get("/api/delivery-channels/list-channels")
        .then()
        .statusCode(200)
        .contentType(ContentType.JSON)
        .body("$", hasSize(1))
        .body("[0].channelId", equalTo("test_channel"))
        .body("[0].displayName", equalTo("Test Channel"))
        .body("[0].external", equalTo(true));
}
```

- [ ] **Step 6: Build and test**

Run: `mvn --batch-mode test -pl notifications -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: PASS — generated REST endpoint serves the same data

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add notifications/src/main/java/io/casehub/platform/notification/rest/DeliveryChannelApi.java notifications/src/main/java/io/casehub/platform/notification/rest/DeliveryChannelService.java notifications/src/test/java/io/casehub/platform/notification/rest/DeliveryChannelResourceTest.java notifications/pom.xml
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#295): migrate DeliveryChannelResource to generated endpoint Refs #295"
```

### Task 8: Digest status migration

**Files:**
- Create: `notifications/src/main/java/io/casehub/platform/notification/rest/DigestApi.java`
- Create: `notifications/src/main/java/io/casehub/platform/notification/rest/DigestService.java`
- Delete: `notifications/src/main/java/io/casehub/platform/notification/rest/DigestStatusResource.java` (use `ide_refactor_safe_delete`)
- Modify: `notifications/src/test/java/io/casehub/platform/notification/rest/DigestStatusResourceTest.java`

**Interfaces:**
- Consumes: Generator (APT already configured in notifications pom from Task 7)
- Produces: `DigestApi` interface, `DigestService` implementation (absorbs CurrentPrincipal logic)

- [ ] **Step 1: Create DigestApi SPI interface**

```java
package io.casehub.platform.notification.rest;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformQuery;

import java.util.Map;

@McpDomain("digest")
public interface DigestApi {

    @PlatformQuery("Get digest status — pending notification counts per channel for the current user")
    Map<String, Integer> status();
}
```

- [ ] **Step 2: Create DigestService implementation**

```java
package io.casehub.platform.notification.rest;

import io.casehub.platform.api.delivery.DigestBuffer;
import io.casehub.platform.api.identity.CurrentPrincipal;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.util.LinkedHashMap;
import java.util.Map;

@ApplicationScoped
public class DigestService implements DigestApi {

    private final DigestBuffer digestBuffer;
    private final CurrentPrincipal principal;

    @Inject
    public DigestService(DigestBuffer digestBuffer, CurrentPrincipal principal) {
        this.digestBuffer = digestBuffer;
        this.principal = principal;
    }

    @Override
    public Map<String, Integer> status() {
        String userId = principal.actorId();
        String tenancyId = principal.tenancyId();

        Map<String, Integer> result = new LinkedHashMap<>();
        for (var key : digestBuffer.pendingKeysForUser(userId, tenancyId)) {
            int count = digestBuffer.pendingCount(key);
            if (count > 0) {
                result.put(key.channelId(), count);
            }
        }
        return result;
    }
}
```

- [ ] **Step 3: Delete hand-written DigestStatusResource**

Use `ide_refactor_safe_delete` on `DigestStatusResource.java`.

- [ ] **Step 4: Update test paths**

In `DigestStatusResourceTest.java`, change all GET paths from `/notifications/digest/status` to `/api/digest/status`:

```java
// In digestStatus_returnsPendingCountsPerChannel:
.when().get("/api/digest/status")

// In digestStatus_returnsEmptyMap_whenNoPending:
.when().get("/api/digest/status")

// In digestStatus_tenantIsolation_doesNotShowOtherTenantsData:
.when().get("/api/digest/status")

// In digestStatus_userIsolation_doesNotShowOtherUsersData:
.when().get("/api/digest/status")
```

- [ ] **Step 5: Build and test**

Run: `mvn --batch-mode test -pl notifications -Dtest=DigestStatusResourceTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add notifications/src/main/java/io/casehub/platform/notification/rest/DigestApi.java notifications/src/main/java/io/casehub/platform/notification/rest/DigestService.java notifications/src/test/java/io/casehub/platform/notification/rest/DigestStatusResourceTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#295): migrate DigestStatusResource to generated endpoint Refs #295"
```

### Task 9: Callback migration

**Files:**
- Create: `callback/src/main/java/io/casehub/platform/callback/CallbackApi.java`
- Create: `callback/src/main/java/io/casehub/platform/callback/CallbackService.java`
- Delete: `callback/src/main/java/io/casehub/platform/callback/CallbackRegistrationResource.java` (use `ide_refactor_safe_delete`)
- Modify: `callback/src/test/java/io/casehub/platform/callback/CallbackRegistrationResourceTest.java`
- Modify: `callback/pom.xml`

**Interfaces:**
- Consumes: Generator, @RestMethod, @PathParam from Tasks 1-6
- Produces: `CallbackApi` interface (uses @RestMethod for PUT/DELETE, @PathParam for id), `CallbackService` implementation (absorbs heartbeat existence check, carries @RolesAllowed)

- [ ] **Step 1: Add graphql-generator to callback pom.xml**

Add `<annotationProcessorPaths>` to `callback/pom.xml` inside the `<build><plugins>` section (add a new `maven-compiler-plugin` configuration):

```xml
<plugin>
    <artifactId>maven-compiler-plugin</artifactId>
    <configuration>
        <annotationProcessorPaths>
            <path>
                <groupId>io.casehub</groupId>
                <artifactId>casehub-platform-graphql-generator</artifactId>
                <version>${project.version}</version>
            </path>
            <path>
                <groupId>io.casehub</groupId>
                <artifactId>casehub-platform-api</artifactId>
                <version>${project.version}</version>
            </path>
        </annotationProcessorPaths>
    </configuration>
</plugin>
```

- [ ] **Step 2: Create CallbackApi SPI interface**

```java
package io.casehub.platform.callback;

import io.casehub.platform.api.callback.CallbackRegistration;
import io.casehub.platform.api.callback.CallbackRegistrationRequest;
import io.casehub.platform.api.mcp.HttpMethod;
import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PathParam;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.platform.api.mcp.RestMethod;

@McpDomain("callbacks")
public interface CallbackApi {

    @PlatformMutation("Register a new callback")
    CallbackRegistration register(CallbackRegistrationRequest request);

    @PlatformMutation("Send heartbeat for an existing callback registration")
    @RestMethod(HttpMethod.PUT)
    void heartbeat(@PathParam String id);

    @PlatformMutation("Deregister a callback")
    @RestMethod(HttpMethod.DELETE)
    void deregister(@PathParam String id);
}
```

- [ ] **Step 3: Create CallbackService implementation**

```java
package io.casehub.platform.callback;

import io.casehub.platform.api.callback.CallbackRegistration;
import io.casehub.platform.api.callback.CallbackRegistrationRequest;
import io.casehub.platform.api.callback.CallbackRegistry;
import io.casehub.platform.api.identity.PlatformRoles;
import jakarta.annotation.security.RolesAllowed;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.NotFoundException;

@ApplicationScoped
@RolesAllowed(PlatformRoles.ADMIN)
public class CallbackService implements CallbackApi {

    private final CallbackRegistry callbackRegistry;

    @Inject
    public CallbackService(CallbackRegistry callbackRegistry) {
        this.callbackRegistry = callbackRegistry;
    }

    @Override
    public CallbackRegistration register(CallbackRegistrationRequest request) {
        return callbackRegistry.register(request);
    }

    @Override
    public void heartbeat(String id) {
        if (callbackRegistry.findById(id).isEmpty()) {
            throw new NotFoundException("Callback registration not found: " + id);
        }
        callbackRegistry.heartbeat(id);
    }

    @Override
    public void deregister(String id) {
        callbackRegistry.deregister(id);
    }
}
```

- [ ] **Step 4: Delete hand-written CallbackRegistrationResource**

Use `ide_refactor_safe_delete` on `CallbackRegistrationResource.java`.

- [ ] **Step 5: Update test paths**

In `CallbackRegistrationResourceTest.java`, update all URL paths:

```java
// register: POST /casehub/callbacks/register → POST /api/callbacks/register
.post("/api/callbacks/register")

// heartbeat: PUT /casehub/callbacks/{id}/heartbeat → PUT /api/callbacks/heartbeat/{id}
.put("/api/callbacks/heartbeat/" + id)

// heartbeat unknown: PUT /casehub/callbacks/nonexistent/heartbeat → PUT /api/callbacks/heartbeat/nonexistent
.put("/api/callbacks/heartbeat/nonexistent")

// deregister: DELETE /casehub/callbacks/{id} → DELETE /api/callbacks/deregister/{id}
.delete("/api/callbacks/deregister/" + id)

// deregister unknown: DELETE /casehub/callbacks/nonexistent → DELETE /api/callbacks/deregister/nonexistent
.delete("/api/callbacks/deregister/nonexistent")
```

- [ ] **Step 6: Build and test**

Run: `mvn --batch-mode test -pl callback -Dtest=CallbackRegistrationResourceTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add callback/src/main/java/io/casehub/platform/callback/CallbackApi.java callback/src/main/java/io/casehub/platform/callback/CallbackService.java callback/src/test/java/io/casehub/platform/callback/CallbackRegistrationResourceTest.java callback/pom.xml
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#295): migrate CallbackRegistrationResource to generated endpoint Refs #295"
```

### Task 10: Notification preferences migration

**Files:**
- Create: `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationPreferenceApi.java`
- Create: `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationPreferenceService.java`
- Delete: `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationPreferenceResource.java` (use `ide_refactor_safe_delete`)
- Modify: `notifications/src/test/java/io/casehub/platform/notification/rest/NotificationPreferenceResourceTest.java`

**Interfaces:**
- Consumes: Generator (APT already configured in notifications pom from Task 7), @RestMethod from Task 1
- Produces: `NotificationPreferenceApi` interface, `NotificationPreferenceService` implementation (absorbs validator logic, default-if-absent)

- [ ] **Step 1: Create NotificationPreferenceApi SPI interface**

```java
package io.casehub.platform.notification.rest;

import io.casehub.platform.api.mcp.HttpMethod;
import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.platform.api.mcp.RestMethod;
import io.casehub.platform.api.notification.settings.NotificationPreferenceUpdate;
import io.casehub.platform.api.notification.settings.NotificationPreferences;

@McpDomain("notification-preferences")
public interface NotificationPreferenceApi {

    @PlatformQuery("Get notification preferences for the current user")
    NotificationPreferences get();

    @PlatformMutation("Update notification preferences for the current user")
    @RestMethod(HttpMethod.PUT)
    NotificationPreferences update(NotificationPreferenceUpdate update);
}
```

- [ ] **Step 2: Create NotificationPreferenceService implementation**

```java
package io.casehub.platform.notification.rest;

import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.notification.settings.NotificationPreferenceStore;
import io.casehub.platform.api.notification.settings.NotificationPreferenceUpdate;
import io.casehub.platform.api.notification.settings.NotificationPreferences;
import io.casehub.platform.notification.PreferenceValidator;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.time.Instant;
import java.util.Map;

@ApplicationScoped
public class NotificationPreferenceService implements NotificationPreferenceApi {

    private final NotificationPreferenceStore store;
    private final CurrentPrincipal principal;
    private final PreferenceValidator validator;

    @Inject
    public NotificationPreferenceService(NotificationPreferenceStore store,
                                          CurrentPrincipal principal,
                                          PreferenceValidator validator) {
        this.store = store;
        this.principal = principal;
        this.validator = validator;
    }

    @Override
    public NotificationPreferences get() {
        return store.get(principal.actorId(), principal.tenancyId())
                    .orElseGet(() -> new NotificationPreferences(
                            principal.actorId(),
                            principal.tenancyId(),
                            Map.of(),
                            null,
                            Instant.EPOCH
                    ));
    }

    @Override
    public NotificationPreferences update(NotificationPreferenceUpdate update) {
        var existing = store.get(principal.actorId(), principal.tenancyId()).orElse(null);
        validator.validate(update, existing);
        return store.update(principal.actorId(), principal.tenancyId(), update);
    }
}
```

Note: `update()` lets `IllegalArgumentException` from `validator.validate()` propagate. Quarkus maps uncaught `IllegalArgumentException` to 400 via the built-in exception mapper. This preserves the current behavior where validation failures return 400.

- [ ] **Step 3: Delete hand-written NotificationPreferenceResource**

Use `ide_refactor_safe_delete` on `NotificationPreferenceResource.java`.

- [ ] **Step 4: Update test paths**

In `NotificationPreferenceResourceTest.java`, update all URL paths:

```java
// GET /notifications/preferences → GET /api/notification-preferences/get
.when().get("/api/notification-preferences/get")

// PUT /notifications/preferences → PUT /api/notification-preferences/update
.when().put("/api/notification-preferences/update")
```

Apply this change to all test methods: `get_returnsEmptyPreferences_whenNoneStored`, `put_storesAndReturnsPreferences` (both GET and PUT), `put_clearQuietHours_removesQuietHours` (PUT and GET), `tenantIsolation_userCannotAccessOtherTenantPreferences` (PUT and GET), `put_overridesUserIdFromPrincipal` (PUT).

- [ ] **Step 5: Build and test**

Run: `mvn --batch-mode test -pl notifications -Dtest=NotificationPreferenceResourceTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: PASS

- [ ] **Step 6: Run full test suite for notifications module**

Run: `mvn --batch-mode test -pl notifications -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: PASS — no regressions in other notification tests

- [ ] **Step 7: Run full platform build**

Run: `mvn --batch-mode install -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: BUILD SUCCESS

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add notifications/src/main/java/io/casehub/platform/notification/rest/NotificationPreferenceApi.java notifications/src/main/java/io/casehub/platform/notification/rest/NotificationPreferenceService.java notifications/src/test/java/io/casehub/platform/notification/rest/NotificationPreferenceResourceTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#295): migrate NotificationPreferenceResource to generated endpoint Refs #295"
```

## References

- `/Users/mdproctor/claude/public/casehub/platform/specs/issue-295-unified-api-generation/2026-09-14-unified-api-generation-design.md` — design spec
- `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java` — existing APT (PoC)
- `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java` — existing tests
- `platform-api/src/main/java/io/casehub/platform/api/mcp/McpDomain.java` — domain annotation
- `platform-api/src/main/java/io/casehub/platform/api/mcp/PlatformQuery.java` — query annotation
- `platform-api/src/main/java/io/casehub/platform/api/mcp/PlatformMutation.java` — mutation annotation
- `callback/src/main/java/io/casehub/platform/callback/CallbackRegistrationResource.java` — migration target
- `notifications/src/main/java/io/casehub/platform/notification/rest/DeliveryChannelResource.java` — migration target
- `notifications/src/main/java/io/casehub/platform/notification/rest/DigestStatusResource.java` — migration target
- `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationPreferenceResource.java` — migration target
- `/Users/mdproctor/claude/public/casehub/platform/specs/issue-295-unified-api-generation/decisions.md` — 10 design decisions
- casehubio/platform#295 — focal issue
