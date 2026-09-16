# DefaultBean Simulation Patterns Design Spec

**Branch:** issue-294-simulation-service
**Issue:** casehubio/platform#321
**Date:** 2026-09-16

## Overview

A single `platform-simulation-core` module that generates simulation
decorators for 11 platform-api SPIs via the existing
`SimulationDecoratorProcessor` listing file mechanism. No changes to the
NoOp implementations — the generated `@Decorator` wraps whatever bean CDI
resolves (NoOp or real), intercepting when a simulation strategy is
configured and passing through otherwise (D6).

This issue does NOT introduce a `SimulationAwareDefaultBean` base class
(the original issue description predates D4/D6). The decorator pattern
established in D4 already handles the upgrade path — NoOps remain
zero-dependency, zero-logic, trivially constructable.

## Architecture

### How it works

The `SimulationDecoratorProcessor` APT already supports two discovery
paths (D4):

1. `@SimulationEligible` annotation — for SPIs that can depend on
   simulation-api
2. `META-INF/simulation-eligible.txt` — for SPIs that cannot

All 11 platform-api SPIs use path 2 (listing file), since platform-api
is a zero-dependency module that cannot depend on simulation-api (D2).
This follows the `memory-simulation-core` precedent where
`CaseMemoryStore` (in neocortex-memory-api) uses the same mechanism.

### Module: `platform-simulation-core`

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

Placeholder — exact method names pending verification.

| SPI | Qualified name prefix | Abstract methods | Category |
|-----|----------------------|------------------|----------|
| AccessControlProvider | access-control-provider | TBD | Silent no-op |
| DataSourceRegistry | data-source-registry | TBD | Silent no-op |
| SubscriptionStore | subscription-store | TBD | Silent no-op |
| NotificationStore | notification-store | TBD | Silent no-op |
| EndpointRegistry | endpoint-registry | TBD | Silent no-op |
| ExpressionEngineRegistry | expression-engine-registry | TBD | Silent no-op |
| DocumentSigningService | document-signing-service | TBD | Silent no-op |
| CredentialResolver | credential-resolver | TBD | Other (config-backed) |
| ModelRegistry | model-registry | TBD | NoOp fallback |
| PreferenceProvider | preference-provider | TBD | Config-driven mock |
| CurrentPrincipal | current-principal | TBD | Config-driven mock |

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
`@DefaultBean`. The other 10 SPIs use identical generated code — the
APT's unit tests in `simulation-generator` already cover code generation
correctness.

## Guide update

Add a "Platform SPIs" section to `docs/guides/simulation-guide.md` (D41)
with:

- Table of available SPIs and their qualified name prefixes
- Example config for simulating a representative SPI
- Reference to the integration test as a copy-paste starting point
- Pointer to #332 (verification API) for testing assertions

## Deliverables

1. New `platform-simulation-core/` module with listing file and pom.xml
2. One `@QuarkusTest` integration test
3. "Platform SPIs" section in simulation guide
4. CLAUDE.md module entry update

## References

- [D4] Annotation-driven generated @Decorator for capture and simulation
- [D6] Generated @Decorator activates simulation — NoOps remain untouched
- [D38] Single platform-simulation-core module for all platform-api SPIs
- [D39] PolicyEnforcer excluded — not an SPI interface
- [D40] Single integration test for CDI ordering verification
- [D41] Platform SPI simulation section in the existing simulation guide
- memory-simulation-core/src/main/resources/META-INF/simulation-eligible.txt — precedent
- SimulationDecoratorProcessor.java — listing file loading (lines 96-122)
- DefaultBeans.java — all platform @DefaultBean NoOps
- Issue #332 — simulation verification API (testing ergonomics)
