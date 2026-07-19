---
layout: post
title: "Seven Cuts Before Migration"
date: 2026-07-19
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [architecture, subject-views, work-queues, migration]
---

The subject view toolkit shipped yesterday. Today was about what it still needed before casehub-work could actually use it.

Migration review surfaced seven items, sorted by priority. Two block migration outright: a missing event type and a missing field. Three save every consumer work that would otherwise be duplicated. Two are optimisations that can wait but are cheap to include now.

The must-fixes were straightforward but the naming mattered. The evaluator had a method called `diff()` — it compared before/after view membership maps and returned ADDED/REMOVED events. Adding CHANGED (for "subject mutated while still in the view") broke the name. A diff that returns events for unchanged items isn't computing a diff. `computeEvents()` is what it actually does now: given a before-state and after-state, compute all view events — additions, removals, and changes. The adversarial review caught this. Nine rounds, sixteen issues, $27.74, and the spec was tighter for it.

The orchestrator was the design decision worth making. The domain wiring pattern — inject evaluator, inject store, inject tracker, fetch before-state, fetch views, evaluate, diff, update tracker, fire events — is twelve lines and identical for every consumer. The question was: abstract base class with template methods, or composition-based orchestrator? The abstract class saves the same line count but forces inheritance. The orchestrator is one `@ApplicationScoped` bean that composes the three collaborators. Domain observer: inject it, call `evaluateAndTrack()`, fire your domain events. Five lines.

The orchestrator also became the natural home for two nice-to-haves: a TTL-based view cache (off by default, opt-in via config) and `saveView()`/`deleteView()` methods that invalidate it automatically. No Quarkus cache dependency — plain `ConcurrentHashMap` with `Instant`-based expiry. The design review pushed the invalidation from a public API (`invalidateCache(tenancyId)`) to internal-only, triggered by the orchestrator's own write methods. Cleaner. Domains that manage views through the orchestrator get transparent cache consistency.

The bulk membership tracker method was for the INFERRED label cascade in work-queues. One filter applies a label, triggering another filter, touching dozens of subjects in a single transaction. N individual `getLastKnownMembership()` calls becomes one `WHERE subject_id IN (...)` query. Default method on the SPI loops over the single-subject call — existing implementations work without modification. JPA overrides with the efficient query.

The in-memory query helper rounds out the test story. `JpaLabelPatternQuerySupport` exists for production; `InMemorySubjectViewQuerySupport` is its test-time parallel. Constructor takes a subject source, label extractor, tenancy extractor, and sort field resolver. Domains extend with concrete types. The design review caught the sort parity gap — the JPA helper sorts via Criteria API `orderBy()`; the in-memory version had no sort support at all. Added a `Function<String, Comparator<S>>` that maps sort field names to type-safe comparators.

Seven items. Five modules touched. No new modules, no new dependencies. casehub-work migration can now proceed cleanly.
