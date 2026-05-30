---
layout: post
title: "Asking Directories Who's in the Group"
date: 2026-05-30
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [scim, identity, quarkus, rest-client]
---

`GroupMembershipProvider.membersOf(groupName)` has been in `platform-api` since the beginning. It answers the inverse membership question — not "what groups is Alice in?" but "who's in the reviewers group?" — and it has always returned `Set.of()`. The mock. Always the mock.

The inverse query matters for work routing. When a task lands, the platform needs to know which actors can claim it. A JWT only tells you the current user's groups; it says nothing about who's eligible when the task is being assigned. That requires a directory call. I brought Claude in to help build one.

## A string wasn't the right type

The existing SPI returned `Set<String>`. The strings were actor IDs — or at least that was the intention. But there's an ambiguity: is the string the OIDC `sub` claim (a UUID, stable, the thing `CurrentPrincipal.actorId()` returns)? Or is it the display name? Or a username that might change?

SCIM 2.0 makes the answer explicit. Each group member has a `value` field (the user UUID, equal to the OIDC `sub` claim) and a `display` field (a human-readable name that may change). The `value` is the stable identity key. Using it for routing decisions is correct; using `display` is a latent bug.

Before writing any SCIM client, we changed the SPI. `Set<String>` became `Set<GroupMember>`, where `GroupMember` is a record:

```java
public record GroupMember(
    String actorId,     // OIDC sub = SCIM value — stable, never changes
    String displayName  // human label; never use as an identity key
) {}
```

Breaking change. Every implementation in the repo needed updating — the `@DefaultBean` mock, the in-memory test fixture in `testing/`. Mechanical, but it has to be total.

## SCIM: one protocol for all of them

The obvious first implementation would be the Keycloak Admin REST API. We use Keycloak. Keycloak has a group management API. Done.

Except that locks every consumer of this SPI to Keycloak forever. The whole point of `GroupMembershipProvider` is to abstract the directory — swap Keycloak for Okta or Azure AD and nothing above it should care. Implementing directly against the Keycloak Admin REST API would undermine the abstraction on first use.

SCIM 2.0 (RFC 7643/7644) is the standard HTTP API that Keycloak, Okta, Azure AD, and JumpCloud all expose. The call sequence is simple: `GET /Groups?filter=displayName eq "{name}"&attributes=id,displayName,members`. If members come back inline, done. If the server omits them from list responses (common for large groups on some servers), a second call fetches the group directly by ID. Map `value` to `actorId`, `display` to `displayName`. Cache the result — `membersOf()` gets called on every routing decision, so an uncached SCIM round-trip per invocation is not viable.

Keycloak native SCIM is experimental in 26.6. The community extension [SCIM for Keycloak](https://scim-for-keycloak.de/) is production-ready. Our client works against any compliant server; deployers choose.

## Two surprises from the WireMock setup

The test approach was straightforward: WireMock stubs replicate the SCIM server, `@QuarkusTest` injects the provider and calls it. Two surprises emerged.

**The Quarkiverse WireMock extension breaks on Quarkus 3.32.2.** `io.quarkiverse.wiremock:quarkus-wiremock-deployment:1.4.1` references `GlobalDevServicesConfig$Enabled`, an internal Quarkus class that no longer exists in 3.32.x. The test class fails to load at all:

```
TypeNotPresentException: Type io.quarkus.deployment.dev.devservices.GlobalDevServicesConfig$Enabled not present
```

Nothing in the error output points to `quarkus-wiremock`. Claude diagnosed it from the class name in the stack trace — the deployment processor for the WireMock extension was loading an annotation type that had been removed. The fix was to drop the Quarkiverse extension and use raw WireMock with `QuarkusTestResourceLifecycleManager`: start WireMock before Quarkus, return the port as a config override, done.

**`@Provider @ApplicationScoped` bypasses CDI for REST client filters.** `ScimAuthFilter` injects `ScimConfig` to read the bearer token. I initially annotated it `@Provider @ApplicationScoped` — the standard JAX-RS provider registration. The filter ran, but `config` was null. `@Provider` causes the Quarkus REST Client to instantiate the filter class directly, outside CDI, so `@Inject` fields are never populated. Remove `@Provider`, add `@RegisterProvider(ScimAuthFilter.class)` to the `@RegisterRestClient` interface, and Quarkus resolves the CDI-managed instance.

## The implementation that nearly slipped through

Before committing, we checked that every in-repo implementation of the SPI had been updated. `InMemoryGroupMembershipProvider` in `testing/` still returned `Set<String>`.

Incremental Maven builds hide this — the stale `.class` file from the previous compile satisfies the classpath check. `mvn install` passes. `mvn clean install` does not. Every downstream consumer hits a compilation failure on their first clean build. It's the kind of thing that's obvious in hindsight: when an SPI return type changes, every implementation in the repo changes in the same commit. We added a protocol for it (PP-20260530-88cdf9).

The fix was a two-minute update — `addMember(groupName, actorId)` now constructs `new GroupMember(actorId, actorId)` for test convenience, with a second overload that takes the full `GroupMember` when display name matters.

## Six tests, one CDI bean, no more empty sets

`casehub-platform-scim` is a library module — `@ApplicationScoped`, displaces the mock by classpath presence. Auth is a static bearer token (`casehub.platform.scim.token`) or client-credentials via `quarkus.oidc-client.scim.*`. The six tests cover inline members, two-step fetch, not-found, server error propagation, cache hit, and identity mapping — verifying that `actorId` comes from `value`, not `display`.

Callers that were treating `membersOf()` results as `Set<String>` need to switch to `Set<GroupMember>` and use `.actorId()`. The affected areas in casehub-work — `WorkBroker`, `ExclusionPolicy` — are tracked as issues on that repo.
