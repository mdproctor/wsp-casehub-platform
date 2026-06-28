---
layout: post
title: "Making Tool Calls Visible"
date: 2026-06-28
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [agent-api, sealed-interface, langchain4j]
---

## What I was trying to achieve: giving the Agent API eyes

The Agent API had a blind spot. `AgentEvent` was `sealed permits TextDelta` — every backend could stream text tokens, and that was it. Tool calls, thinking, tool results: all opaque. The `TextDelta` javadoc even said so explicitly: "ToolCall: Claude Code tool invocations are opaque to the observer."

That was a v1 decision that made sense when the only backend was Claude CLI's `textStream()`. But with `agent-langchain4j` bridging any LangChain4j ChatModel as an AgentProvider, the reasoning broke down. LangChain4j's streaming handler has `onPartialToolCall`, `onCompleteToolCall`, `onPartialThinking`. The Claude SDK's `messages()` API returns `AssistantMessage` with `ToolUseBlock`, `ThinkingBlock`, `ToolResultBlock`. The data was there — the SPI just had no way to carry it.

## The design question that mattered

The interesting part wasn't which event types to add — that was fairly obvious — but how to model tool calls in a streaming interface.

Text deltas are simple: each `TextDelta("hello")` is independently useful. Append it to your display and move on. Tool call arguments are different. They're JSON fragments — `{"ci` is not parseable, not actionable, not independently meaningful. And unlike text, an agent can call multiple tools in one stream. Each tool call needs its own "this one is done" signal.

Three options came up: two separate records (`ToolCallDelta` and `ToolCallComplete`), one record with a boolean completion flag, or a single record with no flag at all (like `TextDelta`). The flag option was the worst — same `arguments` field meaning "unparseable JSON fragment" or "complete parseable JSON" depending on a boolean. That's exactly what the type system exists to prevent.

Two records won. A partial JSON fragment and a complete parseable tool call are genuinely different things serving different consumers. Progress display matches on `ToolCallDelta`. Audit and execution match on `ToolCallComplete`. The sealed interface makes this impossible to miss.

## What the v1 reversal means architecturally

The more significant thing here is the javadoc I updated on `AgentProvider`:

> *This is the platform's own abstraction for AI agent interaction — not tied to any single LLM backend or SDK. The SPI exists because LangChain4j's abstractions sometimes impose overhead — particularly around caching and token cost — that native SDK access avoids. LangChain4j is one adapter path, not the ceiling.*

This has been the informal understanding since `agent-langchain4j` landed, but it wasn't written down where it matters — in the SPI's own javadoc. Making it explicit changes how you think about the event model. The events should capture the richest stream any reasonable backend can produce. Backends that can't produce thinking events just never emit `ThinkingDelta`. The sealed interface is the superset, not the intersection.

The second issue on this branch — verifying that `InMemoryEndpointRegistry` fires `EndpointRegistered` — turned out to be already implemented. The code was there, the CDI event was firing, but the test only checked "no NPE" instead of verifying the actual event payload. A mock-based test now verifies `fireAsync()` is called with the correct descriptor.

Two deferred issues came out of the design review: upgrading `ClaudeAgentClient` to use the SDK's `messages()` API instead of `textStream()` (#119), and upgrading `ChatModelAgentProvider` to use `StreamingChatModel` when available (#120). Both are prerequisites for any backend to actually produce the new event types — right now every producer still emits only `TextDelta`. The SPI is ready; the producers aren't yet.
