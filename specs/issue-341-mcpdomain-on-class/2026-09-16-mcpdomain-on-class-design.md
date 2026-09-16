# @McpDomain on Class — Design Spec

**Issue:** casehubio/platform#341
**Date:** 2026-09-16
**Status:** Draft

## Summary

Support `@McpDomain` on concrete classes, not just interfaces. When annotated on a class, all generators (Quarkus APT, Spring Maven plugins) and the runtime MCP scanner read `@PlatformQuery`/`@PlatformMutation`/`@PlatformStream` methods directly from the class. Generated code delegates to the class via CDI injection — same pattern as interface-based domains.

This eliminates the SPI interface + default implementation split for domains with a single implementation and no alternative providers.

## Architecture

### Current State

`@McpDomain` can only be placed on interfaces. Four independent scanners enforce this:

```
@McpDomain SPI interface (platform-api)
    │
    ├── McpDomainJandexScanner (generator-common)     ← isInterface check
    │     └── Used by: graphql-spring-generator, rest-spring-generator, mcp-spring-generator
    │
    ├── GraphQLResolverProcessor (graphql-generator)   ← isInterface check (2 paths)
    │     ├── Jandex scan path (scanAnnotatedInterfaces)
    │     └── RoundEnvironment scan path (scanRoundEnvironment)
    │
    └── GraphQLModelScanner (mcp, runtime CDI)         ← interface-only second pass
          ├── First pass: @McpDomain on class → requires @GraphQLApi (generated resolvers)
          └── Second pass: @McpDomain on interface → reads @PlatformQuery/@PlatformMutation
```

### Target State

```
@McpDomain on interface OR class
    │
    ├── McpDomainJandexScanner                         ← accepts both
    │     └── @PlatformQuery/@PlatformMutation filter is the real discriminator
    │
    ├── GraphQLResolverProcessor                       ← accepts both (2 paths)
    │     ├── Jandex scan path (scanAnnotatedDomains, renamed)
    │     ├── RoundEnvironment scan path (accepts CLASS + INTERFACE)
    │     └── APT WARNING if class lacks visible CDI scope annotation
    │
    └── GraphQLModelScanner                            ← handles both
          ├── First pass: @McpDomain on class
          │     ├── with @GraphQLApi → read @Query/@Mutation (unchanged)
          │     └── without @GraphQLApi → read @PlatformQuery/@PlatformMutation (new)
          └── Second pass: @McpDomain on interface (unchanged)
```

### Authorization Model

Unchanged. Security is enforced at the service layer. For interface-based domains, the `@ApplicationScoped` implementation carries `@RolesAllowed`. For class-based domains, the class itself carries `@RolesAllowed`. Generated endpoints are pure delegation — CDI interceptors fire on the service bean in both cases.

## Changes

### 1. `DomainScanResult` (generator-common) — D2

**Current:**
```java
public record DomainScanResult(
        String domainName,
        String spiInterfaceFqcn,
        String spiInterfaceSimple,
        String basePath,
        List<ResolvedOperation> operations
) { ... }
```

**After:**
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

Consumers updated to use `sourceFqcn()`/`sourceSimple()`:
- `SpringGraphqlControllerWriter`
- `SpringDomainRestControllerWriter`
- `GraphqlSpringGeneratorMojo` (log message)
- `AbstractVerifyMojo` subclasses (if any reference the field)

### 2. `McpDomainJandexScanner` (generator-common) — D3

Remove the interface-only gate. Pass `isInterface` to `DomainScanResult`.

**Current (line 42):**
```java
if (!java.lang.reflect.Modifier.isInterface(classInfo.flags())) { continue; }
```

**After:**
```java
boolean isIface = java.lang.reflect.Modifier.isInterface(classInfo.flags());
```

The `isIface` value is passed to `DomainScanResult.of()`. No other filtering change — `@PlatformQuery`/`@PlatformMutation` annotation checks on methods (lines 56-59) are already the real filter.

