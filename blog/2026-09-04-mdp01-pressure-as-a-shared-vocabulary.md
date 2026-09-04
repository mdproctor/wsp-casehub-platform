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

The capacity signal SPI addresses this by putting the shared types in platform-api and the default behaviour in platform/. The architecture has three layers, and it's worth walking through each one because the pattern is reusable far beyond capacity management.

## The signal layer

Every capacity-aware subsystem implements `CapacitySignalSource` and reports normalised pressure for the actors it tracks. The key word is *normalised* — every source reduces its internal complexity (queue depth, response time, channel load) to a single 0.0–1.0 scalar. This is a deliberate loss of dimensionality. The aggregator doesn't need to know what causes pressure, only how much.

<div align="center">

<svg width="600" height="220" viewBox="0 0 600 220" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#64748b"/>
    </marker>
  </defs>
  <rect x="10" y="20" width="140" height="50" rx="6" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="80" y="42" text-anchor="middle" font-size="11" font-weight="600" fill="#1e40af">Work Queue</text>
  <text x="80" y="58" text-anchor="middle" font-size="10" fill="#3b82f6">pressure: 0.72</text>
  <rect x="10" y="90" width="140" height="50" rx="6" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="80" y="112" text-anchor="middle" font-size="11" font-weight="600" fill="#1e40af">Qhorus Channel</text>
  <text x="80" y="128" text-anchor="middle" font-size="10" fill="#3b82f6">pressure: 0.91</text>
  <rect x="10" y="160" width="140" height="50" rx="6" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="80" y="182" text-anchor="middle" font-size="11" font-weight="600" fill="#1e40af">Engine Load</text>
  <text x="80" y="198" text-anchor="middle" font-size="10" fill="#3b82f6">pressure: 0.45</text>
  <line x1="150" y1="45" x2="230" y2="105" stroke="#64748b" stroke-width="1.5" marker-end="url(#arrow)"/>
  <line x1="150" y1="115" x2="230" y2="115" stroke="#64748b" stroke-width="1.5" marker-end="url(#arrow)"/>
  <line x1="150" y1="185" x2="230" y2="125" stroke="#64748b" stroke-width="1.5" marker-end="url(#arrow)"/>
  <rect x="235" y="80" width="160" height="70" rx="6" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>
  <text x="315" y="105" text-anchor="middle" font-size="11" font-weight="600" fill="#92400e">Aggregating View</text>
  <text x="315" y="122" text-anchor="middle" font-size="10" fill="#b45309">max(0.72, 0.91, 0.45)</text>
  <text x="315" y="140" text-anchor="middle" font-size="12" font-weight="700" fill="#92400e">= 0.91</text>
  <line x1="395" y1="115" x2="440" y2="115" stroke="#64748b" stroke-width="1.5" marker-end="url(#arrow)"/>
  <rect x="445" y="80" width="140" height="70" rx="6" fill="#fce7f3" stroke="#ec4899" stroke-width="1.5"/>
  <text x="515" y="105" text-anchor="middle" font-size="11" font-weight="600" fill="#9d174d">Policy</text>
  <text x="515" y="122" text-anchor="middle" font-size="10" fill="#be185d">0.91 >= 0.85</text>
  <text x="515" y="140" text-anchor="middle" font-size="12" font-weight="700" fill="#9d174d">REDISTRIBUTE</text>
</svg>

</div>

The aggregator takes `max()` across all sources for each actor. Max is the right default — the most-stressed subsystem sets the floor for capacity decisions. If the work queue is at 0.72 but the channel load is at 0.91, the actor's effective capacity is 0.91 — the channel is the bottleneck regardless of what the work queue thinks.

## The policy layer

The `RedistributionPolicy` evaluates aggregated pressure against three thresholds. The default policy is deliberately simple: compress at 0.7, redistribute at 0.85, escalate at 0.95. All three are MicroProfile Config properties — operators tune them without code.

<div align="center">

<svg width="560" height="100" viewBox="0 0 560 100" xmlns="http://www.w3.org/2000/svg">
  <rect x="30" y="30" width="500" height="30" rx="4" fill="#f1f5f9" stroke="#cbd5e1" stroke-width="1"/>
  <rect x="30" y="30" width="175" height="30" rx="4" fill="#dcfce7"/>
  <text x="117" y="50" text-anchor="middle" font-size="11" font-weight="600" fill="#166534">NONE</text>
  <rect x="205" y="30" width="75" height="30" fill="#fef9c3"/>
  <text x="242" y="50" text-anchor="middle" font-size="10" font-weight="600" fill="#854d0e">COMPRESS</text>
  <rect x="280" y="30" width="50" height="30" fill="#fed7aa"/>
  <text x="305" y="50" text-anchor="middle" font-size="9" font-weight="600" fill="#9a3412">REDIST</text>
  <rect x="330" y="30" width="200" height="30" rx="4" fill="#fecaca"/>
  <text x="430" y="50" text-anchor="middle" font-size="11" font-weight="600" fill="#991b1b">ESCALATE</text>
  <line x1="205" y1="25" x2="205" y2="65" stroke="#854d0e" stroke-width="2"/>
  <text x="205" y="80" text-anchor="middle" font-size="10" fill="#854d0e">0.70</text>
  <line x1="280" y1="25" x2="280" y2="65" stroke="#9a3412" stroke-width="2"/>
  <text x="280" y="80" text-anchor="middle" font-size="10" fill="#9a3412">0.85</text>
  <line x1="330" y1="25" x2="330" y2="65" stroke="#991b1b" stroke-width="2"/>
  <text x="330" y="80" text-anchor="middle" font-size="10" fill="#991b1b">0.95</text>
  <text x="30" y="20" font-size="10" fill="#64748b">0.0</text>
  <text x="520" y="20" font-size="10" fill="#64748b">1.0</text>
</svg>

</div>

What makes the three-tier model useful is that each tier maps to a different operational response. COMPRESS means "defer non-urgent work but don't move anything" — the actor handles it by slowing down. REDISTRIBUTE means "move work to someone else" — the system acts. ESCALATE means "a human needs to look at this" — automated responses are exhausted. Consumers observe `CapacityPressureEvent` CDI events and act on the tier.

## The scheduling boundary

The spec originally had `@Scheduled` on the monitor, but `platform/` doesn't have `quarkus-scheduler` — it's a foundational module with only `quarkus-arc`. The monitor exposes a `sweep()` method instead. Consumer apps that have the scheduler wire the trigger.

This is the right boundary: the platform defines what capacity means and how to evaluate it; the consumer decides when and how often to check. A qhorus deployment checking every 10 seconds has different needs than an engine checking every minute — the platform shouldn't dictate either.

## The concurrency detail

The review caught one issue worth noting. The original `refresh()` used `clear()` then `putAll()` on a `ConcurrentHashMap` — correct for single-threaded access but creates a window where concurrent readers see an empty cache. The fix was a volatile reference swap: build the new map completely, then assign it atomically. Readers always see either the old complete snapshot or the new one, never an empty intermediate.
