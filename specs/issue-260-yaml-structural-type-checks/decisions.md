## D1: Collect-all validation pass for module references

**Choice:** Add a `validateModuleRefs()` method that runs before the expansion loop (after `validateImports`), scans all parameter values for `${module.*}` patterns, and collects all missing-output, type-incompatibility, and forward-reference errors in one pass. Single throw at the end. Consolidates `checkForwardRefs` into this new method. A minimal assertion guard remains in `resolveModuleRefsInParams` as defense-in-depth — if a forward reference somehow bypasses the pre-validation, it throws immediately rather than producing a confusing `UnresolvedVariableException`.
**Alternatives:**
- Fail-fast inline checks — add checks alongside existing `checkForwardRefs` in `resolveModuleRefsInParams`. Simpler but user sees one error at a time, inconsistent with the collect-all pattern used by `validateImports` and `ParameterValidator`.
**Rationale:** Maximise compile-time (expansion-time) type safety. Consistent with `validateImports` (collect-all, processes all imports before the expansion loop). All three checks share the same `${module.*}` pattern scan, so one pass is natural. The principle: catch everything possible at expansion time rather than letting errors slip through to confusing runtime messages. The assertion guard in resolution is cheap (3 lines) and prevents regressions if future refactoring calls resolution without validation.
**Trade-offs:** Slightly more complex implementation — a separate validation pass that pre-scans parameter values rather than checking inline during resolution. But the scan is cheap (regex over string values) and the error quality improvement is significant.
**Sources:** ModuleExpander.java (validateImports at line 88, checkForwardRefs at line 176, resolveModuleRefsInParams at line 142), ParameterValidator.java (collect-all pattern), issue #260
**Exploration:** quick
**Status:** revised (R1-02, R1-08 — clarified all-imports scope; retained defense-in-depth guard)

## D3: Type compatibility method on ParameterType

**Choice:** Add `boolean canAccept(ParameterType outputType)` on `ParameterType`. STRING accepts INTEGER, NUMBER, and BOOLEAN (widening). NUMBER accepts INTEGER (widening). All others must match exactly. LIST only accepts LIST; STRING does NOT accept LIST.
**Alternatives:**
- `isAssignableFrom` naming — familiar from `Class.isAssignableFrom()` but that method is one of the most frequently misused in Java. `canAccept` is unambiguous: `STRING.canAccept(INTEGER)` → true.
- STRING accepts LIST (full widening) — LIST→STRING is lossy and depends on the implementation-specific comma-separated serialization format. If LIST's delimiter changes, STRING parameters silently receive different formats. Conservative: require explicit LIST→STRING conversion.
- Standalone `TypeCompatibility` utility class — unnecessary indirection for a simple matrix lookup
**Rationale:** `ParameterType` already owns `parse()` (value-level type behaviour). Type compatibility is the structural complement — it belongs on the same type. `canAccept` reads clearly: the parameter type is the receiver, the output type is the argument.
**Trade-offs:** LIST outputs cannot be passed to STRING parameters without an explicit conversion step. More conservative than the issue's original matrix, but prevents format-dependent surprises.
**Sources:** issue #260 compatibility matrix, ParameterType.java, R1-04 (naming), R1-05 (LIST→STRING)
**Exploration:** quick
**Status:** revised (R1-04 — renamed to `canAccept`; R1-05 — excluded LIST→STRING widening)

## D4: validateModuleRefs processes all imports at once

**Choice:** `validateModuleRefs` receives the full `List<YamlImport>` and `Map<String, YamlModule> availableModules`. It iterates imports in order, tracking processed aliases internally, and collects all errors across all imports. Runs after `validateImports` (which guarantees imports are structurally valid) but before the expansion loop.
**Alternatives:**
- Per-import call inside the loop with accumulated errors — requires passing a `List` accumulator or returning errors for external aggregation. More scattered, harder to reason about.
- Per-import call inside the loop with per-import throw — loses collect-all across imports
**Rationale:** Matches `validateImports` pattern exactly: static method, receives all imports, collects all errors, single throw at the end. The method needs import ordering to check forward references, which is natural when iterating the full list. No accumulator threading or error return aggregation needed.
**Trade-offs:** Moves validation logic out of the expansion loop. But the expansion loop is cleaner as a result — it handles resolution and merging only, with all validation complete before it starts.
**Depends on:** D1 (collect-all validation pass)
**Sources:** ModuleExpander.java (validateImports at line 88 — same pattern), expand() loop at line 46
**Exploration:** quick
**Status:** revised (R1-02 — resolved per-import vs all-imports contradiction; chose all-imports)

## D5: Error model — ParameterViolation with new constraint types

**Choice:** `validateModuleRefs` returns `List<ParameterViolation>` using new constraint type strings: `"module-ref-forward"`, `"module-ref-missing-output"`, `"module-ref-type-incompatible"`, `"module-ref-embedded-type"`. Throws `ParameterValidationException` if non-empty.
**Alternatives:**
- `List<String>` joined into `IllegalArgumentException` (like `validateImports`) — loses ability to programmatically distinguish error kinds and is inconsistent with the rest of parameter validation
- New exception type for module reference errors — unnecessary; module reference errors ARE parameter-level errors (they occur on specific parameters)
**Rationale:** Module reference errors are parameter-level: each error is about a specific parameter that references a module output. `ParameterViolation` already carries `parameterName`, `constraint`, `message`, and `actualValue` — all meaningful for module reference errors. This makes `ParameterValidationException` the single error model for all parameter-level validation, and `IllegalArgumentException` the model for import-level structural validation (`validateImports`). Clean separation.
**Depends on:** D1 (collect-all validation pass), D4 (all-imports scope)
**Sources:** ParameterViolation.java, ParameterValidationException.java, ModuleExpander.java (validateImports uses IllegalArgumentException for import-level errors, ParameterValidator uses ParameterViolation for parameter-level errors), R1-03
**Exploration:** quick
**Status:** captured

## D2: Embedded vs whole-value reference handling

**Choice:** Whole-value type compatibility check PLUS embedded STRING constraint. A value is whole-value if and only if, after trimming, it matches `^\$\{module\.[^}]+\}$` exactly — any whitespace, additional references, or literal text makes it embedded. When whole-value: check output type against parameter type using `canAccept`. When embedded (including multi-reference values like `${module.a.x}${module.b.y}`): flag as a structural error if the parameter is typed as INTEGER/NUMBER/BOOLEAN/LIST — string interpolation always produces STRING.
**Alternatives:**
- Whole-value only — type compatibility fires only on exact matches. Simpler, but lets embedded-reference type mismatches fall through to ParameterValidator with confusing parse errors.
**Rationale:** Maximise compile-time safety. String interpolation (`"prefix-${module.db.port}"`) always produces a string. If the target parameter is INTEGER, this is structurally guaranteed to fail — catching it here gives a clear message ("parameter 'port' (INTEGER) uses string interpolation, which always produces STRING") instead of the downstream "expected INTEGER, got 'prefix-5432'".
**Trade-offs:** Slightly more logic in the validation pass — must distinguish whole-value from embedded references via regex. But the scan already identifies reference positions.
**Depends on:** D1 (collect-all validation pass), D3 (canAccept method)
**Sources:** ModuleExpander.java (resolveModuleRefsInParams), ParameterType.java, issue #260 compatibility matrix, R1-07 (precise whole-value definition)
**Exploration:** quick
**Status:** revised (R1-06 — added D3 dependency; R1-07 — precise whole-value regex definition)
