# Manifest-Driven Model Chains — Design Spec

**Issue:** casehubio/platform#623
**Date:** 2026-10-15
**Status:** Draft

## Problem

Applications select LLMs by naming specific models or providers. This makes provider selection an application concern — tests check env vars, code branches on provider type. The same binary should work unchanged across dev (Ollama), CI (no LLM), and production (cloud providers) without conditional logic.

## Design Goal

Applications request LLM capability by intelligence tier (`FAST`, `STANDARD`, `FLAGSHIP`), never by model or provider. The manifest declares available providers with priority-ordered fallback chains. The router resolves tier requests to whatever's available. The application is fully decoupled from provider selection.

## What Exists

- `ModelChain` with `Named`/`Queried` entries and full fallback retry logic (reactive + synchronous)
- `AliasDeclaration` → single `ModelQuery` (no chain support)
- `ManifestResult` holds `Map<String, ModelQuery> aliases`
- `SimulatedAgentBackend` (key: `"simulated"`) — corpus-driven agent backend using `SimulationRuntime`
- `ManifestLoader` with profile support (`agent-config-{profile}.yaml`)
- `RoutingAgentProvider` four-step resolution: alias → tier ref → registry ID → backend key
- Tiebreaking: prefer `defaults.backend` → `preferVendor` → first match

## Architecture

### Part 1: Chain Aliases

**`AliasDeclaration`** gains a `chain` field:

```java
public record AliasDeclaration(
    String tier,
    List<String> capabilities,
    String locality,
    @JsonProperty("max-cost") String maxCost,
    @JsonProperty("min-context") Integer minContext,
    @JsonProperty("min-output") Integer minOutput,
    @JsonProperty("prefer-vendor") String preferVendor,
    List<ChainEntry> chain                              // NEW
) {}
```

`ChainEntry` supports both named models and query constraints:

```java
public record ChainEntry(
    String model,       // named model ref (mutually exclusive with query fields)
    String tier,
    List<String> capabilities,
    String locality,
    @JsonProperty("max-cost") String maxCost,
    @JsonProperty("min-context") Integer minContext,
    @JsonProperty("min-output") Integer minOutput,
    @JsonProperty("prefer-vendor") String preferVendor,
    @JsonProperty("backend-key") String backendKey      // direct backend filter
) {}
```

**Manifest YAML:**

```yaml
aliases:
  fast-prefer-local:
    chain:
      - query: { tier: FAST, locality: LOCAL }
      - query: { tier: FAST, locality: CLOUD }

  standard:
    chain:
      - query: { tier: STANDARD }
      - query: { tier: FLAGSHIP }          # fall UP, never down

  frontier:
    chain:
      - query: { tier: FLAGSHIP }          # no fallback — fails if unavailable

  # backwards compatible — single query alias (no chain)
  embedding:
    tier: EMBEDDING
```

**`ManifestProcessor` changes:**

- `toModelQuery(AliasDeclaration)` becomes `toModelChain(AliasDeclaration)`
- If `chain` is present: each entry becomes a `ModelChainEntry.Queried` or `ModelChainEntry.Named`
- If `chain` is absent: existing fields become a single-entry `ModelChain` with one `Queried` entry
- `ManifestResult.aliases` type changes from `Map<String, ModelQuery>` to `Map<String, ModelChain>`

**`RoutingAgentProvider` changes:**

- Step 0 (alias lookup): instead of `resolveQuery(aliases.get(model))`, delegates to chain resolution via `resolveChain()` / `resolveAndInvokeWithRetry()`
- Both resolution paths already exist and handle `ModelChain` — the change is wiring aliases to produce chains instead of single queries

**Validation:**

- `chain` and single-query fields (`tier`, `capabilities`, etc.) are mutually exclusive on `AliasDeclaration`. If both present, fail at manifest load time with a clear error.
- Empty chain (`chain: []`) is rejected.

### Part 2: Simulation as a Routable Backend

**Backend key rename:** `SimulatedAgentBackend.key()` changes from `"simulated"` to `"simulation"`.

**No-corpus fallback:** When no `SimulationRuntime` is available or no corpus entry matches, the backend returns a deterministic canned response:

```
TextDelta: "Simulated response from {modelId}"
InvocationComplete: cost=0, inputTokens=0, outputTokens=0
```

The response includes the resolved model ID so tests/logs can verify routing correctness.

**CDI wiring:** Add `@Produces` method in `simulation-config` that creates `SimulatedAgentBackend` as a CDI-discoverable bean. When `SimulationRuntime` is available, pass it; when not, the backend operates in canned-response mode.

**`openSession()` support:** Currently throws `UnsupportedOperationException`. For manifest-driven use, this needs to work — return a session that produces canned responses per query.

**Manifest declaration:**

```yaml
# agent-config-test.yaml
providers:
  - vendor: simulation

models:
  - id: sim-fast
    backendKey: simulation
    tier: FAST
    locality: LOCAL
  - id: sim-standard
    backendKey: simulation
    tier: STANDARD
    locality: LOCAL
  - id: sim-flagship
    backendKey: simulation
    tier: FLAGSHIP
    locality: LOCAL

defaults:
  backend: simulation
```

