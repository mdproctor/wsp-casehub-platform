# Design Journal — issue-17-multitenancy-foundation

### 2026-05-21 · §Identity API

Two abstract methods added to `CurrentPrincipal`: `tenancyId()` and
`isCrossTenantAdmin()`. Both are abstract — not interface defaults — so every
implementor is forced at compile time to declare a tenancy position. In
single-tenant deployments the mock returns `TenancyConstants.DEFAULT_TENANT_ID`
(a fixed UUID, configurable via `casehub.tenancy.default-id`); real OIDC-backed
implementations will read from the JWT `tenancyId` claim. `isCrossTenantAdmin()`
defaults to `false` everywhere; the mock exposes it via
`casehub.platform.principal.crossTenantAdmin` for local simulation. A companion
`TenancyConstants` utility class in `platform-api` owns the two sentinels
(`DEFAULT_TENANT_ID` and `PLATFORM_TENANT_ID`) so any consumer can import
constants without depending on the identity SPI itself.
