---
layout: post
title: "Per-Statement Snapshots and the Drain That Eats Its Own"
date: 2026-07-08
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [jpa, postgresql, read-committed, cdi, digest, notifications]
series: issue-158-persistent-digest-buffer
---

The in-memory digest buffer worked fine until I started thinking about what happens when the process restarts mid-digest. Notifications buffered for an hourly email digest just vanish. For most deployments that's acceptable — the in-app notification already went out, the digest is a convenience. But for regulated environments where every external notification must be auditable, "the server restarted and your email summary disappeared" doesn't fly.

The obvious answer is a JPA-backed buffer. One row per notification, JSON payload, drain on schedule. But the CDI wiring forced a structural decision first.

## The extraction nobody asked for

`InMemoryDigestBuffer` lived inside `notification-dispatch/` as bare `@ApplicationScoped`. Adding a second `@ApplicationScoped` implementation in another module creates CDI ambiguity — Quarkus can't choose between them. The `cdi-classpath-presence-requires-module-separation` protocol is explicit about this: the implementation must live in a separate module for classpath-presence activation to work.

So before writing a single line of JPA code, I extracted the in-memory buffer to its own `digest-inmem/` module with `@Alternative @Priority(100)`. Same code, different CDI annotations, different module. The extraction is invisible to consumers — `notification-dispatch/` still depends on the `DigestBuffer` SPI, not on any implementation.

This follows the same pattern as every other store in the platform: `notifications-inmem/`, `notification-settings-inmem/`, `subscriptions-inmem/`. The in-memory buffer was the exception. Now it isn't.

## The drain that eats its own

The design review caught something I would have shipped. Under PostgreSQL READ COMMITTED, each *statement* sees the latest committed snapshot. A naive drain — `SELECT` all rows for a key, then `DELETE WHERE key=?` — has a subtle data-loss race:

1. `SELECT` runs, returns 5 rows (snapshot A)
2. A concurrent `add()` commits a 6th row
3. `DELETE WHERE key=?` takes a fresh snapshot (B), sees all 6 rows, deletes all 6
4. The caller got 5 rows back but 6 were deleted — row 6 is gone, never delivered

The fix is ID-scoped deletion: collect the IDs from the SELECT, then `DELETE WHERE id IN (:ids)`. The DELETE targets exactly the rows the caller saw. A concurrent add gets a different ID and survives for the next drain cycle.

This is the same root cause as GE-20260414-62a6df (double delivery from concurrent reads), but the opposite failure mode. That entry now has a variant documenting the data-loss scenario.

## What landed

Two new modules following the Store SPI pattern: `digest-inmem/` at CDI Tier 4 and `digest-jpa/` at Tier 2. The JPA buffer uses one row per notification with a JSON payload column — the same Jackson serialization pattern as `notification-settings-jpa`. Flyway V2000 claims the next thousand-block in the platform allocation table.

Eviction is configurable via `casehub.notification.digest.max-buffer-size`. The in-memory buffer defaults to 500 (RAM is finite). The JPA buffer defaults to 0 (no eviction) — if you're deploying this module, you want durability, not silent discard.
