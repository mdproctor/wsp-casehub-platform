---
layout: post
title: "Root scope and the CDI ladder"
date: 2026-05-22
type: phase-update
entry_type: note
subtype: log
projects: [casehub-platform]
---

Root scope — `Path.root()`, an empty path — was never included in the preference
resolution ancestor chain for any non-root scope. Call `resolve()` with
`Path.of("casehubio", "devtown")` and the walk produces `["casehubio",
"casehubio/devtown"]`. A preference stored at root scope returned the key's
default. No error, no warning.

The cause is in `Path.parent()`, documented as "returns null if root or
single-segment path." Both zero-segment and one-segment paths return null.
Walking via `parent()` terminates at the single segment without reaching root.
The fix adds one conditional after the walk:

```java
if (path.depth() > 0) {
    result.add(0, Path.root().value()); // "" is always lowest priority
}
```

`path.depth() > 0` is the right guard — `Path.root()` is the only zero-depth path,
and it already produces `[""]` from the walk itself. For everything else, root is
now always the base.

There was a second issue: the sort comparator used `getOrDefault(scope, 0)` as
the fallback for unknown scopes. Root's index in the ancestor list is also 0. A
row with an unrecognised scope would sort at root priority — safe by construction,
since the query only returns rows in the ancestor list, but the correct default
is -1.

The MongoDB tests require Docker, which wasn't available. I confirmed the fix by
code inspection — both providers have identical `ancestors()` implementations —
and committed without a verified red phase.

`PreferenceProvider.resolve()` now carries an implementor warning in its Javadoc:
`parent()` returns null for single-segment paths, not root, so root must be
prepended explicitly. The next person implementing the SPI has the contract
written down.

## The CDI ladder gets a nameplate

The priority pattern that makes all this work — `@DefaultBean` (mock) <
`@ApplicationScoped` (JPA) < `@Alternative @Priority(1)` (MongoDB) — has been
the established practice in `casehub-work` for some time. It just wasn't written
down as a platform protocol.

Scope question: the activation mechanism is Quarkus-specific. ARC activates
`@Priority`-carrying alternatives globally without `beans.xml`, which standard
CDI 4.x doesn't do. But layered backends displacing each other by priority isn't
casehub-specific — it applies to any Quarkus project with competing SPI
implementations. The protocol goes in the universal section.

The "What NOT to do" section needed a correction. I'd written that putting
`@Alternative @Priority(1)` on a primary JPA backend "would fall back to the mock
when no NoSQL module is present." Wrong — it still beats the mock. The real failure
mode is both JPA and MongoDB at `@Priority(1)`: ARC sees two competing alternatives
and throws an ambiguous dependency exception at startup. Claude caught this as
Critical.
