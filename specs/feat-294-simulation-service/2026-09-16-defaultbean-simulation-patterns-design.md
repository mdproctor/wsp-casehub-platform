# DefaultBean Simulation Patterns Design Spec

**Branch:** issue-294-simulation-service
**Issue:** casehubio/platform#321
**Date:** 2026-09-16

## Overview

Two changes: (1) a generator enhancement that removes the abstract/default
method distinction, enabling simulation of pure-default interfaces like
`AccessControlProvider` (D42), and (2) a new `platform-simulation-core`
module that generates simulation decorators for 11 platform-api SPIs via
the listing file mechanism (D38).

No changes to NoOp implementations — the generated `@Decorator` wraps
whatever bean CDI resolves (NoOp or real), intercepting when a simulation
strategy is configured and passing through otherwise (D6).

This issue does NOT introduce a `SimulationAwareDefaultBean` base class
(the original issue description predates D4/D6). The decorator pattern
established in D4 already handles the upgrade path — NoOps remain
zero-dependency, zero-logic, trivially constructable.

## Generator enhancement

### Problem

`SimulationDecoratorProcessor` uses `Modifier.isAbstract(method.flags())`
to decide which methods get simulation logic. Default methods get plain
delegation. This excludes pure-default interfaces like
`AccessControlProvider` (14 default methods, zero abstract).

### Change

Remove the abstract/default distinction from the generator. All interface
methods get simulation interception logic. The config layer
(`casehub.simulation.<spi>.<method>.strategy=...`) is the real activation
gate — unconfigured methods passthrough regardless (one
`ConcurrentHashMap` lookup returning `Optional.empty()`).

In `SimulationDecoratorProcessor.generateDecoratorSource()`:

```java
// Before (lines 159-166):
if (java.lang.reflect.Modifier.isAbstract(method.flags())) {
    generateSimulatedMethod(sb, method, spiName);
} else {
    generateDelegatingMethod(sb, method);
}

// After:
generateSimulatedMethod(sb, method, spiName);
```

The same change applies to `RestClientSimulationProcessor` for
consistency.

### Impact on existing decorators

- `SimulatedCaseMemoryStore` (memory-simulation-core): default methods
  like `capabilities()`, `storeAll()`, `scan()` now get simulation logic.
  No behavioral change — these methods passthrough unless a strategy is
  explicitly configured for them.
- All future decorators: benefit from full method coverage automatically.

## Module: `platform-simulation-core`

A new module containing:

- `src/main/resources/META-INF/simulation-eligible.txt` — lists 11 SPIs
- Generated sources (compile-time) — 11 `@Decorator` classes in
  `io.casehub.platform.simulation.generated`
- Integration test — one `@QuarkusTest` verifying CDI ordering (D40)

Dependencies:
- `casehub-platform-api` (compile) — SPI interfaces in Jandex index
- `casehub-platform-simulation-api` (compile) — SimulationStrategy,
  SimulationCorpus
- `casehub-platform-simulation-core` (compile) — SimulationRuntime
- `casehub-platform-simulation-generator` (provided) — APT processor
- `casehub-platform` (test) — DefaultBeans, NoOps for integration test
- `casehub-platform-simulation-config` (test) — config binding for test
- `casehub-platform-simulation-inmem` (test) — in-memory corpus for test

No `quarkus:build` goal. Jandex indexed.

### CDI priority ordering

The generated decorators sit at `@Priority(APPLICATION + 200)`,
consistent with all other simulation decorators. The CDI resolution
chain:

```
@Decorator (APPLICATION + 200) — simulation decorator
  wraps →
@Alternative @Priority(N) — real implementation (if present)
  OR
@DefaultBean — NoOp (if no real impl)
```

The decorator doesn't know or care whether it wraps a NoOp or a real
implementation. When `simulation.strategyFor(qualifiedName)` returns a
strategy and `canResolve(input)` is true, the strategy provides the
response. Otherwise, the delegate is called (passthrough or capture).

## SPI listing

