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

## D5: Spring auto-configuration strategy

**Choice:** Each `-spring-jpa` module self-configures via its own `@AutoConfiguration` class + `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`
**Alternatives:**
- Central aggregator module — single config class importing all JPA modules. Tight coupling, harder to use subsets.
**Rationale:** Follows established pattern (platform-spring, callback-spring). Spring Boot auto-discovers each module independently. Consumers add only the modules they need.
**Trade-offs:** None significant — this is standard Spring Boot practice.
**Sources:** platform-spring/PlatformDefaultsManualConfig.java, spring-generator/AutoConfigurationWriter.java
**Exploration:** quick
**Status:** captured

## D6: Scheduled task translation

**Choice:** Independent Spring `@Scheduled` methods in each `-spring-jpa` module. Same retention logic, Spring annotations, `@Value` for config.
**Alternatives:**
- Core-extract retention logic to shared POJO — adds complexity for simple query+delete+log operations
**Rationale:** Retention tasks are 10-20 line methods (query expired rows, delete, log count). Core extraction adds a module and indirection for no reuse benefit. The SQL is slightly different between Spring Data and EntityManager anyway.
**Trade-offs:** Retention logic is duplicated between Quarkus and Spring. Acceptable — it's simple, stable, and changes rarely.
**Sources:** AclRetentionPurge.java, NotificationRetentionScheduler.java, DigestBufferEntity retention in JpaDigestBuffer.java
**Exploration:** quick
**Status:** captured

## D7: CDI Event to Spring Event translation

**Choice:** Spring store implementations use `ApplicationEventPublisher.publishEvent()` with the same event record types from platform-api.
**Alternatives:**
- Core-extract store logic with Consumer<T> callbacks — follows inmem-core pattern but unnecessary for JPA stores
**Rationale:** Event records (NotificationCreated, SubscriptionUpdated, etc.) are already framework-neutral records in platform-api. Spring's ApplicationEventPublisher accepts any object. No translation layer needed.
**Trade-offs:** None — the event types are shared, only the publishing mechanism differs.
**Sources:** notifications-inmem-core/InMemoryNotificationStore.java (Consumer<T> pattern), platform-api event records
**Exploration:** quick
**Status:** captured

## D8: Flyway 12 incompatibility with Spring Boot 3.4 FlywayAutoConfiguration

**Choice:** Disable Flyway in spring-jpa tests (`spring.flyway.enabled=false`) and use Hibernate DDL generation (`spring.jpa.hibernate.ddl-auto=create-drop`) instead.
**Alternatives:**
- Pin Flyway 10.x for spring-jpa modules — version conflict with Quarkus BOM (Flyway 12)
- Exclude flyway-core from spring-jpa test classpath — still needed at compile scope for production
**Rationale:** Flyway 12 (pulled by Quarkus BOM) removed `cleanOnValidationError()` which Spring Boot 3.4's `FlywayAutoConfiguration` calls. Since the entities define the schema fully via JPA annotations, Hibernate DDL generation creates identical tables. Flyway migrations are tested in the Quarkus -jpa module tests. Production Spring Boot deployments will use Flyway 10.x from the Spring Boot BOM (not the Quarkus BOM).
**Trade-offs:** Spring-jpa tests don't exercise Flyway migrations. Acceptable — same migrations are tested in Quarkus.
**Sources:** persistence-spring-jpa test failure, Flyway 12 changelog (cleanOnValidationError removed), Spring Boot 3.4.5 FlywayAutoConfiguration source
**Exploration:** discovered during Task 2 implementation
**Status:** captured

## D9: @DataJpaTest configuration without @SpringBootApplication

**Choice:** Add `@AutoConfigurationPackage`, `@EnableJpaRepositories(basePackageClasses = ...)`, and `@EntityScan(basePackageClasses = ...)` to the test `@Configuration` class.
**Alternatives:**
- Add a test-only `@SpringBootApplication` class — works but creates a confusing package-scanning anchor
**Rationale:** `@DataJpaTest` needs auto-configuration package registration to discover repositories. Without a `@SpringBootApplication` class, the base packages are unknown. The three annotations explicitly declare what to scan — no hidden scanning behaviour.
**Trade-offs:** Slightly more verbose test config. Consistent across all spring-jpa modules.
**Sources:** persistence-spring-jpa test failure (Unable to retrieve @EnableAutoConfiguration base packages)
**Exploration:** discovered during Task 2 implementation
**Status:** captured
