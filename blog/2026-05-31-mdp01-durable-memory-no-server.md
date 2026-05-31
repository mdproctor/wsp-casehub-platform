---
layout: post
title: "Durable memory, no server required"
date: 2026-05-31
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [memory, sqlite, hikaricp, fts5, java, quarkus]
---

The CaseHub memory stack had two endpoints: an in-memory `ConcurrentHashMap` for tests and ephemeral deployments, and a PostgreSQL-backed adapter for production. There was nothing in between. If you wanted durable memory without standing up a database server — for a single-process deployment, a local install, a device that doesn't have network access — you had nothing.

SQLite is the obvious answer. It's embedded, file-backed, and durable across restarts. The question was how to integrate it in a Quarkus application without Quarkus actually knowing about it.

## The Quarkus blind spot

Quarkus manages JDBC datasources through Agroal, its built-in connection pool. Agroal is configured at augmentation time — you declare `db-kind=postgresql` and the correct JDBC driver and pool factory are baked in at build time. SQLite is not a supported `db-kind`. There is a Quarkiverse extension (`quarkus-jdbc-sqlite`) that adds the support, but the latest release was built against Quarkus 3.15; we're on 3.32, and the version gap felt like an unknown risk for a module I wanted to stand on its own.

I chose to bypass Agroal entirely. The `memory-sqlite` module manages its own HikariCP `DataSource` — created in `@PostConstruct`, closed in `@PreDestroy`, invisible to Quarkus's datasource machinery. For schema setup, Flyway runs programmatically against that DataSource at startup rather than through `quarkus-flyway`. The consumer configures one property:

```properties
casehub.memory.sqlite.path=/var/data/casehub/memory.db
```

That's it. No datasource block, no Flyway location configuration, no Quarkus extension to install.

## Wiring HikariCP to xerial

The standard HikariCP pattern for configuring an underlying DataSource is `setDataSourceClassName` plus `addDataSourceProperty` calls. Xerial's SQLite JDBC driver ships a `SQLiteConfig` class with type-safe setters for every PRAGMA — journal mode, synchronous writes, busy timeout, cache size. Passing `sqLiteConfig.toProperties()` via `addDataSourceProperty` seems like the natural composition.

It fails at runtime. HikariCP's `PropertyElf` tries to call `setConfig(Properties)` on `SQLiteDataSource` via reflection. There's no such method — there's `setConfig(SQLiteConfig)`, which takes the actual config object, not a property bag. `PropertyElf` can't bridge that gap.

Claude discovered this when the first implementation attempt threw at startup. The fix was to construct `SQLiteDataSource` directly with the pre-configured `SQLiteConfig`, then hand the pre-built instance to HikariCP via `setDataSource()` — bypassing `PropertyElf` entirely:

```java
SQLiteDataSource sqLiteDataSource = new SQLiteDataSource(sqLiteConfig);
sqLiteDataSource.setUrl("jdbc:sqlite:" + path);

HikariConfig hikari = new HikariConfig();
hikari.setDataSource(sqLiteDataSource);
```

Obvious in retrospect, undocumented everywhere we looked at the time.

## The timestamp problem I didn't see coming

SQLite doesn't have a native timestamp type. Dates go in as TEXT. ISO-8601 strings sort lexicographically — `"2026-05-31T10:00:01Z"` is greater than `"2026-05-31T10:00:00Z"` — which makes `ORDER BY created_at DESC` correct for chronological ordering.

Except `java.time.Instant.toString()` emits the minimum fractional-second digits needed: zero digits for whole-second precision, three for millisecond, six for microsecond, nine for nanosecond. A whole-second instant produces a 20-character string ending in `Z`. A millisecond instant from `Instant.now()` produces a 24-character string ending in `.000Z`. In ASCII, `.` (46) is less than `Z` (90). The 24-character value sorts as *less than* the 20-character value. A later instant sorts before an earlier one.

The fix: always store `Instant.now().truncatedTo(ChronoUnit.MILLIS).toString()` — always 24 characters, always sortable, everywhere. Apply the same truncation to `since` filter parameters before binding them.

The contract test for `since` used `Thread.sleep(5)` to guarantee a gap between "old" and the barrier instant, which masked the issue. An external code review caught the discrepancy between `>` (what we'd shipped) and `>=` (what the JPA and in-memory adapters use). The `since` filter should include memories at exactly the barrier timestamp; the string comparison needs the boundary truncated to the same precision as the stored values.

## FTS5 for relevance ranking

The JPA adapter uses PostgreSQL's `websearch_to_tsquery` for full-text relevance ranking when `MemoryOrder.RELEVANCE` and a question string are provided. SQLite has FTS5 as a bundled extension. We used a content table — a virtual FTS5 table backed by the real `memory_entry` table, maintained by three triggers (INSERT, DELETE, UPDATE):

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts
    USING fts5(text, content='memory_entry', content_rowid='rowid');
```

Relevance queries join the virtual table, apply `MATCH` on the question, and sort by `rank` — FTS5's built-in BM25 column. One detail that caused a moment's confusion: `rank` returns negative values. Most relevance systems use positive scores with descending order; FTS5 uses negative scores with ascending order. Getting that backwards returns the least relevant results first with no error.

The adapter strips FTS5 operator characters (`"`, `*`, `^`, `:`, `(`, `)`, `+`, `-`) from the question string before binding — no phrase-wrapping, which would change AND-of-terms to exact-phrase matching and break multi-word questions.

## The `:memory:` special case

SQLite in-memory databases don't support WAL mode. And with a connection pool of more than one connection, each connection gets its own isolated in-memory database — a pool of five connections means five separate databases with no shared state.

When `casehub.memory.sqlite.path=:memory:` is detected at startup, the module skips WAL mode and forces pool size to one. This makes in-memory mode work cleanly in `@QuarkusTest` without any additional test infrastructure — configure the path to `:memory:`, and each test method sees a clean slate after `eraseEntity()` runs in `@AfterEach`.

Four garden entries came out of the work: the HikariCP PropertyElf runtime failure, the ISO-8601 variable-digit ordering problem, the correct HikariCP + SQLiteConfig wiring pattern, and the FTS5 content-table recipe.
