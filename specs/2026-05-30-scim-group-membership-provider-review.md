# SCIM-backed GroupMembershipProvider — Design Spec

**Date:** 2026-05-30
**Issue:** casehubio/platform#45
**Branch:** issue-45-oidc-group-membership
**Status:** Approved for implementation

---

## Problem

`GroupMembershipProvider.membersOf(groupName)` answers the inverse membership query: *who is in group X?*
The mock always returns `Set.of()`. No real implementation exists.

The inverse query cannot be answered from a JWT — a token only carries the current user's groups.
It requires a directory call. SCIM 2.0 (RFC 7643/7644) is the standard HTTP API for this: every
major IdP (Keycloak, Okta, Azure AD, JumpCloud) exposes it. We implement a SCIM client that satisfies
the SPI.

### Why not Keycloak Admin REST API

Keycloak-specific. Blocks portability to Okta, Azure AD, etc. The SPI abstraction exists precisely
so the backend can change; locking the first implementation to one vendor undermines that.

### SCIM server state for Keycloak

Native Keycloak SCIM is experimental in 26.6. The community extension
[SCIM for Keycloak](https://scim-for-keycloak.de/) is production-ready and widely used. Deployers
choose the appropriate option. Our client works against any compliant SCIM 2.0 server.

---

## SPI Changes (`platform-api/`)

### New type: `GroupMember`

```java
// io.casehub.platform.api.identity.GroupMember
public record GroupMember(
    String actorId,     // OIDC sub claim = SCIM value (user UUID) — stable, never changes
    String displayName  // SCIM display — human label for logs and UI only; never used as key
) {}
```

**actorId = OIDC `sub` = SCIM `value` (user UUID).** This is the OpenID Connect Core 1.0 mandate:
`sub` MUST be stable and locally unique; `preferred_username` MAY change. `GroupMember.actorId()`
and `CurrentPrincipal.actorId()` both return the same `sub` claim — they match for the same user.

### Updated SPI

```java
// io.casehub.platform.api.identity.GroupMembershipProvider
public interface GroupMembershipProvider {
    Set<GroupMember> membersOf(String groupName);  // empty = group unknown or has no members
}
```

**Breaking change.** Existing callers receive `Set<GroupMember>` instead of `Set<String>`. Migration
is mechanical: `member` (String) → `member.actorId()`. The mock returns `Set.of()` — semantics unchanged.

---

## Mock update (`platform/`)

`MockGroupMembershipProvider` return type changes from `Set<String>` to `Set<GroupMember>`. No
behaviour change — it still returns `Set.of()`.

---

## New module: `scim/` → `casehub-platform-scim`

**Artifact:** `casehub-platform-scim`
**CDI:** `@ApplicationScoped` — displaces `MockGroupMembershipProvider @DefaultBean` when on classpath.
**No `quarkus-maven-plugin` build goal** — library module; no REST resources or augmentation target.

### Package structure

```
io.casehub.platform.scim
  ScimGroupMembershipProvider   // @ApplicationScoped GroupMembershipProvider impl
  ScimClient                    // @RegisterRestClient reactive REST client interface
  ScimConfig                    // @ConfigMapping(prefix="casehub.platform.scim")
  model/
    ScimListResponse<T>         // SCIM ListResponse envelope
    ScimGroupResource           // id, displayName, members[]
    ScimMemberRef               // value (UUID), display (name)
```

### SCIM call sequence

**Step 1 — Resolve group and members in one call:**

```
GET {base-url}/Groups?filter=displayName eq "{groupName}"&attributes=id,displayName,members
```

RFC 7644 §3.4.2.2 filter; RFC 7644 §3.9 attribute selection. Most SCIM servers return `members`
inline when asked. Response: `ListResponse<ScimGroupResource>`.

**Step 2 — Fallback if members absent from Step 1 response:**

```
GET {base-url}/Groups/{id}?attributes=members
```

Used when the server omits members from list responses for large groups. Returns a single
`ScimGroupResource` with members populated.

**Mapping:**
- `ScimMemberRef.value` → `GroupMember.actorId` (user UUID = OIDC sub)
- `ScimMemberRef.display` → `GroupMember.displayName`

**Group not found** (empty `ListResponse.Resources`): return `Set.of()`. Same semantics as the mock.

**SCIM server error** (non-2xx): propagate as `RuntimeException`. Caller decides retry policy.
The SPI contract says "empty set = unknown group" — a server error is not an unknown group, so
it must not be silently swallowed as empty.

### Caching

`membersOf()` is called per work-item routing decision — potentially many times per second.
An uncached SCIM call per invocation is unacceptable in production.

```java
@CacheResult(cacheName = "scim-group-members")
public Set<GroupMember> membersOf(String groupName) { ... }
```

Cache config (application.properties in consuming app):
```properties
quarkus.cache.caffeine.scim-group-members.expire-after-write=5M
quarkus.cache.caffeine.scim-group-members.maximum-size=500
```

Default TTL: 5 minutes. Deployers adjust based on group churn rate. Cache key: `groupName` string.
Invalidation on membership change is not implemented — TTL-based expiry is the trade-off.

### Configuration

```java
@ConfigMapping(prefix = "casehub.platform.scim")
interface ScimConfig {
    /** SCIM server base URL. Example: https://keycloak.example.com/realms/myrealm/scim/v2 */
    String baseUrl();

    /** Bearer token for service account. Mutually exclusive with client credentials. */
    Optional<String> token();

    Auth auth();

    interface Auth {
        /** Client ID for client_credentials flow (alternative to static token). */
        Optional<String> clientId();
        Optional<String> clientSecret();
        Optional<String> tokenEndpoint();
    }
}
```

Auth priority: static `token` wins if present; otherwise `auth.clientId` + `auth.clientSecret` +
`auth.tokenEndpoint` are used for client_credentials grant. Exactly one must be configured.

### Dependencies

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-api</artifactId>
</dependency>
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-rest-client-reactive-jackson</artifactId>
</dependency>
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-cache</artifactId>
</dependency>
<!-- Test -->
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-junit5</artifactId>
    <scope>test</scope>
</dependency>
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-wiremock-devservices</artifactId>
    <scope>test</scope>
</dependency>
```

No `quarkus-keycloak-admin-rest-client`. No Keycloak-specific types anywhere.

---

## Test strategy

**No live Keycloak.** WireMock stubs replicate the SCIM server. One `@QuarkusTest` class:
`ScimGroupMembershipProviderTest`.

| Test | SCIM scenario |
|------|---------------|
| `group_found_members_inline` | Step 1 returns members; Step 2 never called |
| `group_found_members_require_second_call` | Step 1 returns group without members; Step 2 called |
| `group_not_found_returns_empty` | Step 1 returns empty Resources list |
| `scim_error_propagates_exception` | Step 1 returns 500; `RuntimeException` thrown |
| `result_is_cached` | Two calls; SCIM endpoint hit once |
| `actorId_is_scim_value_not_display` | Verifies UUID maps to actorId, not display name |

No `@TestSecurity` — this module makes outbound HTTP calls only; there is no inbound security
layer to intercept (see GE-20260513-3c1a03).

---

## Caller migration

Any existing call to `GroupMembershipProvider.membersOf()` that treats the result as `Set<String>`
must change to `Set<GroupMember>` and access `.actorId()` where it previously used the string directly.

Affected areas: `WorkBroker` / `WorkerSelectionStrategy` in casehub-work, `ExclusionPolicy` in
casehub-work-api, any other work routing code that reads group members.

These are in peer repos — file issues there, do not touch them in this session.

---

## Platform doc updates

- `PLATFORM.md` capability ownership: update GroupMembership row to reference `casehub-platform-scim`
- `PLATFORM.md` Repository Map: add `scim/` to casehub-platform module list
- `docs/repos/casehub-platform.md`: add `scim/` to Module Roadmap and Three-Layer Model

---

## Out of scope

- **Keycloak Admin REST API backend** — revisit once Keycloak native SCIM ships (26.6+)
- **`SecurityIdentityAugmentor`** — augmenting SecurityIdentity.getRoles() with SCIM groups; deferred
  (a separate concern from inverse lookup, and @RolesAllowed is not yet wired in casehub)
- **SCIM write operations** — creating/updating groups; this SPI is read-only
- **Pagination of SCIM member lists** — initial implementation assumes groups fit in one response
  (max 1000 members); file an issue if large-group support is needed
- **Cache invalidation on membership change** — TTL-based expiry is sufficient at this stage

---

## Open issues to file before leaving brainstorming

1. **casehub-work**: update `WorkBroker` / `WorkerSelectionStrategy` callers for `Set<GroupMember>` SPI change
2. **casehub-work-api**: update `ExclusionPolicy` if it uses `membersOf()`
3. **SCIM pagination**: large-group support (>1000 members) — track for future
