# LabelRegistry SPI — Tenant-Scoped Label Tree Enumeration

**Issue:** casehubio/platform#694
**Branch:** issue-694-label-registry-spi
**Date:** 2026-11-02

## Problem

The platform has label consumption infrastructure — `Path` for hierarchy, `LabelPatternMatcher` for glob queries, `LabelRule`/`LabelAction` for entity mutations, `SubjectViewSpec` for filtered views — but no label definition infrastructure. There is no way to answer "what labels exist in this tree?" without scanning entities. This is O(entities), can't report empty branches, and isn't authoritative.

Multiple consumers need this: Pages (tree navigation, dropdowns), engine (case queues), work (WorkItem filters).

## Design

### Core Types (platform-api, `io.casehub.platform.api.label`)

**`LabelDescriptor`** — immutable record describing a node in the label tree:

```java
public record LabelDescriptor(
    String tenancyId,
    Path path,
    String displayName,
    int sortOrder,
    Map<String, String> metadata
) {
    // Compact constructor: requireNonNull on tenancyId + path,
    // default displayName from last path segment if null,
    // defensive copy on metadata
}
```

**`LabelRegistry`** — SPI for label tree enumeration:

```java
public interface LabelRegistry {
    void register(String tenancyId, LabelDescriptor descriptor);
    void deregister(String tenancyId, Path path);
    Optional<LabelDescriptor> resolve(String tenancyId, Path path);
    List<LabelDescriptor> children(String tenancyId, Path parentPath);
    List<LabelDescriptor> subtree(String tenancyId, Path rootPath);
}
```

**`LabelRegistered`** / **`LabelDeregistered`** — CDI event records, following the `EndpointRegistered` pattern.

### Tenant Resolution

Follows the established `PLATFORM_TENANT_ID` convention from `EndpointRegistry` and `DataSourceRegistry`:

- **`register(tenancyId, descriptor)`** — app installers pass `TenancyConstants.PLATFORM_TENANT_ID` for app-defined labels; tenant admins pass their own tenancyId.
- **`resolve(tenancyId, path)`** — tenant-first, platform-global fallback. Same two-step lookup as `InMemoryEndpointRegistry.resolve()`.
- **`children(tenancyId, parentPath)`** — merges platform-global children + tenant-specific children. Tenant wins on conflict (same path at both scopes).
- **`subtree(tenancyId, rootPath)`** — same merge, recursive.
- **`deregister(tenancyId, path)`** — exact match on `(tenancyId, path)`.

### Tree Structure

Implicit in paths. Registering `IT/Hardware/Laptops` implies `IT` and `IT/Hardware` exist as ancestors. The implementation auto-creates ancestor nodes with `displayName` derived from the last segment and `sortOrder` 0. Explicitly registering an ancestor overrides these defaults.

### Module Structure

Following the existing `-core` / CDI-wiring / inmem / jpa split:

| Module | Artifact | Purpose |
|--------|----------|---------|
| platform-api | (existing) | `LabelDescriptor`, `LabelRegistry`, `LabelRegistered`, `LabelDeregistered` |
| platform-core | (existing) | `NoOpLabelRegistry` — silent no-op `@DefaultBean` |
| label-inmem-core | `casehub-platform-label-inmem-core` | Framework-neutral `InMemoryLabelRegistry` POJO — ConcurrentHashMap, `Consumer<LabelRegistered>` for event bridge |
| label-inmem | `casehub-platform-label-inmem` | Quarkus CDI wiring — `@Alternative @Priority(100)`, `@Produces` |

JPA module deferred — inmem is sufficient for all current consumers.

### NoOp Pattern

`NoOpLabelRegistry` in `platform-core` — same pattern as `NoOpEndpointRegistry`:
- `register()` / `deregister()` — no-op
- `resolve()` — returns `Optional.empty()`
- `children()` / `subtree()` — returns `List.of()`
- Does NOT fire CDI events

### app_id

Does not appear in this SPI. Labels are tenant-scoped or platform-global. App-level scoping is a consumer concern via path prefixes (same as `SubjectViewSpec.scope`).

## Scope

### In scope
- `LabelDescriptor` record in platform-api
- `LabelRegistry` SPI in platform-api
- `LabelRegistered` / `LabelDeregistered` CDI event records in platform-api
- `NoOpLabelRegistry` in platform-core
- `InMemoryLabelRegistry` in label-inmem-core (framework-neutral POJO)
- Quarkus CDI wiring in label-inmem
- Tests for all implementations
- CLAUDE.md module table update

### Out of scope
- JPA implementation (deferred until a consumer needs durability)
- Spring auto-configuration (deferred)
- MCP domain / REST endpoints (deferred)
- Label migration tooling

## References

- `io.casehub.platform.api.endpoints.EndpointRegistry` — primary pattern source for tenant resolution
- `io.casehub.platform.api.identity.TenancyConstants` — `PLATFORM_TENANT_ID` sentinel
- `io.casehub.platform.api.path.Path` — hierarchical path record
- `io.casehub.platform.api.view.LabelPatternMatcher` — existing label pattern matching (unchanged)
- `io.casehub.platform.api.label.LabelAction` — existing label mutation (unchanged)
- `io.casehub.platform.endpoints.memory.InMemoryEndpointRegistry` — implementation pattern for inmem + ConcurrentHashMap + event callback
- `io.casehub.platform.endpoints.NoOpEndpointRegistry` — NoOp pattern
- casehubio/pages#600 — consumer issue that drove this design
