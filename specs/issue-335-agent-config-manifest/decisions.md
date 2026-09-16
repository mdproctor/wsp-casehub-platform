# Agent Config Manifest Design Decisions

## D1: Declarative manifest as the orchestration layer for existing infrastructure

**Choice:** A declarative YAML manifest (`agent-config.yaml`) orchestrates the existing LLM infrastructure (LlmCredentialStore, ModelRegistry, BackendInstanceCoordinator, RoutingAgentProvider) at startup. The manifest is the missing glue — it drives the existing SPIs declaratively so that AgentProvider works without custom code.
**Alternatives:**
- Extend LlmConfigService only — keeps the imperative REST-only path; doesn't help YAML apps, JS demos, or tests
- Per-project application.properties fragments — Quarkus-specific, different syntax per framework, no accumulation
**Rationale:** The platform has all the machinery (credential store, model registry, backend coordinator, router) but no declarative path through it. Today every project hand-rolls its own setup. The manifest drives steps 1-4 (catalog → credentials → selection → routing) from a single file.
**Trade-offs:** LlmConfigService remains as the imperative API for runtime/tenant-scoped configuration. The manifest is the bootstrap path for platform-scope configuration. Both coexist — manifest at startup, LlmConfigService at runtime.
**Sources:** Survey of casehub-examples (wacky-manor, showcase), LlmConfigService, BackendInstanceCoordinator, RoutingAgentProvider
**Exploration:** quick
**Status:** revised (R1-02: reframed as orchestration layer, not parallel system. Explicitly defines relationship to existing llm-config module.)

## D2: Resource chain with implicit local discovery and explicit remote sources

**Choice:** The model catalog is built from a chain of resources — each addressable by URI (file, classpath, https). Local resources are discovered implicitly by walking a directory hierarchy (project → user → system → seed catalog). Remote resources are declared explicitly in any manifest's `sources:` section. All resources use the same manifest schema. Accumulation by model ID, highest priority wins.
**Alternatives:**
- Single flat file — no layering, no environment adaptation
- Use PreferenceProvider hierarchy — PreferenceProvider is tenant-scoped runtime resolution; manifest is pre-boot, framework-agnostic, machine-scoped. Different lifecycle.
**Rationale:** A developer configures `~/.casehub/agent-config.yaml` once. Every project inherits it. Projects override with their own file. CI adds a profile override. Corporate IT publishes an approved catalog at a URL. All resources use the same schema, same loading, same accumulation. The seed catalog is just the lowest-priority resource in the chain.
**Trade-offs:** Implicit discovery can surprise users. Mitigated by logging which resources were loaded and in what order at startup.
**Sources:** Maven settings.xml hierarchy, git config, existing ModelSource SPI (sourceId/priority/refresh maps directly)
**Exploration:** quick
**Status:** revised (R1-03: explicitly differentiates from PreferenceProvider — different lifecycle, framework-agnostic. R1-04: remote sources are declared URIs that feed existing CloudModelSource infrastructure.)

## D3: Profile-specific files, not embedded profile sections

**Choice:** Environment profiles are separate files discovered by convention: `agent-config.yaml` (base, always loaded) + `agent-config-{profile}.yaml` (loaded when `CASEHUB_AGENT_PROFILE` matches). Profile file has higher priority than base file at the same level. Composes with the directory hierarchy.
**Alternatives:**
- Embedded profiles in one file — more complex parser, single file grows large
- Quarkus profiles only — not portable to JS demos, non-Quarkus tests, YAML apps
**Rationale:** Separate files compose naturally with the hierarchy: user base + user profile + project base + project profile. In Quarkus deployments, the manifest loader can also respect `QUARKUS_PROFILE` as a fallback, keeping the two systems aligned.
**Trade-offs:** More files to manage. But each file is small and focused. The base file has common config; the profile file has only environment-specific overrides.
**Sources:** Maven profiles, Docker Compose override files, Quarkus application-{profile}.properties
**Exploration:** quick
**Status:** revised (R1-05: addresses Quarkus profile concern — portable profiles with Quarkus fallback. Separate files instead of embedded sections.)

## D4: Named aliases for multi-constraint model selection

**Choice:** Manifest defines named aliases mapping to ModelQuery constraints. Code references aliases by name (`invoke("reasoning-heavy")`). Aliases encode multiple dimensions (tier + capabilities + min-context) and resolve differently per environment based on what models are available.
**Alternatives:**
- Only tier refs (ModelRef.forTier()) — single dimension, can't express "FLAGSHIP with vision and 128K context"
- Inline constraints in every call site — verbose, not environment-portable
**Rationale:** `tier:FLAGSHIP` is one dimension. `reasoning-heavy` encodes multiple constraints AND resolves differently in dev (Claude Opus) vs CI (Ollama Maverick). The alias is the bridge between "what the code needs" and "what this environment has."
**Trade-offs:** Adds indirection. Mitigated by startup logging of alias→model resolution and clear naming.
**Depends on:** D2 (aliases defined in manifest resources)
**Sources:** RoutingAgentProvider.resolve() three-step resolution, ModelRef.forTier()
**Exploration:** quick
**Status:** revised (R1-06: explicitly justifies over tier refs — multi-constraint + environment-varying resolution.)

