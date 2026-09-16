# Decisions — DX Audit: @McpDomain on Classes + Spring Drift Elimination

## D1: Scope — full elimination of hand-coded Spring REST controllers

**Choice:** Enable @McpDomain on classes + add rest-spring-generator for transport controllers. Eliminates all hand-coded Spring REST controllers except PreferenceSchemaRestController (ETag).
**Alternatives:**
- @McpDomain focus only — smaller scope, transport controllers stay hand-coded. Faster but doesn't achieve zero drift.
- Full + ETag annotation — adds @ConditionalGet annotation to platform-api for the PreferenceSchema case. Most complete but adds vocabulary for a single use case.
**Rationale:** The goal is eliminating Spring drift from Quarkus. 5 of 6 hand-coded controllers can be generated using existing infrastructure. PreferenceSchemaRestController has ETag logic that no generator can express — tolerable as the one exception.
**Trade-offs:** Broader scope than just @McpDomain class support. But the rest-spring-generator already exists (issue-474) — we're adding it to platform-spring's build, not building it.
**Sources:** platform-spring/pom.xml (no rest-spring-generator configured), issue-474 D7 (rest-spring-generator design), issue-469 D2 (core extraction module structure)
**Exploration:** quick
**Status:** captured

## D2: DomainScanResult field naming

**Choice:** Rename `spiInterfaceFqcn` / `spiInterfaceSimple` to `declaringTypeFqcn` / `declaringTypeSimple`.
**Alternatives:**
- Keep spiInterface* names + add isInterface boolean — avoids downstream changes but semantically wrong for classes
**Rationale:** Pre-release platform — breaking changes cost nothing. The field names are used by spring generators (graphql-spring-generator, potentially rest-spring-generator). Fixing the name now is trivial; fixing it later after external adoption is expensive.
**Trade-offs:** Touches all consumers of DomainScanResult (generator-common, graphql-spring-generator). Mechanical find-replace.
**Sources:** generator-common/DomainScanResult.java (current field names)
**Exploration:** quick
**Status:** captured

## D3: Injection strategy for class-based @McpDomain

**Choice:** Inject the concrete class directly. `@Inject MyService myService` in generated resolvers/resources.
**Alternatives:**
- Discover and inject interface if present — more complex generator logic, preserves interface-based injection for existing domains
- Always require interface for injection — defeats the purpose of @McpDomain on classes
**Rationale:** CDI alternatives are resolved at the bean level, not the injection point type. A CDI alternative for MyService works whether it's injected by class or interface type. The whole point of this DX improvement is removing the mandatory interface for simple domains.
**Trade-offs:** If someone creates a CDI alternative that implements an interface but not the concrete class, injection won't pick it up. This is an unlikely edge case — and the solution is to add the interface back for that specific domain (which is the current pattern).
**Sources:** CDI spec 4.0 (bean resolution by type), GraphQLResolverProcessor.java lines 668-676 (current injection code)
**Exploration:** quick
**Status:** captured

## D4: SpringModelScanner fix approach

**Choice:** Match GraphQLModelScanner's two-pass pattern independently — add class-first scan to SpringModelScanner without extracting shared code.
**Alternatives:**
- Extract shared scanning to mcp-core utility — eliminates duplication but adds a module dependency and abstraction layer
**Rationale:** The two scanners are framework-specific by nature (CDI Arc container vs Spring ApplicationContext). The scan logic itself is simple — iterate beans, check annotations. Extracting a shared utility would abstract over two fundamentally different bean discovery mechanisms for minimal code sharing.
**Trade-offs:** Two independent implementations of the same logical algorithm. Acceptable because the algorithm is simple and the inputs are framework-specific.
**Sources:** mcp/GraphQLModelScanner.java (two-pass: class-first lines 55-82, interface-fallback lines 84-102), mcp-spring/SpringModelScanner.java (interface-only lines 59-83)
**Exploration:** quick
**Status:** captured

## D5: Overall approach — right tool for each job

**Choice:** @McpDomain on 2 core POJOs (SubscriptionService, EventTypeService) for domain operations + rest-spring-generator for 3 transport-specific endpoints (webhook, callback dispatch, engagement). Fixes SpringModelScanner independently.
**Alternatives:**
- SPI interfaces for everything — creates SubscriptionApi/EventTypeApi interfaces. Consistent but adds ceremony, doesn't validate the DX improvement.
- @McpDomain everywhere — enhances generators for transport concerns (@RequestHeader, special content types). Most aggressive, risks design contamination — webhook headers aren't GraphQL/MCP concerns.
**Rationale:** Uses each tool for what it's designed for. @McpDomain for domain operations (multi-transport: GraphQL, REST, MCP). rest-spring-generator for JAX-RS → Spring translation of transport-specific endpoints. Validates the DX improvement (1 file instead of 2) without over-reaching into transport concerns.
**Trade-offs:** Two generation paths (graphql-spring-generator for @McpDomain, rest-spring-generator for JAX-RS). This matches the existing architecture — both generators already exist and are designed for these exact use cases.
**Sources:** issue-474 D8 (generation pipeline — graphql-spring-generator for @McpDomain, rest-spring-generator for JAX-RS), issue-295 D7 (full platform MCP coverage)
**Exploration:** quick
**Depends on:** D1 (scope), D3 (injection strategy)
**Status:** captured
