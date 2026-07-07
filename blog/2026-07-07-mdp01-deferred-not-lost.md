---
layout: post
title: "Deferred, Not Lost"
date: 2026-07-07
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [notification, architecture, suppression]
series: issue-157-notification-s-xs-batch
---

*Part of a series on [#147 — notification system](https://github.com/casehubio/platform/issues/147). Previous: [Digest and Batching](2026-07-06-mdp03-digest-batching.md).*

## The batch that became a principle

I started this session planning to knock out six small issues — code review findings, a couple of enum additions, a REST endpoint. Cleanup work. The kind of thing you batch because individually they're not worth a branch.

The interesting part wasn't the code review fixes. Redundant null checks, missing Javadoc, a test named for the wrong path — mechanical. The MethodHandle cache in `TemplateResolver` was a known optimisation waiting to happen. The JPA query that filtered expired mute rules in Java instead of SQL — obvious once you look at it.

What made the session worth writing about was how two of the "small" issues intersected into an architectural decision that I think will matter.

## Store-authoritative expiry

`SuppressionEvaluator` had been checking mute expiry in three places: the in-memory store filtered on read, the JPA store filtered in Java after the query, and then the evaluator re-filtered the result. Three `Instant.now()` calls, three slightly different instants, the same expiry logic duplicated at every layer.

The fix was to pick one authority. The store owns expiry — it evicts or filters expired rules at query time. The evaluator trusts what it receives. `checkMuted` drops its expiry guard entirely. One authority, one `now`, no redundant work.

This matters beyond the immediate fix because it sets the precedent for how time-sensitive data flows through the dispatch pipeline. Every component that consumes pre-fetched data should trust its source, not re-verify. The `Instant now` parameter threaded through `evaluate()` and `evaluateUserLevel()` makes the single-instant contract explicit and testable.

## Deferred, not lost

Issue #162 asked for quiet hours to buffer notifications for digest instead of dropping them. The original issue scoped this to channels with an existing digest schedule. But when I traced the actual dispatch flow, the question sharpened: should any notification ever be silently dropped during quiet hours?

Muting drops — that's explicit user intent. But quiet hours means "don't disturb me during these hours," not "I don't care about these." The distinction matters: a user who sets quiet hours and then never sees their overnight URGENT notifications has a data loss bug that looks like a feature.

The design review pushed this further. Claude caught that the spec had no mechanism to actually deliver deferred notifications after quiet hours ended — they'd sit in the digest buffer until the next scheduled flush, which could be hours later. The fix was a `quietHoursDeferredKeys` tracking set in `DigestFlushScheduler`: when quiet hours end, the next tick flushes immediately regardless of the normal digest schedule.

The guard chain ended up with a deliberate ordering: quiet hours check first (pure time comparison, no DB hit), then schedule gate (deferred overrides normal schedule), then snooze check (DB hit only when a flush would actually happen). The ordering preserves the performance characteristic — one DB query per flush, not sixty queries per hour from every tick.

## EntityWatcherProvider

The fourth target type — `ENTITY_WATCHERS` — is an SPI with a `NoOpEntityWatcherProvider @DefaultBean` that logs a WARN per invocation. The platform defines the contract; application repos provide the tracking. Who is watching which case, which project, which work item — that's domain logic. The platform just needs to expand the target set.

The `target.id()` semantics for `ENTITY_WATCHERS` use a blank-string convention — blank means "use the template's entity type." This avoids making `id()` nullable (which would weaken the contract for USER, GROUP, and EVENT_FIELD where it's required) without adding a field that only one target type uses.

The principle that emerged from this batch — "deferred, not lost" — feels like it has further to run. Snooze currently drops external notifications too. The same argument applies: snooze means "don't disturb me now," not "lose these." That's a separate issue, but the infrastructure is in place.
