---
layout: post
title: "Endpoints Config and the Agent Conversation"
date: 2026-06-14
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [endpoint-registry, endpoints-config, agent-provider, claude-sdk, chatmodel]
---

Two issues closed today that were deferred from the endpoint registry session. `EndpointPermissions` (#89) was the simpler one — a static utility class mirroring `MemoryPermissions` exactly, stripped of the async overload since endpoint registration has no `@ObservesAsync` scenario. Simple in concept but the spec went through several rounds because every obvious question had a non-obvious answer.

The CDI proxy was one. `registry.getClass().getSimpleName()` returns the proxy class name — `InMemoryEndpointRegistry_ClientProxy` — not the implementation class. Claude flagged it: `getSuperclass().getSimpleName()` strips the suffix reliably because Quarkus ARC generates single-level proxies, and `assertInstanceOf(InMemoryEndpointRegistry.class, registry)` works because the proxy subclasses the bean. These aren't things I'd have caught until a test failed.

`casehub-platform-endpoints-config` (#88) was the one I wanted. Same architecture as `casehub-platform-config` for preferences — a `@Startup @ApplicationScoped` bean that reads YAML at boot and calls `EndpointRegistry.register()` for each descriptor — but the decisions inside it were less obvious than they look.

The parsing pipeline ended up as static package-visible methods. `parseDescriptor(Map<String, Object> entry, PathParser parser)` is callable from a plain JUnit test without a Quarkus context. This matters because failure-path tests — bad enum value, unresolved `${VAR}`, missing required field — would abort the Quarkus application context if run via `@QuarkusTest`. The reason: `QuarkusTestExtension` implements `BeforeAllCallback` and boots the entire application before any `@BeforeAll` in the test class executes. `System.setProperty()` in `@BeforeAll` arrives after `@PostConstruct` has already run. I submitted that to the garden; it's the kind of timing mismatch that costs an afternoon the first time.

`PathParser` flows into `parseDescriptor()` as an explicit parameter rather than using the global default. `EndpointConfigLoader` and `PathParserConfigurator` are both `@Startup @ApplicationScoped` — CDI makes no ordering guarantees between two startup beans. If `parseDescriptor()` called `Path.parse()` with no arguments, it might run before `PathParserConfigurator` had set the configured separator. The fix is to read the separator via `@ConfigProperty` (injected before `@PostConstruct` regardless of startup ordering) and pass it in. The method signature is honest about what it depends on.

The second half of the session was a conversation I'd been wanting to have about `AgentProvider`. The existing `ClaudeAgentProvider` uses `org.springaicommunity:claude-code-sdk` — a Java wrapper for the Claude Code CLI subprocess, not a thin HTTP client to the Anthropic API. Those are fundamentally different. The official Anthropic Java SDK is a raw API client: tool calls come back to you, you implement the loop. The `claude-code-sdk` runs Claude Code as a subprocess; Claude handles its own tool loop, and tool calls are opaque to the caller. That's why `AgentEvent` only has `TextDelta`. There's nothing to surface.

LangChain4j's Anthropic integration doesn't support `cache_control` (open issue #1591), so calling Claude via LangChain4j silently foregoes prompt caching — 70–80% cost reduction gone. The subprocess handles this natively. A `ChatModel` adapter backed by a persistent `AgentSession` would give you Claude-native caching without exposing the tool loop, and it would look like a standard LangChain4j `ChatModel` to any consumer. The dependency is platform#58 (multi-turn `AgentSession`), which needs a crash-recovery design before it's production-safe. Filed that path as platform#100.
