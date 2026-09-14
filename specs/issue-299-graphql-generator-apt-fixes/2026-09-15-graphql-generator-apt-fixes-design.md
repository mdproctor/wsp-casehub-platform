# graphql-generator APT: Consumer Module Fixes — Design Spec

**Issue:** casehubio/platform#299
**Date:** 2026-09-15
**Status:** Draft

## Summary

The `casehub-platform-graphql-generator` annotation processor cannot be used in consumer modules (discovered when wiring it in casehubio/ledger#207). Four bugs were reported — all four are symptoms of a common failure: the APT generates code for all platform-api domains instead of just the consumer's domains, and the generated GraphQL resolvers import classes not on the consumer's classpath.

This spec fixes the root causes and adds RoundEnvironment scanning so consumers can define SPIs in the same module as the generated code.

## Root Cause Analysis

The issue reports four bugs:
1. Hyphens in domain names produce illegal Java class names
2. `-AdomainFilter` uses `/` separator which breaks class name generation
3. `-AgenerateGraphQL=false` still emits GraphQL resolvers
4. Domain filter doesn't exclude non-matching domains

Static analysis of the current code shows that `toPascalCase()` (lines 590-603) correctly handles hyphens and slashes — the test at line 88 proves `toPascalCase("delivery-channels") = "DeliveryChannels"`. **Bugs 1-2 as described cannot occur with the current `toPascalCase` implementation.** The flag check (`!"false".equals(...)`) and filter check (`allowedDomains.contains(entry.getKey())`) are also logically correct.

**Hypothesis** (not proven — diagnostic logging in D4 will make the actual cause visible): the most likely failure chain when a consumer (Java 26) wires the APT is that APT options are not received by the processor — either due to Maven compiler plugin configuration, the `@SupportedSourceVersion(RELEASE_21)` annotation emitting warnings that confuse the build, or a Quarkus-specific annotation processing quirk. When options are absent:
- `generateGraphQL` defaults to `true` → GraphQL resolvers generated (bug 3)
- `domainFilter` is `null` → all domains pass the filter (bug 4)
- GraphQL resolvers for all 11 platform-api domains are generated
- Generated code imports `@Query`, `@Description`, `@GraphQLApi` — not on the consumer's REST-only classpath
- Compilation fails with errors the reporter attributed to illegal class names (bugs 1-2)

Additionally, consumer SPIs defined in the current compilation unit are invisible — the APT only reads Jandex indexes from dependency JARs, not the source being compiled.

## Changes

### 1. Fix `@SupportedSourceVersion` (D1)

**Current:**
```java
@SupportedSourceVersion(SourceVersion.RELEASE_21)
public class GraphQLResolverProcessor extends AbstractProcessor {
```

**After:**
```java
public class GraphQLResolverProcessor extends AbstractProcessor {

    @Override
    public SourceVersion getSupportedSourceVersion() {
        return SourceVersion.latestSupported();
    }
```

Remove the annotation, add the method override. The processor uses no version-specific language features — it should work on any Java version. This is best practice regardless of whether the source version annotation is the root cause.

**Also apply to `CallbackDecoratorProcessor`** in the `callback-generator` module, which has the identical `@SupportedSourceVersion(SourceVersion.RELEASE_21)` annotation.

### 2. Refactor OperationInfo to ResolvedOperation (D2)

The current `OperationInfo` holds Jandex `MethodInfo` and `ClassInfo` directly. Code generation methods (`generateMethod`, `generateRestMethod`, `collectTypeImports`) reach into Jandex types at generation time. This tight coupling makes it impossible to add RoundEnvironment scanning without duplicating all code gen.

**Why not reuse `DomainDescriptor` from graphql-spring-generator?** `DomainDescriptor` uses JavaPoet `TypeName` for type representation because the spring generators use JavaPoet for code generation. The graphql-generator APT uses `PrintWriter` string concatenation and cannot add a JavaPoet dependency (APTs should minimize dependencies to avoid classpath conflicts). `ResolvedOperation` uses plain strings for the same data.

**New records** (inner classes of `GraphQLResolverProcessor`):

```java
record ResolvedOperation(
    String methodName,
    String returnTypeStr,              // "void", "Optional<AclEntry>", etc.
    List<ResolvedParam> params,
    Set<String> typeImports,           // all FQCNs for import statements
    String declaringClassFqcn,         // "io.casehub.platform.api.acl.AclApi"
    String declaringClassSimple,       // "AclApi"
    OperationType type,
    String description,
    String restMethodOverride,
    String restPathOverride
) {}

record ResolvedParam(
    String name,
    String typeStr,                    // "String", "List<AclEntryInput>", etc.
    String typeFqcn,                   // primary FQCN for import
    boolean isPathParam,
    String pathParamName,              // custom name from @PathParam value, or null
    boolean isSimpleType
) {}
```

**Refactored code gen methods:**

- `generateResolverSource(String domain, DomainOperations ops, ...)` → works with `ResolvedOperation` instead of `OperationInfo`
- `generateRestResourceSource(String domain, DomainOperations ops, ...)` → same
- `generateMethod(PrintWriter out, ResolvedOperation op)` → reads `op.methodName()`, `op.returnTypeStr()`, `op.params()` — no Jandex calls
- `generateRestMethod(PrintWriter out, ResolvedOperation op)` → reads `param.isPathParam()`, `param.isSimpleType()` — no `findParameterAnnotation()` calls
- `collectTypeImports(List<ResolvedOperation> ops)` → unions `op.typeImports()` — no `addTypeImport(Type)` needed

The existing `typeToJava(Type)` and `addTypeImport(Set, Type)` methods move into the Jandex scanning path — called during `scanAnnotatedInterfaces` to populate the `ResolvedOperation` fields. The `DomainOperations` class changes to hold `List<ResolvedOperation>` instead of `List<OperationInfo>`, and gains a `Source source` field (`enum Source { JANDEX, ROUND_ENV }`) for diagnostic logging.

### 3. RoundEnvironment scanning (D3)

**Null-index guard change:** The current `process()` method returns early when no Jandex index is found (line 66-68: `if (index == null) return false`). This must be relaxed — a null Jandex index is fine when RoundEnvironment scanning finds domains:

```java
IndexView index = loadCombinedIndex(); // may be null — that's fine
this.jandexIndex = index;

Map<String, DomainOperations> jandexDomains =
    index != null ? scanAnnotatedInterfaces(index) : new HashMap<>();
Map<String, DomainOperations> roundEnvDomains = scanRoundEnvironment(roundEnv);
```

The downstream uses of `this.jandexIndex` (in `isSimpleType` calls) already handle null — `isSimpleType(fqcn, null)` falls back to the static list.

**New method:**

```java
private Map<String, DomainOperations> scanRoundEnvironment(RoundEnvironment roundEnv) {
    Map<String, DomainOperations> domains = new HashMap<>();

    for (Element element : roundEnv.getElementsAnnotatedWith(McpDomain.class)) {
        if (element.getKind() != ElementKind.INTERFACE) continue;
        TypeElement typeElement = (TypeElement) element;

        String domain = extractMcpDomainValue(typeElement);
        DomainOperations ops = domains.computeIfAbsent(domain,
            d -> new DomainOperations(d, Source.ROUND_ENV));

        for (Element enclosed : typeElement.getEnclosedElements()) {
            if (enclosed.getKind() != ElementKind.METHOD) continue;
            ExecutableElement method = (ExecutableElement) enclosed;

            // Check for @PlatformQuery / @PlatformMutation via AnnotationMirror lookup
            AnnotationMirror queryAnn = findAnnotationMirror(method,
                "io.casehub.platform.api.mcp.PlatformQuery");
            AnnotationMirror mutAnn = findAnnotationMirror(method,
                "io.casehub.platform.api.mcp.PlatformMutation");

            if (queryAnn != null || mutAnn != null) {
                ops.operations.add(resolveFromTypeMirror(method, typeElement, ...));
            }
        }
    }
    return domains;
}
```

**`McpDomain.class` in `getElementsAnnotatedWith`:** This works because `casehub-platform-api` is a compile dependency of the generator — the annotation class is on the processor classpath.

**Type conversion:** `typeMirrorToJava(TypeMirror)` parallels the existing `typeToJava(Type)`:
- `TypeKind.VOID` → `"void"`
- `TypeKind.DECLARED` → simple name for code, qualified name for imports
- `DeclaredType` with type arguments → `"Optional<AclEntry>"` etc.
- `TypeKind.ARRAY` → recurse + `"[]"`
- Primitives → lowercase name

**`isSimpleType` for TypeMirror types:** For types discovered via RoundEnvironment, add a TypeMirror-based check alongside the static list and Jandex fallback:

```java
private boolean isSimpleTypeMirror(TypeMirror type) {
    if (type.getKind() == TypeKind.DECLARED) {
        Element element = ((DeclaredType) type).asElement();
        if (element.getKind() == ElementKind.ENUM) return true;
        // Check for static fromString(String) or valueOf(String) methods
        for (Element enclosed : element.getEnclosedElements()) {
            if (enclosed.getKind() == ElementKind.METHOD) {
                ExecutableElement method = (ExecutableElement) enclosed;
                if (method.getModifiers().contains(Modifier.STATIC)
                    && method.getParameters().size() == 1
                    && method.getParameters().get(0).asType().toString().equals("java.lang.String")) {
                    if (method.getSimpleName().contentEquals("fromString")
                        || method.getSimpleName().contentEquals("valueOf")) {
                        return true;
                    }
                }
            }
        }
    }
    return false;
}
```

This handles consumer-defined enums and types with `fromString`/`valueOf`. Called during `resolveFromTypeMirror()` to populate `ResolvedParam.isSimpleType`. Without this, POST/PUT/PATCH methods accepting both an enum query parameter and a DTO body parameter would see the enum misclassified as a second complex parameter, triggering a confusing error ("method has 2 complex parameters").

**Merging:** In `process()`, scan both sources and merge. Per #296 spec D7, Jandex takes precedence on conflict — this prevents double-generation when a dependency JAR contains a previously compiled version of the same SPI:

```java
// Merge — Jandex wins on conflict (prevents double-generation from
// stale JAR + edited source). In practice conflicts are rare:
// consumer SPIs are typically only in RoundEnv, platform SPIs only in Jandex.
Map<String, DomainOperations> allDomains = new HashMap<>(roundEnvDomains);
allDomains.putAll(jandexDomains);  // Jandex overwrites on conflict
```

**Hand-written skip detection:** The existing `scanHandWrittenGraphQLMethods()` and `scanHandWrittenRestMethods()` only scan the Jandex index. If a consumer defines a hand-written `@GraphQLApi` resolver or `@Path` resource in the same module (the scenario D3 enables), the skip detection won't find them. Add RoundEnvironment scanning to both skip detection methods:

```java
// In scanHandWrittenGraphQLMethods — after Jandex scan:
for (Element element : roundEnv.getElementsAnnotatedWith(GraphQLApi.class)) {
    if (element.getKind() != ElementKind.CLASS) continue;
    TypeElement typeElement = (TypeElement) element;
    AnnotationMirror mcpDomain = findAnnotationMirror(typeElement,
        "io.casehub.platform.api.mcp.McpDomain");
    if (mcpDomain == null) continue;
    String domain = extractAnnotationValue(mcpDomain);
    for (Element enclosed : typeElement.getEnclosedElements()) {
        if (enclosed.getKind() != ElementKind.METHOD) continue;
        ExecutableElement method = (ExecutableElement) enclosed;
        if (hasAnnotationMirror(method, "org.eclipse.microprofile.graphql.Query")
            || hasAnnotationMirror(method, "org.eclipse.microprofile.graphql.Mutation")) {
            methods.add(domain + ":" + method.getSimpleName().toString());
        }
    }
}
```

Similar pattern for `scanHandWrittenRestMethods` — scan for `@Path`-annotated classes with `@McpDomain` and JAX-RS verb annotations.

**Note:** The `GraphQLApi.class` reference in `getElementsAnnotatedWith` only works if the GraphQL API is on the processor classpath. If it isn't (REST-only consumer), the RoundEnv scan for hand-written GraphQL methods silently finds nothing — which is correct (no GraphQL resolvers to skip). Use the string-based `findAnnotationMirror` approach instead of `.class` to handle the case where the annotation class isn't loadable.

**Multi-round limitation:** The existing `processed` flag ensures the processor runs at most once per compilation. If another annotation processor generates `@McpDomain` interfaces in a prior round, this processor would miss them. This is an existing limitation, not introduced by this spec. Multi-round support is not needed for current use cases (no APT generates SPI interfaces).

### 4. Diagnostic logging (D4)

**At process() start:**
```java
processingEnv.getMessager().printMessage(NOTE,
    "GraphQL generator: options received: " + processingEnv.getOptions());
```

**After domain scanning:**
```java
for (var entry : allDomains.entrySet()) {
    processingEnv.getMessager().printMessage(NOTE,
        "GraphQL generator: found domain '" + entry.getKey()
        + "' (" + entry.getValue().operations.size() + " operations)"
        + " [source: " + entry.getValue().source + "]");
}
```

**During filtering:**
```java
if (allowedDomains != null) {
    if (!allowedDomains.contains(entry.getKey())) {
        processingEnv.getMessager().printMessage(NOTE,
            "GraphQL generator: skipping domain '" + entry.getKey()
            + "' — not in domainFilter");
        continue;
    }
}
```

**Zero-match warning:**
```java
if (allowedDomains != null && generatedCount == 0) {
    processingEnv.getMessager().printMessage(WARNING,
        "GraphQL generator: domainFilter=" + domainFilter
        + " matched zero domains. Available domains: "
        + allDomains.keySet());
}
```

**Filter-absent advisory:**
```java
if (allowedDomains == null && allDomains.size() > 1) {
    processingEnv.getMessager().printMessage(NOTE,
        "GraphQL generator: no domainFilter set — generating for all "
        + allDomains.size() + " domains. Set -AdomainFilter=... to restrict.");
}
```

**Flag logging:**
```java
if (!generateGraphQL) {
    processingEnv.getMessager().printMessage(NOTE,
        "GraphQL generator: GraphQL resolver generation disabled (generateGraphQL=false)");
}
if (!generateRest) {
    processingEnv.getMessager().printMessage(NOTE,
        "GraphQL generator: REST resource generation disabled (generateRest=false)");
}
```

### 5. Class name validation guard

After `toPascalCase()`, validate the result is a legal Java identifier:

```java
String className = "Generated" + toPascalCase(domain) + suffix;
if (!SourceVersion.isIdentifier(className)) {
    processingEnv.getMessager().printMessage(ERROR,
        "GraphQL generator: domain '" + domain
        + "' produces invalid class name '" + className
        + "'. Domain names must contain only alphanumerics, hyphens, and slashes.");
    return;
}
```

This is a defensive guard — `toPascalCase` handles all current domain name formats. The guard catches future domain names with characters `toPascalCase` doesn't handle (dots, spaces, special characters).

## Test Strategy

The `compile-testing` dependency (already in pom.xml) enables integration tests that compile in-memory source files through the APT.

**Unit tests (pure, no mocking):**
- `toPascalCase` edge cases: empty, single char, multiple consecutive hyphens, leading/trailing hyphens, `/` mixed with `-`
- `ResolvedOperation` and `ResolvedParam` construction from mock data
- `isSimpleType` with various type categories
- `isSimpleTypeMirror` with enums, fromString types, complex types

**Integration tests (via compile-testing):**
- Compile an `@McpDomain` interface → verify generated resolver/resource source
- Set `-AgenerateGraphQL=false` → verify no GraphQL resolver generated
- Set `-AdomainFilter=testDomain` → verify only matching domain generated
- Set `-AdomainFilter=nonexistent` → verify WARNING emitted
- Interface with hyphenated domain name → verify valid class name
- Interface in current compilation (RoundEnvironment path) → verify discovered and generated
- Interface in Jandex index (dependency path) → verify discovered and generated
- Both Jandex and RoundEnvironment with same domain → verify Jandex wins
- Hand-written `@GraphQLApi` resolver in same compilation → verify methods skipped
- Consumer enum used as POST parameter → verify classified as simple type via TypeMirror

## File Changes

| File | Change |
|------|--------|
| `graphql-generator/src/main/java/.../GraphQLResolverProcessor.java` | Source version, ResolvedOperation record, RoundEnv scanning (including skip detection), diagnostic logging, class name validation, isSimpleTypeMirror |
| `graphql-generator/src/test/java/.../GraphQLResolverProcessorTest.java` | New unit tests for edge cases, new integration tests via compile-testing |
| `callback-generator/src/main/java/.../CallbackDecoratorProcessor.java` | Fix `@SupportedSourceVersion` to `latestSupported()` (same pattern as D1) |

## Out of Scope

- Stale generated file cleanup — a build lifecycle concern, not an APT concern; consumers should use `mvn clean` when changing APT flags
- Changes to other generators (rest-spring-generator, graphql-spring-generator, mcp-spring-generator) — they are Maven plugins, not APTs; different lifecycle
- Changes to the `domainFilter` value format — `,` separator is standard and works correctly
- Scanner consolidation between `ResolvedOperation` and `DomainDescriptor` — different type representations (strings vs JavaPoet TypeName) for different code gen strategies (PrintWriter vs JavaPoet). Consolidation would require choosing one type system, which is a larger architectural decision.

## References

- GraphQLResolverProcessor.java lines 36-694 — full processor source
- graphql-spring-generator/DomainDescriptor.java — established pattern for scan/gen decoupling
- graphql-spring-generator/McpDomainScanner.java — Jandex scanning abstraction
- casehubio/platform#296 spec D7 — RoundEnvironment scanning design + merge precedence (Jandex wins)
- casehubio/platform#296 spec D2 — isSimpleType via Jandex
- casehubio/platform#295 spec — unified API generation decisions
- casehubio/ledger#207 — consumer wiring attempt that discovered these bugs
- javac AbstractProcessor.getSupportedSourceVersion() javadoc
- callback-generator/CallbackDecoratorProcessor.java line 33 — same @SupportedSourceVersion issue
