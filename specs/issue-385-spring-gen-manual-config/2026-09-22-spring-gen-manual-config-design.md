# Spring Generator: Skip Manual Beans + Type Fidelity Fixes

**Issue:** casehubio/platform#385
**Date:** 2026-09-22
**Status:** Design

## Problem

`casehub-platform-spring-generator` generates `@Bean` methods for all `@Produces` methods discovered in the Quarkus Jandex index, even when the consuming Spring module already has hand-written beans. This causes compilation failures when the generator produces type-incorrect code for beans that already have correct manual definitions.

Three independent bugs:

1. **No manual config exclusion** — generated beans duplicate hand-written `*ManualConfig.java` beans
2. **Generic wildcards stripped** — `List<ContextBridge<?>>` becomes `List<ContextBridge>`
3. **Optional not wrapped for constructors** — `Optional<T>` params get raw `T` from `getIfAvailable()`

Engine CI is red because all three converge on `common-spring`.

## Fix 1: Auto-Exclude Manual Beans

### Current Flow

```
SpringGeneratorMojo.execute()
  → JandexProducerScanner.scan(scanIndex, resolveIndex)
  → AutoConfigurationWriter.generate(pkg, className, ALL descriptors)
```

No filtering. Every `@Produces` method becomes a `@Bean` method.

### Changed Flow

```
SpringGeneratorMojo.execute()
  → JandexProducerScanner.scan(scanIndex, resolveIndex)
  → ManualBeanScanner.scan(sourceDir)           ← NEW
  → filter descriptors against manual bean types ← NEW
  → AutoConfigurationWriter.generate(pkg, className, filtered descriptors)
```

### Implementation

**New class: `ManualBeanScanner`** — extracted from `SpringVerifyMojo.collectBeanReturnTypes()` which already does this scan for drift detection.

```java
package io.casehub.platform.spring.generator;

public final class ManualBeanScanner {
    /**
     * Scan Java source files for @Bean method return types.
     * Returns simple class names (not FQN).
     */
    public static Set<String> scan(Path sourceDir) throws IOException
}
```

Walks `sourceDir`, finds `.java` files containing `@Bean`, extracts return type simple names via regex (same pattern as `SpringVerifyMojo`: `public\s+([\w.]+)\s+\w+\s*\(`).

**`SpringGeneratorMojo` changes:**
- Add `@Parameter(defaultValue = "${project.basedir}/src/main/java") private File sourceDir` (matches `SpringVerifyMojo`)
- After scanning descriptors, call `ManualBeanScanner.scan(sourceDir.toPath())`
- Filter: remove any descriptor whose `returnTypeSimpleName()` or `effectiveReturnTypeSimpleName()` is in the manual set
- Log filtered descriptors at INFO level: "Skipping <type> — already defined in manual config"

**`SpringVerifyMojo` refactored** to use `ManualBeanScanner.scan()` instead of its inline `collectBeanReturnTypes()`.

## Fix 2: Preserve Generic Wildcards

### Root Cause

`JandexProducerScanner.resolveParamKind()` extracts inner type arguments using `.name().toString()`, which returns the erasure. `List<ContextBridge<?>>` → type arg name is `ContextBridge`, losing `<?>`.

### Fix

**`ConstructorParam` record change** — add `TypeName resolvedType` field:

```java
public record ConstructorParam(String type, String name, ParamKind kind, TypeName resolvedType) {
    // Backward-compat constructor for tests
    public ConstructorParam(String type, String name, ParamKind kind) {
        this(type, name, kind, null);
    }
}
```

**`ParamResolution` record change** — add `TypeName resolvedType` field.

**`JandexProducerScanner.resolveParamKind()`** — for LIST, OPTIONAL, and all other kinds, compute `JandexTypeConverter.toTypeName()` on the inner type argument (for LIST/OPTIONAL) or the full type (for PLAIN). Store in `ParamResolution.resolvedType`.

Specifically for LIST:
```java
if (JAVA_LIST.equals(rawName) && !paramType.asParameterizedType().arguments().isEmpty()) {
    Type innerType = paramType.asParameterizedType().arguments().get(0);
    String typeArg = innerType.name().toString();
    TypeName resolved = JandexTypeConverter.toTypeName(innerType);
    return new ParamResolution(typeArg, ParamKind.LIST, null, null, resolved);
}
```

