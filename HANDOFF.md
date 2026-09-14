# HANDOFF — issue-296-generator-nested-paths-enum

**Branch:** `issue-296-generator-nested-paths-enum`
**Covers:** #296 (generator enhancements), #297 (batch 2 migration)
**Progress:** All 4 tasks complete. Ready for work-end.

<<<<<<< HEAD
## What Happened

1. Designed and reviewed spec for @RestPath annotation + simple type detection + batch 2 endpoint migration
2. Implemented @RestPath annotation in platform-api and generator support (resolveRestPath, Jandex-based enum/fromString/valueOf detection)
3. Migrated AclResource → AclApi SPI + AclService. 21 tests pass.
4. Migrated PreferenceResource → PreferenceApi SPI + PreferenceService. PreferenceSchemaResource stays hand-written for ETag. 27 tests pass.
5. Migrated NotificationResource + SuppressionResource → NotificationApi + NotificationSuppressionApi SPIs + services. 40 tests pass.

## Key Decisions

- D7 (RoundEnvironment scanning) dropped — SPIs go in dependency modules (platform-api, preferences-editor-core) following batch 1 pattern
- Batch DELETE endpoints changed to POST (DELETE with body is non-standard HTTP)
- registerParent uses String params (ResourceId fromString detection unreliable in APT context)
- Stale annotationProcessorPaths JAR: always `mvn install -pl graphql-generator` before building modules that use the APT, and `rm -rf target/` on the consuming module to force clean generation
- addMute/activateSnooze return 200 (was 201) — generator wraps non-void returns in Response.ok()
- Preference SPIs placed in preferences-editor-core (not platform-api) — requires jandex-maven-plugin addition
- PreferenceSchemaResource annotated with @McpDomain for documentation/future skip detection

## Commits

1. `10f1cf0e` feat(#296): @RestPath annotation + simple type detection via Jandex
2. `527bc868` feat(#297): migrate AclResource to generated @McpDomain approach
3. `bdcbf631` feat(#297): migrate PreferenceResource to generated @McpDomain approach
4. `eb6be20d` feat(#297): migrate notification + suppression endpoints to generated @McpDomain

## Next Action

Run `work end` to close the branch — all tasks and both issues are complete.
=======
Designed Spring Boot generator epic (#474) — validated scope against codebase, reducing 5 generators to 3 (rest, graphql, mcp) + Panache→JPA porting (45 files). 9 design decisions captured and reviewed. Built generator-common module (AbstractGeneratorMojo, AbstractVerifyMojo, JandexTypeConverter with Palantir JavaPoet). Retrofitted spring-generator to extend new base — all existing tests pass, platform-spring consumer validated.

## Immediate Next Step

Execute Batch 2: rest-spring-generator (Task 4 in plan). RestResourceScanner + RestControllerWriter — JAX-RS to Spring MVC mapping.

## Garden Entries Consulted

GE-20260909-81809c, GE-20260817-8b0648, GE-20260909-8fb2e4, GE-20260613-095ce5, GE-20260817-bbfbf5, GE-20260416-f316e2, GE-20260420-7d28fa, GE-0138

## References

- `specs/issue-474-spring-boot-generators/2026-09-14-spring-boot-generators-design.md`
- `specs/issue-474-spring-boot-generators/decisions.md` (9 decisions, review-approved)
- `plans/2026-09-14-spring-boot-generators.md` (10 tasks, 5 batches)
- `blog/2026-09-14-mdp01-spring-generators-epic-shrank.md`
>>>>>>> issue-474-spring-boot-generators
