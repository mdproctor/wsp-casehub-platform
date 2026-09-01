## D1: ParameterViolation gains technicalDetail field

**Choice:** Add `String technicalDetail` as a nullable 5th field on `ParameterViolation`. When `constraintDescription` is set on the parameter, `ParameterValidator` puts the human message in `message` and the generated text in `technicalDetail`. When no `constraintDescription`, `technicalDetail` is null.
**Alternatives:**
- Wrapper method with conditional logic — records are data, keep them transparent
- Subclass with override — records can't be subclassed
**Rationale:** Backward-compatible — existing code that reads `message()` still works. The generated technical message is always available for debugging when the human-friendly message replaces it. Null when not needed avoids empty-string ambiguity.
**Trade-offs:** Record constructor grows to 5 fields. Acceptable — ParameterViolation is constructed only in ParameterValidator, not by consumers.
**Sources:** ParameterViolation.java, ParameterValidator.java, issue #257
**Exploration:** quick
**Status:** captured

## D2: Schema generator uses casehub-platform-schema-generator coordinates

**Choice:** Artifact ID `casehub-platform-schema-generator`, folder name `schema-generator/`. Follows the `casehub-platform-*` convention used by all other modules in this repo.
**Alternatives:**
- `casehub-schema-generator` (from the original spec) — breaks the naming convention, inconsistent with 30+ sibling modules
**Rationale:** Every module in this repo uses the `casehub-platform-` prefix. Consistency makes the build order and dependency graph predictable.
**Trade-offs:** None — the spec was draft and the coordinate wasn't published yet.
**Sources:** CLAUDE.md module table (all artifactIds use casehub-platform-* prefix), issue #248, docs/specs/2026-08-29-shared-schema-generator-design.md
**Exploration:** quick
**Status:** captured
