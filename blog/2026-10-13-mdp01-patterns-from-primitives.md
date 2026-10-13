---
title: "Patterns from primitives"
date: 2026-10-13
author: mdp
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [yaml-core, orchestration, event-patterns, design]
series: casehub-platform
refs:
  - "casehubio/platform#600"
  - "casehubio/platform#608"
---

# Patterns from primitives

The playbook language now has composable event sequence matching. Not a CEP engine — that's still Drools — but enough that a playbook author can write `((A then B) or (A then C))*` as nested YAML and have it do what they expect.

The interesting design question wasn't "how do we build a pattern matcher" but "how little do we need to add?" The answer turned out to be two new step types and one new primitive. Everything else composes from what already existed.

## What we added

**ConsumerHandle** — a named primitive in `ExecutionScope` that gives external control over a `from:` consumer. The `from:` decorator checks `handle.isRunning()` before each receive; `pause:` and `resume:` steps flip that flag. Internally it uses `LockSupport.park()/unpark()` — zero CPU while paused, instant resume, clean scope shutdown via interrupt propagation.

We almost called these `stop:` and `start:`, but that implies a hard lifecycle boundary. If you later add `begin:` and `end:` for consumer creation and destruction, "start" becomes ambiguous — does it mean "create" or "resume"? Pause/resume communicates continuity: the consumer is suspended, not destroyed. Same implementation, better naming for future composition.

**RaceStep** — first-to-complete alternation. Launches branches on virtual threads, CAS picks the winner, `future.cancel(true)` interrupts the losers. The pattern is the same one `SelectStep` already uses for channel/signal multiplexing — we just applied it to arbitrary step blocks instead of raw channel reads.

**from: hardening** — the `from:` decorator gained `until:` conditions, channel close detection (`isClosed()` on `OrcChannel`), and named consumer support, all in one pass through the receive loop. The key design insight: when `name:` or `until:` is present, switch from blocking receive to timed receive (100ms polls). This gives us periodic condition checking without a second blocking mechanism.

## What we didn't add

The temporal patterns — timed absence, delayed sequences, heartbeat monitoring — compose entirely from existing decorators. A timed absence is just `from:` inside a `block:` with `timeout:` and `on-error:` on the outer block. The decorator ordering (`from:` at position 4.5, `timeout:` at 5) means `timeout:` wraps `from:`, so the timeout can cancel the blocked receive. No new code — just tests proving the composition works.

The recursive sub-pattern `((A then B) or (A then C))*` doesn't use `race:` at all. Race branches sharing a channel have competing-consumer semantics — each event goes to exactly one branch, which breaks pattern matching. Instead, we use sequential `from:` reads with `match:/cases:` for single-stream alternation. Race is for independent channels where branches wait on separate data sources.

## The audit catch

The audit surfaced a pre-existing gap: `Walker.RESERVED_KEYS` and `StepSchemaComposer.DECORATOR_KEYS` had diverged. Several decorator keys (`from`, `cancel`, `background`, `at`, and others) were in the schema set but not the parser set. This meant decorator-only steps like standalone `- from: { channel: events }` threw "unknown key" at parse time. The fix was straightforward — unify the sets — but the systemic issue (two independent sets that must stay in sync) earned its own issue (#608).
