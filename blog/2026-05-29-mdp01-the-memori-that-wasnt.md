---
layout: post
title: "The Memori That Wasn't"
date: 2026-05-29
type: pivot
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [memory, jpa, quarkus, spi, gdpr]
---

The branch opened with a clear goal: build a REST client adapter for Memori, the
SQL-native AI memory engine. Tier 1 of the `CaseMemoryStore` adapter ladder. By the
time we were done, there was no Memori REST adapter. There were two others.

## What I Thought Memori Was

The research spec described Memori as self-hosted, SQL-native, Postgres-backed,
Apache 2.0, LoCoMo 81.95%. The "zero extra infra" case was compelling: if you already
run PostgreSQL, Memori uses it — no new database to manage.

Before writing a line of code I went to verify the API. Memori's dedicated REST API is
on the roadmap, not shipped. The BYODB option — self-hosted, using your own Postgres —
requires a running Python service alongside your JVM application. That's not zero extra
infra for a Quarkus deployment. It's a Python sidecar.

The REST client had nothing stable to target, and the "zero infra" premise was wrong.

## A Design Smell in the SPI

Before pivoting, Claude and I did the architectural review and hit something worth naming.

The original `EraseRequest` had `domain` as a nullable field — null meant "erase across
ALL domains" for GDPR Art.17. Compact, but when you're building a backend adapter,
null-domain erase and domain-scoped erase are completely different API calls. There's no
clean way to implement both through one method when your backend uses `domain` as part
of the namespace key. We'd have to track which domains an entity has ever used, which
requires state the adapter doesn't have.

The right shape is two methods: `erase(EraseRequest)` for operational domain-scoped
deletion — domain required — and `eraseEntity(String entityId, String tenantId)` for
GDPR cross-entity wipe. The null-domain pattern was encoding a semantic distinction as
a nullable field on a record. We broke it out.

`EraseRequest.domain` is now required — a compile error if you construct one without it.
`eraseEntity()` is a new `default throw` on `CaseMemoryStore`, consistent with the
existing `eraseById()` pattern. The SPI has no external consumer implementations yet,
so the blast radius was exactly the three classes that implement it in this repo.

## Two Adapters Instead of One

**`memory-inmem/`** — pure Java, `ConcurrentHashMap` keyed by a typed
`BucketKey(tenantId, entityId, domain)` record. Volatile: data lives and dies with the
JVM. Used for `@QuarkusTest` isolation and ephemeral installs. Constructor injection
makes the tests completely framework-free — no CDI container, plain JUnit 5.

**`memory-jpa/`** — JPA/Panache, Flyway V1000 in `classpath:db/memory/migration`,
PostgreSQL with FTS via `websearch_to_tsquery` when a question is provided, chronological
otherwise. The FTS language is configurable (`casehub.memory.jpa.fts.language=english`).
H2 in tests with FTS disabled — H2 doesn't support `to_tsvector`.

Tenant isolation is structural in both. Every JPA query includes `WHERE tenant_id = :tenantId`
as a non-optional predicate. `MemoryPermissions.assertTenant()` fires before any backend
call. `eraseById()` also includes `AND tenant_id = :t` in the SQL — even if you know a
memory UUID, you can't delete another tenant's record.

`em.clear()` after every bulk `DELETE`. The JPA spec says bulk DML leaves the first-level
cache indeterminate. Tests would pass without it, but they'd be testing cached state, not
database state.

## Three Things H2 Got Wrong

Building against H2 in PostgreSQL mode surfaces the edges of that mode.

`TIMESTAMPTZ` isn't recognised — use `TIMESTAMP WITH TIME ZONE`.
`quarkus.flyway.migrate-at-start` defaults to false, which means Flyway starts but
doesn't run; the schema never exists. And `@jakarta.transaction.Transactional` on a
`@QuarkusTest` method commits — data leaks between tests. Quarkus ships
`@io.quarkus.test.TestTransaction` specifically for this, which always rolls back.

None of these are in the documentation you find first.

## What's Next in the Ladder

The Memori REST adapter isn't dead — it's waiting. When their API stabilises and ships
a Java-accessible self-hosted option, `memory-memori/` gets built using the mapping we
worked out: `namespace → tenantId`, `entity_id → entityId`, `process_id → domain.name()`.
The vector and temporal tiers (Mem0, Graphiti) follow the same CDI priority ladder as
what's here — drop in the dep, it displaces what's below it.
