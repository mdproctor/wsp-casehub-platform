---
layout: post
title: "Remote control for temporal simulation"
date: 2026-09-20
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [simulation, temporal, graphql, mcp, pages]
series: issue-372-temporal-driver-pages-scenario
---

The temporal simulation driver from #371 gave us a lifecycle controller — start a named profile, pause it, change speed, stop it. But it was fire-and-forget. You injected the factory, called `start()`, and hoped someone remembered to call `stop()`. No way to control a running driver from outside the JVM.

This matters because Pages scenarios need to orchestrate temporal simulation alongside UI verification. A scenario starts a data feed, waits for the system to react, asserts on the UI state, then stops the feed. All from YAML. The driver had the right API surface — what was missing was the remote control layer.

## The control surface

The approach: put `@McpDomain("temporal-drivers")` directly on a service class in `event-simulation`. The graphql-generator APT produces REST endpoints automatically. Seven operations — start, stop, pause, resume, setSpeed, status, list — mapping 1:1 to the driver's native methods.

The interesting design choice was YAML/Java parity on the start request. You can reference a named profile from the registry:

```java
service.start(new TemporalDriverStartRequest(
    "morning-routine", "morning-routine", null, null, null, null, 20.0));
```

Or define an inline profile with events, qualified name, loop, and speed — the same fields available in `simulation.yaml`. Whatever you can declare in YAML config, you can express programmatically. This came from a conversation about keeping the two surfaces in sync — if the API is a subset of the YAML, someone eventually needs the missing part and writes a workaround.

## Module placement surprise

The spec originally proposed putting the SPI interface in `simulation-api`. Turns out `simulation-api` already exists — it's the zero-dependency simulation contracts module (SimulationStrategy, SimulationCorpus, etc.). Adding platform-api for @McpDomain annotations would have broken its contract.

The fix was simpler: class-based @McpDomain on the service class itself, no separate interface. The graphql-generator supports this pattern — it scans both Jandex-indexed SPI interfaces from dependency JARs and `@McpDomain`-annotated classes in the current compilation unit. One fewer module, same generated endpoints.

## Pages temporal step

On the Pages side, temporal control becomes a new step type — independent from the existing `simulation:` overlay step. They're complementary: `simulation:` controls *what* (push strategy overlays so SPI calls return canned responses), `temporal:` controls *when* (start and stop event streams on a timeline).

```yaml
steps:
  - name: start-data-feed
    temporal:
      action: start
      profile: morning-routine
      speed: 20.0

  - name: verify-dashboard
    label: "Check the metrics board"
    target: browser
    commands:
      - action: expect
        target: { role: heading, name: "Active Devices" }

  - name: stop-feed
    temporal:
      action: stop
      name: morning-routine
```

Temporal steps are control-plane operations — the orchestrator handles them directly instead of dispatching to browser executors. The step completes immediately; the driver runs on its own virtual thread.

## What this opens up

The driver registry tracks active drivers by profile name, which means status queries work — a scenario can check emitted event counts mid-run. The deferred "temporal assertion step type" (#372's follow-up) would let scenario YAML assert on driver state directly, closing the loop between "start generating events" and "verify the system processed them correctly."
