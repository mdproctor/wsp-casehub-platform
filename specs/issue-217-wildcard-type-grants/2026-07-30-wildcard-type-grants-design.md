# Wildcard Type-Level Grants and Deny Entries

**Issue:** casehubio/platform#217
**Date:** 2026-07-30
**Status:** Approved

## Problem

All ACL grants are instance-level — `grant(actor, "case:abc", READ)`. There is no
way to express "actor X can READ all cases" without granting each case individually.
Additionally, there is no way to exclude specific instances from broad grants.

## Design

### SPI Changes (platform-api)

New enum `AclEntryType { ALLOW, DENY }` in `io.casehub.platform.api.acl`.

`AclEntry` record gains an `entryType` field (breaking change — pre-release, zero consumers).

New default methods on `AccessControlProvider`:

```java
void deny(String actorId, String resourceId, AclAction action, Instant expires)
void removeDeny(String actorId, String resourceId, AclAction action)
void denyBatch(Collection<GrantRequest> requests)
void removeDenyBatch(Collection<GrantRequest> requests)
```

`GrantRequest` is reused for deny operations — same fields apply.

`revokeAll(actorId, resourceId)` expands to also remove deny entries for that
actor+resource pair.

### canAccess Evaluation Order

Both backends implement the same six-step chain:

1. Check instance deny (exact resourceId, all candidates, not expired, tenant-filtered) → **false**
2. Check wildcard deny (`type:*`, candidates, not expired, tenant-filtered) → **false**
3. Check instance grant (exact resourceId, candidates, satisfiedBy, not expired, tenant-filtered) → **true**
4. Walk parent chain (recursive, depth guard 20) → **true**
5. Check wildcard grant (`type:*`, candidates, satisfiedBy, not expired, tenant-filtered) → **true**
6. → **false**

Key semantics:

- **Deny always wins** — a deny on `case:abc` blocks access even if `case:*` ADMIN grant exists
- **Deny is action-specific** — `deny(actor, "case:abc", READ)` blocks READ but not WRITE
- **Deny does not imply higher actions** — deny on READ does not block ADMIN checks
- **Wildcard deny** — `deny(actor, "case:*", READ)` blocks READ on all resources of that type
- **Wildcard extraction** — type prefix is everything before the first `:`. ResourceIds with no
  colon have no type prefix and cannot participate in wildcard matching
- **Wildcard grants use satisfiedBy** — `grant(actor, "case:*", ADMIN)` satisfies a READ check
- **Wildcard denies do NOT use satisfiedBy** — `deny(actor, "case:*", READ)` blocks only READ,
  not WRITE or ADMIN

### accessibleResources Behavior

`accessibleResources(actorId, resourceType, action)`:

- Collects instance grants matching `type:` prefix (existing behavior)
- Checks for `type:*` grant — includes `"case:*"` in results if present
- Filters out any resourceId with a matching deny entry (instance-level denies)
- If a wildcard deny exists for the requested action, the wildcard grant is suppressed
  (no `"case:*"` in results); instance grants still returned individually

`accessibleResources(AclQuery)` (paginated):

- Same logic. `"case:*"` sorts lexically before `case:a...` (ASCII 42 < 97), appears
  first in keyset pagination naturally.

`accessibleResourcesIncludingInherited`:

- Same as `accessibleResources` plus existing children traversal
- No children are registered under `case:*` as a parent, so the wildcard entry passes
  through without expansion

The caller interprets `case:*` as "all of this type" and uses `canAccess` for
authoritative per-resource checks (which catch individual denies).

### Storage

**acl-inmem:**

- Separate `ConcurrentHashMap<GrantKey, AclEntry> denies` alongside existing `grants` map
- Same `GrantKey` record works for both
- `deny()` inserts into `denies`, `removeDeny()` removes from `denies`
- `revokeAll()` clears from both maps

**acl-jpa:**

- Flyway V3: `ALTER TABLE acl_entry ADD COLUMN entry_type VARCHAR(5) NOT NULL DEFAULT 'ALLOW'`
- Existing rows backfilled as `ALLOW` via the default
- Unique constraint expands to include `entry_type` — same actor+resource+action+tenant can
  have both an ALLOW and a DENY entry
- `AclEntryEntity` gains an `entryType` field
- Grant queries add `AND entry_type = 'ALLOW'`; deny queries add `AND entry_type = 'DENY'`
- Audit log operations: `DENY` and `REVOKE_DENY` alongside existing `GRANT` and `REVOKE`
- Retention purge: expired deny entries purged alongside expired allow entries (same schedule)

### Contract Tests

All tests in `AccessControlProviderContractTest`, run by both backends.

**Wildcard grants (10 tests):**

- `canAccess_wildcardGrant_matchesInstance`
- `canAccess_wildcardGrant_doesNotMatchDifferentType`
- `canAccess_wildcardGrant_respectsActionHierarchy`
- `canAccess_wildcardGrant_respectsExpiry`
- `canAccess_wildcardGrant_respectsGroupMembership`
- `canAccess_wildcardGrant_respectsTenantIsolation`
- `canAccess_noColonInResourceId_noWildcardCheck`
- `accessibleResources_wildcardGrant_includesWildcardInResults`
- `accessibleResources_wildcardGrant_paginatedIncludesWildcard`
- `accessibleResourcesIncludingInherited_wildcardGrant_passesThrough`

**Deny entries (15 tests):**

- `deny_blocksInstanceGrant`
- `deny_blocksWildcardGrant`
- `deny_wildcardDeny_blocksAllOfType`
- `deny_actionSpecific`
- `deny_doesNotImplyHigherActions`
- `deny_respectsExpiry`
- `deny_respectsTenantIsolation`
- `deny_respectsGroupMembership`
- `removeDeny_restoresAccess`
- `revokeAll_alsoClearsDenies`
- `denyBatch_deniesAll`
- `removeDenyBatch_restoresAll`
- `accessibleResources_excludesDeniedInstances`
- `accessibleResources_wildcardGrantWithDeny_wildcardPlusDeniedExcluded`
- `accessibleResources_wildcardDeny_suppressesWildcardGrant`

### CLAUDE.md Updates

After implementation:

- `AccessControlProvider` SPI documentation: add deny/removeDeny/denyBatch/removeDenyBatch
- `AclEntryType` enum added to package listing
- `acl-inmem` module description: mention deny support
- `acl-jpa` module description: mention deny support, Flyway V3
- `.meta` flyway-next-v updated from `none` to the allocated version

### Out of Scope

- Deny REST API (part of #218 — ACL administration REST API)
- Deny in Case Definition YAML wiring (#219)
- Deny interaction with PropagationContext (#220)
