# graphql-generator APT: Consumer Module Fixes — Design Spec

**Issue:** casehubio/platform#299
**Date:** 2026-09-15
**Status:** Draft

## Summary

The `casehub-platform-graphql-generator` annotation processor cannot be used in consumer modules (discovered when wiring it in casehubio/ledger#207). Four bugs were reported — root cause analysis reveals they share a common failure chain: the APT generates code for all platform-api domains instead of just the consumer's domains, and the generated GraphQL resolvers import classes not on the consumer's classpath.

This spec fixes the root causes and adds RoundEnvironment scanning so consumers can define SPIs in the same module as the generated code.

## Root Cause Analysis

The issue reports four bugs:
1. Hyphens in domain names produce illegal Java class names
2. `-AdomainFilter` uses `/` separator which breaks class name generation
3. `-AgenerateGraphQL=false` still emits GraphQL resolvers
4. Domain filter doesn't exclude non-matching domains

Static analysis of the current code shows that `toPascalCase()` (lines 590-603) correctly handles hyphens and slashes — the test at line 88 proves `toPascalCase("delivery-channels") = "DeliveryChannels"`. **Bugs 1-2 as described cannot occur with the current `toPascalCase` implementation.** The flag check (`!"false".equals(...)`) and filter check (`allowedDomains.contains(entry.getKey())`) are also logically correct.

The real failure chain when a consumer (Java 26) wires the APT:

```
@SupportedSourceVersion(RELEASE_21) on Java 26
  → javac warning / potential option handling quirk in compiler plugin
    → APT options not received or silently defaulted
      → generateGraphQL defaults to true (bug 3)
      → domainFilter is null → all domains pass (bug 4)
        → GraphQL resolvers generated for ALL 11 platform-api domains
          → Generated code imports @Query, @Description, @GraphQLApi
            → GraphQL API not on consumer's REST-only classpath
              → compilation errors (bugs 1-2 symptoms)
```

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

Remove the annotation, add the method override. The processor uses no version-specific language features — it should work on any Java version.

### 2. Refactor OperationInfo to ResolvedOperation (D2)

The current `OperationInfo` holds Jandex `MethodInfo` and `ClassInfo` directly. Code generation methods (`generateMethod`, `generateRestMethod`, `collectTypeImports`) reach into Jandex types at generation time. This tight coupling makes it impossible to add RoundEnvironment scanning without duplicating all code gen.

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

The existing `typeToJava(Type)` and `addTypeImport(Set, Type)` methods move into the Jandex scanning path — called during `scanAnnotatedInterfaces` to populate the `ResolvedOperation` fields. The `DomainOperations` class changes to hold `List<ResolvedOperation>` instead of `List<OperationInfo>`.

### 3. RoundEnvironment scanning (D3)

**New method:**

```java
private Map<String, DomainOperations> scanRoundEnvironment(RoundEnvironment roundEnv) {
    Map<String, DomainOperations> domains = new HashMap<>();

    for (Element element : roundEnv.getElementsAnnotatedWith(McpDomainAnnotation())) {
        if (element.getKind() != ElementKind.INTERFACE) continue;
        TypeElement typeElement = (TypeElement) element;

        String domain = extractMcpDomainValue(typeElement);
        DomainOperations ops = domains.computeIfAbsent(domain, DomainOperations::new);

        for (Element enclosed : typeElement.getEnclosedElements()) {
            if (enclosed.getKind() != ElementKind.METHOD) continue;
            ExecutableElement method = (ExecutableElement) enclosed;

            // Check for @PlatformQuery / @PlatformMutation
            AnnotationMirror queryAnn = findAnnotation(method, PLATFORM_QUERY_FQCN);
            AnnotationMirror mutAnn = findAnnotation(method, PLATFORM_MUTATION_FQCN);

            if (queryAnn != null || mutAnn != null) {
                ops.operations.add(resolveFromTypeMirror(method, typeElement, ...));
            }
        }
    }
    return domains;
}
```

**Type conversion:** `typeMirrorToJava(TypeMirror)` parallels the existing `typeToJava(Type)`:
- `TypeKind.VOID` → `"void"`
- `TypeKind.DECLARED` → simple name for code, qualified name for imports
- `DeclaredType` with type arguments → `"Optional<AclEntry>"` etc.
- `TypeKind.ARRAY` → recurse + `"[]"`
- Primitives → lowercase name

**Merging:** In `process()`, scan both sources and merge:
```java
Map<String, DomainOperations> jandexDomains = scanAnnotatedInterfaces(index);
Map<String, DomainOperations> roundEnvDomains = scanRoundEnvironment(roundEnv);

// Merge — RoundEnv wins on conflict (source code is more authoritative than index)
Map<String, DomainOperations> allDomains = new HashMap<>(jandexDomains);
allDomains.putAll(roundEnvDomains);
```

**`isSimpleType` limitation:** For types discovered via RoundEnvironment (not in the Jandex index), `isSimpleType(fqcn, index)` falls back to the static list. Consumer-defined enums used as query parameters on GET/DELETE methods will be misclassified as complex types. The consumer can add `@PathParam` as a workaround. TypeMirror-based enum detection (`typeElement.getKind() == ElementKind.ENUM`) is a straightforward follow-up but out of scope for this fix.

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

**Integration tests (via compile-testing):**
- Compile an `@McpDomain` interface → verify generated resolver/resource source
- Set `-AgenerateGraphQL=false` → verify no GraphQL resolver generated
- Set `-AdomainFilter=testDomain` → verify only matching domain generated
- Set `-AdomainFilter=nonexistent` → verify WARNING emitted
- Interface with hyphenated domain name → verify valid class name
- Interface in current compilation (RoundEnvironment path) → verify discovered and generated
- Interface in Jandex index (dependency path) → verify discovered and generated
- Both Jandex and RoundEnvironment with same domain → verify RoundEnvironment wins

## File Changes

| File | Change |
|------|--------|
| `graphql-generator/src/main/java/.../GraphQLResolverProcessor.java` | All changes: source version, ResolvedOperation record, RoundEnv scanning, diagnostic logging, class name validation |
| `graphql-generator/src/test/java/.../GraphQLResolverProcessorTest.java` | New unit tests for edge cases, new integration tests via compile-testing |

## Out of Scope

- TypeMirror-based `isSimpleType` for consumer enums — follow-up enhancement
- Stale generated file cleanup — a build lifecycle concern, not an APT concern; consumers should use `mvn clean` when changing APT flags
- Changes to other generators (rest-spring-generator, graphql-spring-generator, mcp-spring-generator) — they are Maven plugins, not APTs; different lifecycle
- Changes to the `domainFilter` value format — `,` separator is standard and works correctly

## References

- GraphQLResolverProcessor.java lines 36-694 — full processor source
- graphql-spring-generator/DomainDescriptor.java — established pattern for scan/gen decoupling
- graphql-spring-generator/McpDomainScanner.java — Jandex scanning abstraction
- casehubio/platform#296 spec — "SPI discovery via RoundEnvironment" planned feature
- casehubio/platform#295 spec — unified API generation decisions
- casehubio/ledger#207 — consumer wiring attempt that discovered these bugs
- javac AbstractProcessor.getSupportedSourceVersion() javadoc
