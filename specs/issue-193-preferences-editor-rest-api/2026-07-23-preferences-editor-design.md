# Preferences Editor — Design Spec

**Issue:** casehubio/platform#193
**Date:** 2026-07-23
**Status:** Approved

## Problem

`PreferenceProvider` is a read-only SPI. No write surface exists. Preferences can only be seeded via YAML config files or direct database insertion. There is no REST API, no write SPI, and no tenant isolation on the preference model.

## Decisions

- **Tenancy**: add `tenancyId` to `SettingsScope` — explicit on the contract, consistent with other platform SPIs. Breaking change; pre-release, acceptable cost.
- **Versioning**: out of scope. Simple upsert, no time-travel. `effectiveAt` remains unused.
- **Backends**: JPA and MongoDB writers only. Config files are hand-edited, not API-managed.
- **SPI pattern**: `PreferenceStore` in platform-api, following the standard persistence SPI pattern.
- **Execution model**: blocking method signatures, virtual threads end-to-end. One virtual thread per request flows through REST → store → JDBC. No reactive/Mutiny SPIs.
- **File writer**: not needed — config YAML is edited by hand in a text editor. Tracking issue to be filed against casehubio/platform for future consideration.
- **Write validation**: intentionally omitted. The write path (`PreferenceStore`) is decoupled from the typed preference system (`PreferenceKey<T>`). Invalid values are caught at read time by `PreferenceProvider.resolve()`. This avoids coupling the editor to preference key definitions scattered across consuming repos, preserves forward compatibility for new keys, and allows administrative overrides (e.g. expression values like `${env:THRESHOLD}`).
- **Tenancy on write path**: flat parameters `(String tenancyId, Path scope, ...)` on `PreferenceStore`, not `SettingsScope`. Read and write paths have different context needs — `SettingsScope` carries `effectiveAt` which is meaningless for writes. Flat parameters are consistent with `NotificationPreferenceStore`.

## Design

### 1. SPI: `PreferenceStore` in platform-api

Blocking write SPI alongside the existing read-only `PreferenceProvider`.

Backend implementations MUST inject `CurrentPrincipal` and call `PreferencePermissions.assertTenant()` before every write operation, consistent with the `MemoryPermissions.assertTenant()` pattern on `CaseMemoryStore` adapters (protocol PP-20260520-439daf: "Tenancy filtering is unconditional").

```java
public interface PreferenceStore {
    void set(String tenancyId, Path scope, String namespace, String name, String subKey, String value);
    void delete(String tenancyId, Path scope, String namespace, String name, String subKey);
    List<PreferenceRecord> list(PreferenceQuery query);
    void deleteAll(String tenancyId, Path scope, String namespace);
}
```

Supporting types in platform-api:

```java
public record PreferenceRecord(String tenancyId, Path scope, String namespace,
                                String name, String subKey, String value) {}
```

```java
public record PreferenceQuery(String tenancyId, Path scope, String namespace) {}
```

`set()` is an upsert — insert or update by `(tenancyId, scope, namespace, name, subKey)`.

`deleteAll()` clears all preferences for a namespace at a given scope. Exact scope match only — does not cascade to descendant scopes. `deleteAll(tenant, Path.of("casehubio"), "devtown")` deletes only preferences at scope `casehubio`, not at `casehubio/devtown/pr-review`.

Default no-op `@DefaultBean` in `platform/`: `set()`/`delete()`/`deleteAll()` are silent, `list()` returns empty.

**Naming:** The SPI return type is `PreferenceRecord` (in platform-api) to avoid collision with the JPA entity `PreferenceEntry` in `persistence-jpa/`. Backend implementations convert between their internal entities and `PreferenceRecord`.

**Tenant assertion utility** in platform-api:

```java
public final class PreferencePermissions {
    private PreferencePermissions() {}

    public static void assertTenant(String tenancyId, CurrentPrincipal principal) {
        if (!principal.tenancyId().equals(tenancyId))
            throw new SecurityException(
                "Tenant ID mismatch: claimed=" + tenancyId
                + ", authenticated=" + principal.tenancyId());
    }
}
```

Consistent with `EndpointPermissions.assertTenant()` and `MemoryPermissions.assertTenant()`. Backend implementations inject `CurrentPrincipal` and call this before every write operation.

**CDI event** fired after successful writes:

```java
public record PreferenceChanged(String tenancyId, Path scope, String namespace) {}
```

