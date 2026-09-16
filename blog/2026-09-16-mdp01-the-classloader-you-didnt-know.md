---
layout: post
title: "The classloader you didn't know you had"
date: 2026-09-16
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [annotation-processing, maven, classloader, spring-generator, core-extraction]
series: issue-478-spring-deployment-completion
---

Continued from [The bugs that weren't](2026-09-15-mdp04-the-bugs-that-werent.md).

The cognitive-observability core extraction was supposed to be mechanical. Move twenty-three framework-neutral files from `cognitive-observability` to `cognitive-observability-core`, refactor `CognitionService` to take nullable params instead of CDI `Instance<T>`, add a `@Produces` wrapper in the CDI module. Same pattern we've done for every other module in this epic.

It compiled. The tests passed. The CDI producer worked. But the generated GraphQL resolver disappeared.

The graphql-generator APT loads Jandex indexes via `getClass().getClassLoader().getResources("META-INF/jandex.idx")`. That classloader is the annotation processor classpath — populated exclusively from `<annotationProcessorPaths>` in the Maven compiler plugin config. Not the compilation classpath. Not the module's dependencies. A completely separate classpath that Maven never tells you about unless you go looking.

When `CognitionApi` was in the module being compiled, the APT found it in the RoundEnvironment. When it moved to a dependency JAR, the APT's classloader couldn't see it. `javac` could still resolve the type for compilation. The APT still ran without error. It just quietly found zero domains instead of one.

The fix is one XML element — add the dependency module to `<annotationProcessorPaths>`. But the failure mode is insidious: no error, no warning, just a file that should exist and doesn't. You'd only notice when something downstream fails to compile, or when a drift-detection verify goal flags the gap.

This is the kind of thing I want the garden for. A skilled Java developer would spend hours on this because every diagnostic points elsewhere — "the annotation is there, the Jandex index is there, the APT runs, what's going on?"

---

With the core extraction landed, we turned to the last two queue items: wiring the graphql-spring-generator in engine and work. The engine was the first repo with forward-slash domain names (`engine/cases`, `engine/control`). Three bugs fell out:

The `SseEmitter` import path was wrong — `org.springframework.web.servlet.mvc.SseEmitter` instead of `org.springframework.web.servlet.mvc.method.annotation.SseEmitter`. The generated code for paginated responses used `ResponseEntity.ok(body).header(...)`, but `.ok(body)` returns a `ResponseEntity`, not a builder — `.header()` doesn't exist on it. And the verify-drift goal's domain name normalization stripped hyphens but not forward slashes, so `engine/cases` never matched `enginecases`.

Three bugs, all one-line fixes. None existed in qhorus because qhorus domain names are flat — no slashes, no SSE subscriptions, no paginated queries. The bugs were always there; the engine was the first consumer that exercised those code paths.

Ten issues across five repos. The epic that started with a shared scanner refactoring ends with every CaseHub repo generating Spring controllers from the same `@McpDomain` SPIs that drive Quarkus. One interface, three surfaces — GraphQL, REST, and MCP — and now all three work in both frameworks.
