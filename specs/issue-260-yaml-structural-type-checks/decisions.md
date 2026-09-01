## D1: Collect-all validation pass for module references

**Choice:** Add a `validateModuleRefs()` method that runs before resolution, scans all parameter values for `${module.*}` patterns, and collects all missing-output, type-incompatibility, and forward-reference errors in one pass. Single throw at the end. Consolidates `checkForwardRefs` into this new method.
**Alternatives:**
- Fail-fast inline checks — add checks alongside existing `checkForwardRefs` in `resolveModuleRefsInParams`. Simpler but user sees one error at a time, inconsistent with the collect-all pattern used by `validateImports` and `ParameterValidator`.
**Rationale:** Maximise compile-time (expansion-time) type safety. Consistent with existing `validateImports` (collects errors in `List<String>`) and `ParameterValidator` (collects `ParameterViolation`). All three checks share the same `${module.*}` pattern scan, so one pass is natural. The principle: catch everything possible at expansion time rather than letting errors slip through to confusing runtime messages.
**Trade-offs:** Slightly more complex implementation — a separate validation pass that pre-scans parameter values rather than checking inline during resolution. But the scan is cheap (regex over string values) and the error quality improvement is significant.
**Sources:** ModuleExpander.java (checkForwardRefs at line 176, resolveModuleRefsInParams at line 142), ParameterValidator.java (collect-all pattern), issue #260
**Exploration:** quick
**Status:** captured

## D3: Type compatibility method on ParameterType

**Choice:** Add `boolean isAssignableFrom(ParameterType outputType)` on `ParameterType`. STRING accepts any type (widening), NUMBER accepts INTEGER (widening), all others must match exactly. LIST only accepts LIST.
**Alternatives:**
- Standalone `TypeCompatibility` utility class — unnecessary indirection for a simple matrix lookup
**Rationale:** `ParameterType` already owns `parse()` (value-level type behaviour). Type compatibility is the structural complement — it belongs on the same type. Reads naturally: `STRING.isAssignableFrom(INTEGER)` → true.
**Trade-offs:** None significant — the matrix is small and stable.
**Sources:** issue #260 compatibility matrix, ParameterType.java
**Exploration:** quick
**Status:** captured

## D2: Embedded vs whole-value reference handling

**Choice:** Whole-value type compatibility check PLUS embedded STRING constraint. When the entire parameter value is `${module.alias.name}`, check output type against parameter type using the compatibility matrix. When a parameter value contains embedded `${module.*}` references (string interpolation), flag it as a structural error if the parameter is typed as INTEGER/NUMBER/BOOLEAN/LIST — string interpolation always produces STRING.
**Alternatives:**
- Whole-value only — type compatibility fires only on exact `${module.alias.name}` matches. Simpler, but lets embedded-reference type mismatches fall through to ParameterValidator with confusing parse errors.
**Rationale:** Maximise compile-time safety. String interpolation (`"prefix-${module.db.port}"`) always produces a string. If the target parameter is INTEGER, this is structurally guaranteed to fail — catching it here gives a clear message ("parameter 'port' (INTEGER) uses string interpolation, which always produces STRING") instead of the downstream "expected INTEGER, got 'prefix-5432'".
**Trade-offs:** Slightly more logic in the validation pass — must distinguish whole-value from embedded references. But the regex scan already identifies reference positions, so this is a substring check.
**Depends on:** D1 (collect-all validation pass)
**Sources:** ModuleExpander.java (resolveModuleRefsInParams), ParameterType.java, issue #260 compatibility matrix
**Exploration:** quick
**Status:** captured