Backend implementations fire `Event<PreferenceChanged>.fireAsync()` after successful `set()`, `delete()`, and `deleteAll()`. Consistent with `EndpointRegistered` pattern (`InMemoryEndpointRegistry.register()` uses `fireAsync()`, `CamelStreamProcessor` observes via `@ObservesAsync`). Asynchronous dispatch is required because synchronous `fire()` inside a `@Transactional` method executes observers before the transaction commits — a rollback would leave observers reacting to a phantom change. `fireAsync()` decouples the observer from the transaction lifecycle. Enables future cache invalidation and reactive preference reload. The no-op `@DefaultBean` MUST NOT fire this event — consistent with `NoOpEndpointRegistry` not firing `EndpointRegistered`.

### 2. `SettingsScope` gains tenancyId

```java
public record SettingsScope(String tenancyId, Path scope, Instant effectiveAt) {
    public SettingsScope {
        Objects.requireNonNull(tenancyId, "tenancyId must not be null");
        Objects.requireNonNull(scope, "scope must not be null");
        Objects.requireNonNull(effectiveAt, "effectiveAt must not be null");
    }

    public static SettingsScope of(String tenancyId, Path scope) {
        return new SettingsScope(tenancyId, scope, Instant.now());
    }

    public static SettingsScope root(String tenancyId) {
        return new SettingsScope(tenancyId, Path.root(), Instant.now());
    }
}
```

No varargs `of(String tenancyId, String... segments)` factory. The previous `of(String... segments)` cannot safely coexist with `of(String tenancyId, String... segments)` — Java resolves `of("casehubio", "devtown")` against both signatures without a compilation error, silently reinterpreting the first segment as tenancyId and reducing the path by one segment. Removing the varargs overload forces every call site to use `Path.of(...)` explicitly, producing a compile-time break instead of a silent semantic change.

Breaking change to all callers. Ripple across platform and consuming repos.

Storage impact:
- **JPA**: `platform_preference` table gains `tenancy_id VARCHAR(100) NOT NULL` column (Flyway V2). Multi-step migration for compatibility with existing data:
  1. `ALTER TABLE platform_preference ADD COLUMN tenancy_id VARCHAR(100)` (nullable)
  2. `UPDATE platform_preference SET tenancy_id = '278776f9-e1b0-46fb-9032-8bddebdcf9ce'` (backfill with `TenancyConstants.DEFAULT_TENANT_ID`)
  3. `ALTER TABLE platform_preference ALTER COLUMN tenancy_id SET NOT NULL`
  4. `ALTER TABLE platform_preference DROP CONSTRAINT uq_platform_preference`
  5. `ALTER TABLE platform_preference ADD CONSTRAINT uq_platform_preference UNIQUE (tenancy_id, scope, namespace, pref_name, sub_key)`
- **MongoDB**: document gains `tenancyId` field, compound index updated.
- **Config files**: tenant-free by nature. Use `TenancyConstants.DEFAULT_TENANT_ID` as the sentinel.

Both `PreferenceProvider.resolve()` and `PreferenceStore` operations filter by tenancyId.

### 3. Backend implementations

**JPA (`persistence-jpa/`)**

`JpaPreferenceStore @ApplicationScoped` alongside the existing `JpaPreferenceProvider`. Reuses the same `PreferenceEntry` JPA entity (which gains `tenancyId`). Injects `CurrentPrincipal` and calls `PreferencePermissions.assertTenant()` before every write. Fires `Event<PreferenceChanged>.fireAsync()` after successful writes.

- `set()` → `INSERT ... ON CONFLICT (tenancy_id, scope, namespace, pref_name, sub_key) DO UPDATE`
- `delete()` → delete by composite key
- `list()` → query by (tenancyId, scope, namespace)
- `deleteAll()` → bulk delete by (tenancyId, scope, namespace)

**MongoDB (`persistence-mongodb/`)**

`MongoPreferenceStore @Alternative @Priority(1)` — same CDI priority ladder as `MongoPreferenceProvider`. Same operations against the Mongo document model. Same tenant assertion and event pattern.

The existing `MongoPreferenceDocument.compoundId()` (`scope|namespace|name|subKey`) must be updated to include `tenancyId` as the leading segment: `tenancyId|scope|namespace|name|subKey`. The `_id` IS the uniqueness mechanism in MongoDB (no separate unique index); without `tenancyId` in the compound key, two tenants storing the same preference would collide on `_id`, silently overwriting across tenant boundaries.

**Default no-op (`platform/`)**

`NoOpPreferenceStore @DefaultBean` — silent no-op, consistent with other optional SPIs. MUST NOT fire `PreferenceChanged`.

### 4. REST module (`preferences-editor/`)

New module. `@Path("/preferences")` JAX-RS resource. Depends on both `PreferenceStore` SPI (for CRUD) and `PreferenceProvider` SPI (for resolved-values view).

