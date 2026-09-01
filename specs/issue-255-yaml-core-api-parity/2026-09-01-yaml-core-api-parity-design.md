# yaml-core API Parity — Design Spec

**Issue:** casehubio/platform#255
**Date:** 2026-09-01
**Status:** Draft
**Blocks:** casehubio/casehub-desiredstate#128 (migration)

## Summary

Four API additions to `casehub-platform-yaml-core` that eliminate migration
regressions for desiredstate#128. After these land, desiredstate can fully
replace its local `VariableResolver`, `ForEachExpander`, and `ModuleExpander`
with yaml-core's versions.

1. `sourceFor(prefix)` + `withChainedScope()` on VariableResolver
2. `IterationValueExpander` callback on ForEachExpander
3. `SectionDeserializer` + `SectionContentRewriter` on ModuleExpander
4. Typed accessor on `ExpandedModule`

All additive — no breaking changes to the landed API.

## 1. VariableResolver — sourceFor + withChainedScope

### sourceFor (primitive accessor)

```java
public VariableSource sourceFor(String prefix) {
    return prefixSources.get(prefix);
}
```

Returns the registered `VariableSource` for a prefix, or `null` if the prefix
is not registered. Enables self-contained module scope chaining.

### withChainedScope (convenience)

```java
public VariableResolver withChainedScope(String prefix, VariableSource source) {
    VariableSource existing = prefixSources.get(prefix);
    VariableSource chained = existing != null
            ? VariableSource.chain(source, existing) : source;
    return withScope(prefix, chained);
}
```

Layers a new source ahead of the existing source for a prefix. Captures
the actual intent (module scope layering) in one call:

```java
// Before: verbose, must carry base source separately
resolver.withScope("var", VariableSource.chain(moduleScope::get, baseVarSource))

// After: self-contained
resolver.withChainedScope("var", moduleScope::get)
```

Both methods follow the immutable-child pattern — return new resolver instances,
propagate `deferredPrefixHandler`.

## 2. ForEachExpander — IterationValueExpander

```java
@FunctionalInterface
public interface IterationValueExpander {
    List<String> expand(String resolvedValue, String groupContext);
}
```

New overload of `ForEachExpander.expand()`:

```java
public static <E> ExpansionResult<E> expand(
        Map<String, E> elements,
        Map<String, IterationGroup> iterationGroups,
        VariableResolver resolver,
        ForEachAdapter<E> adapter,
        int maxExpansion,
        IterationValueExpander valueExpander) { ... }
```

Called in `resolveValues()` after variable resolution on each iteration value.
If the expander returns multiple values, they replace the single value.
Default (null or existing overload): return as single-element list.

**Error handling:** Exceptions from the callback propagate with expansion
context wrapped — the consumer's callback doesn't know which group triggered
the call, but `ForEachExpander` does.

**Desiredstate usage:**
```java
IterationValueExpander jsonExpander = (resolved, ctx) -> {
    if (resolved.startsWith("[")) {
        return mapper.readValue(resolved, new TypeReference<List<String>>() {});
    }
    return List.of(resolved);
};
```

## 3. ModuleExpander — SectionDeserializer + SectionContentRewriter

### SectionDeserializer

```java
@FunctionalInterface
public interface SectionDeserializer {
    Object deserialize(String sectionName, String entryKey, Map<String, Object> rawEntry);
}
```

Registered on `ModuleExpander.expand()`. Called for each section entry during
expansion, converting raw `Map<String, Object>` to typed domain objects. The
typed result is stored as `Object` in the section map.

**Pipeline timing:** Deserialization is compatible with unresolved `${var.*}`
references because domain types use `Map<String, Object>` or `String` for
variable-carrying fields. `YamlNode.spec()` returns `Map<String, Object>` —
`${var.apiEndpoint}` survives as a string value in the map. Jackson
deserializes it without issues.

**Constraint:** Consumer types must use Object-typed fields (String, Map,
List, Object) for any content that may contain variable references. Types
with strictly-typed fields (e.g., `int port`) that carry `${var.*}` will
fail deserialization.

### SectionContentRewriter

```java
@FunctionalInterface
public interface SectionContentRewriter {
    Object rewrite(String sectionName, String entryKey, Object entryValue,
                   String alias, Set<String> moduleKeys);
}
```

