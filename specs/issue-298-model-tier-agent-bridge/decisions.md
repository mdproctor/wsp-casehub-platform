## D1: Where tier resolution lives

**Choice:** Inside RoutingAgentProvider — extend `resolve()` to handle tier-based model references as a fourth resolution step alongside null, model IDs, and backend keys
**Alternatives:**
- Separate TierAwareAgentProvider wrapper — adds indirection for no architectural gain; the wrapper would do one `ModelRegistry.query()` call then delegate to the same router
- Caller-side ModelSelector utility — pushes platform knowledge (which model satisfies FLAGSHIP) into every consumer; undermines the registry's purpose
**Rationale:** The router already resolves model references to backends. A caller saying "tier:FLAGSHIP" is semantically the same as saying "claude-opus-4" — both are "give me a model that satisfies this requirement." Tiers are a third kind of requirement, not a third layer. The router is already the decision point.
**Trade-offs:** RoutingAgentProvider gains `ModelQuery` awareness beyond `resolveById`. Acceptable — the router already depends on `ModelRegistry`.
**Sources:** RoutingAgentProvider.java (resolve method, three-step contract), ModelRegistry.java (query method), ModelQuery.java (tier filter), issue #298
**Exploration:** quick
**Status:** captured

## D2: How callers express tier-based requests — ModelRef utility + String SPI

**Choice:** `ModelRef` utility class in `platform-api` encapsulates the `"tier:"` prefix convention. Typed construction (`ModelRef.forTier(ModelTier)`) for callers, typed parsing (`ModelRef.isTierRef()`, `ModelRef.parseTier()`) for the router. `AgentSessionConfig.model` stays `String` — no SPI change, no backend change.
**Depends on:** D1 (tier resolution inside RoutingAgentProvider)
**Alternatives:**
- Raw string prefix convention without utility class — callers construct `"tier:" + tier.name()` manually, router parses inline. Works but leaks the format convention to both sides; any format change requires updating all callers and the router independently.
- Sealed `ModelRef` type replacing `String model` on AgentSessionConfig — type-safe end-to-end but creates dead branches in every backend (`ByQuery`/`ByBackendKey` variants that backends can never receive after router rewriting). Forces callers to classify their own references (ById vs ByBackendKey) when that's the router's job. Config-driven callers (YAML) hold strings — the sealed type forces config loaders to know resolution semantics. The type persists past the router into backend territory where it carries no useful information.
- New `ModelQuery modelQuery` field on AgentSessionConfig — two fields influencing model selection is a coordination bug
**Rationale:** Type safety matters at construction (caller) and interpretation (router), not at transport (SPI boundary). `ModelRef` as a utility class encapsulates the format at both points without touching the SPI. Neither callers nor the router construct or parse the prefix directly — both go through `ModelRef`. If the wire format changes, only `ModelRef` changes. The `String model` SPI field matches LLM API conventions (every vendor API takes `model: "gpt-4o"` as a string) and works naturally for config-driven callers reading strings from YAML. Resolution precedence: (1) tier prefix via `ModelRef.isTierRef()` — unambiguous, checked first; (2) registry ID via `resolveById`; (3) backend key match; (4) fail-fast.
**Trade-offs:** String transport means a typo in manually constructed strings (bypassing `ModelRef.forTier()`) fails at runtime. Acceptable: `ModelRef` is the documented API — manual string construction is unsupported. The router validates with clear error messages.
**Sources:** AgentSessionConfig.java (model field), RoutingAgentProvider.java (resolve method), ModelTier.java, decision review R1-01/R1-02/R1-07 (sealed type analysis), issue #298
**Exploration:** deep-analysis
**Status:** revised — R1: hybrid approach after steelman/devil's-advocate analysis of sealed ModelRef. Encapsulate the format, not the field.

## D3: Model selection when multiple models match a tier query

