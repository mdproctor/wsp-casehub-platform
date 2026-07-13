# System Subscriptions — Admin-Defined Subscription Scope

**Issue:** casehubio/platform#150
**Date:** 2026-07-13
**Status:** Approved

## Problem

All subscriptions are user-owned. An admin cannot create organisation-wide notification rules that apply to roles, groups, or all users without each user manually creating their own subscription. There is no way to enforce "all case managers are notified on SLA breaches" as an organisational policy.

## Decision

Add a `SubscriptionScope` discriminator (`USER` | `SYSTEM`) to the existing Subscription model. The scope changes the authorisation model — not the targeting, matching, or delivery pipeline.

**Not in scope:**
- New `TargetType` — "all users" targeting uses `GROUP` with an organisation-wide group from the identity provider
- Separate `SystemSubscription` model — one record type with a scope discriminator
- Policy-based materialisation — too complex for the use case

## Design

### SPI Model (platform-api)

**New enum:**

```java
public enum SubscriptionScope {
    USER,   // default — owned and managed by individual user
    SYSTEM  // admin-defined — tenant-wide, managed by any admin
}
```

**Subscription** — add `scope` field between `enabled` and `createdAt`:

```java
public record Subscription(
        String id, String ownerId, String tenancyId, String name,
        String eventType, List<Constraint> constraints,
        List<NotificationTarget> targets, boolean includeActor,
        NotificationTemplate template, boolean enabled,
        SubscriptionScope scope,   // new
        Instant createdAt, Instant updatedAt
)
```

`ownerId` semantics: USER scope = the user who owns it. SYSTEM scope = the admin who created it (audit trail, not authorisation).

**SubscriptionInput** — add `scope` (defaults to `USER`).

**SubscriptionUpdate** — add nullable `SubscriptionScope scope` (null = unchanged).

**SubscriptionQuery** — add nullable `SubscriptionScope scope`:
- `null` or `USER` → filter by ownerId + tenancyId (backward compatible)
- `SYSTEM` → filter by tenancyId only (all system subscriptions for the tenant)

### Store Authorisation (scope-aware)

| Method | USER scope | SYSTEM scope |
|--------|-----------|-------------|
| `findById(id, ownerId, tenancyId)` | ownerId + tenancyId match | tenancyId match only |
| `find(query)` | ownerId + tenancyId filter | tenancyId filter only |
| `update(id, ownerId, tenancyId, update)` | ownerId + tenancyId match | tenancyId match only |
| `delete(id, ownerId, tenancyId)` | ownerId + tenancyId match | tenancyId match only |
| `findAllEnabled()` | unchanged | unchanged |

For SYSTEM scope, the `ownerId` parameter is still passed (it's the requesting user) but not used for authorisation — any user in the tenant can read, only admins can write (enforced at REST layer).

Cross-tenant isolation is unconditional in both scopes.

### REST Layer

Admin authorisation for SYSTEM scope writes: check membership in a well-known group. Add to `SubscriptionConstants`:

```java
public static final String SYSTEM_SUBSCRIPTION_ADMIN_GROUP = "subscription-admins";
```

Inject `GroupMembershipProvider` into `SubscriptionResource`.

| Endpoint | USER scope | SYSTEM scope |
|----------|-----------|-------------|
| `POST /subscriptions` | any user | admin only |
| `GET /subscriptions` | own subs (default) | — |
| `GET /subscriptions?scope=SYSTEM` | — | all system subs for tenant |
| `GET /subscriptions/{id}` | owner only | any tenant user |
| `PATCH /subscriptions/{id}` | owner only | admin only |
| `DELETE /subscriptions/{id}` | owner only | admin only |
| `PATCH /subscriptions/{id}/enable` | owner only | admin only |
| `PATCH /subscriptions/{id}/disable` | owner only | admin only |

On `POST` with `scope=SYSTEM`: do not default empty targets to `[USER(principal)]` — system subscriptions must have explicit targets.

Non-admin attempting SYSTEM scope write → 403 Forbidden.

### JPA Migration

**V3__subscription_scope.sql:**

```sql
ALTER TABLE subscription ADD COLUMN scope VARCHAR(10) NOT NULL DEFAULT 'USER';

CREATE INDEX idx_subscription_scope_tenant
    ON subscription (scope, tenancy_id) WHERE scope = 'SYSTEM';
```

Default `'USER'` backfills all existing rows. Partial index on `scope = 'SYSTEM'` optimises the system subscription tenant query.

**SubscriptionEntity:** add `public String scope` field. Map to/from `SubscriptionScope` enum in `fromInput()` and `toSubscription()`.

### InMemory Store

Same scope-aware logic as JPA:
- `findById`: SYSTEM scope skips ownerId filter
- `find`: SYSTEM scope query filters by tenancyId only
- `update`/`delete`: SYSTEM scope skips ownerId match
- Reactive mirror: identical changes

### What Doesn't Change

- **SubscriptionEngine** — `findAllEnabled()` returns all enabled subscriptions. System subscriptions are wired into the alpha network identically. No changes.
- **ConstraintCompiler** — `$me` resolves to admin's ownerId in SYSTEM scope. Not useful in SYSTEM constraints but not broken. Document as "not meaningful for SYSTEM scope."
- **TargetResolver** — resolves targets identically regardless of scope.
- **NotificationDispatcher** — observes SubscriptionMatched, scope-unaware.
- **SuppressionEvaluator** — users mute/snooze notifications from system subscriptions via existing mechanism.
- **DigestFlushScheduler** — unchanged.

## Testing

- **Contract tests** (`SubscriptionStoreContractTest`): SYSTEM scope store, findById across users in same tenant, cross-tenant isolation, update/delete without ownerId match
- **REST tests** (`SubscriptionResourceTest`): admin creates SYSTEM scope, non-admin gets 403, any user lists/reads SYSTEM subscriptions, admin updates/deletes
- **Engine test**: SYSTEM subscription wired and fires SubscriptionMatched (no engine changes needed — regression test)
- **Integration**: admin creates system subscription targeting GROUP, event fires, group members receive notifications

## Files Touched

| Layer | Files | Change |
|-------|-------|--------|
| platform-api | `SubscriptionScope` (new) | New enum |
| platform-api | `Subscription`, `SubscriptionInput`, `SubscriptionUpdate`, `SubscriptionQuery` | Add scope field |
| platform-api | `SubscriptionStoreContractTest`, `SubscriptionSpiTest` | SYSTEM scope cases |
| platform (no-op) | `NoOpSubscriptionStore`, `NoOpReactiveSubscriptionStore` | Pass-through scope |
| subscriptions-inmem | `InMemorySubscriptionStore`, `InMemoryReactiveSubscriptionStore` | Scope-aware auth |
| subscriptions-jpa | `SubscriptionEntity`, `JpaSubscriptionStore`, `JpaReactiveSubscriptionStore` | Scope column + queries |
| subscriptions-jpa | `V3__subscription_scope.sql` | Migration |
| subscriptions | `SubscriptionResource`, `SubscriptionResourceTest` | Admin auth, scope param |
