# Design Journal — issue-6-persistence-jpa

### 2026-05-22 · §Module Structure

New optional module `persistence-jpa/` (artifact `casehub-platform-persistence-jpa`) follows the same Jandex library module pattern as `config/`, `oidc/`, and `expression/`. Provides JPA-backed `PreferenceProvider` — scope-aware, hierarchy-resolved, current-only. Consumers add as compile dep and include `classpath:db/platform/migration` in `quarkus.flyway.locations`. Displaces `MockPreferenceProvider` automatically via `@ApplicationScoped` (no `@DefaultBean`). ADR-0006 records the decision to ignore `effectiveAt`.

### 2026-05-22 · §Preferences API

`JpaPreferenceProvider.resolve()` builds the ancestor scope list from the target `SettingsScope.scope()` path (shortest first), executes a single `IN`-clause query across all ancestor scopes, sorts results by ancestor list index (shallow = lower priority), and merges into a flat `Map<String, Object>` consumed by `MapPreferences`. Single-value preference rows use `sub_key = ""` (empty string); multi-value rows use the sub-key directly. Map keys follow `namespace.name` (single) and `namespace.name.subKey` (multi) — consistent with what `MapPreferences.get(PreferenceKey)` expects. `@Transactional(TxType.SUPPORTS)` — participates in caller's transaction or opens a read transaction if none is active.
