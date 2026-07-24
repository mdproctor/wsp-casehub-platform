---
layout: post
title: "Twelve Out of Thirteen"
date: 2026-07-24
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [virtual-threads, reactive, multi-repo, neocortex, architecture]
series: issue-384-retire-reactive
---

*Part of a series on [#384 — retire reactive tiers](https://github.com/casehubio/parent/issues/384). Previous: [Thirteen Repos, One Branch Name](2026-07-23-mdp02-thirteen-repos-one-branch.md).*

The issue audit said eight repos still needed work. Four of them — connectors, claudony, openclaw, blocks — turned out to have zero reactive code. The audit was stale. The reactive SPIs they supposedly implemented had never been added, or had been cleaned up somewhere between the audit and today.

Engine #381 delivered overnight, which unblocked ledger, eidos, and the rest. With the engine's reactive SPIs gone from the local Maven cache, every downstream repo could proceed.

Ledger, eidos, and qhorus followed the cookbook exactly. Delete the `Reactive*` interfaces, delete the InMemory wrappers, delete the JPA reactive stores, delete the Panache repos, delete the bridges, delete the build-time config gating, clean the POMs, clean the properties. The blocking implementations were self-contained — they owned the logic, the reactive variants just delegated. Qhorus was the heaviest: fourteen API SPIs, eleven InMemory stores, seven JPA stores, ten Panache repos, the full service layer, MCP tools, REST endpoints, ledger classes, and a dashboard service that needed rewriting from reactive to blocking.

Then neocortex broke the pattern.

Every other casehub repo has blocking as primary and reactive as wrapper. Neocortex is reversed. The reactive implementations — `ReactiveQdrantCbrCaseMemoryStore`, `ReactiveMem0CaseMemoryStore`, `ReactiveGraphitiCaseMemoryStore` — are the real code. They talk to external services via REST clients and gRPC futures. The blocking classes are thin shells that call `.await().indefinitely()` on the reactive results.

I followed the cookbook mechanically: deleted all sixty-five reactive files, expected the blocking path to remain intact. It didn't. The blocking implementations referenced the deleted reactive delegates. The build broke everywhere the blocking wrapper tried to inject its now-absent reactive counterpart.

The fix isn't deletion — it's conversion. Each reactive implementation needs to become the blocking implementation: rename, change `Uni<T>` to `T`, create blocking REST client interfaces where the reactive ones returned `Uni`. The thin blocking wrappers get discarded, replaced by the converted reactive code that was always doing the actual work.

The cookbook was right twelve out of thirteen times. The thirteenth requires checking which direction the delegation flows before deleting anything.
