# Design: Tenant Isolation Gaps (#203, #204, #205, #206)

**Issues:** casehubio/platform#203, #204, #205, #206
**Date:** 2026-07-26
**Status:** Approved

## Context

Tenant isolation audit found 4 gaps: GroupMembershipProvider has no tenancyId,
AccessControlProvider queries omit tenancyId, DeliveryAttemptStore has methods
without tenancyId, and two webhook endpoints accept unauthenticated requests.
All SPIs are platform-internal only — zero cross-repo callers.

DeliveryAttemptStore has 6 query/lookup methods. Of these:
`find(DeliveryAttemptQuery)` already requires tenancyId via
`Objects.requireNonNull(tenancyId)` in the query record constructor — it is
the model of correct design. `claimRetryable(Instant, int)` is a privileged
system operation (no tenant context). The remaining 4 methods
(`findBySource`, `findEngagementsByAttemptId`, `findEngagementsBySource`) get
tenancyId parameters added, and `findById` gets a tenant-scoped overload.

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
already-injected `CurrentPrincipal`. Both implementations centralize the
cross-tenant admin check in a private `shouldFilterByTenant()` helper that
reads `principal.isCrossTenantAdmin()` per request via the CDI proxy.

Protocol PP-20260520-e6a5f0 prescribes checking `isCrossTenantAdmin()` once
at CDI injection time via a Quarkus producer. This mechanism is designed for
`@RequestScoped` repositories where injection time equals request time.
`AccessControlProvider` implementations are `@ApplicationScoped` — the
principal changes per request via a `@RequestScoped` CDI proxy, so the
injection-time pattern does not apply. The per-request check through the
proxy is correct for this scope combination. A protocol update issue will
be filed against PP-20260520-e6a5f0 to document the `@ApplicationScoped`
exception.

### JpaAccessControlProvider changes

| Method | Change |
|--------|--------|
| `canAccess()` | Add `AND e.tenancyId = ?` to count query in `canAccessWithCandidates`; skip when `shouldFilterByTenant()` is false |
| `grant()` | Add `AND tenancyId = ?` to existence check query; already stores `principal.tenancyId()` on new entries |
| `revoke()` | Add `AND tenancyId = ?` to delete WHERE; skip when `shouldFilterByTenant()` is false |
| `revokeAll()` | Add `AND tenancyId = ?` to list and delete WHERE; skip when `shouldFilterByTenant()` is false |
| `registerParent()` | Add `AND tenancyId = ?` to findById; already stores tenancyId; skip when `shouldFilterByTenant()` is false |
| `accessibleResources()` | Add `AND e.tenancyId = ?` to query; skip when `shouldFilterByTenant()` is false |

Add private helper:
```java
private boolean shouldFilterByTenant() {
    return !principal.isCrossTenantAdmin();
}
```

### InMemoryAccessControlProvider changes

- Inject `CurrentPrincipal` (new dependency, added to constructor)
- Add tenancyId to `GrantKey`: `record GrantKey(String actorId, String resourceId, AclAction action, String tenancyId)`
- Store `principal.tenancyId()` on `AclEntry` in `grant()` and use it as the 4th GrantKey component
- Add private `shouldFilterByTenant()` helper (same pattern as JPA)
- Filter by tenancyId in `canAccessWithCandidates()`, `accessibleResources()`, `revoke()`, `revokeAll()`; skip when `shouldFilterByTenant()` is false

### Tests

- `AccessControlProviderContractTest` — add cross-tenant isolation tests:
  - `canAccess_differentTenant_returnsFalse` (grant in tenant A, check from tenant B)
  - `revoke_differentTenant_doesNotDelete`
  - `accessibleResources_filteredByTenant`
  - `grant_sameTupleDifferentTenant_bothStored` (verifies GrantKey includes tenancyId)
- Contract test needs a mechanism to switch tenant context per-test. Add
  `protected void setTenancyId(String tenancyId)` abstract method — implementations
  override to configure their `CurrentPrincipal` or mock.

---

## #205 — DeliveryAttemptStore tenancyId

### SPI change (`platform-api/`)

```java
DeliveryAttempt findById(String id);
DeliveryAttempt findById(String id, String tenancyId);
List<DeliveryAttempt> findBySource(String sourceId, DeliverySourceType sourceType, String tenancyId);
List<EngagementEvent> findEngagementsByAttemptId(String attemptId, String tenancyId);
List<EngagementEvent> findEngagementsBySource(String sourceId, DeliverySourceType sourceType, String tenancyId);
```

`findById(String id)` is the existing unscoped method — retained for
privileged paths (callback handler, system operations) where no tenant
context is available. `findById(String id, String tenancyId)` is a new
tenant-scoped overload; `tenancyId` is non-null (enforced by
implementations). Callers with tenant context use the scoped overload.

