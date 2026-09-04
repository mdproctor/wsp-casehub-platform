---
title: "Pressure as a Shared Vocabulary"
date: 2026-09-04
author: mdp
entry_type: note
subtype: diary
projects:
  - casehubio/platform
series: issue-268-capacity-signal-spi
tags: [platform-api, capacity, spi, cdi, concurrency]
---

# Pressure as a Shared Vocabulary

Platform repos tend to grow domain-specific solutions for the same cross-cutting problem. Capacity management is a good example — qhorus needs to know when an actor is overloaded, engine needs to know when to stop routing, and the work module needs to know when to redistribute. Three consumers, three potential implementations, zero shared vocabulary.

The capacity signal SPI addresses this by putting the shared types in platform-api and the default behaviour in platform/. A `CapacitySignalSource` reports normalised pressure (0.0 idle, 1.0 at capacity) for every actor it tracks. An `AggregatingActorCapacityView` collects signals from all CDI-discovered sources and computes the max-pressure per actor. A `RedistributionPolicy` evaluates the aggregated pressure against configurable thresholds and returns a decision: compress, redistribute, or escalate.

The interesting design constraint was where to draw the scheduling boundary. The spec originally had `@Scheduled` on the monitor, but `platform/` doesn't have `quarkus-scheduler` — it's a foundational module with only `quarkus-arc`. The monitor exposes a `sweep()` method instead. Consumer apps that have the scheduler wire the trigger. This is the right boundary: the platform defines what capacity means and how to evaluate it; the consumer decides when and how often to check.

The review caught one concurrency issue worth noting. The original `refresh()` used `clear()` then `putAll()` on a `ConcurrentHashMap` — correct for single-threaded access but creates a window where concurrent readers see an empty cache. The fix was a volatile reference swap: build the new map completely, then assign it atomically. Readers always see either the old complete snapshot or the new one, never an empty intermediate.
