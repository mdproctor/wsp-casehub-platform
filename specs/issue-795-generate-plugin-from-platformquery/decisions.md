# Decisions — #795 Plugin Generation from @PlatformQuery/@PlatformMutation

## D1: Plugin body strategy

**Choice:** SPI-level — generated plugins take the resolved SPI type (e.g., `BankPlatform`) as an `@Execute` parameter and call SPI methods directly. Matches existing hand-written plugin contract.
**Alternatives:**
- API-class delegation — plugin takes `ConnectorBankApi` and delegates. Simpler generation but CDI bean can't be instantiated by the YAML test engine without CDI.
- Convention-based template — infer body from metadata without SPI-level knowledge. Too fragile.
**Rationale:** The YAML test engine resolves `@Execute` parameters via `ServiceRegistry`, which is a `MapServiceRegistry` in test mode. Resolved SPI types (BankPlatform) are mockable; CDI beans (ConnectorBankApi) are not. Existing hand-written plugins all follow this pattern.
**Trade-offs:** The APT can't see method bodies, so it needs annotation metadata to learn the SPI call chain. This requires a new `pluginCapability` attribute.
**Sources:** BankBalancePlugin (connectors/bank-spi), ConnectorBankApi (connectors/graphql), GraphQLResolverProcessor (platform/graphql-generator)
**Exploration:** quick
**Status:** captured

## D2: Parameter mapping

**Choice:** All non-context method parameters become plugin record fields, except the `platform` routing parameter (excluded because the plugin receives the resolved SPI). `@PathParam` → `@Required`. `@QueryParam` with `@DefaultValue` → `@Optional`. `@QueryParam` without default → heuristic based on nullability. `@ContextParam` excluded.
**Alternatives:**
- Explicit opt-in via annotation — more control but more annotation clutter.
- Simple types only — excludes complex params, limiting plugin coverage.
**Rationale:** Matches the API's own parameter contract. The plugin exposes the same inputs the API method accepts, minus routing and context.
**Trade-offs:** Complex type params (e.g., `PaymentRequest`) become record fields, requiring the StepPluginProcessor to handle their schema generation.
**Sources:** ConnectorBankApi parameter annotations, ResolvedParam in GraphQLResolverProcessor
**Exploration:** quick
**Status:** captured

## D3: Result handling

**Choice:** Inline flatten — APT introspects the return type's record components via Jandex and generates explicit `LinkedHashMap.put()` calls per component. No runtime reflection.
**Alternatives:**
- Runtime utility in yaml-step-runtime — `Records.flatten()` using `java.lang.reflect.RecordComponent`. Cleaner code but adds a runtime reflection dependency.
- Result.of(Object) overload — changes the zero-dep yaml-plugin-api contract.
**Rationale:** J2CL safety (yaml-plugin-api is zero-dep). Generated inline code has no runtime dependency and works in all environments.
**Trade-offs:** More generated code per plugin. Nested records require recursive flatten generation.
**Sources:** yaml-plugin-api zero-dep rule (CLAUDE.md), BankBalancePlugin manual flatten pattern
**Exploration:** quick
**Status:** captured

## D4: SPI call chain communication

**Choice:** Annotation metadata — add `pluginCapability` attribute to `@PlatformQuery`/`@PlatformMutation`. Specifies the capability sub-interface class (e.g., `AccountInformation.class`). APT derives the accessor method name by decapitalizing the class name, introspects accessor parameters via Jandex.
**Alternatives:**
- Flat SPI method — require SPI to have facade methods matching API method names. Requires SPI refactoring.
- Explicit call expression in annotation — maximal control but duplicates method body in annotation text, fragile.
**Rationale:** Minimal annotation addition. The capability class is already known by the developer (it's in the `requireCapability()` call). APT can introspect the full call chain via Jandex once it knows the capability class.
**Trade-offs:** Methods without a capability sub-interface (direct SPI method calls) need a different path — either `pluginCapability` is optional and the APT calls the method directly on the SPI, or a sentinel value is used.
**Sources:** requireCapability() pattern in ConnectorBankApi, ConnectorVoiceApi
**Exploration:** quick
**Status:** captured

## D5: SPI type resolution

**Choice:** Infer from `@Inject` field — APT finds the `@Inject` field on the `@McpDomain` class whose type has a `platform(String)` method, introspects its return type via Jandex to get the SPI type. For multi-field classes (voice), `pluginCapability` disambiguates by finding which SPI type contains the capability interface.
**Alternatives:**
- Explicit `pluginSpi` annotation attribute — direct, no inference. More annotation clutter.
- Derive from pluginCapability hierarchy — walk type hierarchy to find enclosing SPI. Requires complete hierarchy in Jandex.
**Rationale:** The `@Inject` field type → `platform()` return type pattern is consistent across all 13 connectors. Inference avoids redundant annotation attributes.
**Trade-offs:** Connectors with non-standard service patterns may need explicit annotation override.
**Sources:** BankPlatformService.platform() → BankPlatform, RoutingVoicePlatformService patterns
**Exploration:** quick
**Status:** captured