`claimRetryable(Instant, int)` unchanged — privileged system operation.

### Implementations

| Class | Module | Change |
|-------|--------|--------|
| `JpaDeliveryAttemptStore` | `delivery-tracking-jpa/` | Add `AND tenancyId = ?` to scoped methods; unscoped `findById` unchanged |
| `InMemoryDeliveryAttemptStore` | `delivery-tracking-inmem/` | Filter by tenancyId in scoped methods |
| `NoOpDeliveryAttemptStore` | `platform/` | Accept and ignore tenancyId |

### Callers

| Caller | Method used | Source of tenancyId |
|--------|------------|---------------------|
| `EngagementCallbackResource.recordDirect()` | `findById(id, tenancyId)` | `principal.tenancyId()` |
| `EngagementCallbackResource.handleCallback()` | `findById(id)` | Privileged — callback authenticates via handler signature verification |
| `InAppEngagementBridge` | scoped overloads | notification's `tenancyId()` |
| `DeliveryRetryProcessor` | `claimRetryable()` | Privileged — unchanged |

---

## #206 — Webhook authentication

### EngagementCallbackHandler SPI change

```java
public interface EngagementCallbackHandler {
    String channelId();

    /**
     * Translates a provider-specific webhook payload into platform engagement events.
     *
     * <p>Implementations MUST verify the request signature using provider-specific
     * headers (e.g. {@code X-Hub-Signature-256}) before processing the payload.
     * Implementations MUST throw {@link SecurityException} on verification failure —
     * not a generic {@code RuntimeException} or a swallowed internal check.
     *
     * @param rawPayload the raw webhook body
     * @param headers    complete HTTP request headers from the incoming request;
     *                   implementations extract the relevant verification header
     * @return translated engagement events
     * @throws SecurityException if signature verification fails
     */
    List<RawEngagement> translate(String rawPayload, Map<String, String> headers);
}
```

`EngagementCallbackResource.handleCallback()`:
- Inject `@Context HttpHeaders httpHeaders` (add to constructor and test constructor)
- Extract headers into `Map<String, String>` via `extractHeaders(httpHeaders)`
- Call `handler.translate(rawPayload, extractHeaders(httpHeaders))`
- `catch (SecurityException e)` MUST precede the existing `catch (Exception e)`
  block — `SecurityException` extends `RuntimeException` extends `Exception`, so
  the existing catch-all would swallow it. Restructure:

```java
try {
    var rawEvents = handler.translate(rawPayload, extractHeaders(httpHeaders));
    // ... process events ...
} catch (SecurityException e) {
    LOG.warnf("Engagement callback handler '%s' rejected payload: %s", channelId, e.getMessage());
    return Response.status(401).build();
} catch (Exception e) {
    LOG.warnf(e, "Engagement callback handler '%s' failed to translate payload", channelId);
}
return Response.ok().build();
```

### WebhookResource credential validation

Authentication is mandatory by default. Controlled by config property
`casehub.streams.webhook.require-auth` (default: `true`).

When a request arrives:
1. Resolve `EndpointDescriptor` for the `(streamId, tenancyId)` path
2. If descriptor has a non-null `credentialRef`:
   a. Resolve via `CredentialResolver`
   b. Extract `BEARER_TOKEN` from resolved credentials
   c. Validate `Authorization: Bearer <token>` header on the request
   d. Return 401 if missing or mismatched
3. If `credentialRef` is null:
   a. If `casehub.streams.webhook.require-auth` is true (default) → return 401
      with log message identifying the endpoint and directing the operator to
      set `credentialRef` or explicitly opt out
   b. If `require-auth` is false → allow unauthenticated (trusted-network
      deployment)

Inject `CredentialResolver` and `@Context HttpHeaders`.

### Tests

- `EngagementCallbackResourceTest` — update `translate()` calls to include
  headers; add test for SecurityException → 401; update constructor to include
  `HttpHeaders`
- `WebhookResourceTest` (if exists) or new test — verify bearer token
  validation when credentialRef present; verify 401 when credentialRef absent
  and require-auth is true; verify pass-through when require-auth is false

---

## Cross-cutting

### CLAUDE.md updates

- Update `InMemoryAccessControlProvider` description: add "constructor-injected CurrentPrincipal"
- Update `GroupMembershipProvider` in package structure: remove stale method signatures

### No Flyway migrations

Schema is unchanged — all filtering uses existing columns.

### No cross-repo impact

All 4 SPIs have zero cross-repo callers.

### Protocol update

File issue against protocol PP-20260520-e6a5f0 to document that
`@ApplicationScoped` beans with `@RequestScoped` proxy dependencies must
check `isCrossTenantAdmin()` per request via a centralized helper — the
injection-time pattern does not apply to this scope combination.
