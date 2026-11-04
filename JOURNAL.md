# Design Journal — issue-699-type-safe-expression-resolution

## 2026-11-04 — #700 `#@` annotations: design through implementation

Designed and implemented `#@` annotations for YAML playbooks — the full vertical slice from pre-parser through decorator migration.

**Key design pivot:** Started with bare `@` requiring a pre-parser text transformation. User pushed back on the complexity — "don't thrash, think it through." Landed on `#@` (valid YAML comments) which eliminates the transformation step entirely. The pre-parser does extraction only; SnakeYAML ignores `#@` lines natively. Bare `@` rendering deferred to UI (#717).

**Phased delivery within one issue:** Phase 1 (data model + parser + extractor), Phase 2 (@Inject resolution), Phase 3 (decorator migration with dual-path). Decision review (3 rounds, 14 issues) expanded the decisions from 7 to 10 — notably adding the PROMOTABLE_DECORATOR carve-out (structural-scoping forms like `retry condition: [steps]` stay as keys permanently; only decorator-form migrates).

**Implementation:** 8 tasks across 4 batches. The `withAnnotations` pattern on Walker avoids modifying `resolveOne` internals — annotations are attached after resolution via record reconstruction. `parseDecoratorValue` coerces string annotation args to typed values (Integer, Boolean) for DecoratorChain compatibility.

**Queue:** #699 and #700 done. #716 (nested annotations, S/Low) is next.
