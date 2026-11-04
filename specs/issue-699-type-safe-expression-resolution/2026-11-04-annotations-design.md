# Design: `#@` Annotations for YAML Playbooks

**Issue:** #700
**Branch:** `issue-699-type-safe-expression-resolution` (covers #699, #700)
**Date:** 2026-11-04

## Overview

YAML playbooks need metadata that different systems consume at different times: tooling (IDE, MCP discovery), governance (roles, audit, confirmation), deployment (triggers, scheduling, resource hints), and runtime (dependency injection, type declarations). Today this metadata is either absent, wired externally, or mixed into the data model as regular keys.

`#@` annotations are YAML comments with structured metadata, extracted by a pre-parser before SnakeYAML. The raw file is always valid YAML. The `#` prefix is a parser concern — the UI renders bare `@` (#717).

## Phased Delivery

All phases ship within #700. Each phase builds on the previous and is independently testable.

**Phase 1 — Pre-parser + tooling annotations:**
`AnnotationExtractor` in yaml-core, `Annotation` record, `AnnotationMap`, annotation argument parser. Tooling annotations: `@description`, `@requires`, `@version`, `@deprecated`. Integration with `PlaybookParser` and `Walker`.

**Phase 2 — @Inject runtime semantics:**
`InjectionResolver` SPI in yaml-core, `@Inject` annotation processing, pre-flight validation (all bindings resolve before execution starts), variable binding into `VariableResolver`. Simulation framework coherence (D9).

**Phase 3 — Decorator migration:**
Dual-path support for 12 annotation candidates (D4). Deprecation warnings for key-form usage. Annotation-over-key precedence on conflict (D10).

## Annotation Syntax

Annotations use the `#@` prefix — valid YAML comments with structured metadata.

```yaml
#@description("Customer onboarding — triggered on case creation")
#@requires(agent, rest-client)
#@roles(admin, case-worker)
name: Customer onboarding

#@Inject(AgentProvider, qualifier: "claude")
claude: agent

#@Inject(CaseMemoryStore)
memory: store

steps:
  #@audit("PII access — must be logged")
  #@timeout(2s)
  - rest-request:
      url: /api/customers/${customerId}
    capture: customer

  #@retry(3, backoff: exponential)
  - agent-invoke:
      provider: claude
      prompt: "Assess risk for ${customer.name}"
    capture: risk
```

### Argument Grammar (D8)

```
annotation     = "#@" name ["(" arg-list ")"]
name           = identifier ("-" identifier)*
arg-list       = arg ("," arg)*
arg            = named-arg | positional-arg
named-arg      = identifier ":" value
positional-arg = value
value          = quoted-string | number | duration | identifier
quoted-string  = '"' escaped-chars '"'
identifier     = [a-zA-Z_][a-zA-Z0-9_.-]*
duration       = number ("s" | "ms" | "m" | "h")
```

Annotations without arguments are valid: `#@deprecated`, `#@background`.

## Architecture

### Pre-parser Pipeline

```
Raw YAML text (valid — #@ lines are comments)
     │
     ▼
AnnotationExtractor.extract(text)
     │
     ├──→ AnnotationMap (document-level + step-indexed)
     │
     └──→ Same text (unmodified — no stripping needed)
              │
              ▼
         PlaybookParser.parse(text)  →  PlaybookDocument
              │
              ▼
         Walker.resolve(steps, registry, annotationMap)
              │
              ▼
         ResolvedStep (with annotations attached)
```

The pre-parser does **extraction only** — no text transformation. Since `#@` lines are valid YAML comments, SnakeYAML ignores them natively. The pre-parser scans for `#@` lines, parses the annotation name and arguments, and produces an `AnnotationMap`.

### Module Placement (D5)

| Component | Module | Rationale |
|-----------|--------|-----------|
| `AnnotationExtractor` | yaml-core | Pure text processing, zero-dep, J2CL-safe |
| `Annotation` record | yaml-core | Data model for parsed annotations |
| `AnnotationMap` | yaml-core | Document + step-indexed annotation container |
| `AnnotationParser` | yaml-core | Argument grammar parser |
| `InjectionResolver` | yaml-core | Functional SPI for @Inject resolution |
| CDI `InjectionResolver` impl | yaml-step-runtime | CDI-backed resolution |

### Data Model

```java
// yaml-core — zero-dep
package io.casehub.yaml.core.annotation;

record Annotation(String name, List<AnnotationArg> args) {
    boolean hasArg(String name);
    String stringArg(int index);
    String namedArg(String name);
}

sealed interface AnnotationArg {
    record Positional(String value) implements AnnotationArg {}
    record Named(String name, String value) implements AnnotationArg {}
}

record AnnotationMap(
    List<Annotation> documentAnnotations,
    Map<String, List<Annotation>> stepAnnotations
) {
    List<Annotation> forStep(int index);
    boolean hasStepAnnotation(int index, String name);
}
```

The `AnnotationMap` uses string-keyed step paths. V1 uses simple index strings (`"0"`, `"1"`, `"2"`). The `forStep(int)` convenience method converts to string internally. When #716 adds nesting support, the same map accepts hierarchical paths like `"steps[2].block[0]"` — no type change, no API change (D7).

### AnnotationExtractor

```java
// yaml-core
package io.casehub.yaml.core.annotation;

public final class AnnotationExtractor {

    public static AnnotationMap extract(String yamlText) { ... }
}
```

The extractor:
1. Scans lines for `#@` prefix (after optional whitespace)
2. Parses annotation name and arguments using `AnnotationParser`
3. Groups annotations by their target: document-level (before `steps:`) or step-level (before `- ` list items)
4. Counts `- ` items at the step-list indent level for step indexing
5. Returns `AnnotationMap`

### @Inject Binding Lines (D6)

`@Inject` declarations have companion binding lines:
```yaml
#@Inject(AgentProvider, qualifier: "claude")
claude: agent
```

The binding line (`claude: agent`) stays in the parsed content map as an inert key. Downstream code only reads known keys (`steps`, `params`, `vars`, `name`). Unknown keys are harmless.

**Association rule:** The pre-parser knows a line is a binding (not regular content) because it immediately follows an `@Inject` annotation. The `@Inject` annotation consumes its target line as the binding declaration — variable name is the key (`claude`), type hint is the value (`agent`). Non-`@Inject` annotations do not consume their target lines.

**Design invariant:** Inert binding lines are safe only at the document level. Walker's `resolveOne` throws `IllegalArgumentException` on unknown keys within the step map. If future annotations introduce step-level binding lines, they must be stripped or registered as known keys.

### @Inject Resolution (Phase 2)

```java
// yaml-core — functional SPI
package io.casehub.yaml.core.annotation;

@FunctionalInterface
public interface InjectionResolver {
    Object resolve(String typeName, Map<String, String> qualifiers);
}
```

Resolution flow:
1. `AnnotationExtractor` extracts `@Inject` annotations with their binding lines
2. Before step execution, iterate all `@Inject` declarations
3. For each: call `InjectionResolver.resolve(typeName, qualifiers)`
4. Bind the resolved object to the variable name (from the binding line) in `VariableResolver`
5. If any binding fails to resolve → fail fast with a clear error ("CaseMemoryStore not available")

The CDI implementation in yaml-step-runtime resolves via `Instance<T>` with qualifier matching. The `MapServiceRegistry` implementation resolves by class name lookup.

### Simulation Coherence (D9)

`@Inject` variable names become the authoritative namespace for simulation bindings. `SimulateBlockParser`'s `ALIASES` map is deprecated but continues to work for playbooks without `@Inject` declarations.

```yaml
#@Inject(AgentProvider, qualifier: "claude")
claude: agent

simulate:
  claude:                          # matches @Inject variable name directly
    - prompt: "Assess risk"
      response: "High risk."
```

When `@Inject` declarations are present, `SimulateBlockParser` uses them for binding resolution instead of the `ALIASES` map. Existing playbooks without `@Inject` continue to work through the ALIASES fallback.

## Decorator Migration (Phase 3)

### Classification (D4)

12 annotation candidates (policy/metadata — decorator-form only):

| Key | Annotation form | Notes |
|-----|----------------|-------|
| `timeout` | `#@timeout(5s)` | PROMOTABLE_DECORATOR — structural-scoping form retained |
| `retry` | `#@retry(3, backoff: exponential)` | PROMOTABLE_DECORATOR — structural-scoping form retained |
| `mutex` | `#@mutex(lock-name)` | PROMOTABLE_DECORATOR — structural-scoping form retained |
| `delay` | `#@delay(2s)` | |
| `priority` | `#@priority(high)` | |
| `resource` | `#@resource(pool-name)` | |
| `background` | `#@background` | No args needed |
| `on-error` | `#@on-error(continue)` | |
| `trigger` | `#@trigger(event: case.created)` | |
| `semaphore` | `#@semaphore(name, permits: 3)` | |
| `at` | `#@at(expression)` | |
| `cancel` | `#@cancel(target)` | |

16 stay as keys (structural, data-flow, lifecycle) — see D4 for the full classification and criteria hierarchy.

### PROMOTABLE_DECORATOR Carve-out (D3)

`retry`, `timeout`, and `mutex` have two forms in the Walker:

1. **Decorator-form** (scalar value): `retry: 3` — migrates to `#@retry(3)`
2. **Structural-scoping form** (list value): `retry condition: [steps]` — stays permanently as a key

The migration tool must distinguish these by value type. The structural-scoping form has no annotation equivalent because annotations cannot scope a step list.

### Dual-Path Semantics (D3)

During the migration window:
- Both key-form and annotation-form work
- Annotation takes precedence on conflict
- Deprecation warnings emitted for key-form usage of migrated decorators
- Key-form removed in the release following D4 validation

### Conflict Resolution (D10)

- Duplicate annotations of the same type on the same target → error
- Annotation-over-key precedence during D3 dual-path window

## Walker Integration

The Walker receives `AnnotationMap` alongside the step list. During `resolveOne`, for each step at index `i`:

1. Look up `annotationMap.forStep(i)`
2. If annotations exist, attach them to the `ResolvedStep` (new field on the sealed interface)
3. For Phase 3 decorator migration: check for annotation equivalents of decorator keys, merge with precedence

`ResolvedStep` gains an `annotations()` method returning `List<Annotation>` (empty by default).

## Annotation Categories

### Tooling (Phase 1)

| Annotation | Args | Purpose |
|-----------|------|---------|
| `@description` | `(text)` | Machine-readable description |
| `@deprecated` | `(text?)` | Deprecation warning |
| `@requires` | `(cap1, cap2, ...)` | Pre-flight capability check |
| `@version` | `(semver)` | Playbook versioning |

### Governance (Phase 3)

| Annotation | Args | Purpose |
|-----------|------|---------|
| `@roles` | `(role1, role2, ...)` | ACL integration |
| `@confirmation-required` | none | Triggers OperationConfirmationProvider |
| `@audit` | `(text)` | Compliance logging |

### Runtime (Phase 2)

| Annotation | Args | Purpose |
|-----------|------|---------|
| `@Inject` | `(Type, qualifier: value?)` | Dependency injection binding |

### Testing (Phase 1 — pure metadata)

| Annotation | Args | Purpose |
|-----------|------|---------|
| `@tags` | `(tag1, tag2, ...)` | Test classification |
| `@skip` | `(reason?)` | Conditional skip |
| `@expectedFailure` | `(reason?)` | xfail |
| `@slow` | none | Performance annotation |

## Follow-up Issues

- **#716** — Nested step-level annotation support (extend pre-parser to handle annotations inside block/try/if structures)
- **#717** — Render `#@` as bare `@` in playbook UI (presentation concern)
- Migration tool for decorator key-form → annotation conversion (out of scope for #700 — needed before key-form removal per D3)

## References

- Issue #700 — feature spec
- Issue #699 — type-safe expression resolution (companion, `@type(expression)` connects)
- Issue #702 — epic: YAML Playbook Polish
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java` — variable resolution infrastructure
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java` — step resolution, PROMOTABLE_DECORATORS, unknown-key rejection
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepKeywords.java` — 28 DECORATOR_KEYS
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/statemachine/PlaybookParser.java` — SnakeYAML entry point
- `yaml-core/src/main/java/io/casehub/yaml/core/playbook/PlaybookDocument.java` — current data model
- `yaml-test-core/src/main/java/io/casehub/yaml/test/SimulateBlockParser.java` — ALIASES map, simulation bindings
- ytt — prior art for YAML comment-based annotations
- decisions-700.md — D1–D10 validated decisions
