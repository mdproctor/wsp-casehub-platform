## D1: Integration with RoutingAgentProvider — model reference resolution

**Choice:** Expand `AgentSessionConfig.model` semantics in-place — RoutingAgentProvider gains ModelRegistry awareness with explicit resolution contract and config rewriting
**Alternatives:**
- Separate query surface (callers query ModelRegistry, extract backendKey, build config) — unnecessary ceremony, two-step dance for every caller
- Replace model String with structured ModelRef type — over-engineering; the overloading problem is resolved by the router's resolution contract, not by the type system. ModelRef as a String wrapper adds indirection without semantic power; ModelRef as a sealed hierarchy forces callers to choose a variant (backend key vs model ID) — knowledge they may not have in config-driven scenarios
**Rationale:** `AgentSessionConfig.model` stays a String but its resolution semantics are now explicit. RoutingAgentProvider resolves via a three-step contract:
1. **Registry path:** `ModelRegistry.resolveById(model)` — if found, create new `AgentSessionConfig` with the model-specific API identifier from the descriptor, route to the backend identified by `descriptor.backendKey()`
2. **Key-based path:** `backends.get(model)` — if found, create new `AgentSessionConfig` with `model=null` (backend uses its configured default model), route to matched backend
3. **Fail-fast:** if neither matches, throw `IllegalArgumentException` — no silent langchain4j fallback for non-null model references

The config rewriting in steps 1 and 2 eliminates the semantic overloading: backends always receive either a model-specific API identifier (e.g., `"gpt-4o"` for OpenAI) or null (use default). The langchain4j catch-all remains only for `model=null` with no configured default backend.
**Trade-offs:** RoutingAgentProvider gains a dependency on ModelRegistry (via `@DefaultBean` no-op when absent). The config rewriting step creates a new `AgentSessionConfig` per invocation — acceptable cost for semantic correctness. Key-based path nulls the model field, so backends that previously read `config.model()` as both routing key and API identifier (OpenAiAgentBackend) now correctly fall through to their configured default.
**Sources:** RoutingAgentProvider.java (resolve method), AgentSessionConfig.java (model field), AgentBackend.java (key method), OpenAiAgentBackend.java (model ID usage in buildEventStream), ClaudeAgentProvider.java (ignores config.model()), ChatModelAgentProvider.java (ignores config.model()), epic #285 layer model
**Exploration:** quick
**Status:** revised — R1-02: explicit resolution contract with config rewriting eliminates triple semantic overloading; R1-03: fail-fast replaces silent langchain4j fallback; R1-04: resolved-but-missing-backend now fails instead of falling through

## D2: ModelDescriptor record shape

**Choice:** Flat record with typed enum dimensions + extensible properties map
**Alternatives:**
- All-string dimensions — maximum extensibility but no type safety, no IDE completion, string comparison predicates
- Nested records (ModelIdentity, ModelLimits, ModelClassification) — adds indirection for no clear benefit at this scale
- Remove backendKey, resolve binding separately — moves the model→backend binding out of the descriptor into external configuration. ModelDescriptor is the cross-layer integration artifact between Layer 2 (model selection) and Layer 1 (backend execution) — it naturally carries the binding information. Each ModelSource knows which backend serves its models; encoding that in the descriptor keeps it self-contained and eliminates the need for a separate vendor→backend configuration surface
**Rationale:** Known dimensions (tier, capability, locality, cost) are genuinely finite — enums enforce valid values and enable clean query predicates. String-based vendor and backendKey for extensibility. Properties map covers the long tail (vendor-specific metadata) without bloating the record. Pre-release: new dimensions promote from properties to typed fields as needed. backendKey is a deployment binding, not a Platonic model property — but ModelDescriptor describes a model-as-served-by-a-specific-source, which naturally includes deployment context. The same base model (e.g., Llama 3) served by different backends produces different descriptors from different ModelSources, correctly reflecting their distinct deployment characteristics.
**Trade-offs:** Adding a new typed dimension requires a record change and enum addition — acceptable pre-release; post-release would use properties first. backendKey ties the descriptor to a specific backend — intentional, since each descriptor comes from a source that knows its backend.
**Sources:** epic #285 queryable dimensions table, AgentBackend.key() (backendKey foreign key), eidos AgentDescriptor.modelFamily (downstream consumer of id field)
**Exploration:** quick
**Status:** captured

