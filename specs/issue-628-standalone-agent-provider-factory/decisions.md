## D1: Registry SPI justification

**Choice:** Keep `BackendInstanceRegistry` SPI, extract `InMemoryBackendInstanceRegistry` to `agent-router-core`
**Alternatives:**
- Eliminate registry SPI, take `List<AgentBackend>` directly — would break `SessionPoolRegistry` which shares the registry as a lookup contract
- Add new registry abstraction with in-memory + durable — backends are config-derived, not persistent state; durable is actively wrong
**Rationale:** Two independent core-module consumers (RoutingAgentProvider, SessionPoolRegistry) need the same composite (key, instanceId) lookup. The SPI is a shared contract, not over-engineering. Only in-memory is correct — same category as delivery-channel-inmem ("production implementation, channels are static").
**Trade-offs:** Consumers who only need routing still see the registry in the construction path (mitigated by `fromManifest()` factory hiding it entirely)
**Sources:** BackendInstanceRegistry.java (agent-api), SessionPoolRegistry.java (agent-session-core), InMemoryBackendInstanceRegistry.java (agent-router)
**Exploration:** deep-analysis
**Status:** captured

## D2: Consumer-facing API — manifest-driven, no backend leakage

**Choice:** `RoutingAgentProvider.discover(projectDir)` as the primary consumer API. Internally uses AgentConfigLoader (chained manifest hierarchy discovery + merge) and ServiceLoader (backend class discovery). Consumer never sees backend classes.
**Alternatives:**
- `AgentConfigLoader.agentProvider()` — correct instinct but creates circular dependency (config-core ← router-core already exists, can't go both ways)
- `RoutingAgentProvider.of(List<AgentBackend>, ManifestResult)` — leaks backend construction to consumer, duplicates what manifest already declares
- Separate `AgentProviders` utility class — splits construction knowledge away from the type being constructed
**Rationale:** The manifest already declares providers with their configuration (host, model, credentials). The classpath already declares which backend classes are available. Consumer code should not duplicate either. `discover(projectDir)` delegates to AgentConfigLoader.withDefaults() for manifest hierarchy walking + merging + remote sources, and ServiceLoader for backend discovery. One line, zero backend leakage.
**Trade-offs:** ServiceLoader adds META-INF/services files to each backend core module. Acceptable — this is standard Java SPI discovery, and each module already has resources dirs.
**Depends on:** D1 (registry extraction), D7 (BackendProvider SPI), D3 (AgentConfigLoader facade)
**Sources:** RoutingAgentProvider.java (agent-router-core), AgentConfigLoader.java (agent-config-core), ManifestLoader (agent-config-core — hierarchy discovery)
**Exploration:** deep-analysis
**Status:** captured

## D3: Manifest loading facade

**Choice:** Add `AgentConfigLoader.withDefaults(Path)` + `withDefaults(Path, String)` factories with in-memory stubs, plus `modelRegistry()` accessor
**Alternatives:**
- Leave manifest loading out of scope — forces consumers to thread 9 constructor args
- Extract InMemoryModelRegistry from platform to core — that class has CDI scheduling and events; simpler MapMutableModelRegistry is sufficient here
**Rationale:** The 9-arg constructor is the ergonomic barrier. `withDefaults()` provides sensible no-ops (empty credential store, env-only resolver, no-op DID resolver, no-op reconciler) while creating real mutable implementations for LlmCredentialStore and MutableModelRegistry (ManifestProcessor writes to them). Package-private inner classes keep the in-memory impls out of public API.
**Trade-offs:** Package-private stubs mean consumers can't customize individual pieces without using the full 9-arg constructor. Acceptable — a builder could be added later if needed.
**Depends on:** D2 (discover() uses this internally)
**Sources:** AgentConfigLoader.java (agent-config-core), ManifestProcessor (agent-config-core)
**Exploration:** deep-analysis
**Status:** captured

## D4: Route observability

**Choice:** Add `backendKey` and `instanceId` fields to `AgentEvent.InvocationComplete` record
**Alternatives:**
- New `AgentEvent.RoutingResolved` event type emitted before streaming — adds a new event type consumers must handle
- Metadata map on AgentSessionConfig — wrong direction, config is input not output
**Rationale:** `InvocationComplete` is already the terminal event carrying cost/usage/timing metadata. Adding routing info there is consistent — consumers already process it for post-invocation metrics. No new event types needed.
**Trade-offs:** Routing info only available after completion, not during streaming. For observability (the stated use case), this is fine — route decisions are logged post-invocation.
**Sources:** AgentEvent.java (agent-api) — InvocationComplete record
**Exploration:** quick
**Status:** captured

## D5: ModelRegistry.empty() placement

**Choice:** Static factory method on `ModelRegistry` interface in `platform-api`
**Alternatives:**
- NoOpModelRegistry class in agent-router-core — adds a named class for a trivial constant
- Inline anonymous impl in RoutingAgentProvider — hides the pattern, not reusable
**Rationale:** Follows `ManifestResult.empty()` pattern. `platform-api` is zero-dep but static factory methods with private inner impls don't add dependencies. Reusable by any module that needs an empty model registry for testing or standalone use.
**Trade-offs:** Puts implementation (trivial as it is) in the API module. Acceptable for static-factory-on-interface pattern.
**Sources:** ModelRegistry.java (platform-api), ManifestResult.java (agent-config-core)
**Exploration:** quick
**Status:** captured

## D6: Backend convenience constructors — SUPERSEDED

**Choice:** ~~Add direct-parameter constructors to backend core classes~~ → Superseded by D7 (BackendProvider SPI). Backend construction is internal to ServiceLoader-discovered providers, not consumer-facing. No convenience constructors needed on backend classes.
**Status:** superseded

## D7: BackendProvider SPI + ServiceLoader discovery

**Choice:** New `BackendProvider` SPI in `agent-api` with ServiceLoader registration in each backend core module
**Alternatives:**
- Hard-coded vendor→backend mapping in a single module — dependency fan-out, fragile when adding new backends
- Convention-based Class.forName() discovery — brittle, no compile-time safety, obscure failures
- CDI-only (status quo) — the reason this issue exists
**Rationale:** ServiceLoader is standard Java SPI discovery. Each backend core module declares a `BackendProvider` implementation that knows how to create itself from manifest properties (Map<String, String>). Discovery happens at `RoutingAgentProvider.discover()` time — match manifest vendor keys to classpath-available providers. Same principle as CDI discovery but without the container.
**Trade-offs:** Each backend core needs a META-INF/services file + BackendProvider implementation class (~20 lines each). Acceptable — this is the standard pattern and each module already has a resources directory.
**Sources:** BackendInstanceFactory.java (agent-api — existing credential-driven factory pattern), ServiceLoader (java.util)
**Exploration:** deep-analysis
**Status:** captured

## D8: ManifestResult expansion — carry provider declarations

**Choice:** Expand `ManifestResult` record to include `Map<String, ProviderDeclaration> providers` — vendor key to properties mapping
**Alternatives:**
- Return a separate result type from a new loader method — fragments the API, two result types for the same manifest
- Have discover() re-parse the manifest independently — wasteful, duplicates ManifestLoader work
**Rationale:** ManifestResult currently only carries (aliases, defaultBackendKey, pools). The provider entries (vendor key + properties) are consumed by ManifestProcessor and discarded. For ServiceLoader-based backend creation, discover() needs the provider entries. Adding them to ManifestResult keeps one canonical result type from manifest loading.
**Trade-offs:** ManifestResult record grows. Existing consumers see a new field but don't need to use it. Record expansion is backward-compatible for construction (existing callers can use the new constructor).
**Depends on:** D7 (ServiceLoader providers consume the declarations)
**Sources:** ManifestResult.java (agent-config-core)
**Exploration:** quick
**Status:** captured
