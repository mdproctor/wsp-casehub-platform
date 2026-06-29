# #112 — Consumer Cleanup Post-#111

## Problem

#111 shipped `OidcCurrentPrincipal @Alternative @Priority(100)`. Consumers no longer need
`quarkus.arc.exclude-types` entries to suppress competing `CurrentPrincipal` implementations —
the @Alternative wins by CDI priority resolution.

Removing those entries exposes a deeper issue: `FixedCurrentPrincipal @Alternative @Priority(1)`
(testing module) loses to `OidcCurrentPrincipal @Priority(100)` in tests. Any consumer with
oidc on the compile classpath and testing on the test classpath has broken test isolation.

## Root Fix

Bump test fixtures in the testing module to `@Priority(200)`:

- `FixedCurrentPrincipal` — `@Priority(1)` → `@Priority(200)`
- `InMemoryGroupMembershipProvider` — `@Priority(1)` → `@Priority(200)`

Test fixtures must always beat production alternatives. Priority 200 is above the highest
production alternative (OidcCurrentPrincipal at 100) with room for future growth.

## CDI Priority Chain (After Fix)

| Bean | Annotation | Priority |
|------|-----------|----------|
| MockCurrentPrincipal | @DefaultBean | yields to all |
| QhorusInboundCurrentPrincipal | @ApplicationScoped | normal |
| TenantScopedPrincipal | @RequestScoped @Unremovable | normal |
| OidcCurrentPrincipal | @Alternative @Priority(100) | 100 |
| FixedCurrentPrincipal | @Alternative @Priority(200) | 200 |

## Protocol Update

Update `oidc-harness-wiring-checklist.md` in the garden — rewrite step 1 as no longer
needed since platform #111.

## Consumer Cleanup (Cross-Repo Issues)

Per CLAUDE.md ("raise issues instead"), file issues in each affected consumer:

| Consumer | Remove from main props | Remove from test props |
|----------|----------------------|----------------------|
| devtown | QhorusInboundCurrentPrincipal, TenantScopedPrincipal, DefaultTestPrincipal | QhorusInboundCurrentPrincipal, TenantScopedPrincipal |
| clinical | QhorusInboundCurrentPrincipal, TenantScopedPrincipal | — |
| life | MockCurrentPrincipal, QhorusInboundCurrentPrincipal, DefaultTestPrincipal, TenantScopedPrincipal | QhorusInboundCurrentPrincipal, TenantScopedPrincipal |
| openclaw | MockCurrentPrincipal, QhorusInboundCurrentPrincipal | stale selected-alternatives + comments |

Non-CurrentPrincipal exclude-types entries (JpaWorkloadProvider, ActorStateResource,
connectors, etc.) are unaffected.

## MissingTenancyException Awareness

`CurrentPrincipal.tenancyId()` now throws `MissingTenancyException` (extends RuntimeException)
instead of `IllegalStateException`. casehub-work's `IllegalStateExceptionMapper` no longer
catches tenancy failures — this is intentional (409 was the wrong status; 500 is correct for
infrastructure errors). No action required.
