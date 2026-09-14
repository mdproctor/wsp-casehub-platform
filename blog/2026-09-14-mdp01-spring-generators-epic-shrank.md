---
layout: post
title: "The Epic That Shrank: Validating Spring Boot Generators Against Reality"
date: 2026-09-14
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [spring-boot, code-generation, jandex, javapoet, design]
series: issue-474-spring-boot-generators
---

The original plan called for five code generators — REST, persistence, security, GraphQL, and MCP — each producing Spring integration layers from Quarkus source code. Five sounded reasonable from the issue description. Then I looked at what the codebase actually uses.

A survey across seven consumer repos showed that 86 of 131 persistence files already use plain EntityManager and JPQL — framework-neutral JPA that works identically in Spring. The remaining 45 use Panache, but porting those to plain JPA is straightforward refactoring, not a generator problem. Garden entries GE-20260420-7d28fa and GE-0138 document why Panache was being abandoned anyway: SPI interface conflicts and detached entity gotchas. A persistence-spring-generator would have been generating adapters for a pattern the codebase is actively moving away from.

Security was even more decisive: zero `@RolesAllowed` occurrences in consumer repos. The annotation is Jakarta standard — it works in both frameworks without translation.

That left three generators with genuine work to do. JAX-RS endpoints (97 files) can't be neutralised — the annotations are framework-specific. SmallRye GraphQL and Quarkus MCP Server are similarly non-portable. So the epic became three generators plus a Panache porting task, rather than five generators and no porting.

The design review caught something I'd missed: the graphql-spring-generator can't just produce `@QueryMapping` controllers. The existing graphql-generator already produces *two* outputs per `@McpDomain` interface — a GraphQL resolver and a REST resource. The Spring equivalent needs to mirror that dual output. Without the review surfacing this, the first consumer to add the plugin would have lost their REST API endpoints.

The review also narrowed the MCP generator. I'd planned for it to handle both `@Tool` (Quarkus MCP Server) and `@McpDomain` (platform SPI). But `@McpDomain` MCP registration happens at runtime in Quarkus via `GraphQLModelScanner` + `DynamicToolRegistrar` — it's not compile-time generation. The Spring equivalent is a runtime bean in a Spring MCP module, not generated source. The mcp-spring-generator handles `@Tool` only: 11 files, mechanical translation.

With the design validated, we built the foundation. A `generator-common` module extracts the shared infrastructure from the existing spring-generator: Jandex index loading, a drift verification framework, and a type converter that maps Jandex's `Type` to JavaPoet's `TypeName` (handling parameterized types, arrays, and wildcards correctly — Jandex loses generic type parameters in some contexts, which JavaPoet's `ParameterizedTypeName` resolves cleanly). The Palantir fork of JavaPoet replaces the `StringBuilder` approach the existing generators use.

The spring-generator was then retrofitted to extend the new base classes. `SpringGeneratorMojo` extends `AbstractGeneratorMojo`; `SpringVerifyMojo` extends `AbstractVerifyMojo`. All existing tests pass. The `platform-spring` consumer module builds correctly with the retrofitted generator — the contract is preserved, the implementation is shared.

Three tasks done, seven remaining. The REST generator is next — 97 JAX-RS files make it the highest-value target, and the most complex mapping surface (parameter annotations, `@Provider` classes, `ResponseEntity` wrapping). The design spec covers the edge cases: SSE endpoints excluded as Category C, `@RegisterRestClient` interfaces filtered out, `@Priority`-based heuristics for mapping `ContainerRequestFilter` to either Spring `Filter` or `HandlerInterceptor`.
