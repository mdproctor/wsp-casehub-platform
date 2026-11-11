# Decisions — #795 Plugin Generation from @PlatformQuery/@PlatformMutation

## D1: Plugin body strategy

**Choice:** Two-tier — generated plugins operate at the level appropriate to the `@McpDomain` type:
- **Interface** (`@McpDomain` on an interface, e.g. `AclApi`): plugin takes the interface as an `@Execute` parameter and calls the method directly. No SPI routing needed. Works automatically with zero annotation changes.
- **Connector class** (`@McpDomain` on a class with `@Inject` fields, e.g. `ConnectorBankApi`): plugin takes the resolved SPI type (e.g. `BankPlatform`) as an `@Execute` parameter and calls SPI methods using `pluginCapability` metadata. Matches existing hand-written plugin contract.
**Alternatives:**
- API-class delegation — plugin takes `ConnectorBankApi` and delegates. Simpler generation but CDI bean can't be instantiated by the YAML test engine without CDI.
- YAML invoke definitions — `invoke: { rest: GET /api/... }` pointing at generated REST endpoints. Zero Java, but loses in-process execution, offline testability, and type-safe record fields.
- Convention-based template — infer body from metadata without SPI-level knowledge. Too fragile.
**Rationale:** The YAML test engine resolves `@Execute` parameters via `ServiceRegistry`, which is a `MapServiceRegistry` in test mode. Interfaces and resolved SPI types are mockable; CDI beans are not. Platform interfaces get plugins for free (zero annotation changes). Connector methods needing capability routing add `pluginCapability`. YAML invoke definitions were considered but don't participate in the APT → JSON Schema → Action class pipeline, and can't be tested offline with mock SPIs.
**Trade-offs:** Connector methods need `pluginCapability` annotation metadata. Platform interface methods auto-generate but may need `pluginName` for quality tuning.
**Sources:** BankBalancePlugin (connectors/bank-spi), ConnectorBankApi (connectors/graphql), AclApi (platform-api), GraphQLResolverProcessor (platform/graphql-generator)
**Exploration:** quick
**Status:** revised (review R1-02, R1-03)

## D2: Parameter mapping

