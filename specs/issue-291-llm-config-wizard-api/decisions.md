## D1: User scope — tenant admin + per-user overrides

**Choice:** Both tiers — tenant-level defaults with optional per-user overrides
**Alternatives:**
- Tenant admin only — simpler but blocks users from bringing their own keys
- Per-user self-service only — flexible but no shared defaults, credential isolation concerns
**Rationale:** Aligns with PreferenceStore's existing scope model (tenancy + scope path). Tenant admins configure shared providers; users can override with their own keys at a narrower scope. The preference hierarchy handles resolution naturally.
**Trade-offs:** More complex authorization model — must distinguish admin-only operations (configure tenant defaults) from user-level operations (configure personal overrides). PreferenceStore's scope-aware resolution handles the data model, but the wizard API must enforce who can write at which scope.
**Sources:** PreferenceStore SPI (scope-aware set/delete/list), PreferenceResource (scope via @QueryParam), SettingsScope (tenancyId + scope + effectiveAt)
**Exploration:** quick
**Status:** captured

## D2: Credential validation — live vendor API call

**Choice:** Live validation — call the vendor's list-models endpoint to prove the key works
**Alternatives:**
- Format-only validation — fast but doesn't catch invalid/expired keys
- Both modes (format first, optional live) — more API surface for marginal benefit
**Rationale:** Live validation catches expired/revoked keys immediately. Also returns the actual model list from that vendor, which seeds the ModelSource (see D7). One API call serves two purposes.
**Trade-offs:** Requires network access to vendor APIs during configuration. Adds latency to the configure flow. If the vendor API is down, validation fails even if the key is valid.
**Sources:** Anthropic /v1/models API, OpenAI /v1/models API, Ollama /api/tags
**Exploration:** quick
**Status:** captured

## D3: Storage — credentials separate from config metadata

**Choice:** Credentials in CredentialResolver, provider configuration metadata in PreferenceStore under an `llm.provider` namespace
**Alternatives:**
- PreferenceStore only — simpler but mixes secrets with regular preferences; PreferenceStore values visible in listing API
- Dedicated LlmProviderConfigStore SPI — most isolated but adds a new persistence module for small data set
**Rationale:** Separates secrets from config. CredentialResolver already handles API keys, bearer tokens, compound credentials. PreferenceStore already handles tenant-scoped configuration metadata. Using both follows the existing platform separation of concerns.
**Trade-offs:** Two stores to coordinate on write. Must ensure atomicity — if credential write succeeds but preference write fails, cleanup is needed. CredentialResolver is currently read-only (DefaultCredentialResolver reads from MicroProfile Config) — the wizard needs a writable credential path.
**Sources:** CredentialResolver SPI, DefaultCredentialResolver (config-backed), CredentialPropertyKeys (API_KEY, BEARER_TOKEN), PreferenceStore SPI, QuarkusCredentialResolver (Quarkus CredentialsProvider bridge)
**Exploration:** quick
**Status:** captured

## D4: Flow model — stateless endpoints, client orchestrates

**Choice:** Stateless independent endpoints — client drives the wizard flow
**Alternatives:**
- Stateful wizard session (POST /wizard/start → session ID) — more guided but adds session lifecycle, timeout, cleanup
- Hybrid with flow hints — stateless but responses include nextStep hints; adds complexity without clear benefit
**Rationale:** Simpler, RESTful, works naturally for CLI/MCP/UI consumers. No server-side session state to manage. Each endpoint is independently callable and testable. The wizard is a convenience layer, not a state machine.
**Trade-offs:** Client must know the expected flow order. No server-side enforcement of "validate before configure". Partially mitigated by the API returning available actions in responses.
**Sources:** PreferenceResource (stateless REST pattern), issue #291 scope (headless design)
**Exploration:** quick
**Status:** captured

## D5: Registry integration — auto-register ModelSource on configure

**Choice:** Configuring a provider automatically creates a ConfiguredModelSource that joins the ModelRegistry refresh cycle
**Alternatives:**
- Separate activation step — more control but adds ceremony; models don't appear until activation
- Auto-register with enable/disable toggle — most flexible but toggle adds state management
**Rationale:** The wizard is the gateway to the registry. Configuration implies intent to use. Models from configured providers become immediately queryable via ModelRegistry. Removing a configuration removes the source.
**Trade-offs:** No way to configure without activating. If a provider is temporarily problematic, unconfigure/reconfigure is the only path (no disable toggle). Acceptable for pre-release; toggle can be added later if needed.
**Sources:** ModelRegistry SPI (resolveById/query/all), InMemoryModelRegistry.replaceSource(), ModelRegistryRefresher (@Startup + @Scheduled), ModelSource SPI (sourceId/priority/refresh)
**Exploration:** quick
**Status:** captured

## D6: API surface — SPI-only with generated REST + GraphQL + MCP

