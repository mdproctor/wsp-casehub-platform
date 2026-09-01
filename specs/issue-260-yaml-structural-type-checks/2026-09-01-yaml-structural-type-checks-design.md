# yaml-core Structural Type Checking — Design Spec

**Issue:** casehubio/platform#260
**Date:** 2026-09-01
**Status:** Draft

## Summary

Add compile-time (expansion-time) structural type checking to `ModuleExpander`
for cross-module output-to-parameter references. Two remaining validation gaps
from the #260 audit, plus consolidation of the existing forward-reference check
into a unified collect-all validation pass.

## Current State

Issue #260 identified 5 validation gaps. Three were already implemented by #256:

| Gap | Status | Implementation |
|-----|--------|----------------|
| Output template scope restriction | Done | `validateOutputTemplateScope()` — rejects non-`var` prefix |
| Output forward reference | Done | `checkForwardRefs()` — rejects unprocessed alias references |
| Output value type validation | Done | `resolveOutputs()` — parses resolved value against declared type |
| **Cross-module type compatibility** | **Open** | No structural check — runtime parse error only |
| **Missing output reference** | **Open** | `buildModuleSource` returns null — confusing downstream error |

## Three-Layer Validation Model

The design creates a three-layer validation stack for module reference parameters.
Layers 2 and 3 already exist; Layer 1 is the addition.

| Layer | When | What it catches | Method |
|-------|------|-----------------|--------|
| 1. Structural type check (new) | Before resolution | Incompatible declared types, missing outputs, forward refs | `validateModuleRefs` |
| 2. Output value validation (existing) | During output resolution | Resolved output value fails declared output type | `resolveOutputs` |
| 3. Parameter value validation (existing) | After resolution | Resolved parameter value fails type/constraints | `ParameterValidator.validateOrThrow` |

Layer 1 catches errors earlier with better messages. Layers 2 and 3 remain
unchanged — they're still needed for non-module-ref parameters and for
constraint validation (min/max, pattern) that structural checks cannot perform.

## Changes

### 1. `ParameterType.canAccept(ParameterType outputType)`

New method on the `ParameterType` enum implementing the type compatibility matrix:

```java
public boolean canAccept(ParameterType outputType) {
    if (this == outputType) return true;
    if (this == STRING && outputType != LIST) return true;
    if (this == NUMBER && outputType == INTEGER) return true;
    return false;
}
```

**Compatibility matrix:**

| Output type → | STRING param | INTEGER param | NUMBER param | BOOLEAN param | LIST param |
|--------------|-------------|--------------|-------------|--------------|-----------|
| STRING output | ✓ | ✗ | ✗ | ✗ | ✗ |
| INTEGER output | ✓ (widening) | ✓ | ✓ (widening) | ✗ | ✗ |
| NUMBER output | ✓ (widening) | ✗ | ✓ | ✗ | ✗ |
| BOOLEAN output | ✓ (widening) | ✗ | ✗ | ✓ | ✗ |
| LIST output | ✗ | ✗ | ✗ | ✗ | ✓ |

STRING accepts INTEGER, NUMBER, and BOOLEAN (widening — every scalar has a
meaningful string representation). NUMBER accepts INTEGER (widening). LIST
only accepts LIST. STRING does NOT accept LIST — LIST→STRING is lossy and
depends on implementation-specific comma-separated serialization format.

### 2. `ModuleExpander.validateModuleRefs()`

New static method that runs after `validateImports()` and before the expansion
loop. Processes the full `List<YamlImport>` in order, collecting all errors.