**Choice:** All non-context method parameters become plugin record fields, except the `platform` routing parameter (excluded for connector classes because the plugin receives the resolved SPI — identified as the parameter whose name matches the `platform(String)` method's argument on the @Inject service type). `@PathParam` → `@Required`. `@QueryParam` with `@DefaultValue` → `@Optional`. `@QueryParam` without default on reference types → `@Optional`, on primitives → `@Required`. `@ContextParam` excluded. For platform interface methods, no routing parameter exclusion — all params become fields.
**Alternatives:**
- Explicit opt-in via annotation — more control but more annotation clutter.
- Simple types only — excludes complex params, limiting plugin coverage.
**Rationale:** Matches the API's own parameter contract. The plugin exposes the same inputs the API method accepts, minus routing and context.
**Trade-offs:** Complex type params (e.g., `PaymentRequest`) become record fields, requiring the StepPluginProcessor to handle their schema generation.
**Sources:** ConnectorBankApi parameter annotations, ResolvedParam in GraphQLResolverProcessor
**Exploration:** quick
**Status:** revised (review R1-09 — clarified routing param identification and nullability heuristic)

## D3: Result handling

**Choice:** Runtime utility — `Records.toMap(Object record)` in `yaml-step-runtime` using `java.lang.reflect.RecordComponent`. Single testable implementation that handles nested records automatically. Generated plugin calls `Result.of(Records.toMap(result))`.
**Alternatives:**
- Inline generated put() calls — APT introspects record components and generates explicit flatten code. More generated code, recursive codegen needed for nested records.
- Result.of(Object) overload — changes the zero-dep yaml-plugin-api contract (J2CL-safe, must remain zero-dep).
**Rationale:** The generated `Action` class already depends on `yaml-step-runtime` — it's an implementation artifact, not a consumer-facing API. A single `Records.toMap()` handles arbitrary nesting depth and is independently testable. Avoids N generated flatten variants and recursive codegen complexity in the APT.
**Trade-offs:** Runtime reflection dependency (not J2CL-safe, but generated Actions are Java-only).
**Sources:** yaml-plugin-api zero-dep rule (CLAUDE.md), yaml-step-runtime existing runtime utilities
**Exploration:** quick
**Status:** revised (review R1-06 — J2CL constraint applies to yaml-plugin-api, not generated code)

## D4: SPI call chain communication

**Choice:** Annotation metadata on `@PlatformQuery`/`@PlatformMutation` — four optional plugin attributes:
- `pluginName()` default `""` — override generated name
- `pluginAbsorb()` default `false` — `@Plugin(absorbSiblings = true)`
- `pluginSubject()` default `""` — param for bare-value YAML syntax
- `pluginCapability()` default `void.class` — capability sub-interface for connector SPI routing

When `pluginCapability` is set, APT derives the accessor method name by decapitalizing the class name, introspects accessor parameters via Jandex, and verifies the convention holds at compile time (emit error if no matching accessor found). When `void.class` (default), the APT calls the method directly on the interface or SPI type — no capability routing.
**Alternatives:**
- Separate `@GeneratePlugin` annotation — clean separation of concerns, but requires visiting every `@PlatformQuery` method. Since `@PlatformQuery` already exists across the org, keeping attributes on it lets platform interfaces auto-generate plugins with zero changes.
- Explicit call expression in annotation — maximal control but duplicates method body in annotation text, fragile.
**Rationale:** `@PlatformQuery` already exists across the entire org. For platform interface methods, plugin generation is trivially inferrable — adding a separate annotation to every method would be pure toil. Only connector methods with capability sub-interfaces need `pluginCapability`. The tuning attributes (`pluginName`, `pluginAbsorb`, `pluginSubject`) are the quality gate — they ensure the YAML step surface is beautiful, not just functional.
**Trade-offs:** Adds plugin-specific attributes to an MCP-surface annotation. Acceptable because the attributes are optional (zero impact when unused) and the alternative (separate annotation on every method) is worse.
**Sources:** requireCapability() pattern in ConnectorBankApi, ConnectorVoiceApi, all platform-api @McpDomain interfaces
**Exploration:** quick
**Status:** revised (review R1-04 — kept on @PlatformQuery after considering the cross-org reach argument)

## D5: SPI type resolution

**Choice:** Two paths depending on `@McpDomain` target type:
- **Interface**: the interface itself is the `@Execute` parameter type. No inference needed.
- **Class**: infer from `@Inject` field — APT finds the field whose type has a `platform(String)` method, introspects its return type via Jandex. For multi-field classes (voice), `pluginCapability` disambiguates by finding which SPI type contains the capability interface.
**Alternatives:**
- Explicit `pluginSpi` annotation attribute — direct, no inference. More annotation clutter.
- Derive from pluginCapability hierarchy — walk type hierarchy to find enclosing SPI. Requires complete hierarchy in Jandex.
**Rationale:** Platform interfaces need no inference — the interface IS the SPI. For connector classes, the `@Inject` field type → `platform()` return type pattern is consistent across all 13 connectors. Inference avoids redundant annotation attributes.
**Trade-offs:** Connectors with non-standard service patterns may need explicit annotation override. APT must emit a compile error if inference fails (no silent fallback).
**Sources:** BankPlatformService.platform() → BankPlatform, RoutingVoicePlatformService patterns, all platform-api @McpDomain interfaces
**Exploration:** quick
**Status:** revised (review R1-03, R1-10 — added interface path, explicit compile-time validation)

## D4a: Fallback annotation for non-standard shapes

**Choice:** Provide `@GeneratePlugin` as a fallback annotation for methods where `@PlatformQuery` attributes can't express the required plugin shape. Carries the same attributes (`name`, `absorb`, `subject`, `capability`) plus additional ones like `spi` and `accessor` for non-standard SPI routing. When both `@PlatformQuery` attributes and `@GeneratePlugin` are present on a method, `@GeneratePlugin` takes precedence.
**Rationale:** The common case uses `@PlatformQuery` attributes (zero annotation changes for interfaces, minimal for connectors). But unusual patterns (non-standard SPI routing, custom accessor names, methods that need explicit SPI type specification) need an escape hatch without forcing convention-based inference.
**Trade-offs:** Two places to specify plugin metadata — but the rule is clear: `@PlatformQuery` attributes for common cases, `@GeneratePlugin` for overrides.
**Sources:** @CallbackEligible precedent (separate annotation for opt-in generation)
**Exploration:** quick
**Status:** captured

## D6: Error handling strategy

**Choice:** Propagate exceptions — generated plugins do NOT catch SPI exceptions. The step runner's existing exception handling wraps uncaught exceptions into step failure results. The plugin body is a clean, happy-path call chain.
**Alternatives:**
- Generated try-catch — wrap SPI calls and return `Result.Failure`. Adds complexity to generated code and duplicates the step runner's error handling.
- Per-method annotation — `pluginErrorStrategy` attribute. Over-engineering for the common case.
**Rationale:** Hand-written plugins like `BankBalancePlugin` also don't catch exceptions — they let the step runner handle errors uniformly. Generated plugins should follow the same pattern. Error handling policy belongs in the step runner, not in individual plugins.
**Trade-offs:** None significant — this matches existing convention.
**Sources:** BankBalancePlugin (no try-catch), step runner error handling
**Exploration:** quick
**Status:** captured (review R1-08 — gap identified, resolved)