**Choice:** Define wizard operations as an @McpDomain interface with @PlatformQuery/@PlatformMutation. GraphQL resolvers and JAX-RS REST resources are auto-generated by the graphql-generator APT. MCP tools are discovered at runtime by GraphQLModelScanner.
**Depends on:** #295 (unified API generation epic) — PoC already on this branch
**Alternatives:**
- Hand-written REST + hand-written GraphQL — maximum control but dual maintenance, drift risk
- REST-only (JAX-RS) — familiar but no GraphQL or MCP without additional hand-written code
- SPI-only without REST generation — GraphQL + MCP free, but no REST; addressed by extending graphql-generator (PoC done)
**Rationale:** One SPI interface produces three API surfaces with zero hand-written endpoint code. The graphql-generator APT was extended on this branch to generate both @GraphQLApi resolvers and @Path JAX-RS resources from the same @McpDomain scan. This eliminates endpoint drift entirely.
**Trade-offs:** Generated REST follows a convention (GET for queries, POST for mutations, @QueryParam for parameters). Complex request bodies or custom HTTP semantics require hand-written overrides (the generator already supports skip-if-hand-written detection). Generated paths use method names directly (/api/{domain}/{methodName}) — may want kebab-case transformation in productionised version.
**Sources:** GraphQLResolverProcessor (existing + REST extension PoC), DirectDomainApi (test interface), McpDomain annotation, PlatformQuery/PlatformMutation annotations, GraphQLModelScanner (MCP discovery), casehubio/platform#295
**Exploration:** quick
**Status:** captured

## D7: Validation seeds ModelSource — no redundant API call

**Choice:** The validate endpoint calls the vendor's list-models API, returns the discovered models, and if the user confirms, those models become the initial ModelSource content
**Depends on:** D2 (live validation), D5 (auto-register)
**Alternatives:**
- Validation only proves the key works; ModelSource does its own independent refresh later — cleaner separation but wastes an API call since validation already has the data
**Rationale:** The vendor's list-models API returns both proof-of-validity and the model catalog. Using validation results to seed the ModelSource avoids a redundant second API call. The ModelSource still refreshes independently on subsequent cycles.
**Trade-offs:** Couples the validation response format to ModelDescriptor construction. Vendor-specific parsing logic runs in the validate path, not just the refresh path. Mitigated by sharing the parsing logic between validate and refresh.
**Sources:** ModelDescriptor record (id, backendKey, vendor, family, tier, capabilities, etc.), ModelSource.refresh(), SeedCatalogModelSource (YAML parsing pattern)
**Exploration:** quick
**Status:** captured

## D8: Module placement — new llm-config/ module

**Choice:** New top-level `llm-config/` module with its own pom.xml
**Alternatives:**
- Inside platform/ — simpler structure but platform/ is already large, adds HTTP client + validation dependencies
- Inside agent-router/ — colocated with RoutingAgentProvider but agent-router is lean and focused
**Rationale:** The wizard has dependencies beyond platform/ (HTTP client for live validation, vendor-specific API parsing). Follows the preferences-editor/ pattern — a focused module for a specific configuration API. Keeps platform/ focused on @DefaultBean implementations.
**Trade-offs:** One more module in the build. The module needs compile dependencies on platform-api (ModelRegistry, CredentialResolver, PreferenceStore SPIs) and a test dependency on platform (InMemoryModelRegistry for integration tests).
**Sources:** preferences-editor/ (separate module pattern), platform/ (already large), agent-router/ (lean, focused)
**Exploration:** quick
**Status:** captured

## D9: Startup persistence — PreferenceStore scan creates ModelSources dynamically

**Choice:** A @Startup bean reads all `llm.provider.*` preferences, creates a ConfiguredModelSource per persisted provider, registers them with the registry. No restart needed to add providers.
**Depends on:** D3 (PreferenceStore for config metadata), D5 (auto-register ModelSource)
**Alternatives:**
- Static config properties (application.properties) — simple but requires restart, no per-tenant support
- Hybrid (static defaults + PreferenceStore overrides) — two config paths to maintain
**Rationale:** Dynamic, tenant-aware, runtime-configurable. PreferenceStore already supports scope-aware persistence. On startup, the bean reconstructs ConfiguredModelSource beans from persisted configs. On configure, the bean creates/updates sources immediately. ModelRegistryRefresher picks them up on the next refresh cycle (or immediately via an explicit refresh trigger).
**Trade-offs:** PreferenceStore must be available at @Startup time — ordering dependency. If PreferenceStore backend is slow to initialize, startup is delayed. Mitigated by the existing NoOpPreferenceStore @DefaultBean (empty on startup, populated when real backend arrives).
**Sources:** ModelRegistryRefresher (@Startup + @Scheduled), PlatformPreferenceRegistrar (@Startup pattern), PreferenceStore SPI
**Exploration:** quick
**Status:** captured

## D10: Consumer-facing SPI — ModelRegistry, not InMemoryModelRegistry

**Choice:** Consumers inject ModelRegistry (the SPI interface). InMemoryModelRegistry is an implementation detail. All non-derivable sources must be persisted so the registry can be rebuilt on restart.
**Alternatives:**
- Expose InMemoryModelRegistry directly — leaks implementation details, couples consumers to the in-memory approach
**Rationale:** The ModelRegistry SPI is the contract. The implementation (in-memory, persistent, hybrid) is an internal concern. The seed catalog is derivable (classpath YAML). User-configured providers are non-derivable and must be persisted (via D3 + D9). On startup, all sources (derivable + persisted) are refreshed and the registry is populated.
**Trade-offs:** None — this is the correct SPI boundary. The wizard interacts with ModelRegistry for reads and with PreferenceStore + CredentialResolver for writes. The ConfiguredModelSource bridges persisted config to the registry.
**Sources:** ModelRegistry SPI, InMemoryModelRegistry (implementation), SeedCatalogModelSource (derivable), D3 (storage), D9 (startup persistence)
**Exploration:** quick
**Status:** captured
