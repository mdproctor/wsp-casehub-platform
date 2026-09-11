## D1: Integration with RoutingAgentProvider — model reference resolution

**Choice:** Expand `AgentSessionConfig.model` semantics in-place — RoutingAgentProvider gains ModelRegistry awareness with explicit resolution contract and config rewriting
**Alternatives:**
- Separate query surface (callers query ModelRegistry, extract backendKey, build config) — unnecessary ceremony, two-step dance for every caller
- Replace model String with structured ModelRef type — over-engineering; the overloading problem is resolved by the router's resolution contract, not by the type system. ModelRef as a String wrapper adds indirection without semantic power; ModelRef as a sealed hierarchy forces callers to choose a variant (backend key vs model ID) — knowledge they may not have in config-driven scenarios
**Rationale:** `AgentSessionConfig.model` stays a String but its resolution semantics are now explicit. RoutingAgentProvider resolves via a three-step contract:
1. **Registry path:** `ModelRegistry.resolveById(model)` — if found, validate that `backends.get(descriptor.backendKey())` is available. If the backend is missing, throw `IllegalStateException` identifying both the resolved model reference and the missing backend key (e.g., "ModelRegistry resolved 'claude-sonnet-5' to backend 'claude', but no backend with that key is available"). If the backend is present, create new `AgentSessionConfig` with the model-specific API identifier from the descriptor, route to the backend.
2. **Key-based path:** `backends.get(model)` — if found, create new `AgentSessionConfig` with `model=null` (backend uses its configured default model), route to matched backend
3. **Fail-fast:** if neither matches, throw `IllegalArgumentException` — no silent langchain4j fallback for non-null model references

The `model=null` path is unchanged from the current implementation: use the configured `defaultBackend`; if no default backend is configured, throw `IllegalStateException` (as `RoutingAgentProvider.resolve()` does today).

The config rewriting in steps 1 and 2 eliminates the semantic overloading: backends always receive either a model-specific API identifier (e.g., `"gpt-4o"` for OpenAI) or null (use default).
**Trade-offs:** RoutingAgentProvider gains a dependency on ModelRegistry (via `@DefaultBean` no-op when absent). The config rewriting step creates a new `AgentSessionConfig` per invocation — acceptable cost for semantic correctness. Key-based path nulls the model field, so backends that previously read `config.model()` as both routing key and API identifier (OpenAiAgentBackend) now correctly fall through to their configured default.
**Sources:** RoutingAgentProvider.java (resolve method), AgentSessionConfig.java (model field), AgentBackend.java (key method), OpenAiAgentBackend.java (model ID usage in buildEventStream), ClaudeAgentProvider.java (ignores config.model()), ChatModelAgentProvider.java (ignores config.model()), epic #285 layer model
**Exploration:** quick
**Status:** revised — R1-02: explicit resolution contract with config rewriting eliminates triple semantic overloading; R1-03: fail-fast replaces silent langchain4j fallback; R1-04: step 1 now explicitly validates backend availability after registry resolution; R2-03: removed misleading langchain4j sentence, clarified model=null path preserves current behavior

## D2: ModelDescriptor record shape

