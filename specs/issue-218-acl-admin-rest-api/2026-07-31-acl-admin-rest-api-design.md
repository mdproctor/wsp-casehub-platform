# ACL Administration REST API

**Issue:** casehubio/platform#218
**Date:** 2026-07-31
**Status:** Approved

## Problem

The ACL SPI (`AccessControlProvider`) has no REST surface. Grants, denies, parent
registration, and access checks are only available programmatically. Domain modules
and admin UIs need an HTTP API to manage ACL entries.

## Design

### Module

New module `acl-admin/` (`casehub-platform-acl-admin`). Thin REST layer over
`AccessControlProvider` SPI — no domain logic.

Dependencies:
- `casehub-platform-api` (SPI)
- `quarkus-rest`, `quarkus-rest-jackson`, `quarkus-arc`

Test dependencies:
- `casehub-platform-acl-inmem` (in-memory backend)
- `casehub-platform-testing` (FixedCurrentPrincipal)
- `quarkus-junit`, `rest-assured`

No `quarkus:build` goal (library module).

### Resource

Single class: `AclResource @Path("/acl") @ApplicationScoped @RunOnVirtualThread`.

Constructor-injected `AccessControlProvider` + `CurrentPrincipal`.

### Endpoints

**Mutations (`@RolesAllowed("admin")`):**

| Method | Path | Input | SPI call |
|--------|------|-------|----------|
| `POST` | `/acl/grants` | body: `AclEntryInput` | `grant()` |
| `POST` | `/acl/grants/batch` | body: `List<AclEntryInput>` | `grantBatch()` |
| `DELETE` | `/acl/grants` | query: actorId, resourceId, action | `revoke()` |
| `DELETE` | `/acl/grants/batch` | body: `List<AclEntryInput>` | `revokeBatch()` |
| `DELETE` | `/acl/grants/all` | query: actorId, resourceId | `revokeAll()` |
| `POST` | `/acl/denies` | body: `AclEntryInput` | `deny()` |
| `POST` | `/acl/denies/batch` | body: `List<AclEntryInput>` | `denyBatch()` |
| `DELETE` | `/acl/denies` | query: actorId, resourceId, action | `removeDeny()` |
| `DELETE` | `/acl/denies/batch` | body: `List<AclEntryInput>` | `removeDenyBatch()` |
| `POST` | `/acl/parents` | body: `ParentInput` | `registerParent()` |

**Queries (any authenticated user — self-access guard):**

| Method | Path | Params | SPI call | Response |
|--------|------|--------|----------|----------|
| `GET` | `/acl/check` | query: actorId, resourceId, action | `canAccess()` | `AccessCheckResponse` |
| `GET` | `/acl/accessible` | query: actorId, resourceType, action, cursor?, limit? | `accessibleResources(AclQuery)` | `AclPage` |

Non-admin callers: `actorId` must equal `principal.actorId()`, otherwise 403.
Admin callers: any `actorId`.

### DTOs

```java
record AclEntryInput(String actorId, String resourceId, AclAction action, Instant expiresAt) {}
record ParentInput(String childResourceId, String parentResourceId) {}
record AccessCheckResponse(boolean allowed) {}
```

`AclEntryInput` maps to `AclEntryRequest` for batch operations via a trivial
constructor call — same fields, same order.

### Security

- Mutation endpoints: `@RolesAllowed("admin")` — only admin actors can create/remove
  grants and denies
- Query endpoints: any authenticated user, with self-access guard — non-admin callers
  can only query their own `actorId` (enforced by comparing `actorId` param against
  `principal.actorId()`)
- Tenant isolation: all SPI calls operate within `CurrentPrincipal.tenancyId()` —
  no cross-tenant access unless `isCrossTenantAdmin()`

### Error Handling

- Missing required params → 400 with `{"error": "<param> is required"}`
- Non-admin querying other actor → 403 with `{"error": "Access denied"}`
- Invalid `AclAction` → 400 (Jackson deserialization error)
- SPI exceptions → 500 (no special handling — SPI has no checked exceptions)

### Tests

`@QuarkusTest` with `acl-inmem` backend and `FixedCurrentPrincipal`. REST-assured
tests covering:

- Each mutation endpoint happy path (grant, revoke, deny, removeDeny, parents)
- Batch operations (grantBatch, revokeBatch, denyBatch, removeDenyBatch)
- `revokeAll` clears both grants and denies
- `GET /acl/check` returns correct boolean
- `GET /acl/accessible` returns paginated results
- `GET /acl/accessible` includes wildcard grants in results
- Self-access guard: non-admin querying own actorId succeeds
- Self-access guard: non-admin querying other actorId returns 403
- Missing required params return 400

### CLAUDE.md Updates

After implementation:
- New module entry in Modules table
- No package structure changes (DTOs are in the module, not platform-api)
- Parent pom.xml updated with new module

### Out of Scope

- OpenAPI annotations (add when API stabilises)
- Rate limiting
- Audit log REST endpoints (query the audit log — separate concern)
