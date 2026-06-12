---
layout: post
title: "Named Endpoints"
date: 2026-06-12
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [platform-api, endpoint-registry, spi]
---

The casehub platform has four foundation primitives now. Preferences let modules read scoped configuration. Identity lets code know who's acting. Memory gives agents a store that survives cases. And as of today: a named endpoint registry so workers can connect to external systems by name rather than hard-coding connection details.

The need has been obvious for a while — it's sketched in PLATFORM.md's outbound auth table as "Tier 2 named endpoints," with a note that workers fall back to `@ConfigProperty` until it ships. Workers in `casehub-workers-http` and `casehub-workers-camel` currently embed URLs and protocol details inline. That works until you have multiple tenants with different Salesforce orgs or different Kafka endpoints. At that point, hardcoding falls apart.

The SPI ended up cleaner than the GitHub issue's draft proposed. The issue put the `@DefaultBean` in-memory implementation in the same `endpoints/` module as the SPI. That felt right until we worked through the dependency math: `platform/` carries the `@DefaultBean` mock for every SPI in platform-api, so if `platform/` depends on a new module, every consumer gets that module transitively anyway. A separate SPI module only makes sense when the SPI carries a dependency platform-api cannot have — which is why `agent-api/` exists (Mutiny). This SPI is pure Java, so it lives in platform-api directly. The `@Alternative @Priority(100)` in-memory adapter goes in a new `endpoints-memory/` module, and the NoOp lands in `platform/` alongside every other mock.

`resolve()` has two-step priority: tenant-specific wins over platform-global for the same path. A tenant with their own Qhorus deployment needs to override the platform-default URL without removing it from everyone else's view. `discover()` returns both and lets callers choose — no override semantics at the list level. The distinction is deliberate and in the SPI Javadoc.

`EndpointPropertyKeys` follows the same principle as `MemoryAttributeKeys`: only reserve keys whose values cross module boundaries. `URL` and `TOPIC` are the two. Every HTTP/gRPC/MCP/Camel/Qhorus endpoint caller needs a stable string key for the base URL; Kafka producers and consumers need to agree on the topic name. Everything else — bootstrap servers, TLS config, Camel route IDs — stays as module-defined strings. The rule became PP-20260612-042941 in the protocols.

Claude caught a specific error in the population model: the draft had `currentPrincipal.tenancyId()` sourcing the tenancyId for registered endpoints in a `@PostConstruct` method. The OIDC `CurrentPrincipal` is `@RequestScoped` — there's no request context at startup, so that either throws or returns the mock's default. The tenancyId must come from `@ConfigProperty`. It's the kind of mistake that's invisible in tests (the mock is `@ApplicationScoped` and happily returns a config value) but breaks silently in production when the real OIDC impl is on the classpath.

Three issues deferred: #88 for a config-backed registrar module for multi-tenant deployments, #89 for write authorization when `casehub-deployment` starts registering endpoints at runtime, and parent#229 to sync the capability ownership table and deep-dive docs.

The config-backed registrar is the natural follow-on. The `@PostConstruct` pattern handles single-tenant and platform-global endpoints, but it doesn't compose for fifty tenants with different endpoint config per tenant. That's the same problem `casehub-platform-config` solves for preferences — a YAML reader that populates the SPI at startup. The same approach will work here.