```java
private static void validateModuleRefs(
        List<YamlImport> imports,
        Map<String, YamlModule> availableModules) {

    List<ParameterViolation> violations = new ArrayList<>();
    Set<String> processedAliases = new HashSet<>();

    for (YamlImport imp : imports) {
        YamlModule module = availableModules.get(imp.module());
        if (module == null) {
            processedAliases.add(imp.as());
            continue; // validateImports already caught this
        }

        for (Map.Entry<String, String> paramEntry : imp.parameters().entrySet()) {
            String paramName = paramEntry.getKey();
            String paramValue = paramEntry.getValue();

            if (!paramValue.contains("${module.")) continue;

            YamlModuleParameter paramDecl = module.parameters().get(paramName);
            boolean isWholeValue = isWholeModuleRef(paramValue);

            Matcher matcher = VAR_REF.matcher(paramValue);
            while (matcher.find()) {
                String key = matcher.group(1);
                if (!key.startsWith("module.")) continue;
                String rest = key.substring("module.".length());
                int dot = rest.indexOf('.');
                if (dot < 0) continue;
                String refAlias = rest.substring(0, dot);
                String outputName = rest.substring(dot + 1);

                // Check 1: Forward reference
                if (!processedAliases.contains(refAlias)) {
                    violations.add(new ParameterViolation(paramName,
                            "module-ref-forward",
                            "Import '" + imp.as() + "' references ${" + key
                            + "}, but '" + refAlias
                            + "' has not been imported yet. Move the '"
                            + refAlias + "' import before '" + imp.as() + "'.",
                            paramValue));
                    continue;
                }

                // Check 2: Missing output
                YamlModule refModule = findModuleByAlias(refAlias, imports,
                        availableModules);
                if (refModule == null) continue;

                YamlModuleOutput output = refModule.outputs().get(outputName);
                if (output == null) {
                    violations.add(new ParameterViolation(paramName,
                            "module-ref-missing-output",
                            "Import '" + imp.as() + "' references output '"
                            + outputName + "' on '" + refAlias
                            + "', but module '" + refModule.name()
                            + "' does not declare that output. Available: "
                            + refModule.outputs().keySet(),
                            paramValue));
                    continue;
                }

                // Check 3: Type compatibility (whole-value only)
                if (isWholeValue && paramDecl != null) {
                    if (!paramDecl.type().canAccept(output.type())) {
                        violations.add(new ParameterViolation(paramName,
                                "module-ref-type-incompatible",
                                "Output '" + outputName + "' (" + output.type()
                                + ") on '" + refAlias
                                + "' is not assignable to parameter '"
                                + paramName + "' (" + paramDecl.type() + ").",
                                paramValue));
                    }
                }
            }

            // Check 4: Embedded interpolation into non-STRING parameter
            if (!isWholeValue && paramDecl != null
                    && paramDecl.type() != ParameterType.STRING) {
                violations.add(new ParameterViolation(paramName,
                        "module-ref-embedded-type",
                        "Parameter '" + paramName + "' (" + paramDecl.type()
                        + ") uses string interpolation, which always "
                        + "produces STRING.",
                        paramValue));
            }
        }
        processedAliases.add(imp.as());
    }

    if (!violations.isEmpty()) {
        throw new ParameterValidationException(violations);
    }
}
```

**Whole-value detection:** A value is whole-value if and only if, after
trimming, it matches `^\$\{module\.[^}]+\}$` exactly.

```java
private static final Pattern WHOLE_MODULE_REF =
        Pattern.compile("^\\s*\\$\\{module\\.[^}]+}\\s*$");

private static boolean isWholeModuleRef(String value) {
    return WHOLE_MODULE_REF.matcher(value).matches();
}
```

**Alias-to-module lookup:**

```java
private static YamlModule findModuleByAlias(String alias,
        List<YamlImport> imports,
        Map<String, YamlModule> availableModules) {
    for (YamlImport imp : imports) {
        if (alias.equals(imp.as())) {
            return availableModules.get(imp.module());
        }
    }
    return null;
}
```

### 3. Integration into `expand()`

```java
public static ExpandedModule expand(...) {
    validateImports(imports, availableModules);
    validateModuleRefs(imports, availableModules);  // NEW — after imports validated

    // ... existing expansion loop unchanged ...
}
```

### 4. Defense-in-depth guard in `resolveModuleRefsInParams`

`checkForwardRefs` is removed (its logic moves to `validateModuleRefs`). A
minimal assertion guard replaces it — if a forward reference somehow bypasses
pre-validation, it throws immediately rather than producing a confusing
`UnresolvedVariableException`:

```java
// In resolveModuleRefsInParams, after parsing ${module.alias.name}:
if (!allOutputs.containsKey(refAlias)) {
    throw new IllegalStateException(
            "Forward reference to '" + refAlias + "' in import '"
            + currentAlias + "' — should have been caught by validateModuleRefs.");
}
```

### 5. Error model

All new validation errors use `ParameterViolation` with constraint type strings:

| Constraint | When |
|-----------|------|
| `module-ref-forward` | `${module.alias.*}` where alias not yet processed |
| `module-ref-missing-output` | `${module.alias.name}` where output doesn't exist |
| `module-ref-type-incompatible` | Output type not assignable to parameter type (whole-value) |
| `module-ref-embedded-type` | String interpolation into non-STRING parameter |

Thrown as `ParameterValidationException` — consistent with all other
parameter-level validation in the module system.

## Test Plan

### `ParameterTypeTest` — new tests

| Test | Coverage |
|------|----------|
| `canAccept_same_type_always_true` | All 5 types accept themselves |
| `canAccept_string_accepts_scalars` | STRING.canAccept(INTEGER/NUMBER/BOOLEAN) → true |
| `canAccept_string_rejects_list` | STRING.canAccept(LIST) → false |
| `canAccept_number_accepts_integer` | NUMBER.canAccept(INTEGER) → true |
| `canAccept_number_rejects_others` | NUMBER.canAccept(STRING/BOOLEAN/LIST) → false |
| `canAccept_integer_rejects_number` | INTEGER.canAccept(NUMBER) → false (no narrowing) |
| `canAccept_boolean_rejects_non_boolean` | BOOLEAN.canAccept(STRING/INTEGER/NUMBER/LIST) → false |
| `canAccept_list_rejects_non_list` | LIST.canAccept(STRING/INTEGER/NUMBER/BOOLEAN) → false |

### `ModuleExpanderTest` — new tests

| Test | Coverage |
|------|----------|
| `missing_output_reference_throws` | `${module.alias.nonexistent}` → ParameterValidationException with "module-ref-missing-output" |
| `missing_output_lists_available` | Error message includes available output names |
| `type_incompatible_whole_value_throws` | BOOLEAN output → INTEGER param → "module-ref-type-incompatible" |
| `type_compatible_whole_value_passes` | INTEGER output → NUMBER param (widening) → no error |
| `type_compatible_string_widening_passes` | INTEGER output → STRING param → no error |
| `embedded_ref_non_string_param_throws` | `"prefix-${module.a.x}"` → INTEGER param → "module-ref-embedded-type" |
| `embedded_ref_string_param_passes` | `"prefix-${module.a.x}"` → STRING param → no error |
| `collect_all_multiple_errors` | Multiple violations across imports → all reported in one exception |
| `forward_ref_still_caught` | Verify forward references still produce clear errors after consolidation |
| `list_to_string_rejected` | LIST output → STRING param → "module-ref-type-incompatible" |
| `defense_guard_throws_illegal_state` | (if testable) Forward ref bypassing pre-validation → IllegalStateException |

### Existing tests — no changes

All existing `ModuleExpanderTest` tests pass unchanged. The new validation
runs before the expansion loop; existing tests that don't use `${module.*}`
references are unaffected.

## References

- `ModuleExpander.java` — existing validation: `validateImports` (line 88), `checkForwardRefs` (line 176), `resolveModuleRefsInParams` (line 142), `validateOutputTemplateScope` (line 242), `resolveOutputs` (line 209)
- `ParameterType.java` — existing `parse()` method, target for `canAccept`
- `ParameterValidator.java` — existing collect-all pattern, `ParameterViolation`, `ParameterValidationException`
- `YamlModuleOutput.java` — output model with `type()` field (from #256)
- `ExpandedModule.java` — expansion result with `moduleOutputs` (from #256)
- Issue #260 — gap audit and compatibility matrix
- Issue #256 — module outputs (dependency, closed)
- Issue #252 — module system (dependency, closed)
- `docs/specs/issue-252-yaml-core-modules/2026-08-31-yaml-core-modules-design.md` — module system spec
- `docs/specs/issue-252-yaml-core-modules/decisions.md` — D1–D6 design decisions
- `decisions.md` — D1–D5 design decisions for this issue
