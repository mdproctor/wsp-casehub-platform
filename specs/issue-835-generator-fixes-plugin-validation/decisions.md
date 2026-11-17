# Decisions — #835 Generator Fixes + Plugin Validation

## D1: Step name collision strategy

**Choice:** Short names by default, full domain path only on collision
**Alternatives:**
- Playbook-level imports — more powerful but adds YAML language surface area
- Domain-level `@McpDomain(alias=...)` — declared intent, but first-registered-wins is fragile
**Rationale:** Zero verbosity cost for the 99% case where no collision exists. Compile-time detection catches the rare collision and auto-qualifies both names with full domain path. No new language surface area needed.
**Trade-offs:** Naming can change if a new domain introduces a collision later (existing short name becomes full path). This is acceptable because it surfaces at compile time, not silently at runtime.
**Sources:** GraphQLResolverProcessor.java:2026-2031 (derivePluginName), CompositePluginRegistry.java:19-24 (silent put)
**Exploration:** quick
**Status:** captured

## D2: @ContextParam resolution in generated plugins

**Choice:** ServiceRegistry lookup — `services.lookup(CurrentPrincipal.class).tenancyId()`
**Alternatives:**
- Constructor-injected CurrentPrincipal field — changes plugin record shape, couples data record to framework type
- Dedicated ContextResolver SPI — new API surface for a problem ServiceRegistry already solves
**Rationale:** ServiceRegistry already flows into every action's `execute(params, services)`. CurrentPrincipal is a natural service to register there. No new types, no record shape changes.
**Trade-offs:** Relies on CurrentPrincipal being registered in the ServiceRegistry at runtime. If missing, fails with a lookup error rather than a compile-time guarantee. Acceptable because ServiceRegistry registration is already the standard pattern for runtime dependencies.
**Sources:** GraphQLResolverProcessor.java:1997 (skip bug), contextParamResolution() at :2608 (REST pattern), PluginScanner.java:108-109 (existing services.lookup pattern)
**Exploration:** quick
**Status:** captured

## D3: @Plugin validation wrapping location

**Choice:** Wrap in PluginScanner — `scanAndRegister()` wraps the action in ValidatingAction before building the Definition
**Alternatives:**
- In CompositePluginRegistry.register() — catches all sources but couples registry to step-runtime validation types
- Fix extractParam only — duplicates validation logic already in ValidatingAction
**Rationale:** PluginScanner already has the Declaration metadata (inputs, required flags). Wrapping at the source ensures every @Plugin action is validated regardless of which registry or consumer receives it. Self-contained change.
**Trade-offs:** PluginScanner gains a dependency on ValidatingAction. Acceptable because they're in the same module (yaml-step-runtime) and serve the same purpose.
**Depends on:** None
**Sources:** PluginScanner.java:50-55 (raw action), ValidatingAction.java (existing wrapper), YamlDefinitionSource (YAML-defined wrapping pattern)
**Exploration:** quick
**Status:** captured
