# Design: Register Platform Preference Schemas (#197)

**Date:** 2026-08-03
**Issue:** casehubio/platform#197
**Consumer:** casehubio/blocks-ui#92 (preference editor UI)
**Prerequisite:** casehubio/platform#195 (PreferenceSchemaRegistry SPI)

## Context

The `PreferenceSchemaRegistry` SPI (#195) defines `register()`, `resolve()`, `discover()`, and `version()`. The `InMemoryPreferenceSchemaRegistry` in `preferences-editor/` captures registrations; `NoOpPreferenceSchemaRegistry @DefaultBean` silently drops them when the editor isn't deployed. The schema endpoint (`GET /preferences/schema`) serves registered descriptors to UI consumers for form generation.

The registry ships with no registered keys. Domain modules must opt in.

## Scope

1. Define `PlatformPreferenceKeys` — six retention preference keys as `static final PreferenceKey<IntPreference>` constants
2. Create `PlatformPreferenceRegistrar` — `@Startup` bean that registers schema descriptors
3. Migrate three retention schedulers from `@ConfigProperty` to `PreferenceProvider` reads
4. File a follow-up issue for remaining candidates

## PreferenceKey Constants

**File:** `platform-api/src/main/java/io/casehub/platform/api/preferences/PlatformPreferenceKeys.java`

All keys use namespace `casehub.platform`, type `IntPreference`, and `IntPreference::parse`.

| Constant | Name | Default | Source module |
|----------|------|---------|---------------|
| `NOTIFICATION_RETENTION_DAYS` | `notification.retention-days` | 90 | notifications-jpa |
| `NOTIFICATION_UNREAD_RETENTION_DAYS` | `notification.unread-retention-days` | 365 | notifications-jpa |
| `ACL_AUDIT_RETENTION_DAYS` | `acl.audit-retention-days` | 365 | acl-jpa |
| `DELIVERY_ATTEMPT_RETENTION_DAYS` | `delivery.attempt-retention-days` | 30 | delivery-tracking-jpa |
| `DELIVERY_FAILED_RETENTION_DAYS` | `delivery.failed-retention-days` | 365 | delivery-tracking-jpa |
| `DELIVERY_ENGAGEMENT_RETENTION_DAYS` | `delivery.engagement-retention-days` | 90 | delivery-tracking-jpa |

Keys live in `platform-api` because it is zero-dependency and any consumer can reference them without pulling in Quarkus.

## Registrar Bean

**File:** `platform/src/main/java/io/casehub/platform/preferences/PlatformPreferenceRegistrar.java`

`@ApplicationScoped` bean, injects `PreferenceSchemaRegistry`, observes `StartupEvent`. Registers a `PreferenceSchemaDescriptor` for each key with:
- `label` — human-readable name for UI
- `description` — one sentence explaining the setting
- `constraints` — `MIN`/`MAX` integer bounds via `PreferenceConstraintKeys`
- `type` — auto-inferred as `"integer"` from `IntPreference`

Goes in `platform/` (not `preferences-editor/`) so it fires in every deployment. `NoOpPreferenceSchemaRegistry` absorbs registrations harmlessly when the editor isn't deployed.

## Migration Pattern

Replace `@ConfigProperty` field injection with `PreferenceProvider` call-time resolution:

```java
// Before
@ConfigProperty(name = "casehub.notification.jpa.retention-days", defaultValue = "90")
int retentionDays;

// After
@Inject PreferenceProvider preferenceProvider;

// In the scheduled method:
int retentionDays = preferenceProvider
    .resolve(new SettingsScope(Path.root(), Instant.now()))
    .getOrDefault(PlatformPreferenceKeys.NOTIFICATION_RETENTION_DAYS)
    .value();
```

**Scope:** `Path.root()` — platform-global. Schedulers run globally, not per-tenant. Per-tenant retention iteration is a future capability.

### Module-specific migration

**notifications-jpa/ — NotificationRetentionScheduler**
- Remove two `@ConfigProperty` fields (`retentionDays`, `unreadRetentionDays`)
- Add `@Inject PreferenceProvider`
- Read both values via `getOrDefault()` at the start of `purge()`

**acl-jpa/ — AclRetentionPurge**
- Remove one `@ConfigProperty` field (`auditRetentionDays`)
- Add `@Inject PreferenceProvider`
- Read value via `getOrDefault()` at the start of `purgeAuditLog()`
- `purgeExpiredEntries()` is unchanged (uses `expiresAt IS NOT NULL`, no config)

**delivery-tracking-jpa/ — JpaDeliveryAttemptStore**
- Remove three `@ConfigProperty` default fields (`defaultAttemptDays`, `defaultFailedAttemptDays`, `defaultEngagementDays`)
- Add `@Inject PreferenceProvider`
- Change `resolveRetentionConfig(sourceType, suffix, int defaultValue)` to `resolveRetentionConfig(sourceType, suffix, PreferenceKey<IntPreference> defaultKey)` — resolve the preference inside, keep per-source-type MicroProfile Config override on top
- `claimTimeout` `@ConfigProperty` stays as-is (infrastructure, not a preference)

### Dependency impact

All three modules already depend on `platform-api` (they use notification/ACL/delivery types). Adding `PreferenceProvider` and `Path` imports costs nothing.

### Backward compatibility

Old `@ConfigProperty` names (`casehub.notification.jpa.retention-days`, etc.) are retired. `getOrDefault()` returns the key's built-in default unless a value is configured in the active preference backend (YAML, JPA, MongoDB). Existing deployments that set the old property names need to migrate configuration to the preference backend.

## Testing

### PlatformPreferenceKeys (platform-api/ unit tests)
- Keys construct without error, `qualifiedName()` is correct
- Parse round-trips (`IntPreference::parse` on string)

### PlatformPreferenceRegistrar (platform/ @QuarkusTest)
- Inject `PreferenceSchemaRegistry`, verify `discover()` returns all 6 descriptors
- Spot-check one descriptor's shape: namespace, name, type, label, constraints, defaultValue
- Verify `resolve(qualifiedName)` returns present Optional for each key
- Requires `preferences-editor/` on test classpath for `InMemoryPreferenceSchemaRegistry`

### Migrated schedulers (module-specific @QuarkusTest)
- **notifications-jpa/**: `purge()` respects preference value. Set custom retention via `MockPreferenceProvider`, insert notifications older/newer than cutoff, verify correct purge.
- **acl-jpa/**: same pattern for audit log purge.
- **delivery-tracking-jpa/**: same pattern, plus verify per-source-type MicroProfile Config overrides still take precedence over preference default.

### Existing tests
`MockPreferenceProvider @DefaultBean` returns `null` for unset keys; `getOrDefault()` falls back to the key's built-in default. Existing tests get the same defaults as before.

## Doc Updates

- `consumer-guide.md` — add "Registering preference schemas" section with the pattern
- `CLAUDE.md` — update `platform/` module description to mention `PlatformPreferenceRegistrar`

## Follow-up Issues

Single follow-up issue for remaining candidates:
- `casehub.delivery.engagement.enabled` (boolean) — notification-dispatch
- `casehub.delivery.retry.max-retries` (int) — notification-dispatch
- `casehub.notification.digest.retention-days` (int) — digest-jpa
- `casehub.view.cache.ttl-seconds` (int) — platform-view

Consumer repos (out of scope):
- casehub-work: `WorkPreferenceKeys` + `WorkPreferenceRegistrar` (pattern documented in contributor-guide)
- casehub-engine: `TrustRoutingPolicyKeys` already defines PreferenceKey constants but doesn't register schemas