### Part 3: Ollama BackendInstanceFactory

`OllamaBackendInstanceFactory` creates `OllamaAgentBackend` instances from manifest provider declarations. Follows the `ClaudeVertexBackendFactory` pattern:

- `backendKey()` returns `"ollama"`
- `handles()` checks for Ollama-specific credential/config keys (e.g., host URL)
- `create()` builds an `OllamaAgentBackend` with the configured host

This makes Ollama manifest-declarable alongside Claude Vertex — both are auto-created from provider declarations.

## Routing Selection — How It Works

No simulation-specific routing logic exists. Selection uses existing mechanisms:

**`defaults.backend` tiebreaking:** When a tier query matches multiple candidates (real + simulation), the router prefers models whose `backendKey` matches `defaults.backend`. The profile sets this:

```yaml
# test profile: prefer simulation
defaults:
  backend: simulation

# dev profile: prefer Ollama
defaults:
  backend: ollama

# production: prefer Claude
defaults:
  backend: claude
```

**Chain fallback:** Chains provide explicit ordering. ConnectException or RateLimitException trigger fallback to the next entry:

```yaml
aliases:
  fast:
    chain:
      - query: { tier: FAST, locality: LOCAL }        # try Ollama
      - query: { tier: FAST, backendKey: simulation }  # Ollama down → simulation
```

**Environment matrix:**

| Environment | Profile | defaults.backend | `fast` resolves to | `frontier` resolves to |
|-------------|---------|-----------------|-------------------|----------------------|
| Dev laptop | dev | ollama | gemma3:4b (Ollama) | opus via Vertex |
| CI + Ollama | ci | ollama | gemma3:4b | fails (no FLAGSHIP) |
| CI (no LLM) | test | simulation | sim-fast | sim-flagship |
| Production | (none) | claude | haiku via Vertex | opus via Vertex |

In production, simulation models are not declared. The fallback path doesn't exist — not because code prevents it, but because there's nothing to match. `ModelChainExhaustedException` is the correct failure mode.

## Module Changes

| Module | Change |
|--------|--------|
| `agent-config-core` | `AliasDeclaration` gains `chain` field + `ChainEntry` record. `ManifestProcessor.toModelChain()`. `ManifestResult.aliases` type → `Map<String, ModelChain>` |
| `agent-router-core` | `RoutingAgentProvider` alias resolution delegates to chain resolution |
| `agent-simulation-core` | `SimulatedAgentBackend.key()` → `"simulation"`. No-corpus fallback. `openSession()` support |
| `simulation-config` | `@Produces SimulatedAgentBackend` as CDI bean |
| `agent-ollama-core` | `OllamaBackendInstanceFactory` |
| `agent-ollama` | CDI wiring for factory |

## Backwards Compatibility

- Aliases without `chain` continue to work — converted to single-entry chains internally
- Existing `SimulatedAgentBackend` consumers referencing key `"simulated"` need updating (internal to simulation framework only — no external consumers)
- `ManifestResult.aliases` type change requires updating `RoutingAgentProvider.create()` and any code reading the aliases map

## Test Plan

### Chain alias resolution
- Alias with `chain` resolves to `ModelChain`
- Alias without `chain` resolves to single-entry `ModelChain` (backwards compatible)
- Mixed chain (named + queried entries) resolves correctly
- Empty chain rejected at load time
- `chain` + single-query fields rejected at load time

### Chain fallback
- LOCAL-first chain resolves to LOCAL when available
- LOCAL-first falls to CLOUD on ConnectException
- LOCAL-first falls to CLOUD on RateLimitException
- Non-retryable errors propagate immediately
- Chain exhaustion throws `ModelChainExhaustedException`

### Simulation backend
- Returns canned response without corpus
- Returns corpus-matched response with corpus
- `openSession()` works (canned-response mode)
- Backend key is `"simulation"`
- CDI-discoverable by router

### Routing selection
- `defaults.backend: simulation` routes FAST query to sim-fast
- `defaults.backend: ollama` routes FAST query to Ollama model
- Same alias chain, different defaults.backend → different resolution
- Production manifest (no simulation models) → simulation path doesn't exist

### Profile-based selection
- `CASEHUB_AGENT_PROFILE=test` → simulation preferred
- `CASEHUB_AGENT_PROFILE=dev` → real providers used
- Profile defaults.backend overrides base defaults.backend

## References

- `platform-api/ModelChain.java` — existing chain data model
- `agent-router-core/RoutingAgentProvider.java` — existing chain resolution + retry logic
- `agent-config-core/AliasDeclaration.java` — current alias structure
- `agent-config-core/ManifestProcessor.java` — alias → ModelQuery conversion
- `agent-config-core/ManifestLoader.java` — manifest loading + profile merge
- `agent-simulation-core/SimulatedAgentBackend.java` — existing simulation backend
- `agent-claude/ClaudeVertexBackendFactory.java` — BackendInstanceFactory reference impl
- Naming audit: all simulation-related classes, modules, constants audited for noun/adjective consistency
