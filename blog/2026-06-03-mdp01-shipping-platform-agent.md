---
layout: post
title: "Shipping casehub-platform-agent"
date: 2026-06-03
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [quarkus, mutiny, cdi, reactive, claude-sdk]
---

**Shipping `casehub-platform-agent`** was a longer journey than the module count suggests. Two flat modules: `agent-api` for the SPI, `agent-claude` for the Claude integration. The spec looked solid going in.

The Maven coordinate in the originating issue was wrong. Someone had written `com.github.spring-ai-community:claude-agent-sdk-java:1.0.0`. The real one, confirmed on Maven Central, is `org.springaicommunity:claude-code-sdk:1.0.0` — different groupId, different artifactId. A comment was filed on the issue before any code was written.

The spec itself took five rounds to converge. Most of the interesting problems surfaced in the first review.

**The timeout design was wrong.** I'd specified a merge-based approach: race the event stream against a delayed-failure `Multi`. Claude came back with a correctness problem: Mutiny's `merge()` completes when *all* upstreams complete, not when *any* one does. If the agent session finishes before the timer fires, the merged stream stays open — then fails with `AgentTimeoutException` when the timer eventually triggers. A successful session would be falsely reported as timed out.

The correct approach: schedule `client.close()` via a `ScheduledExecutorService` after the wall-clock duration. When the subprocess is killed, the SDK's Flux fails naturally. An `AtomicBoolean` with `compareAndSet(false, true)` in the timer handler prevents the double-close race if completion and the timer coincide. The `timedOut` flag tells the failure transform which exception type to emit.

Claude also caught the CDI module separation problem. The spec had the LangChain4j `@DefaultBean` and the Claude `@ApplicationScoped` implementations in the same Maven module, expecting that adding `agent-claude` to the classpath would activate Claude. That doesn't work — `@ApplicationScoped` always wins over `@DefaultBean` regardless of classpath when they're in the same module. The Claude implementation must be in a *separate* module (`drafthouse-claude/` or equivalent). Only then does adding the module to the POM activate the right bean.

A third surprise came during implementation itself: Mutiny's `Multi.createFrom().publisher()` expects `java.util.concurrent.Flow.Publisher`, not `org.reactivestreams.Publisher`. Reactor's `Flux` doesn't bridge cleanly without `JdkFlowAdapter.publisherToFlowPublisher()`. The adapter is in `reactor-core` — no extra dependency — but the distinction between the two publisher interfaces isn't obvious until you hit the type error.

The `@Startup` annotation on `ClaudeAgentClient` came from a threading question in review: what happens if the first injection occurs from a Vert.x reactive handler? Without it, ARC initializes lazily, and the `@PostConstruct` binary probe — `ProcessBuilder.waitFor()` — would block the IO thread. `@Startup` forces initialization on the main startup thread, same pattern `PathParserConfigurator` and `MongoPreferenceIndexes` use in this module.

What shipped: `AgentProvider` SPI, `AgentEvent.TextDelta`, `AgentSessionConfig`, a sealed `AgentMcpServer` (Stdio/Sse/Http), typed exceptions. `ClaudeAgentProvider @ApplicationScoped` in `agent-claude`, `ClaudeAgentClient @Startup` with the semaphore and subprocess cleanup logic, and `NoOpAgentProvider @DefaultBean` in the existing `platform/` module — active by default, emitting a WARN per invocation so dev misconfiguration shows up immediately.

Multi-turn (`AgentSession`) is deferred. No current use case needs it, and subprocess-held conversational state has no crash-recovery path. Single-shot is the right call for now.
