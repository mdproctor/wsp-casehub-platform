---
layout: post
title: "Laying the platform foundation — and what Drools taught us about config"
date: 2026-05-19
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [java, quarkus, spi, design]
---

casehub-platform is the zero-dependency foundation for everything else in the
stack — Path hierarchies, typed preferences, principal identity. Before any other
module can ship, this one has to exist. We spent two sessions getting it right.

## The straightforward part

The SPIs themselves are clean: `Path` as a hierarchical value type with strict
segment validation, `PreferenceKey<T>` as a typed config key, `CurrentPrincipal`
for identity, `GroupMembershipProvider` for group lookups. The design follows the
Drools `OptionKey<T>` pattern directly — typed keys, marker interfaces, no stringly-typed
fallbacks. None of that took long to settle.

What took longer was the preference mock.

## When devtown read the spec

The initial design had `MockPreferenceProvider.get(key)` always return null —
the justification being that config strings can't be cast to typed preference
instances. Devtown pushed back, correctly: if typed get is always null in the
mock, you're testing against a model that doesn't match production.

Their point had force. But the answer they were implying — an `InMemoryPreferenceProvider`
with scope-walking and programmatic registration — felt like adding a module to fix
a design gap rather than closing the gap.

## The Drools realisation

Drools `ClockTypeOption` has a static `get(String)` factory on the option class itself.
`ChainedProperties` reads the raw string, calls the factory, gets a typed option.
The parsing lives where the type is defined — colocated, explicit, no registry.

I wanted the same thing for casehub. `PreferenceKey<T>` now carries a
`Function<String, T> parser` as a fourth record component. Define a key:

```java
public static final PreferenceKey<HumanApprovalThreshold> KEY =
    new PreferenceKey<>("devtown", "humanApprovalThreshold",
        new HumanApprovalThreshold(500),
        s -> new HumanApprovalThreshold(Integer.parseInt(s)));
```

`MockPreferenceProvider` calls `key.parse(raw)` on the config string via
`MapPreferences`. Typed `get()` now returns the correct type from
`application.properties`. The `InMemoryPreferenceProvider` disappeared —
it had been solving a problem that a better API design prevents.

## One trap

`PreferenceKey` is a record with a `Function` component. Java records use all
components in `equals()` and `hashCode()` — but `Function` instances only have
identity equality. Two separately-created keys with the same namespace and name
are not `equals()`. Claude caught this during the code review, where a test named
`qualifiedName_is_value_based_for_equality` was asserting the opposite of what its
name claimed. Use `key.qualifiedName()` as a map key, never the `PreferenceKey` object.

## What shipped

`casehub-platform-api` has Path, Preferences, Identity SPIs. `casehub-platform`
has `@DefaultBean` mocks configurable via `@ConfigProperty`, with `key.parse()`
making typed lookups work from properties files. `casehub-platform-testing` has
`FixedCurrentPrincipal` and `InMemoryGroupMembershipProvider` as `@Alternative`
fixtures — the identity SPIs need programmatic control in tests, which files can't
provide.

The module-tier-structure protocol got a nuance this session: `persistence-memory/`
is only warranted when in-memory has a production use case. If a file-based provider
covers the no-DB scenario, in-memory is test-only and belongs in `testing/`. Not
every `@Alternative` implementation needs its own persistence module.
