---
layout: post
title: "The Quarkus CredentialsProvider Shaped Everything"
date: 2026-06-25
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [credentials, spi, quarkus, microprofile-config]
---

## The Quarkus CredentialsProvider Shaped Everything

`EndpointDescriptor.credentialRef` has been sitting there since platform#73 — a nullable string field that names a credential but resolves to nothing. The qhorus slack-channel module worked around it by hardcoding `config.getValue("casehub.qhorus.slack-channel.credentials." + workspaceId)` — per-module, per-prefix, unreusable. That's Tier 1.5: it works, but every new consumer reinvents the same pattern.

The original issue described `resolve(credentialRef) → String`. I started there, then went looking at how Quarkus handles this.

Quarkus already has a `CredentialsProvider` SPI — `Map<String, String> getCredentials(String credentialsProviderName)`. It returns a map because credentials aren't always a single token. Database connections need user+password. OAuth needs client_id+client_secret. The map carries all of them, keyed by standard constants (`user`, `password`, `expires-at`).

That changed the design. A `String` return would have been simpler and wrong. The `Map<String, String>` return mirrors Quarkus's contract exactly, so a future bridge module can delegate to `CredentialsProvider` with zero mapping. The SPI lives in `platform-api` (zero deps, pure Java) and the constants live in a separate `CredentialPropertyKeys` class — same pattern as `EndpointPropertyKeys` and `MemoryAttributeKeys`.

The `@DefaultBean` uses MicroProfile Config instead of `System.getenv()`. An early draft used env vars directly, but a review caught it: every other `@DefaultBean` in `platform/` uses `@ConfigProperty` or `Config`. `System.getenv()` bypasses profile support, bypasses `application.properties`, and forces test subclassing to mock lookups. `Config.getOptionalValue()` gets all three for free, and SmallRye's automatic env-var mapping (`CASEHUB_CREDENTIALS_SF_BEARER_TOKEN` → `casehub.credentials.sf-bearer-token`) gives the same env-var ergonomics without custom conventions.

The resolver supports compound credentials via sub-keys — `casehub.credentials.db-primary.user`, `casehub.credentials.db-primary.password` — checked before the bare key. If any sub-key is found, the bare key is ignored. Compound or simple, never both. The bare-key fallback returns under `BEARER_TOKEN` because that's the dominant credential type for the HTTP endpoints that `credentialRef` exists to serve.

Claude hit a Quarkus testing gotcha during implementation — `@Nested` inner classes with `@QuarkusTest` fail with a `QuarkusClassLoader` error. The classloader doesn't propagate to nested classes, even though `@Nested` is standard JUnit 5. The fix is separate top-level test classes. Not documented anywhere in Quarkus — ended up in the garden as a GE.

The bridge to Quarkus `CredentialsProvider` is filed as a follow-up. When someone needs Vault or AWS Secrets Manager, a `credentials-quarkus/` module provides `@Alternative @Priority(1)` that delegates to `CredentialsProvider.getCredentials()`. The SPI is designed for that handoff — same return type, same key names. The migration path from Tier 1.5 is also filed against qhorus: replace the hardcoded config lookup with `credentialResolver.resolve(workspaceId).get(BEARER_TOKEN)`.
