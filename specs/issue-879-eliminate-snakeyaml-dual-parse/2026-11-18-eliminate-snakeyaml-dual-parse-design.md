# Eliminate Dual-Parse: Jackson-Native Source Position Tracking

**Issue:** casehubio/platform#879
**Date:** 2026-11-18
**Status:** Design

## Problem

#870 introduced dual-parsing of module files: Jackson for structured `YamlModuleFile` deserialization, SnakeYAML (`composeAll` + `convertNode`) for source position tracking in `LocationIndex`. The main playbook path (`parseWithLocations`) also uses SnakeYAML exclusively. This creates two problems:

1. **Module files are parsed twice** — Jackson for structure, SnakeYAML for positions, then `transferFrom()` bridges positions from SnakeYAML-created objects to Jackson-created objects.
2. **Direct SnakeYAML API usage** — `PlaybookParser` uses `Yaml`, `composeAll`, `Node`, `MappingNode`, `SequenceNode`, `ScalarNode`, and `Mark` directly. SnakeYAML is not a declared dependency — it's transitive through `jackson-dataformat-yaml`.

## Approach

Replace all direct SnakeYAML usage with a Jackson `Module` that captures `JsonLocation` during deserialization and registers positions in `LocationIndex`. Both the main playbook path and the module file path use a single Jackson parse with position tracking.

## Architecture

### New: `LocationTrackingModule` (in `yaml-jackson`)

A Jackson `Module` that registers a `BeanDeserializerModifier`. The modifier wraps `MapDeserializer` and `CollectionDeserializer` with location-tracking decorators.

```
LocationTrackingModule
  └─ LocationTrackingModifier (BeanDeserializerModifier)
       ├─ modifyMapDeserializer() → LocationTrackingMapDeserializer
       └─ modifyCollectionDeserializer() → LocationTrackingCollectionDeserializer
```

Each wrapper:
1. Reads `parser.currentTokenLocation()` before delegating to the standard deserializer
2. After delegation returns the object, registers `(object, SourceLocation)` in `LocationIndex`
3. `LocationIndex` and `filePath` are read from `DeserializationContext` attributes

**Why yaml-jackson:** This module already hosts `YamlCoreJacksonModule` (Jackson mixins for yaml-core types). It depends on both `yaml-core` (which owns `LocationIndex`) and `jackson-databind`. The location tracking module is a natural sibling.

**Threading through context:**

```java
LocationIndex index = new LocationIndex();
ObjectReader reader = mapper.readerFor(targetType)
    .withAttribute(LocationTrackingModule.LOCATION_INDEX_KEY, index)
    .withAttribute(LocationTrackingModule.FILE_PATH_KEY, filePath);
```

When the attributes are absent (location tracking not requested), the wrappers delegate without recording — zero overhead for non-tracking parses.

### LocationTrackingMapDeserializer

Wraps the standard `JsonDeserializer<Map>`. On `START_OBJECT`:
1. Capture `parser.currentTokenLocation()` → `JsonLocation`
2. Delegate to wrapped deserializer → returns `Map` instance
3. If `LocationIndex` present in context, register `index.put(map, new SourceLocation(filePath, loc.getLineNr(), loc.getColumnNr()))`

### LocationTrackingCollectionDeserializer

Same pattern for `List`/`Collection`. On `START_ARRAY`:
1. Capture location
2. Delegate
3. Register

### UntypedObjectDeserializer interaction

Jackson's `UntypedObjectDeserializer` (used for `readValue(yaml, Object.class)`) delegates to custom map/collection deserializers when they're registered via `BeanDeserializerModifier`. Specifically, `UntypedObjectDeserializer.createContextual()` calls `_findCustomDeser()` for map and list types — custom deserializers survive `_clearIfStdImpl()`. When the untyped deserializer encounters `START_OBJECT`, it delegates to our `LocationTrackingMapDeserializer`; for `START_ARRAY`, to our `LocationTrackingCollectionDeserializer`.

This means a single `ObjectMapper` with `LocationTrackingModule` registered handles both:
- **Typed deserialization** (`YamlModuleFile`) — map/list fields within the typed structure get position tracking
- **Untyped deserialization** (`Object.class`) — raw `LinkedHashMap`/`ArrayList` tree with positions

## Changes to Existing Code

### PlaybookParser

**Remove:**
- `parseRawWithLocations()` — only used by `FileSystemModuleLoader`; replaced by Jackson with `LocationTrackingModule`
- `convertNode()` — SnakeYAML node walking; replaced by Jackson deserialization
- `resolveScalar()` — SnakeYAML scalar resolution; Jackson's YAML parser handles this identically (same SnakeYAML internally, YAML 1.1 resolution: yes/no/on/off as booleans, integer/long/double, quoted strings preserved)
- All 9 inline `org.yaml.snakeyaml.*` FQN references

**Replace `parseWithLocations()`:**

Current (SnakeYAML):
```java
var loader = new org.yaml.snakeyaml.Yaml();
for (var node : loader.composeAll(new StringReader(yaml))) {
    documents.add(convertNode(node, index, filePath));
}
```

New (Jackson):
```java
ObjectReader reader = mapper.readerFor(Object.class)
    .withAttribute(LOCATION_INDEX_KEY, index)
    .withAttribute(FILE_PATH_KEY, filePath);
MappingIterator<Object> iter = reader.readValues(yaml);
while (iter.hasNext()) {
    documents.add(iter.next());
}
```

Multi-document YAML (`---` separators) is handled by `MappingIterator`.

**Keep:** `ParseResult`, `RawParseResult` records, `parse()`, `assembleDocument()`, `extractFrontMatter()`, `asMap()`, `rejectStepsWrapper()` — these are playbook document assembly logic, not parsing.

