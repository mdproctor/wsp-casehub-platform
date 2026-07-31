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
void denyBatch(Collection<AclEntryRequest> requests)
void removeDenyBatch(Collection<AclEntryRequest> requests)
```

`GrantRequest` is renamed to `AclEntryRequest` — the record is semantically neutral and used
by all four batch methods: `grantBatch`, `revokeBatch`, `denyBatch`, `removeDenyBatch`.

New method on `AclAction`:

```java
public Set<AclAction> deniedBy() {
    return switch (this) {
        case READ  -> Set.of(READ);
        case WRITE -> Set.of(READ, WRITE);
        case ADMIN -> Set.of(READ, WRITE, ADMIN);
        case CLAIM -> Set.of(CLAIM);
    };
}
```

`deniedBy()` is the dual of `satisfiedBy()`: it returns the set of actions that, when denied,
cascade to also deny this action. `deny(actor, resource, READ)` blocks READ, WRITE, and ADMIN
checks (since all three include read-level access). `deny(actor, resource, CLAIM)` blocks only
CLAIM (orthogonal to the READ/WRITE/ADMIN hierarchy).

`revokeAll(actorId, resourceId)` expands to also remove deny entries for that
actor+resource pair.

### canAccess Evaluation Order

Both backends implement a specificity-based evaluation. Instance entries take precedence
over wildcard entries; within the same specificity level, deny is checked before grant.

At each resource level (the requested resource, then each parent in the chain), four checks
run in order:

```
resolveAt(candidates, resourceId, action):
  1. Instance deny (any candidate, exact resourceId, action ∈ deniedBy, not expired, tenant-filtered) → DENY
  2. Instance grant (any candidate, exact resourceId, action ∈ satisfiedBy, not expired, tenant-filtered) → ALLOW
  3. Wildcard deny (any candidate, type:*, action ∈ deniedBy, not expired, tenant-filtered) → DENY
  4. Wildcard grant (any candidate, type:*, action ∈ satisfiedBy, not expired, tenant-filtered) → ALLOW
  5. → CONTINUE

canAccess(actorId, resourceId, action):
  candidates = {actorId} ∪ {group:<g> for g in groupsOf(actorId)}
  result = resolveAt(candidates, resourceId, action)
  if result ≠ CONTINUE: return result
  Walk parent chain (recursive, depth guard 20):
    result = resolveAt(candidates, parentResourceId, action)
    if result ≠ CONTINUE: return result
  → false
```

Key semantics:

- **Specificity wins** — instance entries (deny or grant) take precedence over wildcard entries.
  `deny(actor, "case:*", READ)` + `grant(actor, "case:abc", READ)` → allowed (instance grant
  overrides wildcard deny). This enables the "deny-all-except" pattern.
- **Within same level, deny wins** — `deny(actor, "case:abc", READ)` +
  `grant(group:managers, "case:abc", READ)` → denied (both instance-level, deny checked first)
- **Deny cascades via `deniedBy`** — `deny(actor, "case:abc", READ)` blocks READ, WRITE, and
  ADMIN checks on `case:abc`, because WRITE and ADMIN include read-level access.
  `deny(actor, "case:abc", WRITE)` blocks WRITE and ADMIN but not READ.
  `deny(actor, "case:abc", CLAIM)` blocks only CLAIM (orthogonal).
- **Parent chain applies full evaluation** — at each parent level, the same four-step check
  runs. A deny on a parent blocks inherited access; a grant on a parent grants inherited access.
  A direct grant on a child overrides a deny on its parent (the child's instance grant resolves
  before the parent chain is walked).
- **Wildcard extraction** — type prefix is everything before the first `:`. ResourceIds with no
  colon have no type prefix and cannot participate in wildcard matching

### accessibleResources Behavior

`accessibleResources(actorId, resourceType, action)`:

- Collects instance grants matching `type:` prefix (existing behavior)
- Checks for `type:*` grant — includes `"case:*"` in results if present
- Filters out any resourceId where any candidate has a matching deny entry (instance-level
  denies, action ∈ `deniedBy`)
- If a wildcard deny exists for the requested action (or any action in `deniedBy`), the wildcard
  grant is suppressed (no `"case:*"` in results); instance grants still returned individually

`accessibleResources(AclQuery)` (paginated):

- Same logic. `"case:*"` sorts lexically before `case:a...` (ASCII 42 < 97), appears
  first in keyset pagination naturally.

`accessibleResourcesIncludingInherited`:

- Same as `accessibleResources` plus existing children traversal
- Deny filtering applies to traversed children: children with instance deny entries (using
  `deniedBy`) are excluded from results. If a wildcard deny exists for the child's type,
  children of that type are excluded.
- No children are registered under `case:*` as a parent, so the wildcard entry passes
  through without expansion

**Non-authoritative wildcard entries:** When results contain `case:*`, this signals "all of
this type" — the caller must expand to concrete instances and verify each with `canAccess`.
Concrete instance results (non-wildcard) are authoritative after deny filtering. SPI Javadoc
must document this contract.

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

**`condition` column:** The existing `condition TEXT` column on `acl_entry` (from V1) is
reserved for Phase 2 ABAC — conditional grant/deny evaluation via the expression engine
(ARC42STORIES.MD §C21, original ACL design spec §8). Not evaluated by current code. Deny
entries will also support conditions when Phase 2 is implemented. No schema change needed —
the column already exists on all rows including future deny entries.

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
- `deny_actionSpecific_claimDenyDoesNotBlockRead`
- `deny_cascadesViadeniedBy_readDenyBlocksWriteAndAdmin`
- `deny_cascadesViadeniedBy_writeDenyBlocksAdminNotRead`
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
- `deny_wildcardDenyPlusWildcardGrant_denyWinsAtSameLevel`

**Deny + parent chain interaction (5 tests):**

- `deny_onParent_blocksChildInheritance`
- `deny_onParent_directGrantOnChild_allowed`
- `deny_wildcardOnParentType_blocksChildInheritance`
- `deny_wildcardOnParentType_instanceGrantOnParent_childInherits`
- `deny_onParent_groupGrantOnParent_actorDenied`

**Wildcard CLAIM (1 test):**

- `canAccess_wildcardGrant_claimAction_satisfiesOnlyClaim`

### CLAUDE.md Updates

After implementation:

- `AccessControlProvider` SPI documentation: add deny/removeDeny/denyBatch/removeDenyBatch
- `AclEntryType` enum added to package listing
- `acl-inmem` module description: mention deny support
- `acl-jpa` module description: mention deny support, Flyway V3
- `.meta` flyway-next-v updated from `unknown` to the allocated version

### Out of Scope

- Deny REST API (part of #218 — ACL administration REST API)
- Deny in Case Definition YAML wiring (#219)
- Deny interaction with PropagationContext (#220)
