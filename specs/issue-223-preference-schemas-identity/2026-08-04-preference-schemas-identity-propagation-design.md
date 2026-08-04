# Design: Remaining Preference Schemas + Identity Propagation Resolution

**Date:** 2026-08-04
**Issues:** casehubio/platform#223, casehubio/platform#220
**Predecessor:** casehubio/platform#197 (preference schema registration pattern)
**ACL Spec:** `docs/specs/2026-06-08-acl-authorization-model-design.md` §12-§14

---

## Part 1: Remaining Preference Schemas (#223)

Continuation of #197. Four @ConfigProperty values identified as preference candidates.

### New PreferenceKey Constants

**File:** `platform-api/src/main/java/io/casehub/platform/api/preferences/PlatformPreferenceKeys.java`

| Constant | Type | Namespace | Name | Default |
|----------|------|-----------|------|---------|
| `ENGAGEMENT_ENABLED` | `BooleanPreference` | `casehub.platform` | `delivery.engagement-enabled` | `false` |
| `DELIVERY_RETRY_MAX_RETRIES` | `IntPreference` | `casehub.platform` | `delivery.retry-max-retries` | `5` |
| `DIGEST_RETENTION_DAYS` | `IntPreference` | `casehub.platform` | `notification.digest-retention-days` | `90` |
| `VIEW_CACHE_TTL_SECONDS` | `IntPreference` | `casehub.platform` | `view.cache-ttl-seconds` | `0` |

`ENGAGEMENT_ENABLED` is the first `BooleanPreference` key — establishes the pattern. `PreferenceSchemaDescriptor.of()` infers type as `"boolean"` from `BooleanPreference`.

### Registrar Additions

**File:** `platform/src/main/java/io/casehub/platform/preferences/PlatformPreferenceRegistrar.java`

Four new `registry.register()` calls in `onStart()`:

| Key | Label | Description | Constraints |
|-----|-------|-------------|-------------|
| `ENGAGEMENT_ENABLED` | Engagement tracking | Enable engagement event recording for delivery tracking | none (boolean) |
| `DELIVERY_RETRY_MAX_RETRIES` | Delivery retry limit | Maximum retry attempts before marking delivery as expired | MIN=0, MAX=20 |
| `DIGEST_RETENTION_DAYS` | Digest buffer retention (days) | Days to retain digest buffer entries before purge | MIN=1, MAX=3650 |
| `VIEW_CACHE_TTL_SECONDS` | View cache TTL (seconds) | Time-to-live for cached view definitions (0 = disabled) | MIN=0, MAX=3600 |

### Migration

All resolutions use `Path.root()` scope (platform-global). Same pattern as #197.

#### notification-dispatch — EngagementRecorder

Remove `boolean enabled` constructor parameter and `@ConfigProperty`. Add `@Inject PreferenceProvider`. Resolve `ENGAGEMENT_ENABLED` at call time in `record()`:

```java
boolean enabled = preferenceProvider
    .resolve(new SettingsScope(Path.root(), Instant.now()))
    .getOrDefault(PlatformPreferenceKeys.ENGAGEMENT_ENABLED)
    .value();
if (!enabled) return;
```

#### notification-dispatch — InAppEngagementBridge

Same pattern. Remove `boolean enabled` constructor parameter. Resolve `ENGAGEMENT_ENABLED` in `onStatusChanged()`.

#### notification-dispatch — EngagementCallbackResource

Same pattern. Remove `boolean enabled` constructor parameter. Resolve `ENGAGEMENT_ENABLED` in `handleCallback()` and `recordDirect()`. Test constructor changes to accept `PreferenceProvider` instead of `boolean enabled`.

#### notification-dispatch — DeliveryRetryProcessor

Remove `int maxRetries` constructor parameter and `@ConfigProperty`. Add `@Inject PreferenceProvider`. Resolve `DELIVERY_RETRY_MAX_RETRIES` in `advanceOrExpire()`.

Other retry config properties (`base-delay`, `max-delay`, `jitter-ms`, `batch-size`) stay as `@ConfigProperty` — infrastructure tuning, not preference candidates.

#### digest-jpa — JpaDigestBuffer

Remove `@ConfigProperty` field injection for `casehub.notification.digest.retention-days`. Add `@Inject PreferenceProvider`. Resolve `DIGEST_RETENTION_DAYS` at use-time.

#### digest-inmem — InMemoryDigestBuffer

Same migration as digest-jpa — both modules use the same config property name.

#### platform-view — SubjectViewOrchestrator

Remove `@ConfigProperty` field injection for `casehub.view.cache.ttl-seconds`. Add `@Inject PreferenceProvider`. Resolve `VIEW_CACHE_TTL_SECONDS` in `getViews()`.