### 3. `GraphQLResolverProcessor` (graphql-generator) — D3, D1

**3a. Jandex scan path (`scanAnnotatedInterfaces` → `scanAnnotatedDomains`):**

Rename the method. Remove the interface gate on line 264.

**3b. RoundEnvironment scan path (`scanRoundEnvironment`):**

Change line 470:
```java
// Before
if (element.getKind() != javax.lang.model.element.ElementKind.INTERFACE) {continue;}

// After
if (element.getKind() != javax.lang.model.element.ElementKind.INTERFACE
    && element.getKind() != javax.lang.model.element.ElementKind.CLASS) {continue;}
```

**3c. APT scope warning (D1):**

After accepting a class element, check for visible CDI scope annotations:

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

Where `hasVisibleCdiScope` checks for the presence of `@ApplicationScoped`, `@Singleton`, `@RequestScoped`, `@SessionScoped`, or `@Dependent` annotation mirrors directly on the element.

### 4. `GraphQLModelScanner` (mcp module) — D4

Modify the first pass. Currently lines 61-66:

```java
if (!hasGraphQLApi(beanClass)) {
    if (!ModelEnricher.class.isAssignableFrom(beanClass)) {
        LOG.warnf("@McpDomain on %s without @GraphQLApi — skipping",
                  beanClass.getName());
    }
    continue;
}
```

After:

```java
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

The second pass (interface scan, lines 88-112) remains unchanged. If a domain is already registered by the first pass (class-based), the `if (domainOps.containsKey(domain)) { continue; }` guard on line 95 prevents duplicate registration.

### 5. Generated Code — D5

No change to the generated code shape. Both generated resolvers and REST resources use:

```java
@Inject
SourceType fieldName;
```

CDI resolves this identically whether `SourceType` is an interface (resolved to its `@ApplicationScoped` implementation) or a concrete `@ApplicationScoped` class (injected directly).

## Backward Compatibility

- Existing interface-based `@McpDomain` SPIs work identically — no migration required.
- `DomainScanResult` field rename is a source-breaking change for direct users of the record. All known consumers are within casehub repos.
- The `@McpDomain` annotation `@Target(TYPE)` is already correct — no annotation change needed.

## Testing

### McpDomainJandexScannerTest

Add a test class annotated with `@McpDomain` and `@PlatformQuery` methods to the test Jandex index. Verify:
- Scanner returns it in results alongside interface-based domains
- `isInterface` flag is `false`
- Operations are correctly extracted

### GraphQLResolverProcessorTest

Add a class-based `@McpDomain` fixture. Verify:
- Generated resolver delegates to the class type
- Generated REST resource delegates to the class type
- APT warning emitted when class lacks `@ApplicationScoped`
- No warning when class has `@ApplicationScoped`

### GraphQLModelScannerTest

Add an `@ApplicationScoped @McpDomain("test-class")` class with `@PlatformQuery` methods. Verify:
- Domain is registered in the model registry
- Operations are discoverable via the MCP tools
- Coexists with interface-based domains in the same scan

### Spring Generator Tests

Verify `DomainScanResult` with `isInterface=false` produces correct Spring controller and REST controller code (constructor injection of the class type).

## References

- `platform-api/src/main/java/io/casehub/platform/api/mcp/McpDomain.java` — annotation definition (`@Target(TYPE)` already correct)
- `generator-common/src/main/java/io/casehub/platform/generator/McpDomainJandexScanner.java:42` — interface gate
- `generator-common/src/main/java/io/casehub/platform/generator/DomainScanResult.java` — field names to rename
- `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java:264,470` — interface gates
- `mcp/src/main/java/io/casehub/platform/mcp/GraphQLModelScanner.java:56-86` — runtime first pass
- `graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/SpringGraphqlControllerWriter.java:29-30` — field name consumer
- `docs/specs/issue-295-unified-api-generation/` — unified API generation context
- `docs/specs/issue-299-graphql-generator-apt-fixes/` — APT fixes context (ResolvedOperation refactor)
