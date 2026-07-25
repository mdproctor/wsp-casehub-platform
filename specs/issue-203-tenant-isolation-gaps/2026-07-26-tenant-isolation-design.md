# Design: Tenant Isolation Gaps (#203, #204, #205, #206)

**Issues:** casehubio/platform#203, #204, #205, #206
**Date:** 2026-07-26
**Status:** Approved

## Context

Tenant isolation audit found 4 gaps: GroupMembershipProvider has no tenancyId,
AccessControlProvider queries omit tenancyId, DeliveryAttemptStore has 5 methods
without tenancyId, and two webhook endpoints accept unauthenticated requests.
All SPIs are platform-internal only — zero cross-repo callers.

---

## #203 — GroupMembershipProvider tenancyId

### SPI change (`platform-api/`)

```java
public interface GroupMembershipProvider {
    Set<GroupMember> membersOf(String groupName, String tenancyId);
    default List<String> groupsOf(String actorId, String tenancyId) {
        return List.of();
    }
}
```

### Implementations

| Class | Module | Change |
|-------|--------|--------|
| `MockGroupMembershipProvider` | `platform/` | Accept and ignore tenancyId (returns empty) |
| `InMemoryGroupMembershipProvider` | `testing/` | Accept tenancyId; filter internal map by tenant |
| `ScimGroupMembershipProvider` | `scim/` | Accept tenancyId; pass through to SCIM query filter |
| `TestGroupMembershipProvider` | `acl-jpa/` test | Accept and ignore tenancyId (hardcoded test data) |

### Callers

| Caller | Source of tenancyId |
|--------|---------------------|
| `TargetResolver.resolve()` | `subscription.tenancyId()` |
| `JpaAccessControlProvider.buildCandidateSet()` | `principal.tenancyId()` (already injected) |
| `InMemoryAccessControlProvider.buildCandidateSet()` | `principal.tenancyId()` (inject `CurrentPrincipal` — new dependency) |

### Tests

- `GroupMembershipProviderSpiTest` — update all calls to pass tenancyId
- `AccessControlProviderContractTest` — add `tenancyId()` abstract method; subclasses provide test tenant
- `InMemoryGroupMembershipProviderTest` — update calls, add cross-tenant isolation test
- `ScimGroupMembershipProviderTest` — update calls
- `TargetResolverTest` — update lambda, verify tenancyId passed through
- `NotificationDispatcherTest` — update lambda

---

## #204 — AccessControlProvider tenancy filtering

### Approach

No SPI change. Add tenancy predicates to JPA queries using the
already-injected `CurrentPrincipal`. Skip filter when
`principal.isCrossTenantAdmin()` is true.

### JpaAccessControlProvider changes

| Method | Change |
|--------|--------|
| `canAccess()` | Add `AND e.tenancyId = ?` to count query in `canAccessWithCandidates` |
| `grant()` | Already stores `principal.tenancyId()` — no change |
| `revoke()` | Add `AND tenancyId = ?` to delete WHERE |
| `revokeAll()` | Add `AND tenancyId = ?` to list and delete WHERE |
| `registerParent()` | Add `AND tenancyId = ?` to findById; already stores tenancyId |
| `accessibleResources()` | Add `AND e.tenancyId = ?` to query |

### InMemoryAccessControlProvider changes

- Inject `CurrentPrincipal` (new dependency, added to constructor)
- Store `principal.tenancyId()` on `AclEntry` in `grant()`
- Filter by tenancyId in `canAccessWithCandidates()`, `accessibleResources()`, `revoke()`, `revokeAll()`
- Skip filter when `principal.isCrossTenantAdmin()`

### Tests

- `AccessControlProviderContractTest` — add cross-tenant isolation tests:
  - `canAccess_differentTenant_returnsFalse` (grant in tenant A, check from tenant B)
  - `revoke_differentTenant_doesNotDelete`
  - `accessibleResources_filteredByTenant`
- Contract test needs a mechanism to switch tenant context per-test. Add
  `protected void setTenancyId(String tenancyId)` abstract method — implementations
  override to configure their `CurrentPrincipal` or mock.

---

## #205 — DeliveryAttemptStore tenancyId

### SPI change (`platform-api/`)

```java
DeliveryAttempt findById(String id, String tenancyId);
List<DeliveryAttempt> findBySource(String sourceId, DeliverySourceType sourceType, String tenancyId);
List<EngagementEvent> findEngagementsByAttemptId(String attemptId, String tenancyId);
List<EngagementEvent> findEngagementsBySource(String sourceId, DeliverySourceType sourceType, String tenancyId);
```

`claimRetryable(Instant, int)` unchanged — privileged system operation.

### Implementations

| Class | Module | Change |
|-------|--------|--------|
| `JpaDeliveryAttemptStore` | `delivery-tracking-jpa/` | Add `AND tenancyId = ?` to queries |
| `InMemoryDeliveryAttemptStore` | `delivery-tracking-inmem/` | Filter by tenancyId |
| `NoOpDeliveryAttemptStore` | `platform/` | Accept and ignore tenancyId |

### Callers

| Caller | Source of tenancyId |
|--------|---------------------|
| `EngagementCallbackResource.recordDirect()` | `principal.tenancyId()` |
| `EngagementCallbackResource.handleCallback()` | No principal — callback path uses the verified attempt's tenancyId (see #206) |
| `InAppEngagementBridge` | notification's `tenancyId()` |
| `DeliveryRetryProcessor` | Uses `claimRetryable()` — unchanged |

For the callback path: after #206 adds header verification to `translate()`,
the handler authenticates the request. The resource then uses `findById(id, null)`
where `null` tenancyId means "no tenant filter" (the handler's verification IS
the auth). The SPI contract: `findById(id, null)` is equivalent to the
old `findById(id)` — no tenant filter applied.

---

## #206 — Webhook authentication

### EngagementCallbackHandler SPI change

```java
public interface EngagementCallbackHandler {
    String channelId();
    List<RawEngagement> translate(String rawPayload, Map<String, String> headers);
}
```

The resource extracts request headers into `Map<String, String>` and passes
them to `translate()`. The handler verifies the signature using the
appropriate provider-specific header (e.g., `X-Hub-Signature-256`) and
throws `SecurityException` on failure.

`EngagementCallbackResource.handleCallback()`:
```java
var rawEvents = handler.translate(rawPayload, extractHeaders(httpHeaders));
```
Catches `SecurityException` → returns 401.

### WebhookResource credential validation

If the resolved `EndpointDescriptor` has a non-null `credentialRef`:
1. Resolve via `CredentialResolver`
2. Extract `BEARER_TOKEN` from resolved credentials
3. Validate `Authorization: Bearer <token>` header on the request
4. Return 401 if missing or mismatched

If `credentialRef` is null → allow unauthenticated (backward compat,
network-boundary trust).

Inject `CredentialResolver` and `@Context HttpHeaders`.

### Tests

- `EngagementCallbackResourceTest` — update `translate()` calls to include
  headers; add test for SecurityException → 401
- `WebhookResourceTest` (if exists) or new test — verify bearer token
  validation when credentialRef present; verify pass-through when absent

---

## Cross-cutting

### CLAUDE.md updates

- Update `InMemoryAccessControlProvider` description: add "constructor-injected CurrentPrincipal"
- Update `GroupMembershipProvider` in package structure: remove stale method signatures

### No Flyway migrations

Schema is unchanged — all filtering uses existing columns.

### No cross-repo impact

All 4 SPIs have zero cross-repo callers.