## D3: ModelRegistry SPI — query contract

**Choice:** Predicate-based query with ModelQuery record; existing MCP `ModelRegistry` renamed to `DomainModelRegistry` to resolve naming collision
**Alternatives:**
- Fluent filter chain (registry.models().vendor("x").list()) — ergonomic but requires custom builder/stream type, more API surface
- Single all() method, callers filter — minimal SPI but every caller reimplements filtering, no standard query semantics
- Naming the new SPI `LlmModelRegistry` or `AiModelRegistry` — the new SPI is the architecturally significant concept; the existing MCP class (a registry of `DomainModel` objects for domain-index metadata) is the one to rename
**Rationale:** ModelQuery record is simple, serializable (works over REST/MCP), and keeps filtering logic in the registry implementation. resolveById is the fast-path integration with RoutingAgentProvider. query() returns all matching descriptors. Builder provides ergonomic construction without custom stream types. The existing `io.casehub.platform.mcp.ModelRegistry` (consumed by `DomainResourceRegistrar` for MCP domain-index resources) is renamed to `DomainModelRegistry` to eliminate the naming collision — both classes are `@ApplicationScoped`, same repo, different packages, different concepts. The new SPI takes the unqualified name `ModelRegistry` because it's the more significant concept.
**Trade-offs:** ModelQuery record must evolve when new dimensions are added — acceptable pre-release. Post-release, new nullable fields with null=any semantics are backward compatible. Renaming the existing MCP class requires updating its one consumer (`DomainResourceRegistrar`) and its test.
**Sources:** RoutingAgentProvider.resolve() (resolveById integration point), epic #285 MCP tools (ModelQuery serializable for REST/MCP), io.casehub.platform.mcp.ModelRegistry (existing naming collision), DomainResourceRegistrar (sole consumer of existing class)
**Exploration:** quick
**Status:** revised — R1-10: existing MCP ModelRegistry renamed to DomainModelRegistry to resolve naming collision

## D4: ModelSource SPI — refresh contract

**Choice:** Pull-based refresh with no-arg `refresh()`; `ModelCatalogRefreshedEvent` CDI event after each refresh cycle
**Alternatives:**
- Push-based registration (sources call registry.register/deregister) — sources must track lifecycle, handle restarts. More complex for no benefit — vendor APIs are pull-based
- Delta-based refresh (return added/removed/updated) — over-engineering for a catalog of tens to low hundreds of models. Full replacement is cheap and eliminates stale-entry bugs
- `refresh(Instant lastRefreshed)` with incremental hint — YAGNI. No current vendor API (Anthropic `/v1/models`, OpenAI `/v1/models`, Ollama `/api/tags`) supports incremental refresh. Sources that need internal state tracking for future delta APIs can manage their own cursor without SPI surface
- No observation model (consumers poll/tolerate stale data) — inconsistent with platform conventions. The platform uses CDI events for all lifecycle changes (EndpointRegistered, DataSourceRegistered, NotificationCreated, SubscriptionCreated, etc.)
**Rationale:** Simple pull-based contract: registry calls `refresh()` on each source periodically. Sources return the complete current catalog from their perspective. Registry replaces that source's entries atomically. Error-isolated per source. Contract: `refresh()` returns `List<ModelDescriptor>`. After each successful refresh cycle, the registry fires a `ModelCatalogRefreshedEvent` CDI event, following the established platform pattern. This enables consumers (RoutingAgentProvider resolution cache, eidos model-family mappings, MCP tool responses) to invalidate caches reactively without polling.
**Trade-offs:** Full replacement per source means re-transmitting unchanged entries on every refresh. Acceptable: catalog is small, refresh is infrequent (minutes to hours), and full replacement eliminates stale-entry tracking bugs. CDI event fires on every refresh cycle even when nothing changed — consumers must compare if change-detection matters. No-arg refresh means sources that support future incremental APIs must track their own cursor — acceptable, since the registry's concern is the result, not how the source obtained it.
**Sources:** Anthropic /v1/models API, OpenAI /v1/models API, Ollama /api/tags API (all return full lists), EndpointRegistered/DataSourceRegistered/NotificationCreated (established CDI event patterns in platform-api)
**Exploration:** quick
**Status:** revised — R1-13: removed lastRefreshed parameter (YAGNI, no vendor API supports incremental refresh); R1-14: added ModelCatalogRefreshedEvent CDI event following established platform patterns

