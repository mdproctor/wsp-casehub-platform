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

**Issue #150 scope:** The issue body mentions both `scope` and `targetType`. This spec delivers `scope` only. `targetType` is not needed — `TargetType.GROUP` with an organisation-wide group from the identity provider already covers "all users" targeting via `GroupMembershipProvider.membersOf()`. Update issue #150 to reflect that `targetType` changes are unnecessary.

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

**SubscriptionInput** — add `scope` (defaults to `USER`):

```java
public SubscriptionInput {
    // ... existing validations ...
    scope = scope != null ? scope : SubscriptionScope.USER;
}
```

Jackson deserializes a missing `scope` field as `null`; the compact constructor normalises null to `USER` for backward compatibility with existing API clients.

**SubscriptionUpdate** — no scope field. Scope is immutable after creation — it is an authorisation model selector, not a mutable property. Changing scope mid-life conflates two distinct authorisation models on the same record. To change scope, delete and recreate.

**SubscriptionQuery** — add `SubscriptionScope scope` and make `ownerId` conditionally nullable:

```java
public record SubscriptionQuery(
        String ownerId,          // required for USER scope, nullable for SYSTEM
        String tenancyId,        // always required
        SubscriptionScope scope, // null defaults to USER
        Boolean enabled,
        String cursor,
        int limit
) {
    public SubscriptionQuery {
        Objects.requireNonNull(tenancyId, "tenancyId");
        var effectiveScope = scope != null ? scope : SubscriptionScope.USER;
        if (effectiveScope == SubscriptionScope.USER) {
            Objects.requireNonNull(ownerId, "ownerId required for USER scope");
        }
        if (limit <= 0) {
            throw new IllegalArgumentException("limit must be positive");
        }
    }
}
```

- `scope` null or `USER` → `ownerId` required, filter by ownerId + tenancyId (backward compatible)
- `scope` `SYSTEM` → `ownerId` nullable (not used in query), filter by tenancyId + scope only

### Store Authorisation (scope-aware)

| Method | USER scope | SYSTEM scope |
|--------|-----------|-------------|
| `findById(id, ownerId, tenancyId)` | ownerId + tenancyId match | tenancyId match only |
| `find(query)` | ownerId + tenancyId filter | tenancyId filter only |
| `update(id, ownerId, tenancyId, update)` | ownerId + tenancyId match | tenancyId match only |
| `delete(id, ownerId, tenancyId)` | ownerId + tenancyId match | tenancyId match only |
| `findAllEnabled()` | unchanged | unchanged |

**Query-level scope resolution:** The SPI method signatures do not change — `findById`, `update`, and `delete` still receive `(id, ownerId, tenancyId)`. The store resolves scope at the query level using an OR disjunction:

- **JPA:** `WHERE id = ?1 AND tenancyId = ?3 AND (ownerId = ?2 OR scope = 'SYSTEM')`
- **InMemory:** `.filter(s -> s.tenancyId().equals(tenancyId)).filter(s -> s.ownerId().equals(ownerId) || s.scope() == SubscriptionScope.SYSTEM)`

This eliminates the chicken-and-egg problem: the store does not need to know the subscription's scope before fetching it — the query finds the record if the caller owns it (USER) or if the record is tenant-wide (SYSTEM). The `ownerId` parameter is still passed for USER scope authorisation; for SYSTEM scope it is present but not load-bearing.

Admin-only write access for SYSTEM scope is enforced at the REST layer, not the store. The store allows any tenant user to find/update/delete SYSTEM subscriptions; the REST layer gates mutation to admins.

Cross-tenant isolation is unconditional in both scopes.

**SPI Javadoc update:** Both `SubscriptionStore` and `ReactiveSubscriptionStore` interface Javadoc must be updated. The current "User Ownership Enforcement" documentation describes ownerId as unconditionally enforced. Update to describe scope-dependent authorisation: USER scope enforces ownerId at the SPI boundary; SYSTEM scope uses tenancyId-only filtering at the SPI boundary with admin authorisation enforced at the REST layer.

### REST Layer

Admin authorisation for SYSTEM scope writes: use `CurrentPrincipal.hasGroup()` to check membership in a well-known group. This follows the platform's groups-as-roles contract (`CurrentPrincipal.roles()` delegates to `groups()` — see ARC42STORIES.MD). No new dependency injection needed; `CurrentPrincipal` is already injected into `SubscriptionResource`.

Add to `SubscriptionConstants`:

```java
public static final String SYSTEM_SUBSCRIPTION_ADMIN_GROUP = "subscription-admins";
```

