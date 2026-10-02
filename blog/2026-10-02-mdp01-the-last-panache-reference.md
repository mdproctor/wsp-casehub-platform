---
layout: post
title: "The Last Panache Reference"
date: 2026-10-02
entry_type: note
subtype: diary
projects: [casehubio/work]
tags: [jpa, panache, spring, migration, quarkus]
series: issue-403-work-spring-panache
---

# The Last Panache Reference

Panache is Quarkus's active-record layer for JPA — `extends PanacheEntityBase`, call `entity.persist()`, use `Entity.find("field", value)` as static methods on the entity itself. It's convenient and it compiles only against Quarkus. That second part became a problem when the work repo needed Spring Boot deployability.

The issue said 21 entities still extended `PanacheEntityBase`. I expected the fix to be mechanical: swap the superclass, replace static calls with `EntityManager` queries, move on. The entity migration was exactly that. What I didn't expect was the blast radius in test code.

Every `@BeforeEach` cleanup that called `WorkItemTemplate.deleteAll()` or `AuditEntry.deleteAll()` was a Panache static. Every test that called `entity.persist()` directly was an inherited instance method. The production stores had already been migrated to `EntityManager` in the same commit, but the tests were a second front — 26 test files across six modules, each needing `@Inject EntityManager em` and the Panache calls rewritten to JPQL.

One subtle mistake surfaced in the JPQL conversions. The old Panache call was `WorkItemSpawnGroup.find("parentId", value)` — Panache silently prepends `FROM WorkItemSpawnGroup WHERE` and uses the Java field name. The converted query used `workItemId` instead of `parentId`, because the intent was "find by the parent work item" and the column is `work_item_id`. But JPQL resolves against Java field names, not column names, and the field is `parentId`. Hibernate threw `Could not interpret path expression 'workItemId'` — clear enough once you see it, but easy to get wrong when the conversion is done in bulk.

The REST test migration that preceded it had a different texture. The APT code generator had replaced hand-written REST endpoints with generated ones, and the test suite hadn't caught up. 58 tests failing across 18 classes, each for a different reason: wrong paths, wrong status code expectations, response shape changes where the generated API wraps lists in page objects, tests sending JSON bodies where the generated endpoint expects query parameters.

The most interesting fix was the template schema fields. The hand-written endpoint accepted `inputDataSchema` as a raw JSON object — Jackson deserialized it to `JsonNode`, the service called `.toString()` for storage. The generated endpoint used `CreateTemplateRequest` which typed the field as `String`. Sending `{"inputDataSchema": {"type": "object"}}` now failed because Jackson can't deserialize a JSON object into a `String`. The fix was changing the record field to `JsonNode` and adding `.toString()` in the service layer — restoring the original contract while keeping the generated endpoint.

The third issue in the queue turned out to be already resolved. It claimed five REST resources in the `ai/` and `queues/` modules had no Spring controllers. A clean build showed the `graphql-spring-generator` already produces dual output — both GraphQL controllers and REST controllers — from the `@McpDomain` SPI interfaces in the `api/` module. All five were present. The issue predated the generator's dual-output capability.

The Panache Maven dependency is still in seven `pom.xml` files, now dead weight. Zero Java files import from `io.quarkus.hibernate.orm.panache`. Removing the dependency is a separate cleanup — the entities are the hard part, and that's done.
