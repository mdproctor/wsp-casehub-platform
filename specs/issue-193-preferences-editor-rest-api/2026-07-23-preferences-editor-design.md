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
- **File writer**: not needed — config YAML is edited by hand in a text editor.

## Design

### 1. SPI: `PreferenceStore` in platform-api

Blocking write SPI alongside the existing read-only `PreferenceProvider`.

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
public record PreferenceRecord(String tenancyId, String scope, String namespace,
                                String name, String subKey, String value) {}
```

```java
public record PreferenceQuery(String tenancyId, Path scope, String namespace) {}
```

`set()` is an upsert — insert or update by `(tenancyId, scope, namespace, name, subKey)`.

`deleteAll()` clears all preferences for a namespace at a given scope.

Default no-op `@DefaultBean` in `platform/`: `set()`/`delete()`/`deleteAll()` are silent, `list()` returns empty.

**Naming:** The SPI return type is `PreferenceRecord` (in platform-api) to avoid collision with the JPA entity `PreferenceEntry` in `persistence-jpa/`. Backend implementations convert between their internal entities and `PreferenceRecord`.

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

    public static SettingsScope of(String tenancyId, String... segments) {
        return new SettingsScope(tenancyId, Path.of(segments), Instant.now());
    }

    public static SettingsScope root(String tenancyId) {
        return new SettingsScope(tenancyId, Path.root(), Instant.now());
    }
}
```

Breaking change to all callers. Ripple across platform and consuming repos.

Storage impact:
- **JPA**: `platform_preference` table gains `tenancy_id VARCHAR(100) NOT NULL` column (Flyway V2). Unique constraint becomes `(tenancy_id, scope, namespace, pref_name, sub_key)`.
- **MongoDB**: document gains `tenancyId` field, compound index updated.
- **Config files**: tenant-free by nature. Use `TenancyConstants.DEFAULT_TENANT_ID` as the sentinel.

Both `PreferenceProvider.resolve()` and `PreferenceStore` operations filter by tenancyId.

### 3. Backend implementations

**JPA (`persistence-jpa/`)**

`JpaPreferenceStore @ApplicationScoped` alongside the existing `JpaPreferenceProvider`. Reuses the same `PreferenceEntry` JPA entity (which gains `tenancyId`).

- `set()` → `INSERT ... ON CONFLICT (tenancy_id, scope, namespace, pref_name, sub_key) DO UPDATE`
- `delete()` → delete by composite key
- `list()` → query by (tenancyId, scope, namespace)
- `deleteAll()` → bulk delete by (tenancyId, scope, namespace)

**MongoDB (`persistence-mongodb/`)**

`MongoPreferenceStore @Alternative @Priority(1)` — same CDI priority ladder as `MongoPreferenceProvider`. Same operations against the Mongo document model.

**Default no-op (`platform/`)**

`NoOpPreferenceStore @DefaultBean` — silent no-op, consistent with other optional SPIs.

### 4. REST module (`preferences-editor/`)

New module. `@Path("/preferences")` JAX-RS resource. Depends on `PreferenceStore` SPI only.

```
PUT    /preferences/{scope}                     — set a preference (upsert)
DELETE /preferences/{scope}/{namespace}/{name}   — delete a single preference
GET    /preferences/{scope}                     — list preferences at a scope
DELETE /preferences/{scope}/{namespace}          — delete all in a namespace
```

`{scope}` is the Path encoded as a URL path segment (e.g. `casehubio/devtown`). TenancyId comes from `CurrentPrincipal`.

Request body for PUT:
```json
{
  "namespace": "devtown",
  "name": "humanApprovalThreshold",
  "subKey": "",
  "value": "0.85"
}
```

No pagination — preferences at a single scope are bounded (tens, not thousands).

Authorization: `CurrentPrincipal` enforces tenant isolation. No role-based access control beyond tenant membership for now.

## Module map

| Module | What changes |
|--------|-------------|
| `platform-api/` | Add `PreferenceStore` SPI, `PreferenceRecord` record, `PreferenceQuery` record. Add `tenancyId` to `SettingsScope`. |
| `platform/` | Add `NoOpPreferenceStore @DefaultBean`. Update `MockPreferenceProvider` for new `SettingsScope`. |
| `persistence-jpa/` | Add `JpaPreferenceStore`. Add `tenancyId` to JPA entity. Flyway V2 migration. Update `JpaPreferenceProvider` to filter by tenancyId. |
| `persistence-mongodb/` | Add `MongoPreferenceStore`. Add `tenancyId` to Mongo document. Update `MongoPreferenceProvider` to filter by tenancyId. |
| `config/` | Update `ConfigFilePreferenceProvider` to use `TenancyConstants.DEFAULT_TENANT_ID` for file-based preferences. |
| `preferences-editor/` (new) | REST resource, pom.xml, module registration in parent pom. |
| `testing/` | Update any test fixtures that construct `SettingsScope`. |

## Out of scope

- Time-travel / versioned preferences (`effectiveAt` stays unused)
- File writer backend (config YAML is hand-edited)
- Role-based access control (admin-only writes)
- Pagination on list endpoint
- UI component (lives in casehubio/blocks-ui#92)
