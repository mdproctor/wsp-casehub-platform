---
layout: post
title: "Three Generators in One Sitting"
date: 2026-09-14
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [spring-boot, code-generation, jandex, javapoet, maven-plugin]
series: issue-474-spring-boot-generators
---

# Three Generators in One Sitting

Continued from [The Epic That Shrank](2026-09-14-mdp01-spring-generators-epic-shrank.md).

The design session validated the scope and built the foundation — `generator-common` with its shared base classes, the spring-generator retrofit. This session was pure execution: build the three generators the design specified.

Each generator follows the same internal structure: a Scanner reads a Jandex index looking for specific annotation patterns, produces Descriptor records, and a Writer turns those descriptors into Spring-equivalent Java source using JavaPoet. The pattern was established by the spring-generator — the new generators extend the same `AbstractGeneratorMojo` and `AbstractVerifyMojo` base classes.

**rest-spring-generator** has the widest mapping surface. JAX-RS `@Path` resources become `@RestController` classes, with parameter annotations translated: `@PathParam` to `@PathVariable`, `@QueryParam` to `@RequestParam`, `@HeaderParam` to `@RequestHeader`. Return types get wrapped in `ResponseEntity` — void methods return `noContent()`, `Optional<T>` maps to `ok()` or `notFound()`, everything else wraps in `ok()`. The scanner filters out interfaces, `@RegisterRestClient` types, and classes in `*.rest.generated.*` packages (those belong to the graphql-generator, not this one).

The REST generator also handles `@Provider` classes. `ExceptionMapper<T>` becomes `@ControllerAdvice` with `@ExceptionHandler`. `ContainerRequestFilter` maps to either a Spring `Filter` (with `@Order`) or a `HandlerInterceptor`, depending on whether its `@Priority` falls at or below the authentication tier. The heuristic is simple — security-level filters need the servlet lifecycle, application-level filters work better as interceptors.

**graphql-spring-generator** mirrors the existing `graphql-generator`'s dual output: from each `@McpDomain` SPI interface, it produces both a Spring GraphQL `@Controller` (with `@QueryMapping` and `@MutationMapping`) and a Spring MVC `@RestController` (with `@GetMapping` and `@PostMapping` per operation). Both inject the SPI interface and delegate. This was the design review catch — without dual output, consumer repos would have lost their REST API endpoints when switching to Spring.

**mcp-spring-generator** is the narrowest. It scans `@Tool` methods from `io.quarkiverse.mcp.server` and generates Spring AI `@Tool` equivalents in `@Configuration` classes. The interesting testing decision: rather than pulling in the entire Quarkus MCP Server dependency just for `@Tool` and `@ToolArg`, I created synthetic annotation stubs in `src/test/java` with the real fully-qualified names. Jandex works on string-based class name matching, so the scanner can't tell the difference between a real annotation and a stub with the same FQN.

The Panache porting tasks (45 files across ledger, work, and qhorus) were deferred to separate issues per consumer repo. They're mechanical refactoring — `PanacheRepository` to `EntityManager` + JPQL — and genuinely independent of the generator work. Each repo needs its own branch and testing cycle.

The generators are build-time tools. They'll first run when consumer repos add the plugin declarations to their `-spring` module poms. The verify goals provide the safety net — if a Quarkus module adds a new `@Path` resource or `@McpDomain` interface without a Spring equivalent, the build fails. Drift detection as a build constraint rather than a review checklist.
