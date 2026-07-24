---
layout: post
title: "When the Review Writes the Spec"
date: 2026-07-24
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [preferences, spi, design-review]
---

## When the Review Writes the Spec

The issue asked for a `GET /preferences/schema` endpoint — type metadata so the UI can render number inputs, toggles, and dropdowns instead of treating everything as a string. Straightforward enough: `PreferenceKey<T>` already carries the Java type, we just need to expose it over REST.

The interesting part wasn't what we built. It was what the adversarial design review caught before we built it.

### The SPI decision

The issue recommended enriching `PreferenceKey` itself with label, description, and constraint fields. I went the other direction — a separate `PreferenceSchemaRegistry` SPI following the `EventTypeRegistry` pattern we already have. Three reasons: `PreferenceKey` is a clean record whose job is key identity and parsing; UI metadata is a separate concern; and the schema is only useful when `preferences-editor/` is deployed. The registry gives us the same three-layer architecture — SPI in `platform-api`, `@DefaultBean` no-op in `platform/`, real `ConcurrentHashMap` impl in `preferences-editor/`.

That part was a design call. The review caught things that were actual bugs.

### Five findings that would have shipped

**`String.valueOf(defaultValue)` is broken.** Java record `toString()` produces `IntPreference[value=24]`, not `"24"`. Every default value in every schema response would have been garbage. The fix was adding `toSerializedValue()` to the `Preference` interface — marker to behavioural, breaking change across platform and engine.

**`Boolean.parseBoolean("treu")` returns `false`.** Silently. No exception, no signal, just wrong. For a configuration editor where someone fat-fingers a boolean, that's a data corruption bug. We switched to a strict switch expression that rejects anything other than `"true"` or `"false"`.

**`IntPreference` and `DoublePreference` both mapped to `"number"`.** The UI needs to know whether to show a stepper (`step=1`) or a decimal input. Split to `"integer"` and `"number"`, following JSON Schema convention.

**No `multiValue` cardinality.** `SingleValuePreference` renders as one editor widget; `MultiValuePreference` renders as a sub-keyed table. Without the flag, the UI has no way to distinguish them.

**`Map<String, Object>` constraints with no vocabulary.** Added `PreferenceConstraintKeys` — `MIN`, `MAX`, `PATTERN`, `MIN_LENGTH`, `MAX_LENGTH` — following the `EndpointPropertyKeys` pattern.

### What landed

The three-layer SPI pattern is becoming a genuine platform convention now. `EventTypeRegistry`, `PreferenceSchemaRegistry` — same shape, same CDI displacement contract, same `@DefaultBean` fallback. Domain modules register descriptors at startup; if the consuming module isn't deployed, registrations go to the no-op.

The `Preference` interface going from marker to behavioural is a breaking change that ripples into `casehub-engine` — two routing preference types need the new method. Pre-release platform, so the cost is a one-line addition per implementation.
