## D1: Scope — both paths in one shot

**Choice:** Unify both module files AND main playbook path in a single change
**Alternatives:**
- Module files only — smaller change but leaves SnakeYAML usage in main playbook path
**Rationale:** One mechanism, one PR, complete SnakeYAML elimination. No intermediate state where some paths use SnakeYAML and others use Jackson.
**Trade-offs:** Larger change surface, higher test burden
**Sources:** PlaybookParser.java (parseWithLocations, parseRawWithLocations), FileSystemModuleLoader.java (parseModuleContent)
**Exploration:** quick
**Status:** captured

## D2: Approach — Jackson BeanDeserializerModifier with location-tracking wrappers

**Choice:** Register a Jackson Module in yaml-jackson that wraps MapDeserializer and CollectionDeserializer via BeanDeserializerModifier. Each wrapper captures parser.getTokenLocation() before delegating, then registers the returned object + location in a LocationIndex passed via DeserializationContext.setAttribute().
**Alternatives:**
- Direct JsonParser streaming (port convertNode to Jackson token API) — simpler for main playbook but doesn't fix dual-parse for module files; still needs transferFrom
- readTree + tree walk + treeToValue — JsonNode doesn't store locations, treeToValue breaks identity; worst of both worlds
**Rationale:** Only approach that solves both paths with a single mechanism. Module files get single-pass typed deserialization with positions. Main playbooks get single-pass untyped deserialization with positions. transferFrom removed from module-file path entirely.
**Trade-offs:** Relies on Jackson's BeanDeserializerModifier/deserializer wrapping contract being stable. Moderate complexity in deserializer wrapping (map + collection + untyped object).
**Sources:** Jackson BeanDeserializerModifier API, LocationIndex.java, PlaybookParser.java, FileSystemModuleLoader.java
**Exploration:** quick
**Status:** captured
