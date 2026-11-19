# HANDOFF — casehub-platform

**Last worked:** #885, #883, #884, #886, #887 closed; 2 follow-up issues filed (#888, #889)
**Landed:** `ba7c64ed` on main (7 commits), not yet published
**Queue:** 2 items remaining, #888 is next

## This session

Closed 5 issues — the tail of the SnakeYAML migration (#879) plus APT schema improvements.

**#885 (S/Med):** `SchemaEmitter` APT now generates proper `items` schema for `List<T>` plugin fields. Refactored from `toJsonType(String)` to `writeProperty(TypeMirror)` — extracts type arguments via `DeclaredType.getTypeArguments()`. For `List<Record>`, generates full `items` with `properties` and `required`. For `List<SimpleType>`, generates `items` with the basic JSON type. Code review caught a regression: the `startsWith("java.util.List")` fallback was removed from `toJsonType`, breaking raw List and nested record List components — fixed in `ba7c64ed`.

**#883 (XS/Low):** Two test playbooks verifying `use:` steps inside `if/then` branches respect deferred import conditions. Truthy → branch executes; falsy → branch skipped.

**#884 (XS/Low):** Hardened 4 `Map.of()` call sites in `PlaybookModuleBridgeTest` with explicit `Map.<String, Object>of()` to prevent type inference ambiguity with overloaded `expandUseSteps`.

**#886 (XS/Low):** Removed orphaned `parseRawWithLocations` and `RawParseResult` from `PlaybookParser`. Single test caller was redundant with `LocationTrackingModuleTest`.

**#887 (XS/Low):** Migrated `YamlPreferenceLoader` (config-core) and `YamlEndpointLoader` (endpoints-config-core) from `Yaml.load()` to `ObjectMapper(YAMLFactory).readValue()`. Handles empty input via `MismatchedInputException` (Jackson throws where SnakeYAML returned null). POM deps switched from `snakeyaml` to `jackson-dataformat-yaml`. Zero direct SnakeYAML imports remain in platform production code.

**Blog:** "The Type Your Schema Forgot" — APT TypeMirror vs toString() for schema generation, final SnakeYAML removal.

**Issues filed:**
- #888 — Nested record components lose TypeMirror — List fields lack items schema (S/Med)
- #889 — Standalone record fields lack nested properties schema (S/Low)

## Queue (2 items)

1. #888 — SchemaEmitter nested record components lose TypeMirror (S/Med) ← next
2. #889 — SchemaEmitter standalone record fields lack nested properties (S/Low)

## References

- Blog: `docs/blog/2026-11-19-mdp01-the-type-your-schema-forgot.md`
- Key files: `yaml-plugin-processor/.../SchemaEmitter.java`, `config-core/.../YamlPreferenceLoader.java`, `endpoints-config-core/.../YamlEndpointLoader.java`
