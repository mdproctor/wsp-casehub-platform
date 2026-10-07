# HANDOFF — casehub-platform

## Status

**Issue #530 (Link social login to service connection):** CLOSED. Landed as 18b51b72 on main.
**Epic #502 (YAML cross-repo parity):** Batches 1-4 closed. Batch 5 (pages#502 ops sub-epic) open.

## This Session

Added `ServiceConnectionProvider` SPI — a derived-view facade over OAuthTokenStore + ScopeRegistry + OAuthTokenManagerCore. No new persistence. One consent screen for identity + service scopes via `ScopeMergingLoginCustomizer`.

**Changes landed on main:**
- `ServiceConnectionProvider` SPI in platform-api (5 methods: getConnection, listConnections, getAccessToken, disconnect, missingScopes)
- `ServiceConnectionProviderCore` in authn-social-core (86 lines of composition)
- `ScopeMergingLoginCustomizer` in authn-core (integrates into AuthenticationRouterCore)
- `NoOpServiceConnectionProvider` @DefaultBean in platform/
- Quarkus + Spring wiring with `casehub.authn.merge-service-scopes` config (default true)
- `ScopeRegistry.registeredProviders()` default method added
- 33 tests across 5 test classes

**Issues filed this session:**
- connectors#157 — ConnectionPlatform SPI (M/Med)
- connectors#158 — Google service connection: register scopes + consume SPI (S/Med)
- connectors#159 — Connection status UI (S/Low)
- platform#550 — access_type=offline for Google refresh tokens (S/Med, critical for production)
- platform#551 — Doc sync: add SPI to consumer/contributor guides (XS/Low)

## Key Decisions

- ServiceConnectionProvider is a derived view, not a persisted entity — connection status computed from existing OAuthTokenStore + ScopeRegistry data
- ScopeMergingLoginCustomizer lives in authn-core (not authn-social-core) to avoid circular dependency — it only depends on platform-api types
- access_type=offline deferred to #550 — modifying AbstractOAuthAuthenticationProvider.buildAuthorizationUrl() is a broader change
- All new types in io.casehub.platform.api.authn package (not identity) — consistent with existing authn SPIs

## Open Items

- **platform#550 is critical for production use** — without access_type=offline, Google service connections die after ~1 hour when the access token expires. The SPI works correctly but transparent refresh won't have a refresh token to use.
- **Paused branch:** epic-502-yaml-parity still on the stack (Batch 5 remaining)
