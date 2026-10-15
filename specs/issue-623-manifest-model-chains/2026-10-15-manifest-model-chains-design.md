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
- Ollama already CDI-discovered via `OllamaBeans` — models with `backendKey: ollama` route to it

## Architecture

### Part 1: Chain Aliases

#### ModelQuery gains `backendKey`

`ModelQuery` gains an optional `backendKey` field for hard filtering by backend:

```java
public record ModelQuery(
    String vendor,
    String family,
    ModelTier tier,
    Set<String> requiredCapabilities,
    ModelLocality locality,
    CostTier maxCostTier,
    Integer minContextWindow,
    Integer minMaxOutput,
    String preferVendor,
    String backendKey              // NEW — hard filter, not tiebreaking
) {}
```

Unlike `preferVendor` (tiebreaker among equals), `backendKey` is a filter — only models on this backend match. This enables chain entries like `{ tier: FAST, backend-key: simulation }` that target a specific backend without ambiguity.

`ModelRegistry.query()` / `InMemoryModelRegistry` must respect this field: exclude models whose `backendKey` doesn't match when the query field is non-null.

#### Shared query fields: `ModelQuerySpec`

`AliasDeclaration` and chain entries share the same query fields. Extract into a common type:

```java
public record ModelQuerySpec(
    String tier,
    List<String> capabilities,
    String locality,
    @JsonProperty("max-cost") String maxCost,
    @JsonProperty("min-context") Integer minContext,
    @JsonProperty("min-output") Integer minOutput,
    @JsonProperty("prefer-vendor") String preferVendor,
    @JsonProperty("backend-key") String backendKey
) {}
```

`AliasDeclaration` composes `ModelQuerySpec` + `chain`:

```java
public record AliasDeclaration(
    // inherited query fields via Jackson @JsonUnwrapped or flat inclusion
    String tier,
    List<String> capabilities,
    String locality,
    @JsonProperty("max-cost") String maxCost,
    @JsonProperty("min-context") Integer minContext,
    @JsonProperty("min-output") Integer minOutput,
    @JsonProperty("prefer-vendor") String preferVendor,
    @JsonProperty("backend-key") String backendKey,
    List<ChainEntry> chain                              // NEW
) {}
```

`ChainEntry` is either a named model ref or query constraints:

```java
public record ChainEntry(
    String model,       // named model ref — if present, this is a Named entry
    // query fields (used when model is null):
    String tier,
    List<String> capabilities,
    String locality,
    @JsonProperty("max-cost") String maxCost,
    @JsonProperty("min-context") Integer minContext,
    @JsonProperty("min-output") Integer minOutput,
    @JsonProperty("prefer-vendor") String preferVendor,
    @JsonProperty("backend-key") String backendKey
) {}
```

#### Manifest YAML format

Chain entries are flat objects — no `query:` wrapper. Presence of `model` distinguishes Named from Queried entries:

```yaml
aliases:
  fast-prefer-local:
    chain:
      - tier: FAST
        locality: LOCAL
      - tier: FAST
        locality: CLOUD

  standard:
    chain:
      - tier: STANDARD
      - tier: FLAGSHIP                    # fall UP, never down

  fast-with-fallback:
    chain:
      - tier: FAST
        locality: LOCAL
      - tier: FAST
        backend-key: simulation           # explicit simulation fallback

  frontier:
    chain:
      - tier: FLAGSHIP                    # no fallback — fails if unavailable

  mixed:
    chain:
      - model: claude-opus-5              # try specific model first
      - tier: FLAGSHIP                    # then any FLAGSHIP

  # backwards compatible — single query alias (no chain)
  embedding:
    tier: EMBEDDING
```

#### `ManifestProcessor` changes

- `toModelQuery(AliasDeclaration)` becomes `toModelChain(AliasDeclaration)`
- If `chain` is present: each `ChainEntry` becomes `ModelChainEntry.Named` (when `model` is set) or `ModelChainEntry.Queried` (otherwise)
- If `chain` is absent: existing fields become a single-entry `ModelChain` with one `Queried` entry
- `ManifestResult.aliases` type changes from `Map<String, ModelQuery>` to `Map<String, ModelChain>`
- `ManifestProcessor.toModelQuery(ModelQuerySpec)` extracted as shared conversion for both alias and chain entry fields

#### `RoutingAgentProvider` control flow changes

**`invoke()` path (reactive retry):**

Currently `invoke()` bifurcates on `config.modelChain()`:
```java
if (config.modelChain() != null && !config.modelChain().isEmpty()) {
    return resolveAndInvokeWithRetry(config);  // reactive chain
}
var route = resolve(config.model());           // single route
```

