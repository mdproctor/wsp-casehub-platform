# HANDOFF — casehub-platform

## Status

**Platform #428 (YamlMappers standardisation):** CLOSED. 119 sites migrated across 15 repos.
**Epic #520 (Playbook naming unification):** CLOSED. All 11 issues done.
**Epic #502 (YAML cross-repo parity):** Batches 1-4 closed. Batch 5 (pages#502 ops sub-epic) open.

## This Session

Standardised YAML parsing across the entire casehub ecosystem:
- Migrated 119 `new ObjectMapper(new YAMLFactory())` sites to `YamlMappers.create()` (YAML 1.2 Core Schema with `PARSE_BOOLEAN_LIKE_WORDS_AS_STRINGS`).
- 36 production sites + 83 test sites across 15 repos.
- Added `casehub-platform-yaml-jackson` dependency to 11 repos that didn't have it.
- All changes landed on main, pushed to mdproctor and casehubio remotes.

**Repos modified:** platform, engine, work, desiredstate, pages, examples, connectors, ops, iot, claudony, eidos, neocortex, scaffold, fsitrading, blocks

**Excluded (intentionally not migrated):**
- `YamlMappers.java` itself (platform yaml-jackson — IS the factory)
- `ContentResolver(new YAMLFactory())` (platform yaml-codegen, engine codegen — jsonschema2pojo API)
- `CaseHubSchemaGenerator` (engine — custom YAML output features: WRITE_DOC_START_MARKER, MINIMIZE_QUOTES)
- `CognitiveSchemaGenerator` (neocortex — same custom output features)
- `JsonMapper.builder(new YAMLFactory())` (platform yaml-jackson tests — testing builder-specific behaviour)

## Key Decisions

- YAML output sites (CaseHubSchemaGenerator, CognitiveSchemaGenerator) left as-is — they configure YAMLGenerator features for output formatting, not parsing. A future `YamlMappers.createForWriting()` could cover these.
- Engine dependencyManagement was missing yaml-jackson entry — added it as part of this migration (pre-existing gap).
- `.findAndRegisterModules()` chains preserved — only the ObjectMapper creation was replaced.

## Next Action — Pages Post-Rename Cleanup

**Larger goal:** The Scenario→Playbook rename (#520) and YamlMappers standardisation (#428) are landed. But the rename left behind dead code, stale types, and broken references in casehub-pages. These cleanup issues complete the rename's tail work and move platform#502 (YAML cross-repo parity) closer to closure.

**.plan queue (4 issues, all casehubio/casehub-pages):**

1. **#528** — ScenarioLibraryGraphQL breaks SmallRye. Likely already resolved by the playbook rename (#525 landed 241 files). Verify the class is gone or renamed with proper GraphQL annotations, then close. XS/Low.
2. **#514** — Delete remaining Format A types. Old flat-step parser types (`ScenarioParser`, `ScenarioStep` sealed interface, `AriaStep`/`GraphQLStep`/`SimulatedStep`) are dead code after the hierarchical parser migration. Pure deletion. M/Low.
3. **#390** — Scenario format refinements (cleanup items ONLY). Delete `ScenarioParser.java` (Format A parser) and consolidate TS `types.ts`. Skip the new-feature items in this issue (actor, delay, REST/GraphQL wiring). M/Med.
4. **#519** — Annotate historical spec docs with post-unification type names. Docs sweep. S/Low.

**Scope guard:** chores and cleanup only. No new features, no examples, no new capabilities.

## References

- GitHub issue: casehubio/platform#428 (closed)
- `YamlMappers.java`: platform/yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlMappers.java
- `YamlMappersTest.java`: platform/yaml-jackson/src/test/java/io/casehub/yaml/jackson/YamlMappersTest.java
