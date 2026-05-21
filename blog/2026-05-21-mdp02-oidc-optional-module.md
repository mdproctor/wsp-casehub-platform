---
layout: post
title: "The optional OIDC module"
date: 2026-05-21
type: phase-update
entry_type: note
subtype: log
projects: [casehub-platform]
tags: [quarkus, oidc, cdi, testing]
---

The previous entry planted `tenancyId()` and `isCrossTenantAdmin()` in the
SPI before anyone could build on top. This one fills in the real
implementation — `OidcCurrentPrincipal`, now in its own optional module.

## The optional module question

I could have added `quarkus-oidc` to the existing `platform/` mock module.
One fewer artifact to publish. But it would put `quarkus-oidc` on the
transitive classpath of every consumer, including modules that have no
intention of using OIDC.

We already solved this with the preferences provider — `config/` is an
opt-in module that displaces `MockPreferenceProvider @DefaultBean` only when
on the classpath. Same mechanism here: a new `oidc/` module, a plain
`@RequestScoped` bean (no `@DefaultBean`), CDI selects it over the mock
automatically when the consumer declares the dependency. Remove the dep, get
the mock back. No exclusion config, no conditional wiring.

## Where the values come from

`SecurityIdentity` gives `actorId` and `groups`. `JsonWebToken` gives the
custom claims — `tenancyId` (required, throws if absent) and
`crossTenantAdmin` (optional, defaults to `false`).

Claim names are a fixed platform contract, not a configuration option. The
alternative was `@ConfigProperty` defaults that consumers could override.
I don't want that: the claim name is a schema decision, and schema decisions
should be in code, not in `application.properties` files that drift silently
across deployments.

Anonymous identity — an unauthenticated request to a public endpoint —
returns the same sentinels as the mock: `"anonymous"`, empty groups,
`DEFAULT_TENANT_ID`, `false`. The JWT is never accessed in that path, which
matters because there's no JWT to access.

## Testing without HTTP

The obvious approach for testing an OIDC-backed `@RequestScoped` bean: write
a test REST resource, use `@TestSecurity` and `@OidcSecurity`, call via
RestAssured. That's significant scaffolding.

An existing project protocol (PP-20260513-7c227e) already establishes that
`@TestSecurity` only works in the HTTP request context — it has no effect on
direct CDI bean calls. That constraint, which looks like a limitation, points
toward the cleaner approach: `@InjectMock` from `quarkus-junit-mockito`
replaces both `SecurityIdentity` and `JsonWebToken` with Mockito mocks, and
manual request context activation gives the `@RequestScoped` bean somewhere
to live.

```java
@BeforeEach
void activateRequestContext() {
    Arc.container().requestContext().activate();
}

@AfterEach
void terminateRequestContext() {
    Arc.container().requestContext().terminate();
}
```

No HTTP. No test REST resource. No `@TestSecurity`. Five tests, all the
behaviour covered.

## The OIDC startup issue

One gotcha: `quarkus.oidc.discovery-enabled=false` requires either
`jwks-path` or `introspection-path` to be set. Without one of them Quarkus
throws `ConfigurationException: Either 'jwks-path' or 'introspection-path'
properties must be set when the discovery is disabled`. A dummy `jwks-path`
works fine — JWKS loading is lazy, only fetched when validating a real
token. With `@InjectMock` replacing `JsonWebToken` entirely, no real token
validation ever runs.

It's in the knowledge garden (GE-20260521-f50602) since this will come up
again for any Quarkus OIDC module tested without a real auth server.

The module is now live at `casehub-platform-oidc`. Consumers declare it and
get auth-backed identity. They don't, nothing changes.