After this change, `resolve()` Step 0 (alias lookup) returns a `ModelChain` instead of a `ResolvedRoute`. The `invoke()` method detects this and reroutes:

1. `resolve()` is split: `resolveToRoute(String model)` returns `ResolvedRoute` (for non-alias resolution); `resolveAlias(String model)` returns `Optional<ModelChain>` (Step 0 only)
2. `invoke()` checks alias first. If alias matches → build config with chain → `resolveAndInvokeWithRetry()`. If not → existing flow.
3. Single-entry chains go through `resolveAndInvokeWithRetry()` — no special casing. One-entry chain is equivalent to a single query with no fallback.

**`openSession()` path (synchronous pre-flight):**

`resolveFromConfig()` / `resolveFromInit()` currently call `resolveChain()` for explicit chains. After this change:

1. When model string matches an alias → get the `ModelChain` from aliases map
2. Pass to existing `resolveChain()` (synchronous, uses `ModelAvailabilityFilter`)
3. Returns `ResolvedRoute` — same as before

Both paths already handle `ModelChain` — the change is wiring alias lookup to produce chains.

#### Validation

- `chain` and single-query fields (`tier`, `capabilities`, etc.) are mutually exclusive on `AliasDeclaration`. If both present, fail at manifest load time with a clear error.
- Empty chain (`chain: []`) is rejected.
- `ChainEntry` with `model` set alongside query fields is rejected (mutually exclusive).

### Part 2: Simulation as a Routable Backend

#### Backend key rename

`SimulatedAgentBackend.key()` changes from `"simulated"` to `"simulation"`. Naming rationale: backend keys are nouns naming the provider (claude, openai, ollama, gemini). The class name `SimulatedAgentBackend` stays — adjective is correct for the class (it IS a simulated backend), per the codebase naming convention (all generated decorators use "Simulated" prefix).

#### Constructor change

```java
// Before: required SimulationRuntime
public SimulatedAgentBackend(final SimulationRuntime simulation) {
    this.simulation = simulation;
}

// After: nullable SimulationRuntime
public SimulatedAgentBackend(@Nullable final SimulationRuntime simulation) {
    this.simulation = simulation;
}
```

No-arg constructor also available for standalone use (simulation = null).

#### No-corpus fallback behavior

When `SimulationRuntime` is null OR no strategy/corpus match exists:

```java
public Multi<AgentEvent> invoke(final AgentSessionConfig config) {
    if (simulation != null) {
        var strategy = simulation.strategyFor(AgentProviderQN.INVOKE);
        if (strategy.isPresent()) {
            // existing corpus-driven path
            return corpusDrivenInvoke(config, strategy.get());
        }
    }
    // canned-response fallback
    return cannedResponse(config);
}
```

Canned response emits:
```
TextDelta("Simulated response from " + config.model())
InvocationComplete(cost=0, inputTokens=0, outputTokens=0)
```

This changes the existing `Multi.createFrom().empty()` (zero events) behavior for the no-strategy case. This is correct — the old behavior (empty stream) was a silent no-op, not useful for manifest-driven routing where the caller expects a response.

#### `openSession()` implementation

Minimal multi-turn session that returns canned responses per query:

```java
public AgentSession openSession(AgentSessionInit init) {
    return new SimulationAgentSession(init.model());
}
```

`SimulationAgentSession` (package-private): IDLE → ACTIVE → CLOSED state machine. Each `query()` returns the canned response with the model ID. `interrupt()` is a no-op. `close()` transitions to CLOSED.

#### CDI wiring

`SimulationConfigBeans` (in `simulation-config`) gains a `@Produces` method:

```java
@Produces
@ApplicationScoped
SimulatedAgentBackend simulationBackend(Instance<SimulationRuntime> runtime) {
    return new SimulatedAgentBackend(
        runtime.isResolvable() ? runtime.get() : null
    );
}
```

The router discovers it via `Instance<AgentBackend>` like any other backend.

#### Manifest declaration

```yaml
# agent-config-test.yaml
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
  - id: sim-embedding
    backendKey: simulation
    tier: EMBEDDING
    locality: LOCAL

defaults:
  backend: simulation
```

No `providers:` entry needed — the backend is CDI-discovered, not credential-created. Models are sufficient.

### Part 3: Dropped — Ollama BackendInstanceFactory

~~Originally proposed: `OllamaBackendInstanceFactory` for manifest-declared Ollama backends.~~

**Dropped.** Ollama is already CDI-discovered via `OllamaBeans @Produces`. Models with `backendKey: ollama` already route to it. The `BackendInstanceFactory` SPI is designed for credential-gated cloud providers (e.g., Vertex needs project-id + region). Ollama is credential-less — the factory lifecycle (`LlmCredentialStore.listRefs()` → `factory.handles()`) never fires for providers without credentials.

