---
layout: post
title: "Two ways to launch Claude"
date: 2026-06-03
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [quarkus, mutiny, testing, awaitility, agent, tmux]
---

Four backlog items. Three were paperwork — a groupId typo in a spec, a CLAUDE.md table that didn't mention the agent modules yet, a test that used `Thread.sleep(300)` to paper over a timing race. The fourth was the interesting one.

The `Thread.sleep` problem was in `ClaudeAgentClientTest.semaphore_releasedOnCancellation`. The test cancels a subscription and then tries to run a second session. Between `cancelled.countDown()` (the inner onCancellation handler, in the stream factory) and `semaphore.release()` (the outer onCancellation handler, in `run()`), there's a gap. With `runSubscriptionOn` shifting the subscription to a worker pool, the cancellation propagation isn't synchronous end-to-end. The 300ms sleep had been buying time for the semaphore to catch up. It worked in practice; it would have failed under CI load.

The fix: a package-private `availablePermits()` method on `ClaudeAgentClient` — a test seam that doesn't touch the public API — and Awaitility polling on it directly. `Awaitility.await("outer semaphore release after cancellation").atMost(2, SECONDS).pollInterval(10, MILLISECONDS).until(() -> client.availablePermits() == 1)`. The string label matters: Awaitility 4.3.0 dropped `failMessage()`, so the `await(String)` overload is the only way to get a meaningful timeout message in CI logs. Claude flagged both the coarse default poll interval (100ms) and the missing label during review; both were fixed before the commit landed.

The fourth item was the assessment I'd deferred from platform#55: does `ClaudeAgentProvider` replace or complement Claudony's tmux-based `ClaudonyReactiveWorkerProvisioner`? Reading `ClaudonyReactiveWorkerProvisioner` answered it quickly. The tmux session is named (`claudony-worker-{id}`), registered in `SessionRegistry`, and tracked with `SessionStatus`. That registration drives the Claudony terminal panel. `terminate(workerId)` kills the session externally by name. And there's a `causalContext` map that carries `causedByEntryId` from `provision()` through to the `WorkerStarted` ledger event — the audit chain only works because the session persists long enough for both events to fire.

`ClaudeAgentProvider` does none of this. One `run()` call, one subprocess, done. No session name, no registry, no external termination by ID. That's not a deficiency — that's the design. It's the right tool when the consumer is `casehub-engine` orchestrating a case step: fire the task, get the event stream, move on. The dashboard-visible, persistent, ledger-wired session is Claudony's job, and tmux is load-bearing there.

I filed the finding on the issue and closed it. The protocol went into the garden: `ClaudeAgentProvider` for ephemeral task-scoped invocations, tmux for persistent dashboard-visible sessions. They're complementary.
