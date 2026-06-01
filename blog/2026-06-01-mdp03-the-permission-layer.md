---
layout: post
title: "The Permission Layer"
date: 2026-06-01
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [acl, security, design]
---

ACL has been the obvious missing piece for a while. The platform has identity, RBAC, and preferences — it knows who an actor is, what groups they belong to, what settings apply to them. It has nothing to say about what data they can see. That gap becomes visible the moment you try to write an admin API that returns cases, work items, or event logs to a caller who shouldn't see all of them.

Before designing anything, I wanted to know what already exists for Quarkus.

The options divided cleanly. Keycloak Authorization Services is the obvious candidate — UMA 2.0, resource-level permissions, a proper Quarkus extension. The blocker is runtime coupling: Keycloak must be live for authorization to work, and casehub-platform can't impose that on consumers. Quarkus's own `@PermissionsAllowed` is method-level enforcement — it protects code entry points, not data objects. The same resource accessible through three code paths needs annotating in three places. Fragile.

The Zanzibar-style options — OpenFGA and SpiceDB — are open source (Apache 2.0, despite what you might assume from their managed services). Active Quarkus extensions exist for both. But both require an external authorization service at runtime, and the platform needs a pure Java embedded default. jCasbin is closer — pure Java, no external service — but it doesn't solve the problem I actually have. The question that settled it: "show me all cases this actor can access." jCasbin has no answer to that. You write that SQL regardless of whether jCasbin is present, and the evaluation logic it saves is roughly thirty lines of Java. Custom flat JPA following the existing platform module pattern.

Next question: enforcement model. `@PermissionsAllowed` style is about protecting methods. What I need is ACL on data — the permission is a property of the data object itself, not of the code path that retrieves it. Any code that touches a case faces the same question: can this actor see it?

After that, I brought Claude in to work through the two main structural options. Explicit ACL entries at every level gives you clean list queries — one join on the ACL table. But the engine creates plan items dynamically during case execution. Every creation event pumps ACL rows. Revocation cascades across every child. For a system that's inherently dynamic, that accumulates fast.

Implicit inheritance puts entries at the case level. Children derive access from their parent. Write path is minimal — one entry when the case is created, automatic revocation when it's removed. The list query carries more complexity, and the ACL layer needs to know the parent relationship. But for a case management platform where the hierarchy is created at runtime, the write-path cost of explicit-at-every-level is the real risk.

To answer how deep the hierarchy goes, Claude reviewed the engine entities directly. The finding was more interesting than expected. `CaseInstanceEntity` has `parentCaseId` and `parentPlanItemId` — sub-cases are themselves `CaseInstance` rows. The hierarchy is recursive and unbounded. But every other entity — `PlanItem`, `EventLog`, `CaseLedgerEntry` — carries `caseId` directly. Everything traces to a case in one hop. The case is the natural ACL boundary.

The other finding: `tenancyId` is already on every entity in the engine. Multi-tenancy isn't an ACL concern — it's a data layer filter that was already in the schema. ACL operates within already-tenancy-filtered data. The two layers compose without needing to know about each other.

Late in the session, quarkus-flow and drools workers came up. They're landing within 24 hours. Workers are provisioned to specific cases — provisioning is itself an authorization act. A worker assigned to case A should be able to read and write that case while it's running, and not see case B. Time-bounded grants written at provisioning time and revoked at completion. That shapes the ACL table schema: an `expires_at` column, nullable for permanent grants, non-null for worker grants.

That was enough to pause implementation. The worker use cases will answer whether provisioning should automatically write ACL entries, what identity workers carry, and how sub-case access works for workers. Designing around those questions speculatively would mean rework within 24 hours.

The session output is `docs/specs/2026-06-01-acl-design.md` — the full decision record, open questions catalogued, ready to continue once the workers land.
