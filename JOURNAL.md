# Design Journal — issue-151-orchestration-scope-bridge

## 2026-09-24 — Session 1: Design pivot + plugin API implementation

### Direction change

Started with two yaml-core requirements: ProcessExecutor primitive and reconciliation bridge (OrchestrationScope SPI connecting ScenarioScope to desiredstate ReconciliationLoop). ProcessExecutor was parked (already in progress in another session). OrchestrationScope bridge was designed and spec'd, then the other session decided the full mirror wasn't needed.

This triggered a more fundamental question: instead of hand-coding each integration, could we have a plugin API that makes any service YAML-addressable? That evolved into the yaml-core Step Action Plugin API.

### Key design decisions

1. **Actions vs decorators**: step actions (what a step DOES) are an open set — pluggable. Structural decorators (loop, retry, forEach, when, timeout) are a closed set with fixed composition semantics per the 13-position decorator evaluation order (issue-386). Making decorators pluggable would break the composition guarantees.

2. **APT for everything**: compile-time validation, JSON Schema generation, typed binder generation, registry manifests. No Jackson in the binding path — full control over error messages at every level. The design review surfaced this: the hybrid approach (Jackson for binding) leaks poor error messages.

3. **Zero-dep API**: yaml-plugin-api is J2CL-safe, no framework dependencies. Plugin authors depend only on annotations + StepResult + ServiceRegistry.

### Implementation notes

- StepPrimitive/PrimitiveRegistry/StepPipelineExecutor don't exist in platform yet (only in attic slot 184). Created StepAction interface in yaml-plugin-api as the dispatch contract instead.
- Built-in plugins can't live in yaml-plugin-api (builds before processor). They live as test resources in yaml-plugin-processor for the proof-of-concept. A `yaml-plugin-builtins` module is needed for production.
- Kebab-to-camel naming (YAML `absent-when` → Java `absentWhen`) not yet handled in binder generation.

### What landed

- `yaml-plugin-api` module: 7 types, 4 tests
- `yaml-plugin-processor` module: APT + 3 emitters, 16 tests
- 2 proof-case plugins (assert, compare-state) with full APT pipeline verified
