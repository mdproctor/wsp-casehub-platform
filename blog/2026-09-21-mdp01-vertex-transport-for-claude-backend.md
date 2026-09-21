---
layout: post
title: "Vertex transport for Claude — the feature that was mostly already built"
date: 2026-09-21
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [agent, vertex, gcp, claude, backend-instance-factory]
---

The Claude backend talks to Claude Code CLI via the `claude-code-sdk`. When someone
configures `authMethod: gcp-adc` in the model catalog, nothing happened — the
backend didn't know how to use Vertex AI transport. That's the gap this closes.

The interesting part isn't the code. It's how much infrastructure was already in
place. `VertexClient` already existed in `llm-config-vertex/` — it could validate
GCP ADC credentials and list Vertex models. `ManifestProcessor` already seeded
credentials from `agent-config.yaml`. `BackendInstanceCoordinator` already iterated
credential refs and matched them to factories. The `CLIOptions` record already had
an `env` field that gets passed to the CLI subprocess. The routing layer already
used `ModelDescriptor.backendInstanceId()` to pick the right backend instance.

The only missing piece: a `BackendInstanceFactory` that creates a Claude client
with Vertex env vars, and a way to get those env vars into `ClaudeAgentClient`.

We added a `Map<String, String> env` constructor parameter to `ClaudeAgentClient`
and refactored `buildEventStream()` to use `CLIOptions.builder()` instead of the
fluent `ClaudeClient.async()` builder — the fluent API doesn't expose `.env()`,
but the `CLIOptions` record does. The existing single-arg constructor delegates
with `Map.of()`, so nothing changes for the default Claude backend.

`ClaudeVertexBackendFactory` is twenty lines of real logic: check if the credential
ref contains "vertex" and has a `project-id`, then set three env vars
(`CLAUDE_CODE_USE_VERTEX=1`, `ANTHROPIC_VERTEX_PROJECT_ID`,
`ANTHROPIC_VERTEX_REGION`) and hand them to the client. Same pattern as
`OpenAiDirectBackendFactory`.

We also extended the seed catalog to support optional `apiModelId` and `instanceId`
fields. Vertex models need both — `claude-sonnet-5-vertex` as the registry ID
(distinct from `claude-sonnet-5`) but `claude-sonnet-5` as the actual API model ID
sent to the CLI. The `instanceId: vertex` field binds these descriptors to the
factory-created backend, so the router resolves them through the correct transport.

Three Vertex model entries ship in the catalog out of the box: Opus 5, Sonnet 5,
Haiku 4.5. Users see them immediately — no setup required beyond configuring their
GCP project-id and region in `agent-config.yaml`.

The seed catalog approach is worth noting. We could have relied purely on runtime
discovery via `VertexClient.listModels()`, but pre-populated entries mean the models
show up in the registry before anyone has configured Vertex credentials. A user
browsing available models sees the Vertex options and knows the platform supports
them. That's a small UX detail, but it's the difference between "I wonder if Vertex
is supported" and "oh, it's right there."
