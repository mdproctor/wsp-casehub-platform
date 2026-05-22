# Design: casehub-platform-persistence-mongodb

**Issue:** casehubio/platform#7  
**Date:** 2026-05-22  
**Branch:** issue-007-persistence-mongodb

---

## Goal

MongoDB-backed `PreferenceProvider` for scope-aware, hierarchy-resolved preference
lookup. Drop-in replacement for `persistence-jpa` — adding the module to the classpath
activates it with no consumer changes required.

---

## CDI Activation

Follows the persistence-backend CDI priority ladder established in `casehub-work`
(to be formalised as a platform protocol via casehubio/parent#44):

| Tier | Annotation | Module |
|------|-----------|--------|
| Mock / no-op | `@DefaultBean` | `casehub-platform` |
| JPA (primary override) | `@ApplicationScoped` | `casehub-platform-persistence-jpa` |
| MongoDB (secondary override) | `@Alternative @Priority(1)` | `casehub-platform-persistence-mongodb` |

`@Alternative @Priority(1)` beats `@ApplicationScoped` in CDI ArC. MongoDB wins
automatically when co-deployed with the JPA module; consumers add one `<dependency>`
to activate.

---

## Document Model

**Collection:** `platform_preferences`

| Field | BSON type | Notes |
|-------|-----------|-------|
| `_id` | String | Natural compound key: `"{scope}\|{namespace}\|{name}\|{subKey}"` |
| `scope` | String | Path value string — e.g. `"casehubio/devtown"`. Never null. |
| `namespace` | String | e.g. `"devtown"` |
| `name` | String | e.g. `"humanApprovalThreshold"` |
| `subKey` | String | `""` for single-value; non-empty for multi-value (parity with JPA) |
| `value` | String | Raw string value; `key.parse(raw)` converts at call site |

**Uniqueness:** enforced by `_id` at the BSON level — no separate unique index needed.

**Index:** compound index on `scope` to serve the ancestor `$in` query efficiently.

**Note on null scope:** the issue draft mentioned "null = unscoped" but this is not
implemented. The JPA schema has `scope NOT NULL` and uses `Path.root().value()` for
global preferences. Alignment with JPA wins — null scope is a divergence with no
benefit.

**Write path:** `preferences-editor` (#8) will write documents. `persistOrUpdate()`
on `_id` gives trivially correct upsert semantics — storing the compound key as `_id`
was chosen specifically to enable this without a separate find-then-replace.

---

## Scope Resolution Algorithm

Mirrors `JpaPreferenceProvider` exactly:

1. Walk the `Path` hierarchy from root to the requested scope, collecting ancestor
   strings shortest-first (root → target).
2. Query: `{ scope: { $in: ancestors } }` — retrieves all matching rows across the
   entire ancestor chain in one round-trip.
3. Sort results by ancestor depth (index in the ancestors list), root first.
4. Fold into a `Map<String, Object>` — later entries (deeper scopes) overwrite earlier
   ones, giving child-overrides-parent semantics.
5. Wrap in `MapPreferences` and return.

`effectiveAt` from `SettingsScope` is intentionally ignored — all documents are
treated as current. Time-travel requires a versioned write model (issue #8).

---

## Classes

### `MongoPreferenceDocument` (`PanacheMongoEntityBase`)

Panache entity bound to `platform_preferences`. Responsible for:
- `_id` construction from the four-field compound key
- Static `findByScopes(List<String> scopes)` — the one query method used by the provider

### `MongoPreferenceProvider` (`@ApplicationScoped @Alternative @Priority(1)`)

Implements `PreferenceProvider`. Responsible for:
- Building the ancestor list from the requested `Path`
- Calling `MongoPreferenceDocument.findByScopes()`
- Sorting and merging into `MapPreferences`

No other public surface. Read-only from the SPI perspective — Panache write methods
exist on the document class but are not part of this module's contract.

---

## Maven Module

**Artifact:** `casehub-platform-persistence-mongodb`  
**Folder:** `persistence-mongodb/`  
**Parent:** `casehub-platform-parent`

Dependencies:

| Artifact | Scope | Reason |
|----------|-------|--------|
| `casehub-platform-api` | compile | SPI types |
| `quarkus-mongodb-panache` | compile | Panache document + query |
| `quarkus-arc` | compile | CDI |
| `casehub-platform` | test | Mock beans for CDI context |
| `quarkus-junit5` | test | `@QuarkusTest` |

No Flyway. No JDBC driver. MongoDB creates the collection on first write.

Jandex plugin required (per `optional-module-pattern.md`) so CDI beans are discovered
when consumed as a JAR.

---

## Tests

`@QuarkusTest` with Quarkus Dev Services (Testcontainers) — real MongoDB instance, no
emulation. Same six contract scenarios as `JpaPreferenceProviderTest`:

| Test | Verifies |
|------|---------|
| `resolve_returns_value_stored_for_exact_scope` | Basic read |
| `resolve_inherits_value_from_parent_scope` | Hierarchy walk |
| `resolve_child_scope_overrides_parent` | Child wins |
| `resolve_deeper_child_overrides_grandparent` | Multi-level override |
| `resolve_returns_key_default_when_no_rows_match` | Empty → key default |
| `resolve_ignores_sibling_scope` | No cross-contamination |

`@BeforeEach` deletes all documents. Tests are fully isolated.

---

## Protocol Hygiene

Cross-cutting issues filed this session:

- `casehubio/parent#44` — formalise `persistence-backend-cdi-priority.md` protocol;
  update `platform-spi-contract.md` Rule 2; add row to PLATFORM.md
- `casehubio/work#217` — link WorkItemStore/AuditEntryStore Javadoc to new protocol