Scope is passed as a `@QueryParam`, not embedded in the URL path. Hierarchical scope values (e.g. `casehubio/devtown`) contain `/` which conflicts with JAX-RS path segment parsing — `@PathParam("scope")` only captures a single segment, and regex capture `{scope:.+}` creates structural ambiguity with downstream path parameters (e.g. `/preferences/casehubio/devtown/namespace` is unparseable). Query parameters eliminate this entirely.

```
PUT    /preferences?scope=casehubio/devtown                                       — set a preference (upsert)
DELETE /preferences?scope=X&namespace=ns&name=key[&subKey=sk]                     — delete a single preference
DELETE /preferences/by-namespace?scope=casehubio/devtown&namespace=devtown         — delete all in a namespace
GET    /preferences?scope=casehubio/devtown                                       — list raw records at a scope
GET    /preferences/resolved?scope=casehubio/devtown                              — resolved/effective values
```

Single-delete and namespace-delete are separate endpoints to prevent accidental bulk deletion. `DELETE /preferences` requires `name` (returns 400 without it) — an omitted `name` parameter cannot silently escalate a surgical delete into a namespace wipe. `subKey` is optional, defaulting to `""` (the convention for single-value preferences).

TenancyId comes from `CurrentPrincipal.tenancyId()`. No cross-tenant override — consistent with `EndpointPermissions.assertTenant()` strict equality check. Cross-tenant admins operate within their own tenancyId (`PLATFORM_TENANT_ID`). A cross-tenant admin write API (with explicit target tenancyId and `isCrossTenantAdmin()` guard) is out of scope.

Request body for PUT:
```json
{
  "namespace": "devtown",
  "name": "humanApprovalThreshold",
  "subKey": "",
  "value": "0.85"
}
```

The `GET /preferences/resolved` endpoint returns a `ResolvedPreferencesResponse` DTO:

```java
public record ResolvedPreferencesResponse(String scope, Map<String, String> values) {}
```

```json
{
  "scope": "casehubio/devtown",
  "values": {
    "devtown.humanApprovalThreshold": "0.85",
    "devtown.maxRetries": "3"
  }
}
```

Values are always strings — `Preferences.asMap()` returns the raw stored strings; type conversion happens at `PreferenceKey<T>.parse()` call sites, not at the REST layer. The wrapper object (vs a bare map) allows future extension (e.g. adding `inheritedFrom` metadata per key) without breaking the response contract.

The endpoint resolves via `PreferenceProvider.resolve(SettingsScope.of(tenancyId, scope))` and serializes `Preferences.asMap()` into the `values` field. This lets the editor UI show both what is explicitly set at this scope (raw records from `GET /preferences`) and the effective values after inheritance (from `GET /preferences/resolved`).

No pagination — preferences at a single scope are bounded (tens, not thousands).

Authorization: `CurrentPrincipal` enforces tenant isolation. No role-based access control beyond tenant membership for now.

## Module map

| Module | What changes | Layer |
|--------|-------------|-------|
| `platform-api/` | Add `PreferenceStore` SPI, `PreferenceRecord` record, `PreferenceQuery` record, `PreferencePermissions` utility, `PreferenceChanged` event. Add `tenancyId` to `SettingsScope`. | L1 |
| `platform/` | Add `NoOpPreferenceStore @DefaultBean`. Update `MockPreferenceProvider` for new `SettingsScope`. | L2 |
| `persistence-jpa/` | Add `JpaPreferenceStore`. Add `tenancyId` to JPA entity. Flyway V2 multi-step migration. Update `JpaPreferenceProvider` to filter by tenancyId. | L5 |
| `persistence-mongodb/` | Add `MongoPreferenceStore`. Add `tenancyId` to Mongo document. Update `MongoPreferenceProvider` to filter by tenancyId. | L5 |
| `config/` | Update `ConfigFilePreferenceProvider` to use `TenancyConstants.DEFAULT_TENANT_ID` for file-based preferences. | L4 |
| `preferences-editor/` (new) | REST resource, pom.xml, module registration in parent pom. Depends on both `PreferenceStore` and `PreferenceProvider`. | L4 |
| `testing/` | Update any test fixtures that construct `SettingsScope`. | L3 |

Layer placement: `preferences-editor/` is placed at L4 (Platform Extensions) as an opt-in extension module activated by classpath presence. L4's current description ("opt-in non-mock implementations") should be broadened to include REST extension surfaces when ARC42STORIES is updated — `notifications/` and `subscriptions/` are structurally identical REST surface modules that also need layer placement.

## Out of scope

- Time-travel / versioned preferences (`effectiveAt` stays unused)
- File writer backend (config YAML is hand-edited) — tracking issue to be filed against casehubio/platform
- Role-based access control (admin-only writes)
- Pagination on list endpoint
- Cross-tenant admin write API
- UI component (lives in casehubio/blocks-ui#92)
- Write-time validation against `PreferenceKey<T>` parsers
