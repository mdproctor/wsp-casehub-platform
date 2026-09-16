---
title: "From Pieces to Pipeline"
date: 2026-09-16
entry_type: note
subtype: diary
author: mdp
projects:
  - casehubio/platform
series: issue-335-agent-config-manifest
tags: [agent-provider, model-registry, configuration, manifest, llm]
---

# From Pieces to Pipeline

Over the last few weeks we'd built the full machinery for LLM model management — a seed catalog of 17 models across five vendors, cloud model sources that auto-discover from vendor APIs, local Ollama support, credential bootstrapping from environment variables, a multi-instance backend coordinator, tier-based routing, and an MCP-exposed config wizard. Six issues, dozens of commits, all landed on main.

None of it worked end-to-end.

That's the uncomfortable truth I arrived at when I looked at how our example projects actually configured their LLM access. Wacky-manor had two backends on the classpath and nothing configured — `NoOpAgentProvider` activated by default. The showcase had a hand-rolled `TestAgentProvider.claude()` that spawned the CLI binary directly, inheriting whatever the local machine happened to have. No model selection, no provider abstraction, no routing. Every project was doing it differently, with custom code each time.

The infrastructure existed. The adoption path didn't.

## The manifest as orchestrator

The core insight was that we didn't need more infrastructure — we needed a declarative way to drive what we already had. A developer should write one config file and `agentProvider.invoke()` should work.

So we designed a manifest: `agent-config.yaml`. Not a new system. An orchestration layer. It drives the existing SPIs at startup:

- `providers:` → resolves credential references, stores in `LlmCredentialStore`, `BackendInstanceCoordinator` wires the backends
- `models:` → registers via `MutableModelRegistry.replaceSource()` at priority 8 (above cloud discovery, below per-tenant runtime config)
- `aliases:` → registers named constraint sets with `RoutingAgentProvider` (multi-dimension model selection that resolves differently per environment)
- `local-models:` → declares desired state, existing `OllamaModelSource` reconciles

The manifest doesn't replace `LlmConfigService` — it complements it. The manifest is the bootstrap path (platform scope, read at startup). `LlmConfigService` stays as the runtime API for per-tenant configuration.

## The resource chain

The manifest isn't a single file. It's a chain of resources, discovered implicitly from a directory hierarchy — project → user → system → seed catalog — accumulated by model ID with highest-priority-wins semantics. Any manifest can also declare remote sources (corporate model catalogs, live service endpoints) that are fetched and merged into the same chain.

This means a developer configures `~/.casehub/agent-config.yaml` once with their API keys. Every project inherits it. A project drops its own `agent-config.yaml` to add aliases or custom models. CI sets `CASEHUB_AGENT_PROFILE=ci` and the CI-specific file overrides providers to use Ollama. Same code, different environment. No per-project wiring.

## Credentials without secrets

I wanted credentials in the manifest without actual secrets in the file. The solution is reference types: `env:ANTHROPIC_API_KEY` reads from the environment, `file:/var/run/secrets/key` reads file contents (k8s mounted secrets), `ref:vault/anthropic` delegates to the existing `CredentialResolver` SPI — which bridges to Quarkus `CredentialsProvider` via the `credentials-quarkus` module when Vault or AWS Secrets Manager is on the classpath.

Three reference types, three deployment tiers, same manifest schema. The Vault integration required zero new code — the `CredentialResolver` → `CredentialsProvider` bridge was already built.

## Named aliases and constraint-based selection

The interesting design question was model selection. `tier:FLAGSHIP` is fine for single-dimension queries, but "give me something with vision and reasoning and at least 128K context" needs multi-constraint queries. And the same query should resolve to Claude Opus in dev and Ollama Maverick in CI.

Named aliases solve this. The manifest defines `reasoning-heavy` as `{tier: FLAGSHIP, capabilities: [reasoning], min-context: 128000}`. Code says `agentProvider.invoke(config.withModel("reasoning-heavy"))`. The router resolves the alias to a `ModelQuery`, filters the registry, tiebreaks by default backend then vendor preference, and dispatches.

We extended `ModelQuery` with `minContextWindow`, `minMaxOutput`, and `preferVendor`. The first two are filters (deterministic — a model either meets the threshold or doesn't). `preferVendor` is a tiebreaker (not a filter) — it influences selection among matching models without excluding any.

## What this opens up

The JSON Schema (`model-selection.schema.json`) is published as a Maven artifact resource. Eidos case definitions and org descriptors can `$ref` it for task-level and role-level model requirements. A case definition that says `model: reasoning-heavy` goes through the exact same resolution path as Java code — same schema, same router, same environment adaptation.

For tests, this is the end of custom `TestAgentProvider` classes. `@Inject AgentProvider` just works — the manifest configures it from the environment. Configure once, works everywhere.

The web app side is appealing too. The entire seed catalog plus vendor info is ~6KB of JSON. A pure client-side app can load that, let users browse models, filter by capabilities and cost, and produce the manifest YAML. No server needed until someone wants to save credentials. The web app is the setup wizard; the manifest is the artifact.
