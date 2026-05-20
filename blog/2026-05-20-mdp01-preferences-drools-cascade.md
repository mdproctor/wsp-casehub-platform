---
layout: post
title: "Preferences, Drools, and a cascade effect"
date: 2026-05-20
type: phase-update
entry_type: note
subtype: log
projects: [casehub-platform]
tags: [java, quarkus, preferences, drools, config]
---

The previous entry ended with the platform foundation shipped. Devtown read
the spec and came back with six specific problems. The response changed the
shape of everything.

## The mock's blind spot

The one that mattered: `MockPreferenceProvider.get(key)` always returns null.
Devtown's point was simple — if typed `get()` is always null in the mock,
you're testing against a model that doesn't match production. I'd accepted
this as a design constraint, not a design flaw. They were right that it was
the latter.

The obvious answer would have been an `InMemoryPreferenceProvider` — a
test fixture with programmatic `register(key, value)`. We'd designed it,
written the scope-walking logic, even planned the module. Then I looked at
how Drools does it.

## ClockTypeOption.get(String)

Drools `ClockTypeOption` has a static `get(String clockType)` factory. The
factory lives on the option class. `ChainedProperties` reads the raw string,
calls the factory, gets a typed option. No registry, no reflection.

```java
// Drools pattern
ClockTypeOption option = ClockTypeOption.get("pseudo");
```

I wanted the same for casehub. `PreferenceKey<T>` now carries a
`Function<String, T> parser` as a fourth record component:

```java
public static final PreferenceKey<HumanApprovalThreshold> KEY =
    new PreferenceKey<>("devtown", "humanApprovalThreshold",
        DEFAULT,
        s -> new HumanApprovalThreshold(Integer.parseInt(s)));
```

`MockPreferenceProvider.get(key)` now calls `key.parse(raw)` on the config
string. Typed `get()` returns a real value. `InMemoryPreferenceProvider`
disappeared — it had been solving a problem that a better API prevents.

One trap: `PreferenceKey` is a record with a `Function` component. Records
use all components for `equals()` and `hashCode()`, but `Function` instances
only have identity equality. Two separately-created keys with the same
namespace and name are NOT `equals()`. Claude caught this during the code
review — a test called `qualifiedName_is_value_based_for_equality` was
asserting the opposite of what its name claimed. Use `key.qualifiedName()`
as a map key, never the object.

## The config/ module

With `key.parse()` in place, the natural next step was the file-based
provider — the Drools `ChainedProperties` equivalent. Each harness ships
its own preferences YAML. The platform provides the reader.

```yaml
entries:
  - scope: casehubio/devtown
    devtown.humanApprovalThreshold: "500"
  - scope: casehubio/devtown/pr-review
    devtown.humanApprovalThreshold: "100"
```

`ConfigFilePreferenceProvider` reads these at `@PostConstruct`, builds a
`Map<Path, Map<String, String>>` with null key for unscoped entries, and
resolves scope hierarchy on each `resolve()` call. SmallRye Config overrides
win above everything — so `application.properties` overrides still work in
tests, which matters: the mock's `@ConfigProperty` path survives intact.

We added `@QuarkusTestProfile.getConfigOverrides()` for the chaining test
(two files, later file wins). System properties set in `@BeforeAll` come
too late for `@PostConstruct` — the profile is the right idiom.

Also: when adding the JAX-RS `PathParamConverter` to `platform/`, we
reached for `quarkus-rest`. Claude flagged it in the code review. The right
dep is `jakarta.ws.rs-api` (provided scope) — the API, not the runtime.
Tests passed either way, which is exactly what makes this kind of bloat
invisible.