**Choice:** Flat record with typed enum dimensions, `family` grouping field, and extensible properties map
**Alternatives:**
- All-string dimensions — maximum extensibility but no type safety, no IDE completion, string comparison predicates
- Nested records (ModelIdentity, ModelLimits, ModelClassification) — adds indirection for no clear benefit at this scale
- Remove backendKey, resolve binding separately — moves the model→backend binding out of the descriptor into external configuration. ModelDescriptor is the cross-layer integration artifact between Layer 2 (model selection) and Layer 1 (backend execution) — it naturally carries the binding information. Each ModelSource knows which backend serves its models; encoding that in the descriptor keeps it self-contained and eliminates the need for a separate vendor→backend configuration surface
- No family field, use vendor for family grouping — fails when vendor and family diverge (vendor="openai" but family="gpt-4"; vendor="anthropic" but family="claude"; vendor="google" but family="gemini")
**Rationale:** Known dimensions (tier, capability, locality, cost) are genuinely finite — enums enforce valid values and enable clean query predicates. The `family` field groups models by product lineage (e.g., `"claude"`, `"gpt-4"`, `"gemini"`, `"llama"`), distinct from `vendor` (the company: `"anthropic"`, `"openai"`, `"google"`, `"meta"`). This separation is necessary because vendor and family diverge: OpenAI's vendor is `"openai"` but its families are `"gpt-4"`, `"o3"`, etc. The `family` field is the binding target for eidos `AgentDescriptor.modelFamily` (see D6). String-based vendor, family, and backendKey for extensibility. Properties map covers the long tail (vendor-specific metadata) without bloating the record. Pre-release: new dimensions promote from properties to typed fields as needed. backendKey is a deployment binding, not a Platonic model property — but ModelDescriptor describes a model-as-served-by-a-specific-source, which naturally includes deployment context.
**Trade-offs:** Adding a new typed dimension requires a record change and enum addition — acceptable pre-release; post-release would use properties first. backendKey ties the descriptor to a specific backend — intentional, since each descriptor comes from a source that knows its backend. The `family` field adds a dimension that must be populated by every ModelSource — acceptable because family grouping is natural and every vendor's product line already has this structure.
**Sources:** epic #285 queryable dimensions table, AgentBackend.key() (backendKey foreign key), eidos AgentDescriptor.modelFamily (downstream consumer of family field)
**Exploration:** quick
**Status:** revised — R1-07/R2: added `family` field to separate product lineage from vendor identity; the vendor/family divergence (vendor="openai" but modelFamily="gpt-4") makes a dedicated family field necessary

## D3: ModelRegistry SPI — query contract

**Choice:** Predicate-based query with ModelQuery record; existing MCP `DomainModelRegistry` renamed to `DomainModelRegistry` to resolve naming collision
**Alternatives:**
- Fluent filter chain (registry.models().vendor("x").list()) — ergonomic but requires custom builder/stream type, more API surface
- Single all() method, callers filter — minimal SPI but every caller reimplements filtering, no standard query semantics
- Naming the new SPI `LlmModelRegistry` or `AiModelRegistry` — the new SPI is the architecturally significant concept; the existing MCP class (a registry of `DomainModel` objects for domain-index metadata) is the one to rename
**Rationale:** ModelQuery record is simple, serializable (works over REST/MCP), and keeps filtering logic in the registry implementation. resolveById is the fast-path integration with RoutingAgentProvider. query() returns all matching descriptors. Builder provides ergonomic construction without custom stream types. ModelQuery includes a `family` filter (nullable, null=any) alongside vendor, tier, and capabilities. The existing `io.casehub.platform.mcp.ModelRegistry` (consumed by `DomainResourceRegistrar` for MCP domain-index resources) is renamed to `DomainModelRegistry` to eliminate the naming collision — both classes are `@ApplicationScoped`, same repo, different packages, different concepts. The new SPI takes the unqualified name `DomainModelRegistry` because it's the more significant concept.
**Trade-offs:** ModelQuery record must evolve when new dimensions are added — acceptable pre-release. Post-release, new nullable fields with null=any semantics are backward compatible. Renaming the existing MCP class requires updating its one consumer (`DomainResourceRegistrar`) and its test.
**Sources:** RoutingAgentProvider.resolve() (resolveById integration point), epic #285 MCP tools (ModelQuery serializable for REST/MCP), io.casehub.platform.mcp.ModelRegistry (existing naming collision), DomainResourceRegistrar (sole consumer of existing class)
**Exploration:** quick
**Status:** revised — R1-10: existing MCP ModelRegistry renamed to DomainModelRegistry to resolve naming collision; R2: ModelQuery gains `family` filter to support D6 binding contract

## D4: ModelSource SPI — refresh contract