## D5: JSON Schema for type-safe model selection across Java and YAML

**Choice:** `model-selection.schema.json` defines the model selection contract as a union type (string | ModelConstraints). yaml-codegen generates Java records. Same schema powers IDE autocompletion, web app forms, and runtime deserialization. Schema lives in the manifest module and is published as a Maven artifact resource.
**Alternatives:**
- Java-first with manual YAML mapping — schema and types can drift
- Separate schemas per consumer — duplication, inconsistency risk
**Rationale:** One schema, four consumers: IDE autocompletion, yaml-codegen Java records, web app forms, runtime deserialization. ShorthandModule in schema-generator already supports string-or-object union patterns.
**Trade-offs:** Cross-repo `$ref` requires publishing the schema as a versioned artifact. Schema changes need coordinated releases across consumers.
**Sources:** yaml-codegen, schema-generator ShorthandModule, existing ModelQuery record
**Exploration:** quick
**Status:** revised (R1-07, R1-09: explicitly addresses module placement and cross-repo publication.)

## D6: Filtering vs scoring separation for model resolution

**Choice:** Keep `ModelQuery` as exact-match filtering (deterministic). Add range constraints (`minContextWindow`, `minMaxOutput`) as additional filter fields. Add `preferVendor` as a soft tiebreaker applied after filtering, not as a filter. No scoring SPI — ranking is: prefer default backend → prefer specified vendor → first match.
**Alternatives:**
- Full scoring/ranking SPI — over-engineered for current needs, introduces non-determinism
- Range constraints as scoring dimensions — makes "did it match?" ambiguous
**Rationale:** Filtering is deterministic — a model either matches or doesn't. Range constraints are still filters (`contextWindow >= minContextWindow`). Vendor preference is a tiebreaker among matching models, not a filter. This keeps resolution predictable and debuggable.
**Trade-offs:** No fuzzy matching — if nothing matches the constraints exactly, the query returns empty. This is the right failure mode (explicit, fixable) vs scoring (returns something unexpected).
**Sources:** Existing InMemoryModelRegistry.query() exact-match implementation, ModelDescriptor.contextWindow/maxOutput fields
**Exploration:** quick
**Status:** revised (R1-08: separates filtering from preference. No scoring SPI. Range constraints are filters, vendor preference is tiebreaker.)

## D7: Credential references, never raw values

**Choice:** Manifest credential fields are references, not raw values. Three reference types: `env:VAR_NAME` (environment variable), `file:/path` (file contents), `ref:credential-ref` (CredentialResolver SPI → Quarkus CredentialsProvider → Vault/AWS/GCP). The ManifestProcessor resolves references and stores results in LlmCredentialStore. BackendInstanceCoordinator creates backends from the store.
**Alternatives:**
- Allow inline raw values — security risk, credentials in version-controlled files
- Only env vars — insufficient for production (needs Vault, mounted secrets)
**Rationale:** Each reference type maps to a deployment tier: `env:` for dev/CI, `file:` for k8s mounted secrets, `ref:` for production secret stores. The existing `credentials-quarkus/` module bridges `ref:` to Quarkus CredentialsProvider, enabling Vault/AWS/GCP by classpath presence. Outside Quarkus, only `env:` and `file:` are available — correct for those contexts.
**Trade-offs:** No raw values means test manifests must use env vars. Acceptable — tests can set env vars programmatically.
**Sources:** CredentialResolver SPI, credentials-quarkus module, LlmCredentialStore, VendorInfo.requiredFields()
**Exploration:** quick
**Status:** revised (R1-16: explicit credential security. Traces full chain through existing CredentialResolver → credentials-quarkus → Quarkus CredentialsProvider.)

## D8: Local model lifecycle as desired-state reconciliation

**Choice:** `local-models:` declares desired state (`ensure: present`). ManifestProcessor delegates to existing OllamaModelSource.refresh() and LlmConfigService.pullModel() for reconciliation. No new pull logic — manifest declares, existing runtime reconciles.
**Alternatives:**
- New pull mechanism — duplicates existing infrastructure
- Manual-only provisioning — bad onboarding
**Rationale:** The runtime already knows how to check and pull models. The manifest just says what should be there. Agnostic to provisioning mechanism — Docker, Maven plugin, manual pull, or auto-pull all produce the same result.
**Trade-offs:** First-run pull can be slow. CI should pre-provision.
**Sources:** OllamaModelSource.refresh(), LlmConfigService.pullModel()/pullStatus()
**Exploration:** quick
**Status:** revised (R1-10: explicitly delegates to existing infrastructure. No new pull logic.)

## D9: Web app as manifest producer, LlmConfigService as live backend

