# HANDOFF — casehub-platform

## Last Session (2026-11-04)

Completed #705 — JSON Schema for playbook and .test.yaml documents (M/Med), synced to main:

- `yaml-core/src/main/resources/schema/playbook-document.schema.json`: 631-line Draft 2020-12 schema covering full playbook vocabulary
- Flat step property model (not oneOf branches) — avoids multi-match validation errors with additionalProperties:true
- Combined-key syntax (`timeout 10s:`, `forEach item in items:`) via patternProperties with regexes for all 15 prefixes
- 72 drift-detection and fixture-validation tests in `PlaybookSchemaValidationTest`: 4 drift tests (structural keys, decorator keys, plugin schemas, combined-key prefixes) + 61 playbook fixtures + 7 test files
- `networknt/json-schema-validator` 1.5.6 added as test dependency to yaml-step-runtime
- Design decision: static hand-written schema + drift tests over auto-composition — vocabulary changes slowly (8 plugins), tests catch drift, evolution to auto-composition is additive if plugin count grows

## Epic #702 — YAML Playbook Polish

| # | Title | Scale | Complexity | Status |
|---|-------|-------|------------|--------|
| 698 | Enforce combined-key syntax | S | Low | Done |
| 703 | Playbook variable declarations | L | Med | Done |
| 699 | Type-safe expression resolution | XL | High | Done |
| 700 | `@` annotations with `@Inject` | XL | High | Done |
| 716 | Nested step-level annotations | S | Low | Done |
| 718 | Match/select annotation threading | XS | Low | Done |
| 710 | yaml-codegen expression format | XS | Low | Done |
| 711 | AssertPlugin migration evaluation | XS | Low | Done |
| 712 | Scope dual-registration | S | Med | Done |
| 713 | ConditionEvaluator unification eval | S | Med | Done |
| 706 | Typed error handling in catch blocks | M | Med | Done |
| 705 | JSON Schema for playbook documents | M | Med | Done (this session) |
| 708 | Playbook dry-run mode | M | Low | Open — next |
| 701 | Playbook imports via module system | L | Med | Open |

## Immediate Next Step

#708 — Playbook dry-run mode (M/Low).

## References

- Epic: casehubio/platform#702
- TS parity audit: casehubio/casehub-pages#608 (moved from platform#714)
- Remaining queue: #708, #701