**Choice:** Pull-based refresh with no-arg `refresh()`; `ModelCatalogChangedEvent` CDI event when the catalog actually changes
**Alternatives:**
- Push-based registration (sources call registry.register/deregister) — sources must track lifecycle, handle restarts. More complex for no benefit — vendor APIs are pull-based
- Delta-based refresh (return added/removed/updated) — over-engineering for a catalog of tens to low hundreds of models. Full replacement is cheap and eliminates stale-entry bugs
- `refresh(Instant lastRefreshed)` with incremental hint — YAGNI. No current vendor API (Anthropic `/v1/models`, OpenAI `/v1/models`, Ollama `/api/tags`) supports incremental refresh. Sources that need internal state tracking for future delta APIs can manage their own cursor without SPI surface
- Fire event on every poll cycle regardless of change — inconsistent with established platform CDI event patterns. `EndpointRegistered` fires "after every successful register() call" (event-on-mutation). `DataSourceRegistered` fires "after every successful register() call." `DataSourceUpdated` carries old and new descriptors (event-on-change). Polling-triggered events push change-detection complexity to every consumer
**Rationale:** Simple pull-based contract: registry calls `refresh()` on each source periodically. Sources return the complete current catalog from their perspective. Registry replaces that source's entries atomically. Error-isolated per source. Contract: `refresh()` returns `List<ModelDescriptor>`. After each refresh cycle, the registry compares the new descriptor set against the current state; if the catalog changed (entries added, removed, or modified), a `ModelCatalogChangedEvent` CDI event is fired. This follows the established platform pattern where events signal actual state changes, not poll completions. Consumers (RoutingAgentProvider resolution cache, eidos model-family mappings, MCP tool responses) can treat the event as "something changed — invalidate caches" without their own comparison logic.
**Trade-offs:** Full replacement per source means re-transmitting unchanged entries on every refresh. Acceptable: catalog is small, refresh is infrequent (minutes to hours), and full replacement eliminates stale-entry tracking bugs. Change detection in the registry requires comparing the new descriptor set against the current state — O(n) per source refresh where n is the source's model count. Acceptable for catalogs of tens to low hundreds of entries.
**Sources:** Anthropic /v1/models API, OpenAI /v1/models API, Ollama /api/tags API (all return full lists), EndpointRegistered (event-on-mutation), DataSourceRegistered (event-on-mutation), DataSourceUpdated (event-on-change, carries old+new descriptors)
**Exploration:** quick
**Status:** revised — R1-13: removed lastRefreshed parameter (YAGNI); R1-14/R2: CDI event fires on actual catalog change only, renamed to `ModelCatalogChangedEvent`, aligning with platform convention where events signal mutations not polls

## D5: Registry implementation placement

**Choice:** Per-source in-memory maps with priority-resolved view in `platform/`, no-op `@DefaultBean` in `platform/`, source-priority model ID resolution
**Depends on:** D3 (ModelRegistry SPI shape)
**Alternatives:**
- New `model-registry/` module — the registry is a thin cache with a scheduled refresher, doesn't warrant its own module
- Namespace IDs by source (e.g., `seed:llama3`, `ollama:llama3`) — breaks resolveById for callers who don't know the source
- Composite keys (vendor + id) — requires callers to specify vendor alongside model ID, unnecessary ceremony
- Flat `ConcurrentHashMap<String, ModelDescriptor>` — cannot support atomic per-source replacement or shadowed entries; per-source storage is already required for "atomic replacement per source"
**Rationale:** Internal storage: `ConcurrentHashMap<String, ConcurrentHashMap<String, ModelDescriptor>>` keyed by source ID, then model ID. This per-source structure is already required for atomic per-source replacement (replacing one source's entries without touching another's). A priority-resolved view provides `resolveById`: iterate sources in priority order, first match wins. The view can be cached as a flattened `Map<String, ModelDescriptor>` and rebuilt on each source refresh for O(1) lookups.

Cross-source model ID uniqueness: resolved by explicit source-priority ordering. Sources are ordered by priority (configurable, with a sensible default: live API sources > seed catalog). When two sources provide models with the same ID, the higher-priority source's descriptor wins. This is deterministic regardless of refresh timing. Lower-priority entries for the same ID are naturally shadowed in the per-source maps — when the higher-priority source's refresh removes the entry, the next view rebuild picks up the lower-priority entry immediately without waiting for a refresh cycle.