Multi-instance Ollama (different hosts) is a separate concern for a future issue.

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

# production: prefer Claude (no simulation models declared)
defaults:
  backend: claude
```

**Chain fallback:** Chains provide explicit ordering. `ConnectException` or `AgentRateLimitException` trigger fallback to the next entry:

```yaml
aliases:
  fast:
    chain:
      - tier: FAST
        locality: LOCAL
      - tier: FAST
        backend-key: simulation           # Ollama down → simulation
```

**`backendKey` filtering vs tiebreaking:** Chain entry `{ tier: FAST, backend-key: simulation }` is a hard filter — only simulation models match. This is different from `defaults.backend` which is a tiebreaker among all matching models. Both mechanisms compose: `defaults.backend` tiebreaks within each chain entry's candidates.

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
| `platform-api` | `ModelQuery` gains `backendKey` field + Builder method |
| `platform` | `InMemoryModelRegistry.query()` respects `backendKey` filter |
| `agent-config-core` | `ModelQuerySpec` extracted. `AliasDeclaration` gains `chain` + `ChainEntry`. `ManifestProcessor.toModelChain()`. `ManifestResult.aliases` type → `Map<String, ModelChain>`. `AgentConfigLoader` updated for new type. |
| `agent-router-core` | `RoutingAgentProvider`: `resolveAlias()` method, `invoke()` alias→chain reroute, `openSession()` alias→chain reroute. Constructor/factory `aliases` param type → `Map<String, ModelChain>`. |
| `agent-router` | `RouterBeans` updated for new `ManifestResult.aliases` type |
| `agent-simulation-core` | `SimulatedAgentBackend.key()` → `"simulation"`. Nullable `SimulationRuntime`. Canned-response fallback. `SimulationAgentSession` for `openSession()`. |
| `simulation-config` | `@Produces SimulatedAgentBackend` as CDI bean |

## Backwards Compatibility

- Aliases without `chain` continue to work — converted to single-entry chains internally
- Existing `SimulatedAgentBackend` consumers referencing key `"simulated"` need updating (internal to simulation framework only — no external consumers)
- `ManifestResult.aliases` type change requires updating `RoutingAgentProvider.create()`, `RouterBeans`, and any code reading the aliases map
- `ModelQuery` gains a new nullable field — existing code unaffected (null = no filter)

## Test Plan

### Chain alias resolution
- Alias with `chain` resolves to `ModelChain`
- Alias without `chain` resolves to single-entry `ModelChain` (backwards compatible)
- Mixed chain (named + queried entries) resolves correctly
- Chain entry with `backend-key` filter restricts to matching backend
- Empty chain rejected at load time
- `chain` + single-query fields rejected at load time
- `ChainEntry` with `model` + query fields rejected

### Chain fallback — `invoke()` path (reactive)
- LOCAL-first chain resolves to LOCAL when available
- LOCAL-first falls to CLOUD on ConnectException
- LOCAL-first falls to CLOUD on RateLimitException
- Non-retryable errors propagate immediately
- Chain exhaustion throws `ModelChainExhaustedException`

### Chain fallback — `openSession()` path (synchronous)
- Alias chain resolves via `resolveChain()` for session creation
- Availability filter skips unavailable entries
- Single-entry chain works for `openSession()`

### Simulation backend
- Returns canned response without corpus (null SimulationRuntime)
- Returns canned response when corpus has no match
- Returns corpus-matched response with corpus
- Canned response includes model ID
- `openSession()` returns working session (canned-response mode)
- Backend key is `"simulation"`
- CDI-discoverable by router

### `backendKey` filtering
- `ModelQuery` with `backendKey` filters registry results (only matching backend)
- `ModelQuery` without `backendKey` returns all matches (existing behavior)
- `backendKey` filter composes with tier, locality, capabilities filters

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
- `platform-api/ModelQuery.java` — query record (gains backendKey)
- `platform/InMemoryModelRegistry.java` — query filtering
- `agent-router-core/RoutingAgentProvider.java` — chain resolution + retry logic
- `agent-config-core/AliasDeclaration.java` — current alias structure
- `agent-config-core/ManifestProcessor.java` — alias → ModelQuery conversion
- `agent-config-core/ManifestLoader.java` — manifest loading + profile merge
- `agent-config-core/AgentConfigLoader.java` — orchestrates manifest processing
- `agent-simulation-core/SimulatedAgentBackend.java` — existing simulation backend
- `agent-claude/ClaudeVertexBackendFactory.java` — BackendInstanceFactory reference (not used for simulation/Ollama)
- Naming audit: all simulation-related classes, modules, constants audited for noun/adjective consistency
- Design review R1: R1-02 through R1-13 findings addressed
