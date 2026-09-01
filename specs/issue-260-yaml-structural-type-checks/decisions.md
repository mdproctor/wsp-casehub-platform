## D1: Collect-all validation pass for module references

**Choice:** Add a `validateModuleRefs()` method that runs before resolution, scans all parameter values for `${module.*}` patterns, and collects all missing-output, type-incompatibility, and forward-reference errors in one pass. Single throw at the end. Consolidates `checkForwardRefs` into this new method.
**Alternatives:**
- Fail-fast inline checks — add checks alongside existing `checkForwardRefs` in `resolveModuleRefsInParams`. Simpler but user sees one error at a time, inconsistent with the collect-all pattern used by `validateImports` and `ParameterValidator`.
**Rationale:** Maximise compile-time (expansion-time) type safety. Consistent with existing `validateImports` (collects errors in `List<String>`) and `ParameterValidator` (collects `ParameterViolation`). All three checks share the same `${module.*}` pattern scan, so one pass is natural. The principle: catch everything possible at expansion time rather than letting errors slip through to confusing runtime messages.
**Trade-offs:** Slightly more complex implementation — a separate validation pass that pre-scans parameter values rather than checking inline during resolution. But the scan is cheap (regex over string values) and the error quality improvement is significant.
**Sources:** ModuleExpander.java (checkForwardRefs at line 176, resolveModuleRefsInParams at line 142), ParameterValidator.java (collect-all pattern), issue #260
**Exploration:** quick
**Status:** captured
