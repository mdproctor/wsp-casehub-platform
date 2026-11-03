# HANDOFF — casehub-platform

## Last Session (2026-11-03)

Implemented **#699** (type-safe expression resolution, XL/High) — all 7 tasks complete across 3 batches. Branch `issue-699-type-safe-expression-resolution` carries both #699 (done) and #700 (next).

**What was built:**
- `ParameterType.EXPRESSION` enum value + `@Expression` annotation in yaml-plugin-api (zero-dep)
- `ExpressionContext.PARAMETER` in platform-api
- `VariableResolver` scope infrastructure: `withObjectScope(Map)`, `withExpressionContext()`, `buildExpressionContext()`
- `StepResultStore.liveResults()` — live ConcurrentHashMap view for expression context
- `TypeAwareParamResolver` in yaml-step-runtime — routes EXPRESSION params to ExpressionEngine, all others to VariableResolver
- `CatalogStepRunner` wiring with `hasExpressionParams()` guard (zero overhead for non-EXPRESSION plugins)
- `AptPluginSource` format-aware parsing (`"format": "expression"` → `ParameterType.EXPRESSION`)
- Plugin processor `@Expression` support — schema `format` + uncast `Object` extraction
- `StructuralStepEvaluator` dual scope registration (functional source for STRING, live map for EXPRESSION)
- `AssertThatPlugin` cleanup — `resolveSubject()` deleted, `_subject` declared as EXPRESSION type
- Switch expression coverage for new enum value (ModuleParameterParser, StepSchemaComposer)

**Key design decisions:**
- EXPRESSION params always route to ExpressionEngine, never VariableResolver — clean separation
- Concrete Map-backed scopes (not lazy proxies) — MVEL's `getTypeMap()` needs iterable maps
- Result scope dual registration — functional ObjectVariableSource for string resolution, live ConcurrentHashMap for expression context
- `@Expression` fields typed `Object` (not String) — MVEL returns typed results
- `${...}` accepted and stripped for backward compat

**Tests:** 26 new tests across yaml-plugin-api, yaml-core, yaml-step-runtime, yaml-plugin-processor. All module test suites pass (30 + 846 + 749 + 26). Pre-existing failures in acl-admin and mcp-spring are unrelated.

**Blog:** "When the Parser Already Knows" revised with implementation details and advocacy section.

## Epic #702 — YAML Playbook Polish

| # | Title | Scale | Complexity | Status |
|---|-------|-------|------------|--------|
| 698 | Enforce combined-key syntax | S | Low | Done |
| 703 | Playbook variable declarations | L | Med | Done |
| 699 | Type-safe expression resolution | XL | High | **Done** |
| 700 | `@` annotations with `@Inject` | XL | High | **Next — scaffolded on same branch** |
| 701 | Playbook imports via module system | L | Med | Open — blocked by #700 |
| 705 | JSON Schema for playbook documents | M | Med | Open — independent |
| 708 | Playbook dry-run mode | M | Low | Open — independent |

## Immediate Next Step

**Brainstorm and design** #700 (`@` annotations for YAML playbooks — metadata for tooling, governance, and deployment). Same branch — `issue-699-type-safe-expression-resolution` covers both #699 and #700. Fresh session recommended — this session's context is fully consumed.

## References

- Epic: casehubio/platform#702
- Design spec (#699): `wsp-casehub-platform/specs/issue-699-type-safe-expression-resolution/2026-11-03-type-safe-expression-resolution-design.md`
- Implementation plan (#699): `wsp-casehub-platform/plans/2026-11-03-type-safe-expression-resolution.md`
- Blog: `blog/2026-11-03-mdp02-when-the-parser-already-knows.md`