Called AFTER deserialization, for each entry in each section during expansion.
`entryValue` is the deserialized typed object (if deserializer was provided)
or the raw `Map<String, Object>` (if not). The consumer inspects the value and
rewrites internal references that match `moduleKeys` by adding the alias prefix.

### ModuleExpander API

```java
public static ExpandedModule expand(
        List<YamlImport> imports,
        Map<String, YamlModule> availableModules,
        Map<String, Map<String, Object>> existingSections,
        SectionDeserializer deserializer,
        SectionContentRewriter rewriter) { ... }
```

Keep the existing 3-arg overload as convenience (null deserializer + null
rewriter = current behaviour).

**Expansion loop per entry:**
```java
Object value = contentEntry.getValue();
if (deserializer != null) {
    value = deserializer.deserialize(sectionName, contentEntry.getKey(), 
            (Map<String, Object>) value);
}
if (rewriter != null) {
    value = rewriter.rewrite(sectionName, contentEntry.getKey(), value,
            imp.as(), module.sections().get(sectionName).keySet());
}
targetSection.put(prefixedKey, value);
```

## 4. ExpandedModule — typed section accessor

```java
public record ExpandedModule(
        Map<String, Map<String, Object>> sections,
        Map<String, Map<String, String>> moduleScopes,
        Map<String, String> importConditions) {

    @SuppressWarnings("unchecked")
    public <T> Map<String, T> section(String name) {
        return (Map<String, T>) (Map<String, ?>)
                sections.getOrDefault(name, Map.of());
    }
}
```

The cast is unchecked but safe — the consumer registered the `SectionDeserializer`
that produced the typed objects. One accessor beats scattered casts at every
access site.

## Test Plan

| Test | Coverage |
|------|----------|
| `sourceFor` returns registered source | verify non-null for registered prefix |
| `sourceFor` returns null for unknown | verify null |
| `withChainedScope` layers ahead of existing | module params override base source |
| `withChainedScope` with no existing source | new source registered directly |
| `IterationValueExpander` splits JSON array | `["a","b"]` → 2 elements |
| `IterationValueExpander` single value passthrough | no expansion |
| `IterationValueExpander` null = current behaviour | existing overload |
| `IterationValueExpander` error wraps context | exception includes group name |
| `SectionDeserializer` converts during expansion | result values are typed |
| `SectionDeserializer` null = raw passthrough | existing behaviour |
| `SectionContentRewriter` receives typed objects | after deserializer runs |
| `SectionContentRewriter` receives raw maps without deserializer | fallback |
| `SectionContentRewriter` rewrites internal refs | moduleKeys match, alias prefixed |
| `ExpandedModule.section()` typed accessor | returns typed map |
| Import validation still runs with deserializer | structural checks unchanged |

## Downstream Impact

After these land, desiredstate#128 migration achieves full parity:

| Capability | Before (local) | After (yaml-core) |
|-----------|---------------|-------------------|
| Variable resolution | Parity | Parity + DeferredPrefixHandler |
| Module scope layering | `withModuleScope()` | `withChainedScope("var", ...)` |
| ForEach JSON arrays | Built-in Jackson | IterationValueExpander callback |
| Module key prefixing | Typed `Map<String, YamlNode>` | Typed via SectionDeserializer |
| Dependency rewriting | Typed field access | Typed via SectionContentRewriter |
| Parameter validation | Required-only | Full constraints (minLength, pattern, etc.) |
| Import validation | Build-time processor | ModuleExpander structural checks |

## References

- `io.casehub.yaml.core.resolver.VariableResolver` — D1 target
- `io.casehub.yaml.core.resolver.VariableSource` — chain composition
- `io.casehub.yaml.core.foreach.ForEachExpander` — D2 target
- `io.casehub.yaml.core.module.ModuleExpander` — D3/D4 target
- `io.casehub.yaml.core.module.ExpandedModule` — typed accessor target
- `io.casehub.desiredstate.yaml.resolver.VariableResolver` — local version with `withModuleScope()`
- `io.casehub.desiredstate.yaml.ForEachExpander.resolveGroupValues()` — JSON array parsing
- `io.casehub.desiredstate.yaml.ModuleExpander` — typed dependency rewriting
- casehubio/platform#255 — this issue
- casehubio/casehub-desiredstate#128 — migration issue (first consumer, blocked)
- `decisions.md` — D1–D4 design decisions
