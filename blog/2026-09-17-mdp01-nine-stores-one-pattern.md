---
layout: post
title: "Nine Stores, One Pattern"
date: 2026-09-17
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [spring, jpa, dual-framework, persistence]
---

# Nine Stores, One Pattern

The platform has ten JPA persistence modules. Each one implements an SPI — PreferenceStore, NotificationStore, AccessControlProvider, and so on — using plain EntityManager under Quarkus Hibernate ORM. Spring deployments need the same data access, but Spring Data JPA is a different programming model: repository interfaces with derived queries, `@Modifying` annotations, `ApplicationEventPublisher` instead of CDI events.

I wanted to avoid the obvious approach of just wrapping EntityManager in a Spring `@Service` — it works, but you're fighting the framework instead of using it. The question was whether nine different stores, each with its own quirks (cursor pagination, deny cascades, JSON column serialization, pessimistic locking), could share a single structural pattern without that pattern being so generic it's useless.

## The three-tier split

The answer turned out to be extracting entities first. Every entity class in the existing `-jpa` modules already used pure `jakarta.persistence` annotations — no Quarkus imports, no CDI. We moved them into `-jpa-common` modules: same Java package, different Maven artifact, zero framework dependencies. Both the Quarkus `-jpa` module and the new Spring `-spring-jpa` module depend on the common one. Flyway SQL moves with the entities.

This sounds mechanical, and it mostly was — until the visibility issue. The entity conversion methods (`fromInput()`, `toNotification()`, `toSubscription()`) were package-private. Fine when the store lives in the same package. Not fine when the Spring store lives in `io.casehub.platform.notification.spring.jpa` and the entity lives in `io.casehub.platform.notification.jpa`. Widening them to public across four entity modules was the kind of thing that feels wrong until you realise the alternative is duplicating the conversion logic.

## The pattern that emerged

Every Spring store module ended up with the same shape: a `JpaRepository` interface with derived queries (plus `@Query` for anything non-trivial), a store class implementing the SPI, an `@AutoConfiguration` with `@ConditionalOnMissingBean`, and a test using `@DataJpaTest` with H2 in PostgreSQL mode.

The interesting constraint was Flyway. The Quarkus BOM pulls Flyway 12, which removed `cleanOnValidationError()`. Spring Boot 3.4's FlywayAutoConfiguration still calls it. The two BOMs are in the same Maven reactor, so Flyway 12 wins — and Spring's auto-config crashes with a `NoSuchMethodError`. The fix is disabling Flyway in tests entirely and letting Hibernate generate the schema from entity annotations. The same migrations are verified by the Quarkus tests; the Spring tests verify the store logic, not the schema.

The other gotcha was `@DataJpaTest` in a library module. Without a `@SpringBootApplication` class, Spring can't discover repository base packages. Three annotations on the test config solve it — `@AutoConfigurationPackage`, `@EnableJpaRepositories`, `@EntityScan` — but the error message ("Unable to retrieve @EnableAutoConfiguration base packages") gives no hint that those are the fix.

## Where complexity lives

Most stores are straightforward CRUD. The interesting ones are the ACL provider (460 lines of deny cascade, parent chain traversal with depth guard, group expansion via GroupMembershipProvider, and a recursive CTE that only works on PostgreSQL) and the delivery-tracking store (pessimistic write locking with `SKIP LOCKED` for claim-based retry processing).

The ACL's `accessibleResourcesIncludingInherited` falls back to the non-inherited query in the Spring implementation — the recursive CTE is PostgreSQL-only and H2 can't run it. This is a known gap, documented and disabled in tests. The Quarkus implementation covers it.

Cursor pagination had a subtler issue. Claude caught that the notifications store was dropping status and category filters on the second page — the cursor query included the keyset condition but not the original WHERE clauses. The Quarkus counterpart builds its JPQL dynamically, so all conditions are always present. The Spring version needed separate repository methods for each filter combination with cursor, which is verbose but correct.

## What this means

Nine Spring Data JPA modules, sharing entities with nine existing Quarkus modules via ten jpa-common intermediaries. Each Spring module auto-configures via `@ConditionalOnMissingBean` on the SPI type, so a Spring Boot application gets the JPA implementation by adding the dependency — same classpath-presence activation as the Quarkus `@DefaultBean` pattern. The one missing store — memory — depends on a cross-repo SPI and will follow separately.

The dual-framework pattern is now proven at scale across the full persistence surface. The next gap is the REST layer: 38 controllers across two repos that need Spring MVC equivalents.
