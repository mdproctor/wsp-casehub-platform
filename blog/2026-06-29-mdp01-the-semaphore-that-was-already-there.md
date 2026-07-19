---
layout: post
title: "The Semaphore That Was Already There"
date: 2026-06-29
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [concurrency, agent-langchain4j, backpressure]
---

## The Semaphore That Was Already There

`ClaudeAgentProvider` has had a concurrency limiter since day one — a `Semaphore(maxConcurrentSessions)` that gates every `invoke()` and `openSession()` call. `ChatModelAgentProvider` had nothing. Every call went straight to the underlying ChatModel without throttling.

This didn't matter much when calls were blocking: one request, one response, connection freed. With the streaming upgrade, each call holds an HTTP connection for the entire token generation — potentially minutes for large responses. Unbounded concurrency on that path exhausts connection pools and racks up API costs.

The fix was obvious: mirror the Claude pattern. `tryAcquire()` at entry, `AgentSessionLimitException` if at capacity, three-path release (completion, failure, cancellation) to prevent permit leaks. Config property `max-concurrent-sessions`, default 10 (vs Claude's 4 — LangChain4j wraps generic models where backend capacity varies).

The interesting part was what the adversarial design review surfaced. I'd originally spec'd session query failure as transitioning to CLOSED with a semaphore release — copying Claude exactly. The reviewer caught the assumption: Claude closes on failure because a subprocess failure means the process is dead. ChatModel wraps stateless HTTP APIs where failures are transient — rate limits, network blips, model timeouts. None invalidate the session's `ChatMemory` or the underlying `ChatModel` bean. The correct behaviour is failure → IDLE, keeping the session open for retry.

The review also caught that my spec didn't acknowledge the issue's original request for timeout-based acquisition (`tryAcquire(timeout, unit)`). We chose fail-fast deliberately — on Vert.x, blocking a thread for permit acquisition is unacceptable on the event loop. But the spec should have said so explicitly rather than silently diverging from the issue. Five rounds, fourteen verified fixes, and the spec was tight enough to implement mechanically.

The `close()` double-release guard was another catch. The original spec said "idempotent — only if not already CLOSED" but didn't specify the mechanism. `state.set(State.CLOSED)` can't prevent a second `close()` from releasing the semaphore again. `getAndSet(State.CLOSED)` with a conditional check on the previous value does.

Three production files changed, fifteen new tests. The semaphore stays within `ChatModelAgentProvider` and `ChatModelAgentSession` — no leakage into `AgentEventBridge`, `AgentProviderChatModel`, or SPIs. The implementation is small because the design review already resolved every edge case before code was written.
