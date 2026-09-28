# Block-level iteration: forEach and loop on YamlImport

**Covers:** #432
**Repo:** casehubio/platform (yaml-core)
**Depends on:** #429 (ValueType, TypedMap, ObjectVariableSource.drillOnly — landed)

## Problem

ForEachDirective decorates individual nodes. LoopDirective decorates individual steps. Modules define blocks but accept neither. To iterate over a group of nodes, you must put `forEach` on every node independently — verbose, error-prone, and the block boundary is implicit.

## Design

### YamlImport gains forEach and loop

```java
public record YamlImport(
        String module,
        String as,
        String when,
        Map<String, String> parameters,
        Object forEach,
        Object loop) {

    public YamlImport {
        if (parameters == null) { parameters = Map.of(); }
    }
}
```

`forEach` is parsed via `ForEachDirective.parse()`. `loop` is parsed via `LoopDirective.parse()`. Both are nullable — absent means no iteration.

### YAML surface

```yaml
imports:
  - module: regional-pipeline
    as: region
    forEach: { group: regions }
    parameters:
      endpoint: ${each.region.endpoint}

  - module: retry-pipeline
    as: attempt
    loop: { count: 3, until: ${module.attempt.status} == "ok" }
```

### Three-phase expansion

| Phase | Responsibility | Input | Output |
|-------|---------------|-------|--------|
| **1. ImportExpander** | Expand forEach on imports | List\<YamlImport\> with forEach | List\<YamlImport\> without forEach (N stamped copies per forEach import) |
| **2. ModuleExpander** | Flatten imports into nodes | List\<YamlImport\> (regular) | Merged sections with `alias.nodeId` keys |
| **3. ForEachExpander** | Expand forEach on nodes | Map\<String, Node\> | Map\<String, Node\> (stamped copies) |

Phases 2 and 3 are unchanged. Phase 1 is new.

### Phase 1: ImportExpander

New class `io.casehub.yaml.core.module.ImportExpander`. Pure function, zero dependencies beyond yaml-core.

```java
public final class ImportExpander {

    public static List<YamlImport> expand(
            List<YamlImport> imports,
            Map<String, IterationGroup> iterationGroups,
            Map<String, CsvDataSource> dataSources,
            VariableResolver resolver) {
        // ...
    }
}
```

**For each import with `forEach`:**

1. Parse directive: `ForEachDirective.parse(imp.forEach())`
2. Resolve iteration values:
   - `GroupRef` → look up in `iterationGroups` or `dataSources` (same logic as ForEachExpander)
   - `InlineIteration` → use the inline list
3. For each value, create a stamped `YamlImport`:
   - **Alias:** `imp.as() + "-" + value` (dash composition)
   - **Parameters:** resolve `${each.*}` references against the iteration context
   - **When:** resolve `${each.*}` if present; if resolved `when` is falsy, skip this import entirely
   - **forEach:** null (consumed)
   - **loop:** preserved (runtime concern)
4. Replace the original import with the stamped copies
5. Imports without `forEach` pass through unchanged

**Alias separator:** Dash (`-`). Follows Helm/K8s/CloudPosse conventions for identity composition. The dot is reserved for module-to-node hierarchy (`alias.nodeId`).

**Variable resolution for parameters:**

For list iteration (simple string values):
```java
VariableResolver eachResolver = resolver.withScope("each",
    VariableSource.forEachContext(Map.of(as, value), null));
```

For CSV iteration (typed rows):
```java
VariableResolver eachResolver = resolver.withScope("each",
    VariableSource.forEachContext(
        Map.of(as, rowKey, "index", String.valueOf(i)),
        Map.of(as, row)))
    .withObjectScope("each", ObjectVariableSource.drillOnly(
        name -> name.equals(as) ? row : null));
```

Same dual-registration pattern from #429. Parameters are `Map<String, String>`, so typed values are stringified via the VariableSource path. But if a future extension allows typed parameters, the ObjectVariableSource path is already wired.

**Validation:**
- Stamped alias must not contain dots (ImportExpander enforces this — if the iteration value contains a dot, reject with a clear error)
- Stamped alias must be unique across all expanded imports (reject duplicates)

### Phase integration (consumer responsibility)

yaml-core provides `ImportExpander.expand()`. The consumer (e.g., desiredstate's `YamlGraphRecorder`) calls it at the right point in its pipeline:

```java
// Before:
// ModuleExpander.expand(imports, modules, sections)

// After:
List<YamlImport> expandedImports = ImportExpander.expand(
        imports, iterationGroups, dataSources, resolver);
ModuleExpander.expand(expandedImports, modules, sections);
```

### loop — model only

`loop` field on YamlImport is parsed and carried. yaml-core does not execute loops — the orchestration runtime reads `LoopDirective.parse(imp.loop())` and handles repetition. This is the same pattern as LoopDirective on nodes.

### What forEach and loop mean together

If an import has both `forEach` and `loop`:
- `forEach` is compile-time: Phase 1 stamps out N copies
- `loop` is runtime: each stamped copy retains its `loop` directive
- Result: N independent blocks, each looping at runtime

This is the natural composition — expansion × repetition.

### Nesting

Import-level forEach does not nest. The stamped imports are regular imports (no `forEach`). If a stamped import's module itself contains imports with forEach, those are module-internal and would need their own expansion — but that's a module-expansion concern, not an import-expansion concern. Phase 1 operates on the top-level import list only.

### Variable scope isolation

`${each.*}` in Phase 1 is consumed by parameter resolution. The stamped imports have fully resolved parameters — no `${each.*}` references survive into Phase 2 or 3. If a node inside the module also has `forEach`, it creates its own `each` scope in Phase 3. No collision.

## What changes where

| File | Change |
|------|--------|
| `yaml-core/module/YamlImport.java` | Add `forEach` and `loop` fields |
| `yaml-core/module/ImportExpander.java` | **New** — Phase 1 pre-expansion |
| `yaml-core/module/ImportExpanderTest.java` | **New** — tests for import-level forEach |
| `yaml-jackson/YamlCoreJacksonModule.java` | Add forEach/loop to YamlImport mixin if Jackson deserialises imports |

No changes to ModuleExpander or ForEachExpander — they see regular imports and nodes.

## References

- `yaml-core/module/YamlImport.java:1-14` — import record to extend
- `yaml-core/module/ModuleExpander.java:36-91` — expand method (unchanged, receives pre-expanded imports)
- `yaml-core/module/ModuleExpander.java:validateImports` — dot check (Phase 1 ensures no dots in aliases)
- `yaml-core/foreach/ForEachExpander.java:170-344` — CSV forEach with ObjectVariableSource (pattern to reuse)
- `yaml-core/orchestration/LoopDirective.java:1-47` — runtime loop model
- `yaml-core/foreach/ForEachDirective.java:1-35` — forEach directive parsing
- `desiredstate/yaml/runtime/YamlGraphRecorder.java:100-130` — consumer integration point
- GitHub #432, #429
