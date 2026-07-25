# Design: Retire Hibernate Reactive from ACL (#202)

**Issue:** casehubio/platform#202
**Date:** 2026-07-25
**Status:** Approved

## Context

Issue #384 retired the reactive tier across the platform repo — deleting
dual-stack SPIs, rewriting JPA modules to standard Hibernate ORM, and
converting REST endpoints to `@RunOnVirtualThread`. The ACL subsystem was
missed: `AccessControlProvider` still returns `CompletionStage`, `acl-jpa`
still uses Hibernate Reactive Panache, and `acl-inmem` wraps synchronous
logic in `CompletableFuture.completedFuture()`.

Cross-repo caller analysis (ledger, engine, qhorus, neocortex) found zero
references to `AccessControlProvider`. The breaking change is fully contained
within the platform repo.

## Changes

### SPI (`platform-api/`)

`AccessControlProvider` — convert all 6 methods from `CompletionStage<T>` to
blocking returns:

| Before | After |
|--------|-------|
| `CompletionStage<Boolean> canAccess(...)` | `boolean canAccess(...)` |
| `CompletionStage<Void> grant(...)` | `void grant(...)` |
| `CompletionStage<Void> revoke(...)` | `void revoke(...)` |
| `CompletionStage<Void> revokeAll(...)` | `void revokeAll(...)` |
| `CompletionStage<Void> registerParent(...)` | `void registerParent(...)` |
| `CompletionStage<List<String>> accessibleResources(...)` | `List<String> accessibleResources(...)` |

Default implementations return direct values (`true`, nothing, `List.of()`).
Remove `CompletableFuture` and `CompletionStage` imports.

### @DefaultBean (`platform/`)

`NoOpAccessControlProvider` — no change, inherits defaults.

### In-memory adapter (`acl-inmem/`)

`InMemoryAccessControlProvider` — strip all `CompletableFuture.completedFuture()`
wrappers. Return values directly. Remove `CompletableFuture`/`CompletionStage`
imports.

### JPA adapter (`acl-jpa/`)

**pom.xml:**
- `quarkus-hibernate-reactive-panache` → `quarkus-hibernate-orm-panache`
- Remove `quarkus-reactive-pg-client`
- Remove `quarkus-test-vertx` (test scope)

**Entities** (`AclEntryEntity`, `AclAuditLogEntity`, `ResourceParentEntity`):
- Change import `io.quarkus.hibernate.reactive.panache.PanacheEntityBase`
  → `io.quarkus.hibernate.orm.panache.PanacheEntityBase`
- No annotation, field, or schema changes

**`JpaAccessControlProvider`:**
- Replace Uni chains with direct Panache blocking API calls
- Add `@Transactional` on mutation methods (`grant`, `revoke`, `revokeAll`, `registerParent`)
- `canAccessWithCandidates` becomes a plain recursive boolean method
- Remove `Vertx` injection, `execute()` helper
- Remove all Vert.x/Mutiny imports (`Uni`, `Vertx`, `VertxContext`,
  `VertxContextSafetyToggle`, `Panache`)

### Tests

**`AccessControlProviderContractTest`:** Remove `await(CompletionStage)` helper.
Call provider methods directly.

**`AccessControlProviderSpiTest`:** Remove `.toCompletableFuture().join()` calls.

**`JpaAccessControlProviderTest`:** Remove `reactive()` helper and Vert.x imports.
Use `@TestTransaction` for `clearState`. Direct entity operations for
setup/assertions (standard Panache blocking API in test context).

**`InMemoryAccessControlProviderTest`:** No change beyond contract test signature
update (inherits).

**`MockBeansTest`:** Remove `.toCompletableFuture().join()` on `canAccess` call.

### CLAUDE.md

Remove stale `ReactiveCaseMemoryStore (Mutiny SPI)` from the package structure
(removed by #384, never cleaned from docs).

## Non-goals

- No Flyway migrations — schema is unchanged
- No REST endpoint changes — ACL has no REST layer in platform
- No cross-repo propagation — zero consumers
