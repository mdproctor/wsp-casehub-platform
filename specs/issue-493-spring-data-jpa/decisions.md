# Decisions — Spring Data JPA Modules (#493)

## D1: Query style for Spring JPA modules

**Choice:** Idiomatic Spring Data JPA repositories (JpaRepository interfaces, derived query methods, @Query annotations)
**Alternatives:**
- EntityManager-based — easier to keep in sync with Quarkus modules but less idiomatic Spring
- Mixed (repo where clean, EM where complex) — pragmatic but inconsistent
**Rationale:** The issue explicitly calls for Spring Data JPA. Idiomatic Spring Data is more maintainable for Spring developers and leverages framework features (pagination, auditing, query derivation). Complex queries (cursor pagination, CTEs, FTS) will still use @Query or EntityManager where Spring Data derived methods aren't expressive enough.
**Trade-offs:** Query logic is not shared with Quarkus modules — changes to query behaviour must be made in both places
**Sources:** casehubio/parent#493 issue body, existing JPA module EntityManager usage patterns
**Exploration:** quick
**Status:** captured

## D2: Entity and migration sharing strategy

**Choice:** Extract to `*-jpa-common` modules — shared entity classes + Flyway SQL + helpers with `jakarta.persistence-api` dependency only
**Alternatives:**
- Duplicate entities in -spring-jpa — simpler structure but creates maintenance burden (changes in two places)
- Move entities to existing -core modules — fewer modules but pollutes framework-neutral core with JPA annotations
**Rationale:** Entities are pure JPA annotations, Flyway SQL is framework-neutral. A shared module eliminates duplication without contaminating either framework's classpath. Both -jpa (Quarkus) and -spring-jpa depend on the common module.
**Trade-offs:** 10 additional Maven modules (jpa-common). More module machinery, but each is small (entities + SQL only).
**Sources:** persistence-jpa/PreferenceEntry.java (pure JPA), platform-core pattern (no JPA deps), spring-generator (classpath separation)
**Exploration:** quick
**Status:** captured

## D3: Uniform vs selective three-tier pattern

**Choice:** Uniform — all 10 modules get the same three-tier structure (jpa-common / jpa / spring-jpa)
**Alternatives:**
- Selective (2+ entities only) — fewer modules for simple domains, but inconsistent structure
**Rationale:** Consistency reduces cognitive load. Every JPA domain follows the same pattern. Even single-entity modules benefit from shared migrations and entity source of truth.
**Trade-offs:** 20 new modules total (10 jpa-common + 10 spring-jpa). Some jpa-common modules will be very small (1 entity + 1 SQL file).
**Sources:** Existing uniform patterns: every CDI module has a -core counterpart (37 core modules already exist)
**Exploration:** quick
**Status:** captured

## D4: Test database strategy for Spring JPA modules

**Choice:** H2 with `MODE=PostgreSQL` for all modules. Only `@Disabled` for genuinely incompatible features (FTS `websearch_to_tsquery` in memory-jpa, recursive CTEs in acl-jpa). Revisit if coverage gaps appear.
**Alternatives:**
- Testcontainers PostgreSQL — full fidelity but slower CI, requires Docker
- H2 + Testcontainers selectively — mixed strategy, inconsistent test infrastructure
**Rationale:** Matches existing Quarkus test strategy (H2). PostgreSQL mode covers most dialect features (`SELECT FOR UPDATE SKIP LOCKED`, PG-style casts). Keeps CI fast and dependency-light. Only 2 of 10 modules have truly incompatible features.
**Trade-offs:** FTS and recursive CTE paths are untested in Spring. Acceptable risk since the same SQL runs in Quarkus tests against the same H2 constraints.
**Sources:** Existing Quarkus test pom.xml (quarkus-jdbc-h2 test scope), H2 MODE=PostgreSQL documentation
**Exploration:** quick
**Status:** captured
