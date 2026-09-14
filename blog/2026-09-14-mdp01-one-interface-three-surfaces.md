---
layout: post
title: "One Interface, Three Surfaces"
date: 2026-09-14
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [code-generation, apt, rest, graphql, mcp, jandex]
---

# One Interface, Three Surfaces

The graphql-generator APT has been sitting on main since the LLM config wizard work, generating `@GraphQLApi` resolvers from `@McpDomain` SPI interfaces. It also had a REST generation PoC — mapping `@PlatformQuery` to `@GET` and `@PlatformMutation` to `@POST`, all params as `@QueryParam`, no skip detection, no response wrapping. Functional but not something you'd point real endpoints at.

This session productionised the REST side. The generator now produces JAX-RS resources with kebab-case paths, proper HTTP verb mapping, convention-based parameter binding, `@RunOnVirtualThread`, `@Consumes` on body methods, `@Valid` on body params, and response wrapping — `void` returns 204, `Optional` returns 404 when empty, everything else wraps in `Response.ok()`. One SPI interface in, three API surfaces out: REST, GraphQL, MCP.

## The annotation question

The first design decision worth recording: where does HTTP verb metadata live?

The obvious answer was to put it on `@PlatformMutation` — add a `method` attribute, default to POST, let SPI authors override to DELETE or PUT when needed. I proposed this initially. The decision review caught the problem: `@PlatformMutation` is protocol-agnostic. It drives GraphQL generation, MCP tool registration, *and* REST generation. Putting `method = HttpMethod.DELETE` on it embeds REST transport semantics into an annotation that two other generators consume and ignore.

The fix was a separate `@RestMethod` annotation. A mutation that needs DELETE gets two annotations:

```java
@PlatformMutation("Remove a callback registration")
@RestMethod(HttpMethod.DELETE)
void deregister(@PathParam String id);
```

More verbose for the handful of methods that need non-POST verbs. But `@PlatformMutation` stays clean as a semantic marker, and the pattern scales — if a gRPC or WebSocket transport ever needs its own metadata, it gets its own annotation. The same logic applies to `@PathParam`: it's a REST-specific hint that the GraphQL generator ignores, so it lives in the same `io.casehub.platform.api.mcp` package alongside `@RestMethod` and `HttpMethod`, all zero-dependency.

## The Jandex surprise

The interesting constraint came during migration. The generator is an annotation processor — it runs during `javac` and reads `META-INF/jandex.idx` files from JARs on the processor classpath to find `@McpDomain` interfaces. The plan was to put each migration's SPI interface in its own module: `CallbackApi` in the callback module, `DeliveryChannelApi` in notifications.

That doesn't work. Jandex indexes are built *after* compilation by `jandex-maven-plugin`. The APT runs *during* compilation. The module's own index doesn't exist yet when the processor scans. The SPI interface is invisible to the generator that lives in the same build.

The solution is straightforward once you see it: put the SPI interfaces in a pre-compiled dependency. `CallbackApi` went into `callback-api`, the delivery channel and notification preference SPIs went into `platform-api`. The interface has no module-internal dependencies — it's pure Java with platform-api annotations — so it belongs at the SPI layer anyway. The service implementation stays module-local, which is where the `CurrentPrincipal` injection, validation logic, and `@RolesAllowed` enforcement live.

A second constraint surfaced from the same root cause. The generator's classpath includes Jandex indexes from *all* dependency JARs. When `platform-api` contains SPI interfaces for four domains, every module that uses the generator would produce endpoints for all four — even the ones it doesn't own. Claude surfaced this during the migration and added a `domainFilter` processor option: `-AdomainFilter=callbacks` scopes generation to listed domains only.

## What it enables

Four hand-written REST resources are gone: `DeliveryChannelResource`, `DigestStatusResource`, `CallbackRegistrationResource`, `NotificationPreferenceResource`. Each replaced by an `@McpDomain` SPI interface (3-5 methods), a service implementation (business logic stays explicit), and zero generated code to maintain. The generated REST and GraphQL endpoints match the hand-written behaviour — same HTTP verbs, same status codes, same parameter semantics.

The immediate value is MCP coverage. Every domain that has a `@McpDomain` SPI is automatically discoverable by `GraphQLModelScanner` at runtime — LLM agents can call `casehub_action` to invoke any operation. The REST and GraphQL endpoints are free extras, kept in sync by the compiler. No drift between API surfaces because there's only one source of truth.

The batch 2 endpoints — `AclResource`, `PreferenceResource`, `NotificationResource`, `SuppressionResource` — are more complex. They have nested resource paths, per-method security, and conditional response logic that the current generator can't express. That's a separate branch. But the generator and the migration pattern are proven on four real endpoints, and the path from SPI interface to three API surfaces is now mechanical.
