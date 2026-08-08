---
title: "The Decorator the Platform Didn't Have"
date: 2026-08-08
author: Mark Proctor
type: diary
projects: [casehub-platform]
tags: [cdi, rate-limiting, agent-provider, architecture]
---

Every AgentProvider implementation in CaseHub had its own concurrency semaphore. Claude's subprocess manager had one. LangChain4j's adapter had one. The wacky-manor demo app bolted on another on top. Three independent semaphores guarding the same call path, each configured separately, none aware of the others.

The obvious fix — "just extract the semaphore" — misses the deeper problem. Concurrency control is a cross-cutting concern that doesn't belong inside any specific provider. A token bucket for throughput control doesn't either. These are orthogonal to whether you're calling Claude via subprocess, hitting OpenAI through LangChain4j, or running a local model. The right abstraction isn't a shared utility class; it's a transparent wrapper that applies regardless of which backend CDI resolves.

CDI has had `@Decorator` since CDI 1.0. The entire CaseHub platform — over forty modules — had never used one. Every cross-cutting variation used `@Alternative @Priority` instead: the replacement pattern, where one bean wins the priority contest and the others step aside. But rate limiting isn't a replacement. It's a wrapper. The gate module doesn't compete with Claude or LangChain4j — it wraps whichever one wins.

The distinction matters for the dependency graph. A `@Decorator` at `@Priority(APPLICATION)` sits above the alternative-selection mechanism. Adding `casehub-platform-agent-gate` to a classpath activates rate limiting. Removing it deactivates it. No consumer code changes. No provider code changes. The decorator is invisible to both sides.

Two controls compose inside the decorator. A token bucket handles throughput — "how many calls per unit time" — with a fair `ReentrantLock` and `Condition.await()/signal()` for FIFO wakeup without thundering herd. A `Semaphore` handles concurrency — "how many in-flight simultaneously." Token check runs first, concurrency second. If the concurrency gate rejects after a token was consumed, the token is refunded via `release()` — no wasted throughput from callers that never executed. If the delegate itself fails, the token stays consumed. Rate limiting controls the rate of attempts, not the rate of successes.

Claude caught something I'd missed in the design review. The original spec had `invoke()` acquiring the gate eagerly — blocking the calling thread before returning the `Multi`. That breaks the cold-Multi contract documented in the `AgentProvider` Javadoc and would deadlock any caller on the Vert.x event loop. The fix: `Multi.createFrom().deferred()` with `runSubscriptionOn(workerPool)`. Admission is deferred to subscription time; if nobody subscribes, no resources are consumed. A small change that would have been a production bug.

The provider semaphore subsumption uses a trick worth knowing. The gate module ships a `META-INF/microprofile-config.properties` at ordinal 200 that sets both providers' `max-concurrent-sessions` to zero. At ordinal 200 it beats the provider defaults (ordinal 100) but loses to the application's `application.properties` (ordinal 250). The providers accept zero as "create `Semaphore(Integer.MAX_VALUE)`" — an always-permit semaphore that requires zero downstream code changes. One config file, two providers subsumed, and a deployer who needs the old behaviour can override at ordinal 300.

The gate is the first decorator in the platform. Circuit breakers, observability, and cost tracking are all cross-cutting concerns that compose the same way — `@Priority(APPLICATION + N)` determines ordering. The pattern is now documented as a protocol alongside the existing `@DefaultBean` / `@Alternative` / `@Priority` ladder.
