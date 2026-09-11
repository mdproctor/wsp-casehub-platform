## D1: Integration with RoutingAgentProvider — model reference resolution

**Choice:** Expand `AgentSessionConfig.model` semantics in-place — RoutingAgentProvider gains optional ModelRegistry awareness
**Alternatives:**
- Separate query surface (callers query ModelRegistry, extract backendKey, build config) — unnecessary ceremony, two-step dance for every caller
- Replace model String with structured ModelRef type — over-engineering for this stage; String works because the resolution is transparent to callers
**Rationale:** `AgentSessionConfig.model` stays a String but its meaning broadens from "backend key" to "model reference" — could be a specific model ID ("claude-sonnet-5") or a backend key ("claude"). RoutingAgentProvider resolves via: registry → key-based → langchain4j fallback. Callers don't change. Backends don't change. ModelRegistry injected as optional @DefaultBean no-op. The router is the natural Layer 1/Layer 2 composition point. Terminology improves — `model` was misleading before (meant backend key), now genuinely means "model."
**Trade-offs:** RoutingAgentProvider gains a dependency on ModelRegistry — but it's optional (@DefaultBean no-op when absent) and the router is already the composition boundary between execution and selection.
**Sources:** RoutingAgentProvider.java (resolve method), AgentSessionConfig.java (model field), AgentBackend.java (key method), epic #285 layer model
**Exploration:** quick
**Status:** captured

## D2: ModelDescriptor record shape

**Choice:** Flat record with typed enum dimensions + extensible properties map
**Alternatives:**
- All-string dimensions — maximum extensibility but no type safety, no IDE completion, string comparison predicates
- Nested records (ModelIdentity, ModelLimits, ModelClassification) — adds indirection for no clear benefit at this scale
**Rationale:** Known dimensions (tier, capability, locality, cost) are genuinely finite — enums enforce valid values and enable clean query predicates. String-based vendor and backendKey for extensibility. Properties map covers the long tail (vendor-specific metadata) without bloating the record. Pre-release: new dimensions promote from properties to typed fields as needed.
**Trade-offs:** Adding a new typed dimension requires a record change and enum addition — acceptable pre-release; post-release would use properties first.
**Sources:** epic #285 queryable dimensions table, AgentBackend.key() (backendKey foreign key), eidos AgentDescriptor.modelFamily (downstream consumer of id field)
**Exploration:** quick
**Status:** captured

## D3: ModelRegistry SPI — query contract

**Choice:** Predicate-based query with ModelQuery record
**Alternatives:**
- Fluent filter chain (registry.models().vendor("x").list()) — ergonomic but requires custom builder/stream type, more API surface
- Single all() method, callers filter — minimal SPI but every caller reimplements filtering, no standard query semantics
**Rationale:** ModelQuery record is simple, serializable (works over REST/MCP), and keeps filtering logic in the registry implementation. resolveById is the fast-path integration with RoutingAgentProvider. query() returns all matching descriptors. Builder provides ergonomic construction without custom stream types.
**Trade-offs:** ModelQuery record must evolve when new dimensions are added — acceptable pre-release. Post-release, new nullable fields with null=any semantics are backward compatible.
**Sources:** RoutingAgentProvider.resolve() (resolveById integration point), epic #285 MCP tools (ModelQuery serializable for REST/MCP)
**Exploration:** quick
**Status:** captured

## D4: ModelSource SPI — refresh contract

**Choice:** Pull-based refresh with lastRefreshed hint for incremental efficiency
**Alternatives:**
- Push-based registration (sources call registry.register/deregister) — sources must track lifecycle, handle restarts. More complex for no benefit — vendor APIs are pull-based
- Delta-based refresh (return added/removed/updated) — over-engineering for a catalog of tens to low hundreds of models. Full replacement is cheap and eliminates stale-entry bugs
**Rationale:** Simple pull-based contract: registry calls refresh() on each source periodically, passing the timestamp of the last successful refresh. Sources that support incremental APIs can use the hint; sources that don't ignore it and return the full catalog. Registry replaces that source's entries atomically. Error-isolated per source. The contract: `refresh(Instant lastRefreshed)` returns the complete current catalog from this source's perspective. The hint is advisory — sources always MAY return the full list.
**Trade-offs:** Full replacement per source means re-transmitting unchanged entries on every refresh. Acceptable: catalog is small, refresh is infrequent (minutes to hours), and full replacement eliminates stale-entry tracking bugs.
**Sources:** Anthropic /v1/models API, OpenAI /v1/models API, Ollama /api/tags API (all return full lists)
**Exploration:** quick
**Status:** captured
