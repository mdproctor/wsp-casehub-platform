# Generator Fixes + Plugin Validation — Design Spec

**Issue:** casehubio/platform#835
**Epic:** #827 — Playbook language direction (platform)
**Findings:** P27, P29, P37

## Summary

Three targeted fixes in the generator and plugin runtime to close gaps that block typed playbooks. Each finding is a point fix in existing code — no new modules or API surfaces.

## P27 — Generated steps skip @ContextParam tenancyId

### Problem

`GraphQLResolverProcessor.generatePluginSource()` (line 1997) skips `@ContextParam` parameters when building the plugin's delegate call argument list:

```java
if (p.isContextParam()) continue;  // drops tenancyId from call
```

The REST generator handles this correctly via `contextParamResolution()` (line 2608), which maps `tenancyId` → `currentPrincipal.tenancyId()`. The plugin generator has no equivalent — it just drops the parameter, producing broken calls.

### Fix

In the plugin delegate call loop (line 1996-2001), instead of `continue` for `@ContextParam`, generate a `ServiceRegistry` lookup:

```java
// Generated code in the plugin's execute() method:
CurrentPrincipal __principal = services.lookup(CurrentPrincipal.class);
api.listItems(__principal.tenancyId(), otherParam);
```

The generated code uses `contextParamResolution()` to determine which accessor to call (`tenancyId()`, `actorId()`, etc.), then emits a `services.lookup(CurrentPrincipal.class)` call in the generated execute method body. One lookup per execute call, reused across multiple context params.

`mapParamsToFields()` (line 2200) correctly skips `@ContextParam` — context params are NOT record fields, they're resolved at runtime.

### Scope

- Modify `generatePluginSource()` in `GraphQLResolverProcessor.java`
- Add import for `CurrentPrincipal` in generated plugin source when context params are present
- Add test: `@McpDomain` SPI with `@ContextParam("tenancyId")` → verify generated plugin compiles and passes tenancyId

## P29 — Step name collision from derivePluginName

### Problem

`derivePluginName()` (line 2026) uses only the last segment of the domain path:

```java
String domainSuffix = domain.contains("/")
        ? domain.substring(domain.lastIndexOf('/') + 1)
        : domain;
return domainSuffix + "-" + toKebabCase(methodName);
```

Two domains ending in the same segment (e.g., `connectors/voice` and `messaging/voice`) produce identical step names. `CompositePluginRegistry.register()` silently overwrites via `ConcurrentHashMap.put()`.

### Fix

**Short names by default, full domain path only on collision.** Two changes:

1. **Compile-time collision detection in `GraphQLResolverProcessor`:** Collect all generated plugin names across the APT round. When two domains produce the same short name, both get full-path names (all `/` replaced with `-`). This runs during `processPlugins()` — a two-pass approach:
   - Pass 1: collect all `(domain, method)` → short name mappings
   - Pass 2: for any short name with >1 mapping, switch those to full domain path names

2. **Runtime collision detection in `CompositePluginRegistry.register()`:** Change from silent `put()` to `WARNING` log + explicit error when two different definitions register the same name. This catches collisions from non-APT sources (manual registration, different compilation units).

`@GeneratePlugin(name=...)` remains the escape hatch for explicit short names.

### Scope

- Modify `derivePluginName()` to accept a collision set and produce full-path name when colliding
- Add two-pass collection in `processPlugins()` or `generatePluginSources()`
- Change `CompositePluginRegistry.register()` from INFO to WARNING, throw on collision
- Add test: two domains with same last segment → verify different step names generated

## P37 — @Plugin records: missing @Required not rejected, type coercion

### Problem

Two gaps:

**Gap 1 — No validation wrapping:** `PluginScanner.scanAndRegister()` registers the raw `Action` directly. YAML-defined actions go through `ValidatingAction` which calls `Validator.validateStep()`. `@Plugin` actions bypass this entirely — missing `@Required` fields silently default to `0`/`false`.

**Gap 2 — Type coercion in `extractParam()`:** Several types fail at runtime:
- String→Number: `((Number) value).intValue()` throws `ClassCastException` when value is a String from YAML interpolation
- `float`/`Float`: falls through to raw cast (Double→float fails)
- Enums: String won't cast to enum type
- Nested records: Map won't cast to record type
- `byte[]`: List<Integer> won't cast to byte array

### Fix

**Gap 1:** Wrap in `PluginScanner.scanAndRegister()`. Build a `Declaration` from the `Definition`'s inputs metadata, wrap the action in `ValidatingAction` before passing it to the `Definition` constructor. This ensures `@Required` fields are checked before the action executes.

`ValidatingAction` requires a `Consumer<ActionExecutionEvent>` — for `@Plugin` actions, use a no-op consumer (or the same event sink pattern used elsewhere). The validation is the primary value; event telemetry is secondary.

**Gap 2:** Fix `extractParam()` with proper coercion:

| Type | Current | Fix |
|------|---------|-----|
| `int`/`Integer` from String | ClassCastException | `Integer.parseInt(value.toString())` |
| `long`/`Long` from String | ClassCastException | `Long.parseLong(value.toString())` |
| `double`/`Double` from String | ClassCastException | `Double.parseDouble(value.toString())` |
| `float`/`Float` | Falls through | `((Number) value).floatValue()` + String parse |
| Enum | Falls through | `Enum.valueOf(type, value.toString())` |
| Nested record | Falls through | Out of scope — reject with clear error message |
| `byte[]` | Falls through | Out of scope — reject with clear error message |

Nested records and `byte[]` are edge cases that need a broader deserialization strategy. For now, throw `IllegalArgumentException` with a clear message rather than silently failing.

### Scope

- Modify `PluginScanner.scanAndRegister()` to wrap action in ValidatingAction
- Fix `extractParam()` for String→Number, float, enum coercion
- Add explicit rejection for unsupported types (nested records, byte[])
- Add tests: missing @Required field → validation error, String "42" → int 42, enum coercion

## Testing Strategy

Each finding gets its own test class in the respective module's test directory:

- **P27 tests** in `graphql-generator/`: APT test verifying generated plugin source contains ServiceRegistry lookup for @ContextParam
- **P29 tests** in `graphql-generator/`: APT test with two colliding domains → verify full-path names; non-colliding → verify short names preserved
- **P37 tests** in `yaml-step-runtime/`: Unit tests for PluginScanner — missing required, String→Number, float, enum, unsupported type rejection

## Order of Implementation

1. P37 (extractParam + ValidatingAction wrapping) — foundation, no generator changes
2. P27 (@ContextParam in plugin delegate) — generator fix, independent of P29
3. P29 (collision detection) — generator fix, touches derivePluginName

## References

- `GraphQLResolverProcessor.java:1997` — P27 skip bug
- `GraphQLResolverProcessor.java:2026-2031` — P29 derivePluginName
- `GraphQLResolverProcessor.java:2608` — contextParamResolution() (correct pattern)
- `PluginScanner.java:50-55` — P37 raw action registration
- `PluginScanner.java:195-213` — P37 extractParam gaps
- `ValidatingAction.java` — existing validation wrapper
- `CompositePluginRegistry.java:19-24` — silent put() on collision
- casehubio/platform#835 — issue
- casehubio/platform#827 — parent epic
