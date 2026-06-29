---
layout: post
title: "Two abstractions, one architecture"
date: 2026-06-27
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [agent, langchain4j, CDI, architecture]
---

## The question that started it

Platform has AgentProvider. LangChain4j has ChatModel. Both exist, neither talks to the other, and the bridges between them are per-provider duplicates. That sounded like a design problem. I wanted to understand whether it was — and if so, what the right architecture looked like.

The obvious answer was to drop one. AgentProvider looked like a Claude-specific abstraction pretending to be generic: subprocess management, MCP servers, concurrent-session semaphores — all Claude CLI concepts. Why not just use ChatModel everywhere?

## Why AgentProvider still earns its place

I spent time tracing through OpenClaw's `OpenClawAgentProvider` to understand whether anyone besides Claude actually used AgentProvider. They did — and for reasons that don't map to ChatModel. OpenClaw uses `correlationId` for fire-and-forget webhook delivery via a `DirectCallBridge`. The `Multi<AgentEvent>` stream with subscriber cancellation handles teardown. None of this fits into ChatModel's synchronous request/response model.

But the real argument is caching. Claude CLI manages `cache_control` breakpoints transparently at the Anthropic API level. LangChain4j's `SystemMessage` has no `cache_control` field. Even a native Anthropic SDK behind LangChain4j's `doChat()` loses caching control — LangChain4j mediates every call, and there's nowhere to express the caching metadata.

The architecture that fell out: AgentProvider is the platform SPI. Two implementation strategies — native SDK (Claude today, anything with SDK advantages tomorrow) and LangChain4j-backed (everything else, zero provider-specific code). The bridge becomes first-class architecture, not a per-provider hack.

## The @DefaultBean trap

We built the bidirectional interop module — `ChatModelAgentProvider` wrapping ChatModel as AgentProvider, `AgentProviderChatModel` wrapping AgentProvider as ChatModel. The CDI wiring looked clean: `AgentProviderChatModel` at `@Alternative @Priority(10)`.

Claude caught the problem during spec review. quarkus-langchain4j registers its ChatModel beans as `@DefaultBean` via `SyntheticBeanBuildItem.defaultBean()`. An `@Alternative` doesn't just outprioritize a `@DefaultBean` — it suppresses it entirely. The bean vanishes from the container. `Instance<ChatModel>` would find only our adapter, not the raw model it was supposed to wrap.

The fix: `@DefaultBean @Priority(10)`. Two `@DefaultBean` beans coexist — neither suppresses the other. `@Priority(10)` disambiguates for direct injection. `Instance` sees both, so the filtering logic works. ArC's javadoc confirms this pattern explicitly, though I'd never seen it used before.

## invoke() was the right API all along

A smaller discovery: the existing `ClaudeAgentChatModel` used `openSession()` + single `query()` + `close()` for every single-shot call. The prior spec documented the rationale — synchronous exception on session-limit vs Multi-level failure. I traced through `ClaudeAgentClient.run()` and the difference is marginal: `Multi.createFrom().failure()` surfaces immediately on subscribe, `await()` unwraps it directly. Using a multi-turn session API for single-shot calls was a semantic mismatch dressed up as an ergonomic choice. The new adapter uses `invoke()`.

The `@DefaultBean` discovery ended up in the garden as a gotcha. The kind of thing where you expect the CDI container to prioritize — and instead it amputates.