Admin check: `principal.hasGroup(SYSTEM_SUBSCRIPTION_ADMIN_GROUP)`.

Do NOT inject `GroupMembershipProvider` — that SPI is for expanding notification targets at dispatch time, not for authorisation checks. `CurrentPrincipal.hasGroup()` checks JWT claims, consistent with the platform's groups-as-roles authorisation model.

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

**SYSTEM scope creation validation (`POST` with `scope=SYSTEM`):**

1. Do not default empty targets to `[USER(principal)]` — system subscriptions must have explicit targets.
2. Empty or null targets → 400 Bad Request. A SYSTEM subscription with no targets is a silent no-op (stored but never delivers notifications).
3. Reject any constraint with value `$me` → 400 Bad Request. `$me` resolves to the creating admin's ownerId, which is semantically wrong for a tenant-wide subscription (see §What Doesn't Change, ConstraintCompiler).

Non-admin attempting SYSTEM scope write → 403 Forbidden.

**SYSTEM scope mutation enforcement (PATCH, DELETE, enable, disable):**

The OR disjunction in the store (§Store Authorisation) means `store.update()` and `store.delete()` succeed for any tenant user on SYSTEM subscriptions. The REST layer must enforce the admin gate before calling the store. Every mutation endpoint on an existing subscription uses a two-phase pattern:

```java
// Phase 1: lookup to determine scope
return store.findById(id, principal.actorId(), principal.tenancyId())
    .chain(opt -> {
        if (opt.isEmpty()) return Uni.createFrom().item(Response.status(404).build());
        var sub = opt.get();
        // Phase 2: admin gate for SYSTEM scope
        if (sub.scope() == SYSTEM && !principal.hasGroup(ADMIN_GROUP)) {
            return Uni.createFrom().item(Response.status(403).build());
        }
        return store.update(id, principal.actorId(), principal.tenancyId(), update)
            .map(result -> result.map(s -> Response.ok(s).build())
                .orElse(Response.status(404).build()));
    });
```

This applies to: `update()`, `delete()`, `enable()`, `disable()`. The `POST` endpoint does not need this pattern — scope comes from the request body and is checked directly. `GET` endpoints do not need it — the spec allows any tenant user to read SYSTEM subscriptions.

### JPA Migration

**V3__subscription_scope.sql:**

```sql
ALTER TABLE subscription ADD COLUMN scope VARCHAR(10) NOT NULL DEFAULT 'USER';

CREATE INDEX idx_subscription_scope_tenant
    ON subscription (tenancy_id) WHERE scope = 'SYSTEM';
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
- **ConstraintCompiler** — `$me` substitution resolves to the subscription's `ownerId`. For SYSTEM scope, this is the creating admin's ID, which is almost never the intended filter subject. Rather than allowing a latent semantic trap (especially once MVEL activates), creation-time validation in the REST layer rejects SYSTEM scope constraints containing `$me` (see §REST Layer). The ConstraintCompiler itself is unchanged — validation is at the input boundary.
- **TargetResolver** — resolves targets identically regardless of scope.
- **NotificationDispatcher** — observes SubscriptionMatched, scope-unaware.
- **SuppressionEvaluator** — users mute/snooze notifications from system subscriptions via existing mechanism.
- **DigestFlushScheduler** — unchanged.

## Testing

- **Contract tests** (`SubscriptionStoreContractTest`): SYSTEM scope store, findById across users in same tenant, cross-tenant isolation, update/delete without ownerId match
- **REST tests** (`SubscriptionResourceTest`):
  - Admin creates SYSTEM scope subscription → 201
  - Non-admin creates SYSTEM scope subscription → 403
  - Any tenant user lists SYSTEM subscriptions → 200
  - Any tenant user reads SYSTEM subscription by ID → 200
  - Admin updates SYSTEM subscription → 200
  - Non-admin updates SYSTEM subscription → 403
  - Admin deletes SYSTEM subscription → 204
  - Non-admin deletes SYSTEM subscription → 403
  - Non-admin enables SYSTEM subscription → 403
  - Non-admin disables SYSTEM subscription → 403
  - SYSTEM scope creation with empty targets → 400
  - SYSTEM scope creation with `$me` constraint → 400
  - USER scope creation without `scope` field (backward compat) → 201 with `scope=USER`
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
| platform-api | `SubscriptionStore`, `ReactiveSubscriptionStore` | Javadoc: scope-dependent authorisation |
| docs | `ARC42STORIES.MD` | New `SubscriptionScope` enum in SPI layer taxonomy |
