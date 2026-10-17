## D1: Registry SPI justification

**Choice:** Keep `BackendInstanceRegistry` SPI, extract `InMemoryBackendInstanceRegistry` to `agent-router-core`
**Alternatives:**
- Eliminate registry SPI, take `List<AgentBackend>` directly — would break `SessionPoolRegistry` which shares the registry as a lookup contract
- Add new registry abstraction with in-memory + durable — backends are config-derived, not persistent state; durable is actively wrong
**Rationale:** Two independent core-module consumers (RoutingAgentProvider, SessionPoolRegistry) need the same composite (key, instanceId) lookup. The SPI is a shared contract, not over-engineering. Only in-memory is correct — same category as delivery-channel-inmem ("production implementation, channels are static").
**Trade-offs:** Consumers who only need routing still see the registry in the construction path (mitigated by `RoutingAgentProvider.of()` factories)
**Sources:** BackendInstanceRegistry.java (agent-api), SessionPoolRegistry.java (agent-session-core), InMemoryBackendInstanceRegistry.java (agent-router)
**Exploration:** deep-analysis
**Status:** captured

## D2: Convenience factory placement

**Choice:** Static `of()` factory methods on `RoutingAgentProvider` with 3 overloads (varargs, +manifest, +manifest+modelRegistry)
**Alternatives:**
- Builder pattern on RoutingAgentProvider — overkill for 3 clear tiers of parameters, adds API surface
- Separate `AgentProviders` utility class — splits construction knowledge away from the class it constructs
**Rationale:** Follows `List.of()`, `ManifestResult.empty()` patterns already in the codebase. The factory internally creates `InMemoryBackendInstanceRegistry` and `ModelRegistry.empty()`, hiding the registry from simple consumers. Three overloads map to three real use cases: single backend, manifest-driven, full model resolution.
**Trade-offs:** Varargs overload uses first backend as default — implicit convention, but matches the common "I have one backend" case
**Sources:** RoutingAgentProvider.java (agent-router-core) — existing `create()` factories
**Exploration:** deep-analysis
**Status:** captured

## D3: Manifest loading facade scope

**Choice:** Add `AgentConfigLoader.withDefaults(Path)` + `withDefaults(Path, String)` factories with in-memory stubs, plus `modelRegistry()` accessor
**Alternatives:**
- Leave manifest loading out of scope — forces consumers to construct ManifestResult records manually, doesn't address the 9-arg constructor barrier
- Extract InMemoryModelRegistry from platform to core — that class has CDI scheduling and events; a simpler MapMutableModelRegistry is sufficient here
**Rationale:** The 9-arg constructor is the real ergonomic barrier. `withDefaults()` provides sensible no-ops (empty credential store, env-only resolver, no-op DID resolver, no-op reconciler) while creating real mutable implementations for LlmCredentialStore and MutableModelRegistry (ManifestProcessor writes to them). Package-private inner classes keep the in-memory impls out of public API.
**Trade-offs:** Package-private stubs mean consumers can't customize individual pieces without using the full 9-arg constructor. Acceptable for S-scale issue; a builder could be added later if needed.
**Depends on:** D2 (convenience factories consume ManifestResult from this loader)
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
- Inline anonymous impl in RoutingAgentProvider.of() — hides the pattern, not reusable
**Rationale:** Follows `ManifestResult.empty()` pattern. `platform-api` is zero-dep but static factory methods with private inner impls don't add dependencies. Reusable by any module that needs an empty model registry for testing or standalone use.
**Trade-offs:** Puts implementation (trivial as it is) in the API module. Acceptable for static-factory-on-interface pattern already used throughout Java stdlib.
**Sources:** ModelRegistry.java (platform-api), ManifestResult.java (agent-config-core)
**Exploration:** quick
**Status:** captured

## D6: Backend convenience constructors

**Choice:** Add direct-parameter constructors to backend core classes (starting with `OllamaAgentBackend`) alongside existing properties-interface constructors
**Alternatives:**
- Inline record implementing the properties interface — adds a type for each backend just to satisfy construction
- Require consumers to implement the properties interface — defeats the purpose of standalone ergonomics
**Rationale:** Backend `-core` classes currently take properties interfaces (e.g., `OllamaAgentProperties`) designed for Quarkus `@ConfigMapping` binding. Programmatic construction needs direct parameters: `new OllamaAgentBackend(host, model, timeout, maxSessions)`. The properties-interface constructor stays for CDI wiring; the direct constructor delegates to it via an anonymous/inner implementation.
**Trade-offs:** Two constructors per backend core class. Acceptable — one is the CDI path, one is the standalone path. Both are stable APIs.
**Depends on:** D2 (convenience factories show backends being constructed inline)
**Sources:** OllamaAgentBackend.java (agent-ollama-core), OllamaAgentProperties.java (agent-ollama-core)
**Exploration:** quick
**Status:** captured
