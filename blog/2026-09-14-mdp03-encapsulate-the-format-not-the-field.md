---
layout: post
title: "Encapsulate the Format, Not the Field"
date: 2026-09-14
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [design, spi, model-registry, agent-provider]
---

# Encapsulate the Format, Not the Field

The model registry knows about every LLM available to the platform — their tiers, capabilities, vendors, costs. The agent router knows how to dispatch prompts to backends. Nothing connects them. A caller who wants "the best model available" has to know its specific ID.

I wanted to close that gap: let a caller say "give me a FLAGSHIP model" and have the router figure out the rest.

The obvious approach was a sealed type — replace the `String model` field on `AgentSessionConfig` with a `ModelRef` that discriminates between model IDs, backend keys, and tier queries. Type-safe end to end. The kind of design that looks right on a whiteboard.

Claude's decision review pushed hard for it. Three of the nine findings converged on the same argument: the consumer already holds a typed `ModelTier` enum, the string prefix creates a parallel query mechanism alongside the existing `ModelQuery`, and the enum-to-string-to-enum roundtrip is unnecessary ceremony.

I steelmanned it properly. The arguments are real. But the devil's advocate surfaced something the steelman missed: `AgentSessionConfig` crosses two boundaries, not one. Callers set the `model` field to express intent. The router rewrites it to a concrete API model ID. Backends read the rewritten value. A sealed `ModelRef` on that field creates dead branches in every backend — `ByQuery` and `ByBackendKey` variants that backends can never receive after the router's rewrite. The type carries semantic information past the point where it's useful.

The proper fix would be splitting the config into a caller-facing request type and a backend-facing resolved type. That's a larger refactor than the feature warrants.

The insight that unlocked the design: type safety matters at **construction** and **interpretation**, not at **transport**. This is how URLs work — typed construction at the caller, typed routing at the server, string in the protocol. Nobody argues HTTP should use a sealed `URLRef`.

So `ModelRef` became a utility class — `forTier(ModelTier.FLAGSHIP)` returns the string `"tier:FLAGSHIP"`, `isTierRef()` detects the prefix, `parseTier()` extracts the enum. The format is encapsulated at both endpoints. The string flows through the SPI untouched. Zero backend changes. Zero SPI changes. Four files total.

The router's `resolve()` method gained one new step — check the `tier:` prefix before the existing registry-ID and backend-key paths. When it matches, query the model registry for that tier, prefer models from the configured default backend, and fail fast with a diagnostic error if nothing matches. The error distinguishes "no model sources configured" from "no model at that tier" — the kind of message that turns a 30-minute debugging session into a 30-second config fix.

A deployment with `default-backend=claude` now has sentiment analysis on Opus and monitoring on Haiku — and the caller never names either model.
