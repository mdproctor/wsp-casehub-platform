---
layout: post
title: "Teaching the Router What a Model Actually Is"
date: 2026-09-11
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [model-registry, agent-infrastructure, spi-design]
series: issue-286-model-registry-spi
---

# Teaching the Router What a Model Actually Is

Until today, `RoutingAgentProvider` treated the `model` field on `AgentSessionConfig` as a backend key. Pass `"claude"` and it routes to the Claude backend. Pass `"openai"` and it routes to OpenAI. Pass something unknown and it silently fell through to langchain4j as a catch-all. The field was doing triple duty — model identifier, backend selector, and fallback trigger — and the only reason it worked was that nobody was passing actual model IDs like `"claude-sonnet-5"` or `"gpt-4.1"`.

That changes with the model registry. The new `ModelRegistry` SPI in `platform-api` provides a normalised catalog of LLM models — each described by a `ModelDescriptor` carrying the model's vendor, family, tier, capabilities, context window, cost, and critically, which `AgentBackend` serves it. A `ModelSource` interface lets different catalog providers (a committed seed YAML, a live vendor API, an Ollama local scan) contribute models at different priorities, with higher-priority sources shadowing lower ones for the same model ID.

The interesting part is what this does to routing. `RoutingAgentProvider` now resolves the `model` field through a three-step contract:

1. **Registry lookup** — `ModelRegistry.resolveById("claude-sonnet-5")` finds the descriptor, extracts `backendKey: "claude"`, and rewrites the config to carry the API-specific model ID. The backend receives a config that says `model: "claude-sonnet-5"` — a real model identifier it can pass to the vendor API.

2. **Key-based match** — `"claude"` matches a backend directly. The config is rewritten with `model: null`, so the backend falls through to its configured default. This preserves backward compatibility — existing callers that pass backend keys still work.

3. **Fail-fast** — no match means `IllegalArgumentException`. The old langchain4j catch-all is gone. If you pass a string that's neither a known model ID nor a backend key, you hear about it immediately.

The config rewriting in steps 1 and 2 is the subtle part. Before this change, backends received the raw `model` string from the caller — which might be a backend key (`"claude"`), a model ID (`"claude-sonnet-5"`), or something the backend has never heard of. Now backends always receive either a specific API model identifier from the registry or `null` (use your default). The semantic overloading is resolved at the router, not pushed down to every backend.

We seeded the registry with 17 models from five vendors — Anthropic, OpenAI, Google, Meta, and Mistral — in a committed YAML file at priority 0. Live API sources at higher priorities will override these entries when they land. The seed catalog means the registry works out of the box without network access, which matters for air-gapped deployments and local development.

One thing that caught us: adding `ModelRegistry` as a CDI dependency to `RoutingAgentProvider` broke `@QuarkusTest`s in `mcp/` and any other module that transitively depended on `agent-router`. The fix was a `@DefaultBean NoOpModelRegistry` in `agent-router` itself — empty registry, key-based routing preserved, no external dependencies needed. When `platform/` is on the classpath, `InMemoryModelRegistry @ApplicationScoped` naturally overrides the no-op.

This is Layer 2 in the epic's three-layer model. Layer 1 (model execution) already exists — the agent backends know how to send prompts and get responses. Layer 2 (this work) knows what models exist and how to find them. Layer 3 (eidos) will know which agent can handle which task and select the right model for it. The `family` field on `ModelDescriptor` is the binding point — eidos `AgentDescriptor.modelFamily` references it as a foreign key, so agent selection can query "give me a FLAGSHIP model from the claude family with vision capabilities" without knowing the specific model ID.
