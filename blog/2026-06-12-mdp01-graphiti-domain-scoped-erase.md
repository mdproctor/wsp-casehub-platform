---
layout: post
title: "Teaching Graphiti to Forget by Domain"
date: 2026-06-12
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [graphiti, memory, gdpr, spi]
---

The adapter's `erase()` has thrown `MemoryCapabilityException` since the day it was written. Graphiti's REST server offers one deletion primitive: `DELETE /group/{group_id}`, which cascades everything for a group — episodes, extracted entities, relationship facts. Domain and caseId were metadata carried in `source_description` (`"domain=investigation;caseId=case-99"`), invisible to the deletion layer. You couldn't delete a domain slice without deleting the entire entity.

The fix is the group_id scheme. We changed it from `{tenantId}::{entityId}` to `{tenantId}::{entityId}::{domain}`. Domain is the right partitioning key for a knowledge graph — entity relationships span cases within a domain, which is exactly what Graphiti extracts via LLM. CaseId is a filter, not a partition. Partitioning at caseId level would sever those cross-case relationships.

With domain encoded in the group_id, `erase()` gets two branches. When `caseId` is null (domain-level), it calls `eraseGroup()` — a pre-fetch of episode count, then `DELETE /group`. The deletion cascades completely; the count is for GDPR Art.5(2) audit logging. When `caseId` is non-null, it fetches episodes via `getEpisodesOrEmpty()`, filters by the `caseId=X` segment in `source_description`, and issues `DELETE /episode/{uuid}` per match. This second path is best-effort — `DELETE /episode` removes the EpisodicNode but leaves LLM-extracted entity and relationship facts intact, per a known upstream issue. For strict GDPR Art.17 compliance at case granularity, the domain-level path is the right one.

There's a subtle split between two private helpers. `eraseGroup()` wraps both its REST calls in a single catch: a 404 from either means the group doesn't exist, erasure is trivially satisfied, return 0. But `getEpisodesOrEmpty()`, used in Branch 2, can't have that combined catch — if it absorbed a 404 and returned an empty list, there'd be no way to distinguish "group doesn't exist" from "group exists with zero matching episodes." The difference matters because Branch 2 never calls `deleteGroup`; it only deletes individual episodes.

`eraseEntity()` needed rethinking too. Graphiti has no group listing endpoint, so there's no way to enumerate all domain groups for an entity without help from outside the graph. The answer is a deployment config: `casehub.memory.graphiti.known-domains`, a comma-separated list of domain names. When set, `eraseEntity()` iterates `DELETE /group` per domain, with `eraseGroup()`'s 404 handling treating any domain the entity never wrote to as a no-op. When absent, the operation throws `MemoryCapabilityException` — the capability is only declared when the config is present.

One thing that bit us during testing: you can't mix `@ConfigProperty` with `@ConfigMapping` on the same prefix in Quarkus. `GraphitiConfig` already owned `casehub.memory.graphiti.*`, so adding `@ConfigProperty(name = "casehub.memory.graphiti.known-domains")` to `GraphitiCaseMemoryStore` caused `SRCFG00014` at startup. SmallRye strict validation treats the prefix as exclusively owned by the mapping interface — any key under it that isn't declared as a method is rejected, regardless of what other beans want to inject. The fix was to add `knownDomains()` to `GraphitiConfig` with `@WithName("known-domains")`, which is also the cleaner design.

We also changed `CaseMemoryStore.erase()` from `void` to `int`. `eraseEntity()` already returns a count for audit logging; `erase()` has the same rationale. The SPI break touches nine adapters, but the change in each is mechanical — either capture `executeUpdate()`, count with an `AtomicInteger`, or pre-list before delete.

The group_id change is a silent migration break — existing data under the old 2-segment format is unreachable after deployment. For this project that's acceptable; for anyone else, it's worth knowing before upgrading.
