# Design Journal — issue-3-current-principal-request-scoped

### 2026-05-21 · §Identity API

New `oidc/` module (`casehub-platform-oidc`) ships `OidcCurrentPrincipal @RequestScoped`.
Follows the `config/` optional-module pattern: plain `@ApplicationScoped`-style bean (no
`@DefaultBean`), Jandex plugin for CDI library discovery, `quarkus-oidc` compile dep.
Consumers add the artifact to activate OIDC identity; the mock remains default for everyone
else — no exclusion config.

Claim names are fixed platform contract: `tenancyId` (required String — throws
`IllegalStateException` if absent), `crossTenantAdmin` (optional Boolean — defaults
`false`). Anonymous identity (`identity.isAnonymous() = true`) returns sentinel values
without touching the JWT. OIDC session configuration for tests: `discovery-enabled=false`
+ `jwks-path` avoids startup connectivity while keeping CDI beans registered for
`@InjectMock` replacement.

`GroupMembershipProvider` OIDC / `SecurityIdentityAugmentor` is deferred — needs a
directory (Keycloak Admin API, LDAP), not just the JWT.
