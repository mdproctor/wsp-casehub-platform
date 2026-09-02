---
layout: post
title: "Shared Vocabulary for Overload"
date: 2026-09-02
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [capacity, spi, redistribution, platform-api, design]
series: issue-268-capacity-redistribution
---

# Shared Vocabulary for Overload

Three systems in casehub detect actor overload independently. Qhorus measures context window percentage. Engine counts active tasks against a maximum. The agent gate counts concurrent sessions against a semaphore. None of them can see the others' signals, and none of them can do anything about it after the fact — once work is assigned, it stays.

The fix starts with a shared vocabulary. Pressure 0.0 to 1.0, where 1.0 means saturated. Each domain maps from its own units — context window percentage becomes a fraction, task ratio becomes a fraction, session ratio becomes a fraction. The aggregated view takes the max across all signals, because any single saturated dimension means the actor can't take new work regardless of how idle they look on the other dimensions.

## The ActorState question

I spent real time on whether this should fold into the existing `ActorStateContributor` / `ActorStateAccumulator` infrastructure. It already aggregates cross-domain data for actors — trust scores, work items, commitments — and the capacity SPI is fundamentally about actor state too.

The answer is no, but the reason is architectural, not semantic. `ActorStateContributor` is a per-actor push model: you give it an actor ID, it populates an accumulator via typed visitor methods. The capacity SPI needs `observeOverloaded(threshold)` — a fleet-wide scan that returns all actors above a pressure threshold. The contributor pattern literally can't express that query. Different access patterns require different SPIs.

But the two should be connected. I added a `capacity()` default method to `ActorStateAccumulator` and a `CapacityActorStateContributor` that bridges capacity data into the dashboard view. The capacity SPI runs the operational sweep and fires CDI events; the contributor bridges the results into the dashboard for human operators. Separate SPIs, connected via a bridge — same actors, different lenses.

## The call flow

The design review surfaced a question I hadn't made explicit: who builds the `RedistributionContext` that the policy evaluates? The context carries both platform data (pressure) and domain data (open obligation count, time since last activity). Platform can observe pressure but not obligation counts. Domain repos know their obligations but receive pressure via CDI events.

The domain executor is the natural composer. It observes `CapacityPressureEvent`, queries its own state, builds the full context, and calls `RedistributionPolicy.evaluate()`. The concern about multiple domains over-correcting on the same event is real — qhorus moving obligations while engine moves tasks simultaneously — but self-healing. The next sweep sees reduced pressure and doesn't re-trigger. Grace periods provide a coordination window. A centralized coordinator could avoid this, but adds an SPI and a dispatcher for marginal benefit. The simpler design wins for now.

## What the review caught

Claude's design review ran three rounds and found 13 issues worth fixing. Three were high severity: two `@DefaultBean` beans implementing the same SPI in the same module (CDI ambiguity at boot), a dead `NoOpActorCapacityView` that the aggregator unconditionally displaces, and a `>` vs `>=` threshold boundary gap that would make actors at exactly the sweep threshold invisible to the monitor.

The boundary fix had a subtle consequence — changing `isOverloaded()` to `>=` meant the `observeOverloaded()` contract needed explicit documentation that the threshold is an inclusive lower bound. Without that, a source returning `pressure >= threshold` signals and a view filtering with `pressure > threshold` would silently disagree at the boundary. The review's second round caught this contract gap.

## What ships

Nine types in `io.casehub.platform.api.capacity` — the shared vocabulary. Four implementations in `io.casehub.platform.capacity` — aggregation, policy, sweep, and the actor state bridge. The policy is configurable: compress at 0.7, redistribute at 0.85, immediate at 0.95, escalate after 5 minutes of inactivity. All `@DefaultBean` — domain repos override by classpath presence.

Next is qhorus#428 — the signal source that reads existing CONTEXT_PRESSURE watchdog data and the redistribution executor that does the actual HANDOFF delegation. That's where the vocabulary meets reality.
