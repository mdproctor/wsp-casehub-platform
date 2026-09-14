# HANDOFF — issue-296-generator-nested-paths-enum

**Branch:** `issue-296-generator-nested-paths-enum`
**Covers:** #296 (generator enhancements), #297 (batch 2 migration)
**Progress:** Tasks 1-2 of 4 complete. Batches 3-4 remain.

## What Happened

1. Designed and reviewed spec for @RestPath annotation + simple type detection + batch 2 endpoint migration
2. Implemented @RestPath annotation in platform-api and generator support (resolveRestPath, Jandex-based enum/fromString/valueOf detection)
3. Migrated AclResource → AclApi SPI + AclService. 21 tests pass.

## Key Decisions

- D7 (RoundEnvironment scanning) dropped — SPIs go in dependency modules (platform-api, preferences-editor-core) following batch 1 pattern
- Batch DELETE endpoints changed to POST (DELETE with body is non-standard HTTP)
- registerParent uses String params (ResourceId fromString detection unreliable in APT context)
- Stale annotationProcessorPaths JAR: always `mvn install -pl graphql-generator` before building modules that use the APT, and `rm -rf target/` on the consuming module to force clean generation

## Next Action

Run `work continue` — picks up at Task 3 (Preferences migration). Plan: `plans/2026-09-14-generator-nested-paths-batch2.md`
