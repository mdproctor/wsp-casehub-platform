# Design Journal — issue-474-spring-boot-generators

## 2026-09-14 — Session 1: Design + Batch 1 Foundation

**Scope validation changed the epic.** The original epic specified 5 generators. Surveying consumer repos (engine, work, qhorus, ledger, blocks, connectors, eidos) revealed that persistence (86/131 files already plain JPA) and security (@RolesAllowed: 0 occurrences in consumers) don't need generators. Revised to 3 generators (rest, graphql, mcp) + Panache→JPA porting (45 files). The decision review surfaced two additional decisions: the graphql-spring-generator must produce dual output (GraphQL + REST from @McpDomain, mirroring the existing graphql-generator), and the mcp-spring-generator handles @Tool only (not @McpDomain — that's runtime infrastructure).

**generator-common module created.** Extracted shared infrastructure from spring-generator: AbstractGeneratorMojo (Jandex loading), AbstractVerifyMojo (drift detection), JandexTypeConverter (Jandex Type → JavaPoet TypeName), JandexUtils. Palantir JavaPoet chosen over Square's archived version. Spring-generator retrofitted — extends the new base classes, all existing tests pass, platform-spring consumer validated.

**Batch 1 complete.** 3 of 10 tasks done. Next session starts at Batch 2: rest-spring-generator (97 JAX-RS files — highest value).
