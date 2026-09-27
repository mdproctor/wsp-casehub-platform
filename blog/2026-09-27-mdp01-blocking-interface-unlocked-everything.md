---
layout: post
title: "The Blocking Interface That Unlocked Everything"
date: 2026-09-27
entry_type: note
subtype: diary
projects: [casehubio/workers]
tags: [spring-boot, dual-framework, core-extraction, spi-design, mcp]
---

# The Blocking Interface That Unlocked Everything

Six worker modules needed core extraction — moving framework-neutral POJOs out of Quarkus CDI modules so Spring Boot auto-configuration could wire the same classes. Five were mechanical. One required a design decision that turned out to be the interesting part.

The mechanical pattern held across GitHub Actions, HTTP, Scenario, Camel, and K8s: strip CDI annotations, replace `org.jboss.logging.Logger` with `java.util.logging.Logger`, convert field injection to constructor injection, move tests, create a `*Beans.java` in the Quarkus module with `@Produces` methods. Each extraction took roughly the same shape. The Beans class reads config and calls constructors — the POJO does the work.

Camel was the smallest extraction (two types — constants and a record). K8s was partial: the `JobDefinitionResolver` moved but the Runtime and ExecutionManager stayed because they use fabric8's `KubernetesClient` directly. These are structural coupling decisions, not temporary ones — fabric8 is the K8s API, not a framework convenience that could be swapped.

MCP was different. The `McpWorkerExecutionManager` already used JDK `HttpClient` for `tools/call` dispatch — pure Java, Jackson for JSON-RPC, SSE parsing, the works. It should have moved cleanly to core. But it had one Mutiny coupling point: `sessionManager.getOrInitialize(serverName).await().indefinitely()`. A blocking bridge to get an `McpSession` from a Vert.x WebClient-backed session manager that uses `Uni.memoize().indefinitely()` for concurrent-safe lazy initialization.

The instinct was to migrate the session manager itself — replace Vert.x WebClient with JDK HttpClient for the MCP initialize/initialized handshake. But the session manager's value is in its reactive caching. `memoize().indefinitely()` gives you concurrent dedup for free — multiple callers requesting the same server session share a single initialization flight. Reimplementing that with `CompletableFuture` is possible but fiddly, and it would be solving the wrong problem.

The execution manager doesn't need reactivity. It needs a session — a `String` sessionId and a `String` protocolVersion. That's a data dependency, not a behaviour dependency.

```java
public interface McpSessionProvider {
    McpSession getSession(String serverName);
    void invalidate(String serverName);
}
```

Two methods. The Quarkus session manager implements it with a one-line bridge to its existing Uni pipeline. A Spring implementation can use whatever HTTP client and caching strategy fits Spring's idioms. The execution manager takes the interface, and all its JDK HttpClient code, JSON-RPC parsing, and SSE handling move to core without touching the session lifecycle.

The consolidated `workers-spring` module fell out naturally after that. Six auto-configuration classes, each `@ConditionalOnClass`-guarded so they only activate when the specific core module is on the classpath. The common auto-config bridges `Consumer<T>` callbacks to `ApplicationEventPublisher` — the same pattern the platform uses for agent backends.

The MCP auto-config has one notable guard: `@ConditionalOnBean(McpSessionProvider.class)`. No session provider, no execution manager. Spring consumers that want MCP workers need to provide their own session lifecycle — the SPI makes that a deliberate integration point rather than a missing feature.

Twenty modules in the reactor now. All green.
