---
layout: post
title: "Multi-Turn Arrives"
date: 2026-06-16
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [agent-session, multi-turn, concurrency, mutiny, claude-sdk]
---

The multi-turn agent API has been sitting in the backlog since the single-shot `AgentProvider.invoke()` shipped in June. Platform#58 was the explicit "finish this later" — the spec said multi-turn was deferred because no use case required it yet. This session shipped it.

The spec went through seven rounds of review before a line of code was written. The concurrency model is non-trivial enough that each round surfaced something real: semaphore leaks, JMM ordering violations, the wrong failure mode for timeouts. None of them were obvious in the first draft.

The most interesting one: when a wall-clock timeout fires and calls `sdkClient.close()`, the active turn's stream doesn't fail — it *completes*. `DefaultClaudeAsyncClient.cleanup()` calls `turnSink.tryEmitComplete()`, not `tryEmitError()`. The SDK's design is to drain cleanly rather than propagate teardown as an application error. Reasonable on its own, but invisible to any caller trying to detect timeouts via `onFailure`. The fix: wrap the stream in an `onCompletion().call()` that checks a per-turn `timedOut` flag and converts the completion to `AgentTimeoutException` before the termination handlers fire. The subscriber then sees a failure with the right type regardless of whether the transport IOException raced ahead of `tryEmitComplete()`.

The other non-obvious piece: writing `currentTurnFuture` to a volatile field BEFORE the `AtomicReference` CAS. `close()` reads the future after its own `getAndSet(CLOSED)` — and the CAS in `close()` synchronizes-with the CAS in `query()`, which in turn happens-after the volatile write. No extra lock needed. The JMM chain is exact: Thread A writes volatile → Thread A CAS → Thread B CAS (observes Thread A's) → Thread B reads volatile. Reverse the write and the CAS and the chain breaks, `close()` reads null, drain window silently disappears.

The state machine ended up clean: IDLE → ACTIVE (one turn in flight) → IDLE (turn done) → CLOSED (error or cancellation or explicit close). The session is serial — `query()` throws if ACTIVE. Cancellation is terminal: the subprocess connection is torn down, there's no clean way to resume conversation context. `interrupt()` is the alternative for "stop the current turn but keep the session" — a fire-and-forget signal to the CLI that may or may not cause a `ResultMessage` to arrive.

There's one known gap: `AgentTimeoutException` is not deterministic in which code path fires. When the timeout fires, the stream usually completes (via `tryEmitComplete()`) rather than errors, and the converter fires. But if the transport closes with an `IOException` before `tryEmitComplete()` runs, the original error path fires instead, goes through `onFailure().transform()`, and still produces `AgentTimeoutException`. Both paths end in CLOSED, semaphore released. The subscriber sees an exception either way. The non-determinism is in which code path, not in the outcome.

Platform#100 (the `ChatModel` adapter backed by `AgentSession`) is next. The session API is in place; that's the dependency it was blocked on.