| SPI | FQCN | Qualified name prefix | Simulatable methods | Category |
|-----|------|-----------------------|--------------------|----------|
| AccessControlProvider | `io.casehub.platform.api.acl.AccessControlProvider` | access-control-provider | canAccess, grant, revoke, revokeAll, registerParent, accessibleResources, grantBatch, revokeBatch, deny, removeDeny, denyBatch, removeDenyBatch, accessibleResourcesIncludingInherited, canAccessAny | Silent no-op (all default) |
| DataSourceRegistry | `io.casehub.platform.api.datasource.DataSourceRegistry` | data-source-registry | register, resolve, resolveSource, discover, deregister, update | Silent no-op |
| SubscriptionStore | `io.casehub.platform.api.subscription.SubscriptionStore` | subscription-store | store, findById, find, update, delete, findAllEnabled | Silent no-op |
| NotificationStore | `io.casehub.platform.api.notification.NotificationStore` | notification-store | store, storeAll, find, unreadCount, markRead, dismiss, markAllRead | Silent no-op |
| EndpointRegistry | `io.casehub.platform.api.endpoints.EndpointRegistry` | endpoint-registry | register, resolve, discover, deregister | Silent no-op |
| ExpressionEngineRegistry | `io.casehub.platform.api.expression.ExpressionEngineRegistry` | expression-engine-registry | register, resolve, compile, validate | Silent no-op |
| DocumentSigningService | `io.casehub.platform.api.signing.document.DocumentSigningService` | document-signing-service | signPdf, signDetached | Silent no-op |
| CredentialResolver | `io.casehub.platform.api.credentials.CredentialResolver` | credential-resolver | resolve | Config-backed |
| ModelRegistry | `io.casehub.platform.api.model.ModelRegistry` | model-registry | resolveById, query, all | NoOp fallback |
| PreferenceProvider | `io.casehub.platform.api.preferences.PreferenceProvider` | preference-provider | resolve | Config-driven mock |
| CurrentPrincipal | `io.casehub.platform.api.identity.CurrentPrincipal` | current-principal | actorId, groups, tenancyId, isCrossTenantAdmin | Config-driven mock |

PolicyEnforcer is excluded — it's a concrete class, not an SPI interface
(D39).

## Testing

One `@QuarkusTest` integration test (D40) that:

1. Configures `access-control-provider.canAccess.strategy=sequential`
   via `@TestProfile`
2. Seeds the in-memory corpus with a known `canAccess` response
3. Injects `AccessControlProvider` (CDI resolves the decorator wrapping
   the NoOp)
4. Calls `canAccess()` and asserts the corpus response is returned
5. Verifies passthrough: unconfigured methods delegate to the NoOp

This proves the CDI ordering works for `@Decorator` wrapping
`@DefaultBean`, including for pure-default interfaces (D42). The other
10 SPIs use identical generated code — the APT's unit tests in
`simulation-generator` already cover code generation correctness.

Additionally, update `SimulationDecoratorProcessorTest` to verify that
default methods now get simulation logic (regression test for D42).

## Guide update

Add a "Platform SPIs" section to `docs/guides/simulation-guide.md` (D41)
with:

- Table of available SPIs and their qualified name prefixes
- Example config for simulating a representative SPI
- Reference to the integration test as a copy-paste starting point
- Pointer to #332 (verification API) for testing assertions

## Deliverables

1. Generator enhancement — remove abstract/default distinction in
   `SimulationDecoratorProcessor` and `RestClientSimulationProcessor`
2. Generator test update — verify default methods get simulation logic
3. New `platform-simulation-core/` module with listing file and pom.xml
4. One `@QuarkusTest` integration test
5. "Platform SPIs" section in simulation guide
6. CLAUDE.md module entry update

## References

- [D4] Annotation-driven generated @Decorator for capture and simulation
- [D6] Generated @Decorator activates simulation — NoOps remain untouched
- [D38] Single platform-simulation-core module for all platform-api SPIs
- [D39] PolicyEnforcer excluded — not an SPI interface
- [D40] Single integration test for CDI ordering verification
- [D41] Platform SPI simulation section in the existing simulation guide
- [D42] Intercept all interface methods — remove abstract/default distinction
- SimulationDecoratorProcessor.java lines 159-166 — abstract/default branch
- RestClientSimulationProcessor.java — same pattern to update
- AccessControlProvider.java — pure-default interface (14 methods)
- memory-simulation-core/src/main/resources/META-INF/simulation-eligible.txt — precedent
- DefaultBeans.java — all platform @DefaultBean NoOps
- Issue #332 — simulation verification API (testing ergonomics)
