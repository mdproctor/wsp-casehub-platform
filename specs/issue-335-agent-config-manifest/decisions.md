# Agent Config Manifest Design Decisions

## D1: Standard configuration file as the single artifact

**Choice:** A declarative YAML configuration file (`agent-config.yaml`) is the single artifact that determines how AgentProvider is wired. All entry points — web app, MCP tools, env var bootstrap, Java code, YAML definitions — produce or consume this file.
**Alternatives:**
- Per-project application.properties fragments — scattered, no accumulation, different syntax per framework
- Programmatic-only configuration — excludes YAML-based apps and non-developer users
**Rationale:** The current state has every project hand-rolling its own LLM setup (hardcoded CLI passthrough, custom TestAgentProvider, inline API keys). A single declarative file standardises the path for all consumers.
**Trade-offs:** Requires a config loader and parser that feeds the existing ModelRegistry/RoutingAgentProvider. Adds a file format to maintain.
**Sources:** Survey of casehub-examples (wacky-manor, showcase), existing ModelSource SPI, RoutingAgentProvider
**Exploration:** quick
**Status:** captured

## D2: Implicit local file chain with accumulation

**Choice:** Config files are discovered by walking a directory hierarchy (project → user → system → seed catalog), accumulating model descriptors with most-specific-wins semantics per model ID. Like Maven POM resolution or git config.
**Alternatives:**
- Single flat file — no layering, every project must declare everything
- Explicit includes — requires each file to reference the next, fragile chain
**Rationale:** A developer configures `~/.casehub/agent-config.yaml` once with credentials. Every project inherits it. Projects override with their own file. CI sets env vars. No coordination needed between layers.
**Trade-offs:** Implicit discovery can surprise users who don't know about a higher-level file. Mitigated by logging which files were loaded at startup.
**Sources:** Maven settings.xml hierarchy, git config (local → global → system), Spring property source ordering
**Exploration:** quick
**Status:** captured

## D3: Explicit remote sources declared in config

**Choice:** Remote model catalogs (HTTP, REST/GraphQL endpoints) are declared as URIs in the config file under `remote-sources:`. They are fetched and accumulated alongside local files.
**Alternatives:**
- Only local files — limits corporate catalog and live service integration
- Auto-discovery of remote sources — too magical, hard to debug
**Rationale:** Local chain handles developer/project/system defaults. Remote sources handle corporate catalogs ("these are our approved models") and live services. Both feed the same ModelRegistry accumulation.
**Trade-offs:** Remote sources add network dependency. Mitigated by last-known-good caching (already built for CloudModelSource).
**Sources:** Existing CloudModelSource, OllamaModelSource implementations
**Exploration:** quick
**Status:** captured

## D4: Environment profiles for dev/CI/prod

**Choice:** Named profiles (e.g., `dev`, `ci`) within the config file, selected via `CASEHUB_AGENT_PROFILE` env var. Each profile declares its own providers and preferences.
**Alternatives:**
- Separate config files per environment — works but duplicates shared settings
- Spring-style profile activation — ties to framework, not portable
**Rationale:** Same file, different profiles. `dev` uses Anthropic/Vertex API keys. `ci` uses Ollama local models. Profile selection is a single env var.
**Trade-offs:** Profile complexity could grow. Kept simple: each profile just declares providers and optional overrides.
**Sources:** Maven profiles, Spring profiles, Docker Compose profiles
**Exploration:** quick
**Status:** captured

## D5: Named aliases for constraint-based model selection

**Choice:** Config file defines named aliases that map to ModelQuery constraints. Code references aliases by name (`invoke("reasoning-heavy")`). The same alias resolves differently per environment profile.
**Alternatives:**
- Inline constraints in every call site — verbose, not environment-portable
- Hardcoded model IDs — brittle, can't adapt to environment
**Rationale:** Keeps the invoke() API simple (string-based). The constraints live in config, not scattered through code. `reasoning-heavy` hits Claude Opus in dev, Ollama in CI — same code, different environment.
**Trade-offs:** Adds indirection — must read config to understand what a name resolves to. Mitigated by clear naming and startup logging.
**Sources:** RoutingAgentProvider.resolve() three-step resolution, ModelRef.forTier() pattern
**Exploration:** quick
**Status:** captured

## D6: JSON Schema as single source of truth for model selection types

**Choice:** A `model-selection.schema.json` defines the model selection contract as a union type (string | ModelConstraints object). yaml-codegen generates Java records. The same schema powers IDE autocompletion in YAML and web app form rendering.
**Alternatives:**
- Java-first with manual YAML mapping — schema and types can drift
- Separate schemas per consumer — duplication, inconsistency risk
**Rationale:** One schema, four consumers: IntelliJ/VS Code autocompletion, yaml-codegen Java records, web app forms, runtime deserialization. The ShorthandModule in schema-generator already supports string-or-object union patterns.
**Trade-offs:** Schema must be kept in sync with enum values (vendors, capabilities). Can be derived from seed catalog at build time.
**Sources:** yaml-codegen, schema-generator ShorthandModule, existing ModelQuery record
**Exploration:** quick
**Status:** captured

