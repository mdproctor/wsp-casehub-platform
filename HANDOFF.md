# HANDOFF — casehub-platform

**Last worked:** #879 closed, 2 follow-up issues filed (#886, #887)
**Landed:** `b975807b` on main (3 commits), not yet published
**Queue:** 5 items remaining, #885 is next

## This session

Eliminated direct SnakeYAML API usage from `yaml-step-runtime` (#879). The dual-parse pattern — Jackson for typed `YamlModuleFile` deserialization, SnakeYAML `composeAll`/`convertNode` for source position tracking, then `transferFrom` to bridge positions between object identities — was replaced with a single-pass Jackson `BeanDeserializerModifier` approach.

**New classes in yaml-jackson:**
- `LocationTrackingModule` — Jackson Module with `LOCATION_INDEX_KEY` and `FILE_PATH_KEY` context attributes
- `LocationTrackingModifier` — wraps `MapDeserializer` and `CollectionDeserializer`
- `LocationTrackingMapDeserializer` / `LocationTrackingCollectionDeserializer` — capture `JsonLocation` before delegating, register in `LocationIndex`
- `LocationTrackingHelper` — shared recording logic

**Modified in yaml-step-runtime:**
- `PlaybookParser` — replaced `composeAll`/`convertNode`/`resolveScalar` with Jackson `ObjectMapper` + `MappingIterator`. Static `MAPPER` field. `parseRawWithLocations` reduced to package-private (only test caller remains).
- `FileSystemModuleLoader` — single Jackson parse with `LocationTrackingModule` replaces dual-parse + `transferFrom`. `PlaybookParser` import removed.

**Code review:** 0 CRITICAL, 0 WARNING, 2 NOTEs (both fixed: orphaned public method → package-private, FQN → import).

**Blog:** "The Parse You Already Paid For" — Jackson BeanDeserializerModifier for position tracking.

**Issues filed:**
- #886 — Remove orphaned `parseRawWithLocations` entirely (XS/Low)
- #887 — Migrate config-core and endpoints-config-core from direct SnakeYAML to Jackson (XS/Low)

## Queue (5 items)

1. #885 — SchemaEmitter bare array type for List<T> plugin fields (S/Med) ← next
2. #883 — Test deferred condition with use inside branch structures (XS/Low)
3. #884 — Fix pre-existing compile errors in yaml-test-core (XS/Low)
4. #886 — Remove orphaned parseRawWithLocations (XS/Low)
5. #887 — Migrate config-core/endpoints-config-core from SnakeYAML (XS/Low)

**Note:** The task hierarchy under #885 in the .queue is stale (injected under wrong issue during queue reorder). It will be overwritten when #885's actual plan is created.

## References

- Blog: `blog/2026-11-18-mdp06-the-parse-you-already-paid-for.md`
- Design spec: `specs/issue-879-eliminate-snakeyaml-dual-parse/2026-11-18-eliminate-snakeyaml-dual-parse-design.md`
- Key files: `yaml-jackson/.../LocationTrackingModule.java`, `yaml-step-runtime/.../PlaybookParser.java`, `yaml-step-runtime/.../FileSystemModuleLoader.java`
