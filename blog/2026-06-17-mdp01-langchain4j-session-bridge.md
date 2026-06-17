---
layout: post
title: "The LangChain4j/AgentSession bridge"
date: 2026-06-17
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [agent, langchain4j, ChatModel, AgentSession, prompt-caching]
---

Prompt caching was always the point. `quarkus-langchain4j-anthropic` doesn't support `cache_control` breakpoints — langchain4j#1591 has been open for a while — so repeated calls with the same large system prompt pay full token cost every time. The Claude CLI handles caching automatically: system prompt cached on first call, cheaper on subsequent ones. We wanted that benefit available through LangChain4j's `ChatModel` interface.

The design split into two shapes depending on who owns the session. `ClaudeAgentChatModel` is the stateless path: fresh `AgentSession` per call, query once, close. The caching benefit here comes from Anthropic's API level — identical system prompts within the cache TTL are served from cache regardless of which subprocess sends them. `AgentSessionChatModel` is the multi-turn path: a plain class wrapping a caller-supplied `AgentSession`. Subsequent `doChat()` calls send only the latest user message; the subprocess maintains the conversation history internally. The caller opens the session and closes it in try-with-resources — the wrapper never touches `close()`.

That never-close rule turned out to be worth testing explicitly. If the wrapper closes a session it didn't open, the caller's resource is silently invalidated after the first use. A few review passes surfaced that we had no test verifying `close()` was never called on the multi-turn path after a streaming completion, so we added one.

The `engine.Agent` incompatibility deserves a direct statement. The engine's `Agent.buildResponseFormat()` hardcodes `ResponseFormatType.JSON` — every call through that path forces JSON mode. Our adapter throws `UnsupportedFeatureException` on any JSON format request, synchronously, before any session is opened. That's intentional: the two capability tiers are genuinely different, and making the boundary explicit is cleaner than hiding it.

One genuinely non-obvious Java issue: both `ChatModel` and `StreamingChatModel` declare four identical default method signatures — `listeners()`, `defaultRequestParameters()`, `provider()`, `supportedCapabilities()`. Implementing both in one class requires explicit overrides for all four. The diamond ambiguity produces a compile error otherwise. Not documented in LangChain4j. The compiler error is unambiguous, but knowing which four to override requires reading both interfaces carefully.

There's a subtler point about `session.query()` and the streaming contract. The session's CAS check fires before any `Multi` is returned — CLOSED or already-ACTIVE sessions throw `IllegalStateException` synchronously from `query()`. That means the exception propagates synchronously from `doChat()` through to the caller of `chat()`, not to `handler.onError()`. Three review passes flagged this before the error table got it right. It's the kind of thing that only becomes apparent when you trace the exact calling sequence rather than assuming the reactive terminal handlers catch everything.

The spec went through seven feedback rounds before implementation started. That's a lot for a module this size, but the multi-turn lifetime semantics and error surface have enough subtlety that the precision mattered — the implementation was straightforward once the design was settled.