@Startup initial refresh, @Scheduled periodic refresh. Error-isolated per source. No persistence — registry is a cache, sources are the truth. Seed catalog (#287) on the same branch provides the initial data. Follows platform's established pattern: SPI in platform-api, @ApplicationScoped impl in platform.
**Trade-offs:** Lost on restart — repopulated from seed catalog immediately, live sources within first refresh cycle. No persistence needed for a cache. Priority-based resolution means a higher-priority ModelSource may shadow a lower-priority source's entries for the same model ID — this is intentional, logged at WARN level, and deterministic. Per-source maps use slightly more memory than a flat map — negligible for catalogs of tens to low hundreds of models.
**Sources:** platform NoOpCaseMemoryStore pattern, DataSourceRouter @ApplicationScoped pattern
**Exploration:** quick
**Status:** revised — R1-16: described per-source storage explicitly; ConcurrentHashMap per source supports both atomic replacement and priority-based shadowing; view is cached and rebuilt on refresh

## D6: AgentDescriptor.modelFamily → ModelDescriptor binding contract

**Choice:** modelFamily is a product-family identifier that maps to `ModelDescriptor.family`, not to `ModelDescriptor.vendor` or `ModelDescriptor.id`
**Alternatives:**
- modelFamily as vendor-level identifier mapping to ModelDescriptor.vendor — fails when vendor and family diverge. Production code uses `modelFamily="claude"` but vendor would be `"anthropic"`; test fixtures use `modelFamily="gpt-4"` but vendor would be `"openai"`. The vendor/family conflation worked only for Anthropic where "claude" happens to be both brand and product line
- modelFamily as foreign key to ModelDescriptor.id — breaks across model generations (claude-sonnet-4 → claude-sonnet-5), forces callers to track specific model IDs
- Freeform with fuzzy matching — undermines the typed query contract from D3
- Undefined (leave implicit) — creates a semantic gap between Layer 2 (model selection) and Layer 3 (agent selection) with no defined contract
**Rationale:** `modelFamily` is a product-family identifier within a vendor's lineup. The `family` field on `ModelDescriptor` (added in D2 revision) captures this dimension explicitly:
- Anthropic: vendor=`"anthropic"`, family=`"claude"` (Haiku, Sonnet, Opus)
- OpenAI: vendor=`"openai"`, family=`"gpt-4"` (4o, 4o-mini, 4-turbo, 4.1) or family=`"o3"` (o3, o3-mini)
- Google: vendor=`"google"`, family=`"gemini"` (Flash, Pro, Ultra)
- Meta: vendor=`"meta"`, family=`"llama"` (3-8b, 3-70b)

The binding contract: when eidos selects an agent with `modelFamily="claude"`, the model selection layer queries `DomainModelRegistry` with `family="claude"` (and optionally tier/capability filters) to find available models. The `family` filter on `ModelQuery` (D3 revision) provides the typed predicate.

`modelVersion` on `AgentDescriptor` provides optional specificity within a family — e.g., `modelFamily="claude"`, `modelVersion="sonnet-5"`. However, `modelVersion` narrowing is **implementation-layer logic** beyond the current SPI: the Layer 3→2 bridge filters the family-matched result set using ID substring matching or properties lookup. The SPI provides the query primitives (`family` filter); the bridge composes them with application-level logic. This is consistent with the scope boundary established in R1-11 (aliasing/versioning is implementation, not SPI).
**Trade-offs:** The `family` dimension must be populated by every `ModelSource`. This is acceptable because product-family grouping is natural and universal — every vendor's product line already has this structure. `modelVersion` narrowing lacks a typed SPI predicate, requiring implementation-layer logic — acceptable for now; if version narrowing becomes a frequent query pattern, a `version` field can be promoted to `ModelQuery` pre-release.
**Sources:** AgentDescriptor.java (modelFamily, modelVersion, provider fields), YamlAgentDescriptor.java (YAML binding), @Identity annotation examples (modelFamily = "claude"), CaseDefinitionYamlMapperAgentDescriptorTest.java (modelFamily = "gpt-4" test fixture), epic #285 three-layer model (Layer 3 → Layer 2 binding)
**Exploration:** quick (surfaced by R1-07)
**Status:** revised — R1-07/R2: changed from vendor-level to product-family-level; resolved internal contradiction where "gpt-4" is not a vendor. Added `family` field to D2 and `family` filter to D3's ModelQuery. R2-04: acknowledged modelVersion narrowing as implementation-layer logic