Same pattern for OPTIONAL, SUPPLIER_DEP, EVENT_CONSUMER. For PLAIN: `JandexTypeConverter.toTypeName(paramType)`.

**`AutoConfigurationWriter.buildEnhancedBeanMethod()`** — use `cp.resolvedType()` (falling back to `toClassName(cp.type())` when null) wherever types are used for code generation:

```java
case LIST -> {
    TypeName elementType = cp.resolvedType() != null ? cp.resolvedType() : toClassName(cp.type());
    ParameterizedTypeName listType = ParameterizedTypeName.get(
            ClassName.get(java.util.List.class), elementType);
    builder.addParameter(listType, cp.name());
    paramNames.add(cp.name());
}
```

## Fix 3: Always Wrap Optional

### Root Cause

```java
case OPTIONAL -> {
    ...
    if (d.hasFactoryMethod()) {
        paramNames.add("java.util.Optional.ofNullable(" + cp.name() + ".getIfAvailable())");
    } else {
        paramNames.add(cp.name() + ".getIfAvailable()");  // ← BUG: returns T, not Optional<T>
    }
}
```

`ParamKind.OPTIONAL` means the constructor takes `Optional<T>`. The wrapping is always needed.

### Fix

Remove the conditional:

```java
case OPTIONAL -> {
    ParameterizedTypeName providerType = ParameterizedTypeName.get(
            OBJECT_PROVIDER, resolveType(cp));
    builder.addParameter(providerType, cp.name());
    paramNames.add("java.util.Optional.ofNullable(" + cp.name() + ".getIfAvailable())");
}
```

## Testing

### Bug 1 — ManualBeanScanner
- Unit test: scan a temp directory with a `*ManualConfig.java` containing `@Bean` methods, verify return types collected
- Unit test: verify `SpringGeneratorMojo` (or an extracted filter method) removes descriptors matching manual types
- Integration: verify the filtered descriptor list excludes manual beans

### Bug 2 — Generic Wildcards
- Unit test in `JandexProducerScannerTest`: index a class with constructor taking `List<Foo<?>>`, verify `resolvedType` is `ParameterizedTypeName` with wildcard
- Unit test in `AutoConfigurationWriterTest`: descriptor with `resolvedType` containing wildcards generates correct `List<Foo<?>>` parameter

### Bug 3 — Optional Wrapping
- Unit test in `AutoConfigurationWriterTest`: descriptor with `OPTIONAL` param on a non-factory constructor generates `Optional.ofNullable(...)` wrapping

## Files Changed

| File | Change |
|------|--------|
| `spring-generator/.../ManualBeanScanner.java` | NEW — extracted source scanner |
| `spring-generator/.../SpringGeneratorMojo.java` | Add `sourceDir`, filter descriptors |
| `spring-generator/.../SpringVerifyMojo.java` | Refactor to use `ManualBeanScanner` |
| `spring-generator/.../ProducerDescriptor.java` | Add `TypeName resolvedType` to `ConstructorParam` |
| `spring-generator/.../JandexProducerScanner.java` | Compute `resolvedType` via `JandexTypeConverter` |
| `spring-generator/.../AutoConfigurationWriter.java` | Use `resolvedType`, fix Optional wrapping |
| `spring-generator/.../JandexProducerScannerTest.java` | Wildcard test cases |
| `spring-generator/.../AutoConfigurationWriterTest.java` | Optional wrapping + wildcard test cases |

## References

- `spring-generator/src/main/java/.../AutoConfigurationWriter.java:148-154` — Optional wrapping bug
- `spring-generator/src/main/java/.../JandexProducerScanner.java:222-252` — resolveParamKind erasure bug
- `spring-generator/src/main/java/.../SpringVerifyMojo.java:71-89` — existing @Bean scan pattern
- `generator-common/src/main/java/.../JandexTypeConverter.java` — full Jandex→JavaPoet type conversion
- casehubio/platform#385 — issue with engine CI impact
