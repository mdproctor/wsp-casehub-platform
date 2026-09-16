---
title: "@McpDomain on Classes: One File, Four Outputs"
date: 2026-09-16
entry_type: note
subtype: diary
series: issue-489-dx-audit
projects:
  - casehubio/platform
tags: [dx, generators, spring, quarkus, mcp]
---

# @McpDomain on Classes: One File, Four Outputs

The CaseHub generator pipeline requires a separate SPI interface for every MCP domain. For complex domains with multiple implementations — notifications, ACL, subscriptions — the interface earns its place. For a simple single-class agent tool, it's pure ceremony: write an interface, annotate it, implement it, wire it. Two files where one would do.

We fixed this by removing three interface-only filters across the generator stack. The APT processor (`GraphQLResolverProcessor`) had the filter in both its Jandex and RoundEnvironment scan paths. The shared Jandex scanner (`McpDomainJandexScanner`) used by all Spring generators had a third. Each was a single line: `if (!isInterface(classInfo.flags())) {continue;}`. After removing them, a concrete class with `@McpDomain` generates the same four outputs — Quarkus GraphQL resolver, Quarkus REST resource, Spring GraphQL controller, Spring REST controller — that previously required a separate interface.

The real test was putting it to use. We annotated `SubscriptionService` directly with `@McpDomain("subscriptions")` and seven operation annotations (`@PlatformQuery`, `@PlatformMutation`, `@RestMethod`, `@RestPath`). The hand-written Quarkus `SubscriptionResource` — 108 lines of delegation boilerplate — deleted. The hand-written Spring `SubscriptionRestController` — 99 lines of the same thing in a different framework — also deleted. Both replaced by generated code from a single source.

That uncovered three bugs in the Spring generators. The `graphql-spring-generator` hardcoded `/api/` as the base path instead of reading `@McpDomain(basePath=...)`. It appended `/{id}` to paths even when the `@RestPath` override already contained it. And it generated `if (result == null)` null-checks for primitive `boolean` returns — a compile error. All three were one-liners, all three had been invisible because nobody had pointed the generator at a class with CRUD-style REST paths before.

The more interesting problem was the three transport-specific controllers — webhook, callback dispatch, engagement callbacks. These have HTTP concerns that don't translate to GraphQL or MCP: raw `byte[]` bodies with `application/cloudevents+json`, `@HeaderParam` for SPI headers, and `@Context HttpHeaders` fields that the JAX-RS resource extracts into `Map<String,String>` for the core POJO. The `rest-spring-generator` handles these, but it needed fixes too.

The biggest was `@Context HttpHeaders` — the Quarkus resources extract headers from a field-injected `HttpHeaders` and pass them to the core POJO as an extra parameter. The generator didn't know about this. We added delegate method lookup: the scanner loads the core module's Jandex, compares each JAX-RS method's parameter count with the delegate method's count, and marks methods where the delegate needs more parameters. The writer injects `HttpServletRequest` and generates an `extractHeaders()` helper — but only on methods that actually need it. Without the per-method check, `recordDirect(attemptId, request)` would get a spurious headers parameter.

`WebhookResource` had a deeper issue: it constructed `WebhookReceiver` internally instead of injecting it. The generator's delegation heuristic — pick the first constructor parameter — grabbed `EndpointRegistry` instead. The fix was completing the core extraction: a new `WebhookBeans` producer with `@Startup` (to preserve eager initialization), and a simplified `WebhookResource` that injects `WebhookReceiver` directly.

End result: 5 of 6 hand-coded Spring REST controllers eliminated. The survivor — `PreferenceSchemaRestController` — has ETag conditional GET logic that no generator can express. One hand-coded controller out of six is a tolerable exception.

The ceremony comparison lands well. A minimal CaseHub MCP domain is now one file:

```java
@McpDomain("support")
@ApplicationScoped
public class SupportService {
    @PlatformQuery("Get customer") Customer get(@PathParam String id) { ... }
    @PlatformMutation("Update customer") void update(@PathParam String id, Update u) { ... }
}
```

One source file. One per-method annotation. Generates GraphQL + REST for both Quarkus and Spring, plus runtime MCP tool registration. Fewer per-method annotations than Embabel's `@Action` + `@AchievesGoal` + `@Export`. The remaining gap is `annotationProcessorPaths` in pom.xml — one-time setup inherited from the parent BOM.

The `SpringModelScanner` fix was a parallel concern. It only scanned interfaces, while its Quarkus counterpart `GraphQLModelScanner` did two passes — class-first, interface-fallback. A parity gap that had already drifted. Fixed with the same two-pass pattern, independently implemented — the two scanners use fundamentally different bean discovery mechanisms (CDI Arc vs Spring ApplicationContext) that don't share code cleanly.

What opens up: every core POJO in the platform could carry `@McpDomain` directly. The `rest-spring-generator` now handles transport endpoints, and the `graphql-spring-generator` handles domain operations. The generation pipeline is complete — new domains get both framework's endpoints with zero hand-coding. The question that remains is whether `PreferenceSchemaRestController`'s ETag pattern is worth adding a `@ConditionalGet` annotation for. One controller is tolerable. Two would be a pattern.
