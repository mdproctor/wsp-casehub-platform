# Decisions — #623 Manifest-Driven Model Chains

## D1: Simulation backend — new class vs enhance existing

**Choice:** Enhance existing `SimulatedAgentBackend` rather than creating a separate backend
**Alternatives:**
- New `SyntheticAgentBackend` (key: `"synthetic"`) — clean separation but creates two agent-level simulation concepts that overlap
- Unify under a new class, deprecate existing — unnecessary churn for a working class
**Rationale:** The simulation backend and the manifest-driven "always-available provider" are the same concept at different levels of sophistication. Without corpus → canned responses; with corpus → realistic responses. One backend, one concept. The application code is invariant — it asks for a tier, the manifest determines what answers.
**Trade-offs:** The backend pulls `simulation-core` dependencies even for the no-corpus case. Acceptable because `yaml-core` (the transitive dep) is zero-dependency and lightweight.
**Sources:** `agent-simulation-core/SimulatedAgentBackend.java`, `simulation-core/SimulationRuntime.java`
**Exploration:** deep-analysis
**Status:** captured

## D2: Backend key naming — "simulation" vs "simulated"

**Choice:** Rename backend key from `"simulated"` to `"simulation"`
**Alternatives:**
- Keep `"simulated"` — inconsistent with all other backend keys which are nouns
- Use `"synthetic"` — introduces vocabulary that doesn't exist elsewhere in the codebase
**Rationale:** Every other backend key is a noun naming the provider: `"claude"`, `"openai"`, `"ollama"`, `"gemini"`, `"codex"`, `"langchain4j"`. The key names the provider, not describes the implementation. `"simulation"` (noun) follows this convention. The class name `SimulatedAgentBackend` stays — it IS a simulated backend (adjective is correct for the class). Full codebase audit confirmed: "Simulation" (noun) is used for framework/modules/engine; "Simulated" (adjective) for decorators and implementations. The backend key was the sole inconsistency.
**Trade-offs:** Requires updating any test code that references the `"simulated"` key string. Minimal — the key is internal to the simulation framework.
**Sources:** Naming audit across all simulation-related classes, modules, and constants
**Exploration:** deep-analysis
**Status:** captured

## D3: Discovery mechanism — CDI bean vs BackendInstanceFactory

**Choice:** Simple CDI bean (like Claude/OpenAI/Gemini), not a BackendInstanceFactory
**Alternatives:**
- BackendInstanceFactory — for dynamic creation from credentials, but simulation needs no credentials
**Rationale:** `BackendInstanceFactory` exists for credential-based dynamic backend creation (e.g., `ClaudeVertexBackendFactory` creates Vertex-configured instances from GCP credentials). The simulation backend needs no credentials and no dynamic configuration — it's always available. A CDI-produced `@ApplicationScoped` bean is the correct pattern, consistent with how most backends are discovered.
**Trade-offs:** No per-provider-declaration customization. Not needed — one simulation backend handles all simulation models.
**Sources:** `agent-claude/ClaudeVertexBackendFactory.java`, `agent-router/RouterBeans.java`
**Exploration:** quick
**Status:** captured

## D4: Alias chain type representation

**Choice:** `ManifestResult.aliases` changes from `Map<String, ModelQuery>` to `Map<String, ModelChain>` — single-query aliases become one-entry chains
**Alternatives:**
- Sealed interface `AliasResolution` with `SingleQuery` / `ChainResolution` variants — adds type complexity for no behavioral difference
- Separate maps for queries and chains — router would need to check both
**Rationale:** A single `ModelQuery` alias is semantically equivalent to a one-entry `ModelChain` with a `Queried` entry. Unifying the representation eliminates branching in the router — all aliases resolve through chain resolution. `ModelChain` already supports mixed `Named`/`Queried` entries. The chain resolution logic (reactive retry + synchronous fallback) already exists in `RoutingAgentProvider`.
**Trade-offs:** Slight overhead wrapping single queries in a chain. Negligible — chain resolution with one entry is equivalent to direct query resolution.
**Depends on:** None
**Sources:** `platform-api/ModelChain.java`, `agent-router-core/RoutingAgentProvider.java`
**Exploration:** quick
**Status:** captured

## D5: Routing selection mechanism — simulation vs real

**Choice:** No simulation-specific routing logic. Selection is purely via existing `defaults.backend` tiebreaking and chain ordering.
**Alternatives:**
- Simulation-aware routing (explicit fallback-to-simulation logic) — violates the design goal of provider-agnostic application code
**Rationale:** Simulation models are declared with real tier and locality values (e.g., `tier: FAST, locality: LOCAL`). A tier query matches both simulation and real models. The existing `defaults.backend` tiebreaker selects: `defaults.backend: simulation` → simulation wins; `defaults.backend: ollama` → Ollama wins. Same chain alias, different result per profile. In production, simulation models aren't declared — the fallback path doesn't exist, not because code prevents it, but because there's nothing to match.
**Trade-offs:** Relies on manifest authors setting `defaults.backend` correctly per profile. This is the intended design — environment differences are configuration, not code.
**Sources:** `RoutingAgentProvider.resolve()` step 0 alias lookup + tiebreaking logic
**Exploration:** deep-analysis
**Status:** captured