### Dependency Impact

All modules already depend on `platform-api`. Adding `PreferenceProvider` and `Path` imports costs nothing.

### Backward Compatibility

Old `@ConfigProperty` names are retired. `getOrDefault()` returns the key's built-in default unless a value is configured in the active preference backend. Existing deployments that set old property names need to migrate configuration.

### Testing

#### PlatformPreferenceKeys (platform-api unit tests)
- New keys construct without error, `qualifiedName()` correct
- `BooleanPreference` round-trips via `parse()` — first boolean key validates the pattern

#### PlatformPreferenceRegistrar (preferences-editor @QuarkusTest)
- Verify `discover()` returns all 10 descriptors (6 existing + 4 new)
- Spot-check boolean descriptor shape: type inferred as `"boolean"`, no min/max constraints
- Spot-check int descriptor constraints present

#### Migrated beans (module-specific @QuarkusTest)
- **EngagementRecorder**: set `ENGAGEMENT_ENABLED` to true via MockPreferenceProvider, verify `record()` proceeds. Set false, verify early return.
- **InAppEngagementBridge**: same enabled/disabled pattern.
- **EngagementCallbackResource**: same pattern for both endpoints.
- **DeliveryRetryProcessor**: set custom `DELIVERY_RETRY_MAX_RETRIES`, verify retry limit respected.
- **JpaDigestBuffer / InMemoryDigestBuffer**: set custom `DIGEST_RETENTION_DAYS`, verify retention cutoff.
- **SubjectViewOrchestrator**: set `VIEW_CACHE_TTL_SECONDS` > 0, verify caching behavior.

Existing tests: `MockPreferenceProvider @DefaultBean` returns null for unset keys; `getOrDefault()` falls back to the key's built-in default. Same defaults as before.

---

## Part 2: Identity Propagation Resolution (#220)

### Context

ACL spec Phase 2 (§12-§14) covers wiring actor identity through the engine's execution hierarchy. The spec explicitly states "Engine repo work. No new platform SPIs." All acceptance criteria target engine classes. Platform's contribution is resolving the open §14 design decision and filing actionable engine issues.

### §14 Resolution: Store actorId on CaseInstance

**Decision:** Store `actorId` on `CaseInstance` at creation AND propagate identity via `PropagationContext`.

**Rationale:** PropagationContext is ephemeral — it exists during execution but isn't persisted. ACL enforcement needs to answer "who created this case?" after the original request is gone. That requires durable storage. CaseInstance gains an `actorId` field populated from `currentPrincipal.actorId()` at `createRoot()` time.

PropagationContext also carries identity (userId + roles as plain strings in `inheritedAttributes`) for cross-scope propagation during active execution. Both are needed — CaseInstance for persistence, PropagationContext for runtime propagation.

### Engine Issues to File

**1. Populate PropagationContext with identity at createRoot()**
- Update all 4 call sites: CaseHubReactor ×2, EmptyWorkerContextProvider, CaseContextChangedEventHandler
- Capture: `Map.of("userId", currentPrincipal.actorId(), "roles", String.join(",", currentPrincipal.roles()))`
- Verify `createChild()` propagates inherited attributes (existing behavior, no changes expected)

**2. Store actorId on CaseInstance at creation**
- Add `actorId` column to `CaseInstanceEntity` (Flyway migration)
- CaseHubReactor sets `actorId` from `currentPrincipal.actorId()` at save
- Resolves the §14 identity gap identified in the ACL spec

**3. Read identity from PropagationContext in CasehubDispatch**
- CasehubDispatch extracts userId/roles from `PropagationContext.inheritedAttributes` when submitting via WorkOrchestrator
- Identity available for ACL checks on dispatched work without requiring request scope

### Platform Deliverables

1. Update ACL spec §14 with the resolution (actorId on CaseInstance + PropagationContext)
2. File the 3 engine issues with acceptance criteria above
3. Close platform#220 referencing the engine issues

### ACL Spec Update

In `docs/specs/2026-06-08-acl-authorization-model-design.md`, replace §14 body with:

> **Resolved:** Store `actorId` on `CaseInstance` at creation. `CaseHubReactor` populates `instance.actorId` from `currentPrincipal.actorId()` at save time. CaseInstance is the durable identity record; PropagationContext carries identity for runtime propagation during active execution. See engine issues for implementation.

---

## Doc Updates

- `CLAUDE.md` — update `platform/` module description: PlatformPreferenceRegistrar registers 10 schemas (was 6)
- `consumer-guide.md` — update preference config table with new keys; note BooleanPreference pattern
- ACL spec §14 — resolution as described above