**Choice:** Prefer the default backend's models — filter `ModelRegistry.query()` results to models whose `backendKey` matches the configured `default-backend`. Falls back to any available model if the default backend has no match for the requested tier.
**Depends on:** D1 (tier resolution inside RoutingAgentProvider), D2 (prefix convention)
**Alternatives:**
- First match by source priority — deterministic but opaque; selection depends on which ModelSource beans are registered and their priority values, which is an implementation detail not a user-visible preference
- Configurable default vendor per tier (`casehub.agent.tier.flagship.vendor=anthropic`) — correct but premature; adds per-tier config maintenance for a scenario that isn't the first to optimize for. One-line extension on top of option 3 if the need arises
**Rationale:** The deployment already declared its preference via `default-backend` — that's the signal. No new configuration surface, no per-tier maintenance, and graceful degradation. A deployment that sets `default-backend=claude` is already expressing "prefer Claude"; tier queries should respect that rather than introducing a parallel config axis.
**Trade-offs:** Semantically overloads `default-backend` (fallback default + tier preference). Acceptable if documented — the two meanings are aligned in practice (an admin who defaults to Claude also wants tier queries to prefer Claude). Per-tier vendor preferences are a one-line extension if needed. Within the preferred backend, multiple same-tier models (e.g., claude-opus-5, claude-opus-4-6, claude-opus-4) are selected by first match from query results — seed catalog orders newest first, cloud sources typically return newest first. Documented as a convention; deterministic quality-aware ordering is a refinement if the catalog grows.
**Sources:** RoutingAgentProvider.java (defaultBackendKey field), casehub.platform.agent.default-backend config, ModelQuery.java (tier filter), seed-catalog.yaml (three FLAGSHIP Anthropic models), decision review R1-03/R1-06, issue #298
**Exploration:** quick
**Status:** revised — R1-03: acknowledged multiple same-tier same-backend models, documented first-match convention with seed catalog ordering; R1-06: acknowledged semantic overloading of default-backend, documented as intentional with extension path

## D4: Prefix format scope — tier only vs tier + capabilities

**Choice:** Tier only — `ModelRef.forTier(ModelTier.FLAGSHIP)` produces `"tier:FLAGSHIP"`. No capability filtering in the initial implementation. Extension point documented.
**Depends on:** D2 (ModelRef utility)
**Alternatives:**
- Tier + capabilities (`ModelRef.forTier(FLAGSHIP, Set.of("vision"))` → `"tier:FLAGSHIP:vision"`) — adds parsing complexity for a use case that's marginal today. o3 (FLAGSHIP) lacks vision, but D3's default-backend preference means a Claude-defaulting deployment won't select o3 anyway.
**Rationale:** The default-backend preference (D3) already narrows the candidate set — within a single vendor's flagship models, capability differences are minimal. Capability filtering becomes meaningful when a deployment uses multiple vendors at the same tier. That scenario exists but isn't the first consumer's need. The `ModelRef` utility encapsulates the format — adding `forTier(ModelTier, Set<String>)` later is backward-compatible and internal to `ModelRef`.
**Trade-offs:** A multi-vendor deployment requesting `"tier:FLAGSHIP"` could get a model lacking a needed capability if the default backend's model doesn't have it and the fallback selects o3 (no vision). Acceptable: the extension is one method on `ModelRef` + one parser branch.
**Sources:** seed-catalog.yaml (o3 FLAGSHIP lacks vision — R1-05), ModelRef design (format encapsulation), issue #298 (fsitrading consumer only needs tier)
**Exploration:** quick
**Status:** revised — R1-05: acknowledged capability inhomogeneity (o3 lacks vision), documented as mitigated by D3's default-backend preference, extension point documented

## D5: Failure behavior when no model matches a tier query

**Choice:** Fail-fast with a descriptive error — throw `IllegalArgumentException` with a message distinguishing "no model sources configured" from "no model matches the requested tier." Consistent with the existing step 4 fail-fast behavior.
**Depends on:** D1 (tier resolution inside RoutingAgentProvider), D3 (default backend preference)
**Alternatives:**
- Fall back to default backend with no model specified (treat as `model=null`) — silent tier degradation means a deployment could think it's running sentiment analysis on Opus while actually using whatever the backend defaults to. The system "works" but produces worse results, and nobody knows why. If the caller doesn't care which model they get, they wouldn't request a specific tier.
**Rationale:** Silent degradation in model selection takes hours to diagnose. An actionable error message gets fixed in minutes. A caller that specifies `"tier:FLAGSHIP"` is expressing a requirement, not a preference — the system should fail visibly when that requirement can't be met. Error path checks `modelRegistry.all().isEmpty()` to provide targeted guidance: "no model sources configured" vs "no model matching tier X (default backend: Y, available tiers: [Z])".
**Trade-offs:** A deployment that adds tier-based routing before configuring model sources will get hard failures instead of graceful fallback. Acceptable: the error message tells them exactly what to configure.
**Sources:** RoutingAgentProvider.java (existing fail-fast in step 4), NoOpModelRegistry (empty catalog), decision review R1-08, issue #298
**Exploration:** quick
**Status:** revised — R1-08: error message now distinguishes empty registry (no sources) from no-match (sources configured but tier unavailable)
