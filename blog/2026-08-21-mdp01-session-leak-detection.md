---
layout: post
title: "Leaking Semaphore Slots: Anatomy of a Session Leak"
date: 2026-08-21
entry_type: article
subtype: diary
projects: [casehub-platform]
tags: [agent-gate, concurrency, cdi, leak-detection, semaphore]
---

A `GatedAgentSession` holds a `Semaphore` permit for the duration of its lifecycle. The caller opens a session, runs queries against it, and closes it — at which point the permit returns to the pool. Standard `AutoCloseable` contract, standard try-with-resources discipline.

The problem is what happens when the caller doesn't close it.

## Three Things Leak at Once

An unclosed session is not one leak — it's three. The semaphore permit is the most visible: with a concurrency limit of five, one leaked session means only four can run. Leak enough and the system stops accepting new sessions entirely. But the registry entry (a strong reference to the session object) prevents garbage collection of the delegate — which may hold subprocess handles, network connections, or other resources from the underlying `AgentProvider` implementation. The leak is a resource, a reference, and whatever the delegate was holding.

The `AgentSession` javadoc warns about this explicitly: *"Sessions not closed leak a semaphore slot permanently."* But a warning in a javadoc is documentation, not enforcement. The question is what to do when callers ignore it.

## Detection: A Registry and a Reaper

The detection mechanism has two parts. `SessionRegistry` is an `@ApplicationScoped` bean that tracks every open `GatedAgentSession` with a monotonically increasing ID and a creation timestamp. Registration happens in `GatedAgentProvider.openSession()` immediately after the session is constructed. Deregistration happens in `GatedAgentSession.close()`, in the `finally` block.

`SessionLeakReaper` is a `@Scheduled` bean that scans the registry at a configurable interval (default: every 60 seconds). It takes a snapshot of the registry — `Map.copyOf()` to avoid concurrent modification — and checks each entry's age against three thresholds:

```java
if (held.compareTo(maxRegistryAge) > 0) {
    entry.session().close(FORCE_CLOSE_TIMEOUT);
    // ...
} else if (forceCloseEnabled && held.compareTo(forceCloseThreshold) > 0) {
    entry.session().close(FORCE_CLOSE_TIMEOUT);
    // ...
} else if (held.compareTo(warnThreshold) > 0) {
    LOG.warning("Leaked GatedAgentSession detected: sessionId=...");
}
```

The escalation ladder: warn at 5 minutes (default), force-close at 30 minutes (disabled by default), evict at 24 hours. Each tier does more than the last: warn logs, force-close recovers the semaphore, eviction is the unconditional backstop that closes regardless of the `forceCloseEnabled` flag.

## The Double-Release Problem

Force-close introduces a race. The reaper takes a snapshot, iterates it, and calls `close()` on a leaked session. But between snapshot and iteration, the legitimate caller might close the session normally. Both callers hit `close()`. Both hit the `finally` block. Both call `Semaphore.release()`.

`Semaphore.release()` doesn't check whether the caller holds a permit. It just increments. Two releases on one acquisition means the semaphore now has more permits than it was configured with — concurrency control is permanently inflated beyond the intended maximum. The reaper designed to fix leaks would create a worse problem than the leak itself.

The fix is an `AtomicBoolean` close guard:

```java
private final AtomicBoolean closed = new AtomicBoolean(false);

public void close(Duration maxWait) {
    if (!closed.compareAndSet(false, true)) {
        return;
    }
    try {
        delegate.close(maxWait);
    } finally {
        registry.deregister(sessionId);
        GatedAgentProvider.releaseAll(sessionStrategies);
    }
}
```

Only the first caller through the CAS gate executes the close. The second gets a no-op. This also protects `query()` — if the reaper closes a session while the caller still holds a reference, `query()` checks the flag and returns a failure immediately rather than forwarding to a closed delegate that would produce confusing errors.

## Configuration Validation

The three thresholds form an invariant: `warnThreshold ≤ forceCloseThreshold ≤ maxRegistryAge`. Without validation, an operator could configure `maxRegistryAge=10m` and `forceCloseThreshold=30m` — sessions would be evicted before force-close ever fires. The constructor validates at startup and fails fast with a clear error. This caught a real misconfiguration possibility that would have silently defeated the escalation ladder.

## Why a CDI Bean, Not a Field

`GatedAgentProvider` is a `@Decorator`. CDI decorators can't be injected into other beans — they exist to wrap a delegate, not to expose services. The reaper needs access to the session registry, so the registry has to be a standalone `@ApplicationScoped` bean that both the decorator and the reaper can inject independently. The decorator registers sessions on creation; the reaper scans them periodically. Neither knows about the other's lifecycle.

The whole mechanism is a safety net. Try-with-resources remains the correct way to manage sessions. But for the cases where a caller forgets — or where an exception path skips the close — the reaper ensures the damage is bounded rather than permanent.
