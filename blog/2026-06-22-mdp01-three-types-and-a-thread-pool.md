---
layout: post
title: "Three types and a thread pool — execution governance lands on platform"
date: 2026-06-22
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [governance, threading, retry, timeout, quarkus, cdi]
---

Platform#104 was started on 19 June, code-reviewed, fixed, and then orphaned — the branch
never made it to main before the session ended. Wrapped it today.

What it adds is small and deliberate: `ExecutionPolicy`, `RetryPolicy`, and `BackoffStrategy`
in `platform-api`, plus a `PolicyEnforcer` interface and `DefaultPolicyEnforcer` in a new
`governance/` submodule. The enforcer handles retry, timeout, and backoff for any blocking
`Supplier<T>` — one place to configure execution resilience rather than ad-hoc try/catch loops
scattered across worker implementations.

The code review caught one real issue. The original `executeWithTimeout` created a new
`Executors.newSingleThreadExecutor()` on every call. In an `@ApplicationScoped` bean, that
leaks a thread pool per invocation — nothing shuts them down, and under load the JVM
accumulates thread pools indefinitely. The fix: share a single
`Executors.newVirtualThreadPerTaskExecutor()` at the bean level with `@PreDestroy shutdown()`.
Virtual threads are the right call here — they're cheap and don't hold OS threads idle.

The blocking-only constraint (must not be called from Vert.x event-loop threads) is
documented at the class level and left to callers to honour. That's the right contract:
the enforcer does timeout enforcement by submitting to a thread pool, which is inherently
blocking, and the engine's worker execution already runs on worker threads. No additional
scaffolding needed.

Engine#543 is the immediate consumer — it migrates to casehub-worker-api which depends on
these types. Until this lands and publishes, CI can't resolve the chain.