**Choice:** Web app loads static JSON dump (~6KB) for client-side model browsing. In live mode, calls LlmConfigService REST endpoints. The web app's output is a manifest file. It's a frontend for producing the declarative config, not new backend capability.
**Alternatives:**
- Server-rendered UI — requires running backend for all interactions
- New backend API — duplicates LlmConfigService
**Rationale:** The JS demo runs from static JSON, no server. The live mode uses existing REST endpoints. The web app produces the manifest YAML that the loader reads at startup.
**Trade-offs:** Static dump can go stale. Mitigated by generating JSON from seed catalog at build time.
**Sources:** Seed catalog (5.9KB minified), LlmConfigService REST endpoints, VendorInfo
**Exploration:** quick
**Status:** revised (R1-11: explicitly identifies as frontend for LlmConfigService, not new capability.)

## D10: Module placement — agent-config-core + agent-config (core/Quarkus split)

**Choice:** `agent-config-core` contains Manifest record, ManifestLoader, ManifestProcessor. Pure Java + Jackson. No CDI. `agent-config` contains Quarkus @Startup bean that runs the loader and wires into CDI context. Follows the established core/Quarkus module pattern.
**Alternatives:**
- In platform-api — violates zero-dependency constraint (needs YAML parser)
- In llm-config — llm-config is the imperative API; manifest loading is a separate concern
- In platform — platform is @DefaultBean implementations, not config loading
**Rationale:** The core module is framework-neutral. Tests and JS demos can use ManifestLoader directly without Quarkus. The Quarkus module is a thin @Startup wiring layer.
**Trade-offs:** Two new modules. But they're small and focused — the core is the loader/processor, the Quarkus module is ~20 lines of CDI wiring.
**Sources:** Existing core/Quarkus split pattern (platform-core/platform, expression-core/expression, etc.)
**Exploration:** quick
**Status:** captured (R1-14: addresses module placement gap.)

## D11: Manifests operate at platform scope — tenancy is LlmConfigService's domain

**Choice:** Manifest resources operate at platform scope (`PLATFORM_TENANT_ID`). They configure what models and credentials are available to the deployment. Per-tenant model configuration (restricting which models a tenant can use, tenant-specific API keys) remains LlmConfigService's domain via REST API.
**Alternatives:**
- Tenant-scoped manifests — adds complexity for a use case that the existing REST API already handles
- Ignore tenancy entirely — creates incoherence with the platform's identity model
**Rationale:** The manifest answers "what does this machine/deployment have access to?" — that's platform-scope. "What can tenant X use?" is a runtime, per-tenant question that LlmConfigService handles with its existing tenant-scoped credential store and configuration.
**Trade-offs:** Multi-tenant deployments need both: manifest for platform bootstrap + LlmConfigService for per-tenant configuration. This is the correct separation.
**Sources:** TenancyConstants.PLATFORM_TENANT_ID, LlmConfigService tenant-scoped operations, CurrentPrincipal.tenancyId()
**Exploration:** quick
**Status:** captured (R1-15: addresses multi-tenancy gap.)

## D12: RoutingAgentProvider.resolve() extended with alias step

**Choice:** Add alias resolution as step 0 in RoutingAgentProvider.resolve(): alias → ModelQuery → filter → tiebreak → model. Existing steps shift: (1) tier ref, (2) registry ID, (3) backend key, (4) fail-fast. Aliases are registered at startup from the merged manifest.
**Alternatives:**
- Separate AliasResolver before the router — adds indirection without benefit
- Aliases in the config file only, resolved at config load time — loses environment adaptability
**Rationale:** Aliases must be resolved at invocation time, not config load time, because the model registry may have been refreshed since startup (cloud models added, Ollama models pulled). The router is the natural place for resolution.
**Trade-offs:** Router gains a lookup table. Minimal complexity — Map<String, ModelQuery> keyed by alias name.
**Sources:** RoutingAgentProvider.resolve() existing 3-step resolution
**Exploration:** quick
**Status:** captured

## D13: Manifest schema reusable as $ref for eidos and org descriptors

**Choice:** The model-selection schema fragment is published as a Maven artifact resource. Eidos case definitions and org descriptors `$ref` it for their `model:` fields. Any definition type that assigns an agent to a task can reference model selection constraints identically.
**Alternatives:**
- Per-definition-type model fields — inconsistent, each definition invents its own
- Platform-only schema — eidos can't express per-task model requirements
**Rationale:** Model selection is cross-cutting. A case definition task, an org role, and the agent config manifest all need the same expressive power. One schema, one resolution path.
**Trade-offs:** Schema changes require coordinated releases across repos. Mitigated by semantic versioning of the schema artifact. Initial consumers are within the casehub family — coordination is manageable.
**Sources:** eidos case definitions, yaml-codegen $ref support, existing cross-repo dependency graph (platform publishes before everything)
**Exploration:** quick
**Status:** revised (R1-09, R1-22: acknowledges cross-repo coordination cost. Scoped to casehub family initially.)
