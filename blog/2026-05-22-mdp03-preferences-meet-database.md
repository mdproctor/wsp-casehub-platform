---
layout: post
title: "Preferences Meet a Database"
date: 2026-05-22
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [persistence, jpa, preferences]
---

The `persistence-jpa/` module is the first in the platform that actually
writes to a database. Config reads from YAML files. OIDC reads from JWT
claims. Nothing persists state — until now.

The design is straightforward: one table, `platform_preference`, with
columns for scope, namespace, name, sub_key, and value. Scope hierarchy
resolution is a single `IN` query — build the ancestor list from the
`SettingsScope` path, query all rows where `scope IN (ancestors)`, sort
by ancestor list index (shortest first = lowest priority), then merge.
The child scope wins by last-write into a `HashMap`.

The first thing we hit was `effectiveAt`. `SettingsScope` carries an
`Instant` alongside the path. I had to decide: honour it for time-travel
queries, or treat all rows as current? I chose current-only. No caller
passes a non-current time today — they all use `SettingsScope.of(path)`,
which defaults to `Instant.now()`. More importantly, time-travel reads
require a write model that records *when* each value became effective, and
the preferences-editor (issue #8) doesn't exist yet. Adding `effective_from`
to the schema now would be designing around a write path that's still
hypothetical. ADR-0006 records the reasoning.

Then the migration failed with `"expected identifier"`. The column was
named `value` — a reserved keyword in H2, even in `MODE=PostgreSQL`. Not
obvious from the error. We renamed it to `pref_value` and kept moving.
`name` also conflicted with the `@UniqueConstraint.columnNames` annotation,
which needed `"pref_name"` not `"name"` to match the actual column.

The code review caught two things I'd missed. The `@UniqueConstraint`
annotation listed `"name"` instead of `"pref_name"` — a silent metadata
bug that would produce the wrong constraint if schema generation were ever
enabled. And `resolve()` was missing `@Transactional(TxType.SUPPORTS)`.
Without it, calls outside an active transaction fail in production
configurations where `quarkus.hibernate-orm.request-scoped.enabled=false`.
The reviewer was right on both counts.

We also switched from `PanacheEntity` to `PanacheEntityBase` with an
explicit `@SequenceGenerator` binding, rather than relying on Hibernate's
implicit sequence name derivation. It worked in tests without it — but
that was a coincidence, not a contract.

The module is now at `casehub-platform-persistence-jpa`. Consumers add
it as a compile dependency and include `classpath:db/platform/migration`
in their Flyway locations. It displaces the mock automatically.
