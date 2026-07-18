---
layout: post
title: "The Queue That Wasn't a Queue"
date: 2026-07-18
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [architecture, subject-views, work-queues]
---

Issue #175 asked for a generic queue toolkit. `AbstractQueueEntity`, `AbstractQueueService`, `QueueSubject` — the container model. Items enqueued by name, escalated by moving to a different queue. Straightforward JPA `@MappedSuperclass` work.

I started by investigating casehub-work to understand what queue infrastructure already existed. The first pass missed the point entirely. I saw `work-queues` as a read-model layer — `QueueView` entities, `QueueSnapshot` counts for trend charts, nothing operational. The real queue operations (claim, release, escalate) lived on `WorkItem` itself, with its twelve lifecycle statuses and SLA deadlines. Two different things, I concluded. Move on.

Wrong.

`QueueView` defines a queue by a label pattern: `legal/contracts/**` matches any WorkItem with labels under that path. `QueueMembershipContext` diffs the before/after state on every lifecycle event and fires ADDED, REMOVED, CHANGED. `FilterEvaluationObserver` wires it all together — re-evaluates labels, computes membership, fires events. A queue in casehub-work isn't a container you enqueue into. It's a view that selects items by their metadata.

The ServiceNow model. Your main view has everything. Filtered sub-views show subsets. Setting a label on an item is functionally identical to setting a `queueName` field — the item appears in whatever views match. But labels give you hierarchy for free (`iot/**` shows all IoT items), and an item can appear in multiple views simultaneously.

So the queue toolkit wasn't a queue toolkit. It was a view toolkit — filtered views of any labeled subject, with lifecycle events on entry and exit. The design pivoted completely: labels instead of queue names, pattern matching instead of explicit enqueue, ADDED/REMOVED events instead of container operations.

The interesting problem was the join. Querying "which subjects are in this view?" means joining the subject table with its labels table, matching against the view's pattern. Each backend handles this differently — SQL `JOIN ... WHERE path LIKE` for JPA, `$elemMatch` with `$regex` for MongoDB, iteration for in-memory. The platform can't own the join because it doesn't own the entity.

The solution: JPA Criteria API with Metamodel attributes as constructor parameters. The platform provides `JpaLabelPatternQuerySupport<E, L>` — an abstract class that takes four metamodel attributes (entity class, labels collection, path field, tenancy field) and builds the join query generically. A domain consumer wires four attributes and gets efficient SQL joins:

```java
super(CaseQueueEntry.class,
      CaseQueueEntry_.labels,
      CaseLabel_.path,
      CaseQueueEntry_.tenancyId);
```

The pure-Java membership evaluation (subject's labels × view patterns) stays in `SubjectViewEvaluator` — backend-agnostic, O(views × labels) per mutation. The listing query goes through the SPI with native database queries. Nobody loads subjects into memory to filter in Java when a database index exists.

Three new modules landed: `platform-view` (evaluator), `platform-view-inmem` (ConcurrentHashMap backends), `platform-view-jpa` (Flyway V5000, Criteria API helper). casehub-work-queues continues unchanged — compatibility is designed in, migration is a separate issue.

The thing I keep coming back to: the container model felt natural because that's what most queue systems look like. But the view model is strictly more powerful — hierarchy, multi-membership, pattern matching — and it's what casehub-work already does. The toolkit generalises an existing pattern rather than inventing a parallel one.