**New dependency:** `PlaybookParser` gains a static `ObjectMapper` field configured with `YAMLFactory`, `LocationTrackingModule`, and `YamlCoreJacksonModule`. This matches the pattern already used in `FileSystemModuleLoader` (line 30). The class stays static — no instance state beyond the shared mapper.

### FileSystemModuleLoader

**Simplify `parseModuleContent()`:**

Current (dual-parse):
```java
YamlModuleFile moduleFile = mapper.readValue(yaml, YamlModuleFile.class);
if (locations != null) {
    var raw = PlaybookParser.parseRawWithLocations(yaml, filePath);
    // ... transferFrom bridge ...
}
```

New (single-parse):
```java
ObjectReader reader = mapper.readerFor(YamlModuleFile.class);
if (locations != null) {
    reader = reader
        .withAttribute(LOCATION_INDEX_KEY, locations)
        .withAttribute(FILE_PATH_KEY, filePath);
}
YamlModuleFile moduleFile = reader.readValue(yaml);
```

Positions for all maps and lists within `YamlModuleFile` are captured during deserialization. No second parse, no `transferFrom`.

**ObjectMapper configuration:** The existing `ObjectMapper` in `FileSystemModuleLoader` already has `YAMLFactory` and `YamlCoreJacksonModule`. Add `LocationTrackingModule` to the registration.

### LocationIndex

**Keep `transferFrom()`** — still used by `PlaybookModuleBridge.expandBranches()` for identity preservation when creating new maps during branch expansion. This usage is unrelated to SnakeYAML.

No changes to `LocationIndex` itself.

## Compatibility

### Scalar resolution

Jackson's `YAMLParser` uses SnakeYAML internally for YAML parsing. YAML 1.1 scalar resolution (yes/no/on/off as booleans, integer overflow to long, quoted string preservation) is handled at the SnakeYAML layer before Jackson sees JSON tokens. `UntypedObjectDeserializer` creates `Integer`/`Long`/`Double`/`Boolean`/`String`/`null` from these tokens — the same types `convertNode`'s `resolveScalar` produces.

**Verification:** TDD tests will parse playbooks with edge-case scalars (yes, no, on, off, quoted "true", integer overflow, null/~) and assert identical types.

### Source positions

Jackson's `currentTokenLocation()` returns 1-based line and column numbers. SnakeYAML's `Mark` is 0-based with `+1` applied in `convertNode`. Result: identical positions with no adjustment needed — `getLineNr()` directly replaces `mark.getLine()+1`.

**Verification:** TDD tests will parse playbooks and assert identical `SourceLocation` values for known map/list positions.

### Multi-document YAML

Jackson's `MappingIterator` (via `readValues()`) iterates all `---`-separated documents, matching `composeAll()` behavior.

**Verification:** TDD tests will parse 1-document, 2-document, and 3-document playbooks and assert correct document count and structure.

## What's NOT changing

- `LocationIndex` API — no changes
- `PlaybookModuleBridge` — continues using `transferFrom` for self-transfer
- `YamlModuleFile` / `YamlModuleFileMixin` — Jackson deserialization config unchanged
- `ModuleExpander` — unchanged, receives same map structures
- Downstream consumers of `LocationIndex` — unchanged, same `SourceLocation` values

## Module placement

| Component | Module |
|-----------|--------|
| `LocationTrackingModule` | `yaml-jackson` |
| `LocationTrackingModifier` | `yaml-jackson` |
| `LocationTrackingMapDeserializer` | `yaml-jackson` |
| `LocationTrackingCollectionDeserializer` | `yaml-jackson` |
| Changes to `PlaybookParser` | `yaml-step-runtime` |
| Changes to `FileSystemModuleLoader` | `yaml-step-runtime` |

No new modules. No new dependencies beyond what already exists.

## Test strategy

1. **Unit tests for LocationTrackingModule** (in `yaml-jackson`):
   - Parse simple YAML map → verify map registered in LocationIndex with correct line/column
   - Parse nested maps → verify all levels registered
   - Parse lists → verify lists registered
   - Parse without LocationIndex attribute → verify no-op (no errors, no tracking)
   - Parse typed object (record with map/list fields) → verify positions captured

2. **Compatibility tests for PlaybookParser** (in `yaml-step-runtime`):
   - Scalar resolution: yes/no/on/off, quoted "true"/"false", integers, longs, doubles, null/~
   - Multi-document: 1-doc, 2-doc, 3-doc playbooks
   - Position accuracy: known map/list positions match expected SourceLocation values
   - Existing PlaybookParser tests continue to pass

3. **Integration tests for FileSystemModuleLoader** (in `yaml-step-runtime`):
   - Module file parse produces YamlModuleFile with positions in LocationIndex
   - Positions match for all section maps and step lists
   - Existing module loading tests continue to pass

## References

- `yaml-step-runtime/.../PlaybookParser.java` — SnakeYAML usage site (parseWithLocations, parseRawWithLocations, convertNode, resolveScalar)
- `yaml-step-runtime/.../FileSystemModuleLoader.java` — dual-parse site (parseModuleContent)
- `yaml-step-runtime/.../PlaybookModuleBridge.java` — transferFrom self-transfer (expandBranches)
- `yaml-core/.../LocationIndex.java` — IdentityHashMap position tracking
- `yaml-jackson/.../YamlCoreJacksonModule.java` — existing Jackson module for yaml-core types
- Jackson `BeanDeserializerModifier` API — deserializer wrapping contract
- Jackson `UntypedObjectDeserializer` source — `_findCustomDeser` / `_clearIfStdImpl` for custom deserializer delegation
