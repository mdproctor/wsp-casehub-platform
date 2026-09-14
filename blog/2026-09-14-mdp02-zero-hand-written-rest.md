---
layout: post
title: "Zero Hand-Written REST"
date: 2026-09-14
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [codegen, rest, mcp, annotation-processing, graphql-generator]
series: issue-296-generator-nested-paths-enum
---

# Zero Hand-Written REST

The platform had 28 hand-written REST endpoints spread across five resource classes — ACL administration, preferences, preference schemas, notifications, and notification suppression. Each was a bespoke JAX-RS class with its own path conventions, response wrapping, and auth patterns. The generator APT (`graphql-generator`) already handled three notification sub-domains from the first migration wave, but the remaining five resources were still hand-crafted.

Today we finished the migration. Every REST endpoint in the platform is now generated from `@McpDomain` SPI interfaces — except `PreferenceSchemaResource`, which stays hand-written because its ETag conditional GET requires `@Context Request`, a JAX-RS runtime concept that doesn't belong in an SPI contract.

## Two generator enhancements made this possible

The existing generator could produce REST from `@McpDomain` SPIs, but it couldn't handle nested paths or non-trivial parameter types. Two additions fixed that:

**`@RestPath` for nested resource paths.** ACL endpoints need paths like `/grants/batch` and `/denies/revoke-batch` — the generator's default `toKebabCase(methodName)` derivation produces flat segments only. `@RestPath("grants/batch")` overrides the path literally, slashes and all. Combined with `@PathParam`, it handles patterns like `/mute/{id}` where the action prefix and the path parameter sit at different levels.

**Jandex-based simple type detection.** The generator classifies method parameters as either query params (simple types) or request body (complex types). The static type list covered primitives and `java.time.*` but missed enums like `AclAction` and value types like `ResourceId` that implement `fromString(String)`. The fix queries the Jandex `IndexView` at compile time — three checks: `isEnum()`, `hasStaticMethod("fromString", String)`, `hasStaticMethod("valueOf", String)`. O(1) hash lookup per type, negligible cost.

## The migration pattern

Each resource followed the same four steps: create the `@McpDomain` SPI interface in a dependency module, create a service implementation carrying the business logic and auth annotations, wire the APT, delete the hand-written resource. The service absorbs everything the resource class did — `@RolesAllowed` for authorization, `BadRequestException` for validation, `CurrentPrincipal` threading for tenant isolation — while the generated REST resource becomes a thin delegation layer.

SPI placement matters. The APT discovers interfaces via Jandex indexes from dependency JARs, so the SPI must live in a module that's already compiled and indexed before the consuming module builds. `AclApi`, `NotificationApi`, and `NotificationSuppressionApi` went into `platform-api`. `PreferenceApi` and `PreferenceSchemaApi` went into `preferences-editor-core` — a pure Java module that needed a `jandex-maven-plugin` addition to produce the index.

## Verb changes worth noting

Batch delete operations (`revokeBatch`, `removeDenyBatch`) changed from `DELETE` to `POST`. HTTP DELETE with a request body is non-standard — RFC 9110 §9.3.5 says clients SHOULD NOT generate content in DELETE requests. The generator only classifies POST/PUT/PATCH as body-accepting verbs, which forced the verb change. Pre-release project, no external consumers, so the path shift is free.

Notification suppression creates (`addMute`, `activateSnooze`) now return 200 instead of the original 201. The generator wraps non-void returns in `Response.ok()` — there's no annotation for custom status codes, and adding one for two endpoints isn't worth the complexity. The status code change is trivial for pre-release.

## What this opens up

The immediate payoff is consistency — every domain's REST surface is generated from the same SPI contract that drives MCP and (eventually) GraphQL discovery. Adding a new endpoint to any domain means adding a method to the SPI interface. The generator handles path derivation, parameter classification, verb mapping, body detection, and response wrapping.

The less obvious payoff is that the SPI interfaces are now the single source of truth for the platform's public API surface. `GraphQLModelScanner` discovers them at runtime for MCP tool registration. The generator produces REST at compile time. Both read the same annotations — `@PlatformQuery`, `@PlatformMutation`, `@RestPath`, `@RestMethod`, `@PathParam`. One interface definition, multiple transports.
