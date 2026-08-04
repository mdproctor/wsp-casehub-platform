---
layout: post
title: "Ten Preferences and a Design Decision"
date: 2026-08-04
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [preferences, acl, identity]
---

## Ten Preferences and a Design Decision

The preference schema work reached its natural conclusion today. Four more keys registered — bringing the platform to ten — and six beans migrated from `@ConfigProperty` to `PreferenceProvider`. The interesting part wasn't the migration itself (the pattern was established in #197), but what the first `BooleanPreference` key revealed about the system's type-inference design.

`PreferenceSchemaDescriptor.of()` takes any `PreferenceKey<T>` and calls `inferType()` on its default value:

```java
private static String inferType(Preference defaultValue) {
    if (defaultValue instanceof IntPreference) return "integer";
    if (defaultValue instanceof BooleanPreference) return "boolean";
    if (defaultValue instanceof DurationPreference) return "duration";
    return "string";
}
```

The type system already handled it — `BooleanPreference.of(false)` produces the right schema metadata for the UI editor without any changes to the registry infrastructure. The constraint model adapts too: boolean keys register with empty constraints (no min/max), while int keys carry bounds. The engagement toggle's `ENGAGEMENT_ENABLED` is the proof that the `PreferenceKey<T>` generics carry enough information for the schema layer to do the right thing automatically.

The migration pattern repeats across modules: remove `@ConfigProperty`, inject `PreferenceProvider`, resolve with `SettingsScope.root(TenancyConstants.PLATFORM_TENANT_ID)` at call-time. Each bean gains runtime configurability — engagement tracking can be toggled without a restart, retry limits can be adjusted per-deployment. The `InMemoryDigestBuffer` was the only one that needed care: its TTL expiry tests use 50ms retention for fast assertions, and the preference system operates in days. We kept a package-private test constructor with raw milliseconds alongside the CDI constructor — a test affordance, not an abstraction.

The second piece of work was design resolution, not code. The ACL spec's §14 had an open question: should the identity of whoever created a case be stored on `CaseInstance` (durable, queryable) or carried exclusively via `PropagationContext` (ephemeral, execution-scoped)? The answer is both — `CaseInstance.actorId` for persistence, `PropagationContext.inheritedAttributes` for runtime propagation. I resolved this in the spec and filed three engine issues (engine#865, #866, #867) for the implementation. No platform code changes were needed — `CurrentPrincipal` already provides everything engine requires.

The open question now is how the downstream repos respond. Work#328 and engine#864 are ready to register their own preference schemas — the consumer-guide documents the pattern. The identity propagation issues are engine-side work, prerequisite for ACL enforcement on internal execution paths. Whether those land this quarter depends on the engine team's priorities, not on platform readiness.
