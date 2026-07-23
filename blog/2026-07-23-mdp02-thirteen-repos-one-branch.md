---
layout: post
title: "Thirteen Repos, One Branch Name"
date: 2026-07-23
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [virtual-threads, reactive, multi-repo, slot]
---

*Part of a series on [#384 — retire reactive tiers](https://github.com/casehubio/parent/issues/384). Previous: [The Reactive Layer That Was Already Dead](2026-07-23-mdp01-reactive-layer-already-dead.md).*

The reactive tier spans thirteen repos. Platform was the proving ground — two dual-stack pairs, a clean cookbook, and the SSE discovery that nobody else would have hit. But platform is one repo. The issue covers platform, qhorus, neocortex, ledger, eidos, connectors, claudony, openclaw, ras, ops, iot, blocks, and desiredstate.

A git worktree slot holds all thirteen checkouts on `issue-384-retire-reactive` simultaneously. One branch name, thirteen repos, each with its own reactive surface. The slot model means no branch-switching, no stale checkouts, no "which repo was I working in." Each repo is a directory in `/worktrees/30/`.

Five repos landed today: platform (merged via PR), plus ras, ops, desiredstate, and iot (PRs opened, awaiting CI). The app repos were small — ras had the real reactive SPIs (SituationStore, Ganglion, GanglionStateStore all returned `Uni<T>`), while ops/desiredstate/iot just consumed those SPIs and adapted to blocking signatures.

The remaining eight vary wildly in scope. Qhorus is the heaviest — fifteen dual-stack pairs, `@IfBuildProperty` gating, reactive Panache repos, and a build-time config flag that controlled the entire reactive/blocking switch. Neocortex has ten pairs plus a full decorator chain (outcome weighting, temporal decay, scope decay, trend enrichment, tracking, reranking, corrective, hybrid, query expanding — each with a reactive mirror). Ledger and eidos consume engine SPIs. Claudony, openclaw, connectors, and blocks implement them.

The cookbook holds. The pattern is identical everywhere: delete the `Reactive*` interface, rewrite the JPA store from Panache Reactive to EntityManager, convert REST from `Uni<T>` to `@RunOnVirtualThread`. What varies is the surface area, not the technique.