## D7: ModelConstraints extends ModelQuery with range constraints

**Choice:** The schema's ModelConstraints object includes range constraints beyond what ModelQuery currently supports: `min-context` (minimum context window), `min-output` (minimum output tokens), `prefer-vendor` (soft preference with fallback). These supplement existing ModelQuery fields (vendor, family, tier, capabilities, locality, maxCostTier).
**Alternatives:**
- Keep ModelQuery as-is, only exact-match filtering — limits use cases like "I need at least 128K context"
- Fully separate query type — duplicates existing fields
**Rationale:** Range constraints are the natural extension for "find me the best model that fits these requirements." The existing ModelQuery handles exact-match dimensions; range constraints handle numeric thresholds and soft preferences.
**Trade-offs:** Router resolution logic becomes richer. Scoring/ranking needed when multiple models match.
**Sources:** ModelQuery record (7 fields), ModelDescriptor.contextWindow/maxOutput fields
**Exploration:** quick
**Status:** captured

## D8: Model selection reusable as $ref across eidos, org descriptors, agent config

**Choice:** The `model-selection.schema.json` is a reusable schema fragment that eidos case definitions, org descriptors, and agent config all `$ref`. Any definition type that assigns an agent to a task or role can reference model selection constraints identically.
**Alternatives:**
- Per-definition-type model fields — inconsistent, each definition invents its own model selection
- Single global config only — can't express "this task needs vision" at the definition level
**Rationale:** Model selection is a cross-cutting concern. A case definition task, an org role, and the agent config manifest all need the same expressive power. Sharing the schema ensures consistency and a single resolution path through the router.
**Trade-offs:** Schema fragment must be published as an artifact that other repos can consume.
**Sources:** eidos case definitions, org descriptor YAML format, yaml-codegen $ref support
**Exploration:** quick
**Status:** captured

## D9: Local model lifecycle — ensure: present

**Choice:** Local models (Ollama) declare `ensure: present` in config. The runtime checks if the model is available; if not, it pulls it. Agnostic to how the model was provisioned (Docker, Maven plugin, manual pull).
**Alternatives:**
- Always pull — wasteful if model already present
- Manual-only — bad onboarding experience
**Rationale:** The contract is "is this model available?" not "how did it get here." Docker bakes models into images. Maven plugins pre-pull. Dev machines auto-pull on first run. All produce the same result.
**Trade-offs:** First-run pull can be slow for large models. Acceptable for dev; CI should pre-provision.
**Sources:** Existing LlmConfigService.pullModel()/pullStatus()/cancelPull() methods, OllamaModelSource
**Exploration:** quick
**Status:** captured

## D10: Web app is pure client-side from static JSON dump

**Choice:** The web app loads a static JSON dump (~6KB: 17 models, 6 vendors, enums) and runs entirely client-side for model browsing, filtering, and selection. Only the final ConfigureRequest (vendor + credentials) hits the server. Can also connect to a live service for cloud-discovered models.
**Alternatives:**
- Server-rendered UI — requires running backend for all interactions
- Fully static with no live connection option — can't show cloud-discovered models
**Rationale:** The JS demo case needs no server. The static dump is small enough to inline. The data provider abstraction (static JSON vs live REST) keeps the same app working in both modes.
**Trade-offs:** Static dump can go stale. Mitigated by generating the JSON from the seed catalog at build time.
**Sources:** Seed catalog (17 models, 5.9KB minified), VendorInfo (6 vendors), ModelDescriptor fields
**Exploration:** quick
**Status:** captured

## D11: URI-based ModelSource bridges config to existing SPI

**Choice:** A new URI-based ModelSource implementation handles `file:`, `classpath:`, and `https:` schemes, bridging the config file's source declarations to the existing ModelSource SPI. This is the missing connector between "config declares what to load" and "registry accumulates models."
**Alternatives:**
- Separate loader outside ModelSource — bypasses the existing refresh/priority infrastructure
- Extend each existing source (SeedCatalog, Cloud, Ollama) — doesn't handle arbitrary URIs
**Rationale:** ModelSource already has `sourceId()`, `priority()`, `refresh()`. A URI-based implementation fits naturally: source ID is the URI, priority comes from the config chain position, refresh fetches the URI.
**Trade-offs:** HTTP sources need caching and error handling. Already solved by CloudModelSource's last-known-good pattern.
**Sources:** ModelSource SPI, SeedCatalogModelSource (classpath YAML), CloudModelSource (HTTP + caching)
**Exploration:** quick
**Status:** captured