## D5: Registry implementation placement

**Choice:** In-memory ConcurrentHashMap registry in `platform/`, no-op `@DefaultBean` in `platform/`, source-priority model ID resolution
**Depends on:** D3 (ModelRegistry SPI shape)
**Alternatives:**
- New `model-registry/` module — the registry is a thin cache with a scheduled refresher, doesn't warrant its own module
- Namespace IDs by source (e.g., `seed:llama3`, `ollama:llama3`) — breaks resolveById for callers who don't know the source
- Composite keys (vendor + id) — requires callers to specify vendor alongside model ID, unnecessary ceremony
**Rationale:** ConcurrentHashMap keyed by model ID, atomic replacement per source via ModelRegistryRefresher. @Startup initial refresh, @Scheduled periodic refresh. Error-isolated per source. No persistence — registry is a cache, sources are the truth. Seed catalog (#287) on the same branch provides the initial data. Follows platform's established pattern: SPI in platform-api, @ApplicationScoped impl in platform.

Cross-source model ID uniqueness: resolved by explicit source-priority ordering. Sources are ordered by priority (configurable, with a sensible default: live API sources > seed catalog). When two sources provide models with the same ID, the higher-priority source's descriptor wins. This is deterministic regardless of refresh timing. The source priority is configured once at startup, not per-refresh. Lower-priority entries for the same ID are shadowed, not lost — a refresh that removes the higher-priority entry reveals the lower-priority one.
**Trade-offs:** Lost on restart — repopulated from seed catalog immediately, live sources within first refresh cycle. No persistence needed for a cache. Priority-based resolution means a higher-priority ModelSource may shadow a lower-priority source's entries for the same model ID — this is intentional, logged at WARN level, and deterministic.
**Sources:** platform NoOpCaseMemoryStore pattern, DataSourceRouter @ApplicationScoped pattern
**Exploration:** quick
**Status:** revised — R1-16: added explicit source-priority model ID uniqueness strategy; deterministic resolution regardless of refresh timing

## D6: AgentDescriptor.modelFamily → ModelDescriptor binding contract

**Choice:** modelFamily is a vendor-level family identifier that maps to ModelDescriptor.vendor, not a foreign key to ModelDescriptor.id
**Alternatives:**
- modelFamily as foreign key to ModelDescriptor.id — breaks across model generations (claude-sonnet-4 → claude-sonnet-5), forces callers to track specific model IDs
- modelFamily as a separate ModelDescriptor dimension (family enum) — adds a new dimension that duplicates vendor semantics at current scale
- Undefined (leave implicit) — creates a semantic gap between Layer 2 (model selection) and Layer 3 (agent selection) with no defined contract
**Rationale:** Examination of current usage shows modelFamily values are vendor-level identifiers: `"claude"` (in @Identity annotations across GoapAnnotatedCase, WarehouseCase, AircraftMaintenanceCase, SearchRescueCase, IncidentResponseCase, WildfireResponseCase), `"gpt-4"` (in YAML test fixtures). These correspond to ModelDescriptor.vendor, not to specific model IDs. The binding contract: when eidos selects an agent with `modelFamily="claude"`, the model selection layer queries ModelRegistry with `vendor="claude"` (and optionally tier/capability filters) to find available models. modelVersion on AgentDescriptor provides optional specificity within a family — e.g., `modelFamily="claude"`, `modelVersion="sonnet-5"` narrows the query. The `provider` field on AgentDescriptor is orthogonal — it identifies the agent platform provider (e.g., `"casehub"`), not the LLM vendor.
**Trade-offs:** Vendor-level granularity means `modelFamily="claude"` matches all Claude models (Haiku through Opus). Additional filtering by tier and capabilities is needed to narrow selection. This is intentional — the agent descriptor declares a family preference, and the routing layer selects the specific model based on available capacity and capability requirements.
**Sources:** AgentDescriptor.java (modelFamily, modelVersion, provider fields), YamlAgentDescriptor.java (YAML binding), @Identity annotation examples (modelFamily = "claude"), epic #285 three-layer model (Layer 3 → Layer 2 binding)
**Exploration:** quick (surfaced by R1-07)
**Status:** captured
