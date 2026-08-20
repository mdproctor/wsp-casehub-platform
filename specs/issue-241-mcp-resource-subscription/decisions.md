## D1: Resource serving direction

**Choice:** Platform-serves-content (A) — the platform IS the MCP server, domain repos contribute resource content through a platform SPI. The platform registers resources with quarkus-mcp-server's `ResourceManager`/`ResourceTemplateManager` on behalf of domains.

**Alternatives:**
- (B) Proxy/aggregation — platform aggregates resources from remote MCP servers run by domain repos. Wrong abstraction — domains don't run their own MCP servers.

**Rationale:** Domain repos produce data (device state, case state, metrics). The platform's MCP server (`@McpServer("casehub")`) is the single MCP endpoint that clients connect to. Domains contribute content through SPIs, not by running separate servers. This matches the existing tool pattern: domains declare `@McpDomain` resolvers, the platform's `GraphQLModelScanner` discovers them and `DynamicToolRegistrar` registers tools.

**Trade-offs:** Domains cannot independently configure MCP server behavior (transport, auth). This is acceptable — the platform owns the MCP server configuration.

**Sources:** Issue #241 description, `DynamicToolRegistrar.java`, `GraphQLModelScanner.java`, `ResourceManagerImpl.java` (quarkus-mcp-server 1.11.1)
**Exploration:** quick
**Status:** captured

## D2: SPI location

**Choice:** `platform-api` — new types in `io.casehub.platform.api.mcp` alongside `McpDomain` and `ModelEnricher`. Pure Java, zero deps, available to all domain repos.

**Alternatives:**
- New `mcp-api` module — adds a dependency edge for no isolation benefit (same reasoning as EndpointRegistry placement in platform-api)
- Extend EndpointRegistry — conflates connection routing with content serving (ruled out by D1 and D7)

**Rationale:** `platform-api` is the established home for pure Java SPIs used by domain repos. `McpDomain` and `ModelEnricher` are already there. Adding resource contribution types follows the same pattern. No new dependency edges needed.

**Trade-offs:** `platform-api` grows slightly. Acceptable — it's the foundational SPI module and is expected to grow as the platform adds capabilities.

**Sources:** `io.casehub.platform.api.mcp` package, `EndpointRegistry` placement rationale in endpoint-registry-design spec
**Exploration:** quick
**Depends on:** D1 (resource serving direction)
**Status:** captured

## D3: SPI shape — registry with builder and handle

**Choice:** `McpResourceRegistry` SPI in `platform-api` with `newResource(descriptor)` returning a `McpResourceRegistration` builder. The builder accepts `.handler(h)`, optional `.completion(argName, supplier)` calls, optional `.serverName(name)`, and `.register()` which returns a `McpResourceHandle`. The handle provides `notifyUpdate(uri)` for push notifications and `deregister()` for cleanup. The registry also has `deregister(name)`, `resolve(name)`, and `list()`.

The handler type is `McpResourceHandler` — a functional interface: `McpResourceContent read(McpResourceReadRequest request)`. `McpResourceReadRequest` carries `uri` (the resolved URI) and `templateArgs` (`Map<String, String>` of resolved template variables — empty for static resources, populated for templates). `McpResourceContent` carries `uri`, `text`, and optional `mimeType`.

**Alternatives:**
- CDI-discovered providers — domains implement `McpResourceProvider` interface, platform discovers via `Instance<>`. More declarative but less explicit; harder for domains to control registration timing and lifecycle. No natural place for the update notification handle.
- CDI event registration — domains fire `McpResourceRegistered` events. Most decoupled but no registry to query, handler lifecycle unclear, no handle returned.
- Overloaded `register(desc, handler)` / `register(desc, handler, completions)` — simpler for the current two-arg case, but each future concern (completions, server scoping, annotations, metadata) requires another overload. Builder is the right extension model.

**Rationale:** Builder pattern parallels established upstream API (`ResourceManager.newResource(name).setUri(...).setHandler(...).register()`, `ToolManager.newTool(name).setHandler(...).register()`). Extensible without breaking existing call sites. Deregistration on the handle parallels `ResourceManager.removeResource(uri)` / `ResourceTemplateManager.removeResourceTemplate(name)` and matches the platform convention (`EndpointRegistry.deregister()`, `DataSourceRegistry.deregister()`). Registry-level `deregister(name)`, `resolve(name)`, and `list()` provide introspection without requiring callers to hold handles.

**Trade-offs:** Builder is more API surface than a simple `register()` call. Worth it for extensibility — the quarkus-mcp-server API already uses this pattern, and future fields (annotations, metadata) integrate cleanly.

**Sources:** `EndpointRegistry` SPI pattern, `DataSourceRegistry` SPI pattern, `ResourceManager.newResource()` and `ToolManager.newTool()` builder patterns (quarkus-mcp-server 1.11.1)
**Exploration:** quick
**Depends on:** D1 (resource serving direction), D2 (SPI location)
**Status:** revised (R1-04: builder pattern replaces overloaded register(); R1-03: deregistration added; R1-06: handler type specified)

## D4: Resource type representation

**Choice:** Sealed interface `McpResourceDescriptor` with two record implementations: `StaticResourceDescriptor` (with `uri()`) and `TemplateResourceDescriptor` (with `uriTemplate()`). Factory methods `McpResourceDescriptor.of(...)` → `StaticResourceDescriptor` and `McpResourceDescriptor.template(...)` → `TemplateResourceDescriptor` for ergonomic construction. Shared fields (`name`, `mimeType`, `description`, `subscribable`) live on the sealed interface. The bridge pattern-matches on the sealed type to route to `ResourceManager` or `ResourceTemplateManager`.

**Alternatives:**
- Single record with `Kind` enum — simpler to write but `uri` field is semantically overloaded (literal URI for STATIC, URI template for TEMPLATE). No compile-time field safety, no exhaustiveness checking on switch, permits invalid states (STATIC kind with template URI syntax).

**Rationale:** Java 21 sealed types with pattern matching give compile-time field safety (`StaticResourceDescriptor.uri()` vs `TemplateResourceDescriptor.uriTemplate()` — distinct accessors with distinct semantics), exhaustiveness checking (adding a third kind forces every `switch` to update), and no invalid states (construction enforces the distinction). The bridge is the primary consumer that switches on type — same line count as enum dispatch, but with compile-time guarantees. Factory methods on the sealed interface preserve the same ergonomic construction API as the enum approach.

**Trade-offs:** Three types (sealed interface + two records) instead of one record. Minimal surface cost for significant type safety benefit. The design philosophy is explicit: "If 'simpler is better' crosses your mind, ask whether the simplicity serves the architecture or just avoids work."

**Sources:** `ResourceManager` vs `ResourceTemplateManager` (quarkus-mcp-server), Java 21 sealed types + pattern matching
**Exploration:** quick
**Depends on:** D3 (SPI shape)
**Status:** revised (R1-02: sealed hierarchy replaces single record with Kind enum)

## D5: Branch scope

**Choice:** SPI types in `platform-api` + bridge implementation in `mcp/` + domain metadata resources (from #240 Batch 2: `DomainResourceRegistrar` with `casehub://domain-index` and `casehub://domains/{domain}` template + completions) + tests. IoT consumer stays in casehubio/iot#77.

**Alternatives:**
- SPI + bridge only — too thin to validate the design; domain metadata is the simplest real consumer and proves the infrastructure works
- Full stack including IoT — cross-repo; IoT is a separate issue with its own lifecycle

**Rationale:** Domain metadata resources from #240 Batch 2 are the ideal first consumer: static data, same repo, validates the full registration→read path without subscription complexity. IoT adds subscription/notification — a natural follow-up that the infrastructure enables but doesn't require for validation.

**Trade-offs:** Subscription/notification relay is wired but not exercised by the first consumer. Tests will exercise it synthetically.

**Sources:** Issue #241 "Platform domain metadata" section, #240 spec §3.5, iot#77
**Exploration:** quick
**Depends on:** D1 (resource serving direction)
**Status:** captured

## D6: Template completions on builder

**Choice:** Completions provided at registration time via `.completion(argumentName, Supplier<List<String>>)` calls on the `McpResourceRegistration` builder. Each call maps a template variable name to a supplier of valid values. The bridge registers completions with `ResourceTemplateCompletionManager`. Repeatable — one call per template variable.

**Alternatives:**
- Defer completions — misses an explicit requirement from #240 design review
- Separate `registerCompletions()` API — more flexible but more API surface; domains would need two calls instead of one
- `Map<String, Supplier<List<String>>>` parameter on `register()` — works for current scope but requires method overloads for every future optional concern

**Rationale:** Completions are needed for the domain metadata consumer (`{domain}` variable needs valid domain names). Providing them on the registration builder keeps the API cohesive — one builder chain sets up the resource, handler, and completions together. `Supplier<List<String>>` allows dynamic values (domain list can change at runtime). Per-variable `.completion()` calls are clearer than a map and allow future per-variable options (e.g., max completion count).

**Trade-offs:** None significant. Builder pattern naturally accommodates optional, repeatable configuration.

**Sources:** #240 spec §3.5 (template completions), `ResourceTemplateCompletionManager` / `CompletionManager` (quarkus-mcp-server 1.11.1)
**Exploration:** quick
**Depends on:** D3 (SPI shape — builder pattern), D4 (resource type representation)
**Status:** revised (R1-04: moved from Map parameter on register() to per-variable calls on builder)

## D7: EndpointRegistry is not the integration point for MCP resources

**Choice:** MCP resource contribution uses `McpResourceRegistry` (a new SPI), not `EndpointRegistry`. This is an intentional divergence from issue #241's text, which mentions EndpointRegistry as the mechanism.

**Alternatives:**
- (A) EndpointRegistry IS the integration point — resources registered as `EndpointDescriptor` with `EndpointProtocol.MCP` and resource metadata in properties. Platform MCP server discovers resources from the registry.

**Rationale:** `EndpointRegistry` models external connections: "where can I find service X?" It is keyed by `(Path, tenancyId)`, stores `EndpointDescriptor` with URL, protocol, credentials, and capabilities. `EndpointProtocol.MCP` represents remote MCP server URLs for tool proxying (used by `workers-mcp` and `McpEndpointRegistry` in `casehub-engine`). MCP resource contribution models in-process content provision: "what data does this process's MCP server expose?" It requires a content handler (code that produces response data), not a URL to connect to.

These are categorically different:
1. `EndpointDescriptor` has no handler concept — it stores connection metadata, not behavior
2. Resource handlers execute code (e.g., query `ModelRegistry` for domain data) — they can't be reduced to a URL
3. `EndpointRegistry` is keyed by `(Path, tenancyId)` — resources are keyed by URI/name
4. The issue's intent is correct (programmatic data-driven registration, not `@Resource` annotations) but `EndpointRegistry` is the wrong mechanism for in-process content contribution

Remote MCP resource aggregation (issue §2: "Resource subscription discovery") is a distinct concern. When needed, `EndpointRegistry` entries with `EndpointProtocol.MCP` could drive discovery of remote MCP servers. But that's proxy/gateway logic, not in-process content contribution — and explicitly out of scope (D1).

**Sources:** `EndpointRegistry.java`, `EndpointDescriptor.java`, `EndpointProtocol.java` (`MCP` javadoc: "Use EndpointPropertyKeys.URL for the MCP server base URL"), `McpEndpointRegistry` in `casehub-engine` (uses EndpointRegistry to discover remote MCP servers for tool proxying)
**Exploration:** quick (surfaced by reviewer R1-01/R1-09)
**Depends on:** D1 (resource serving direction)
**Status:** captured

## D8: Config-driven server scoping with optional per-resource override

**Choice:** The bridge reads the MCP server name from config (`casehub.mcp.server-name`, default `"casehub"`) and applies it to all registrations by default. The `McpResourceRegistration` builder provides an optional `.serverName(name)` override for resources that need to register on a different MCP server in multi-server deployments.

**Alternatives:**
- Per-resource server name on the descriptor — couples domain code to MCP server topology; descriptors should describe what the resource IS, not where it's served
- No server scoping at all (hardcoded) — works for single-server, breaks when Qhorus or another module needs resources on `@McpServer("qhorus")`
- Per-bridge-instance config only (no per-resource override) — works when each MCP server has its own bridge deployment, but doesn't handle mixed registrations in a single bridge

**Rationale:** Config-driven default handles the common case (all resources on `"casehub"`). Per-resource override on the builder handles the multi-server case cleanly without burdening the descriptor with deployment concerns. This parallels `FeatureDefinition.setServerName(String)` in the upstream quarkus-mcp-server API — server scoping is a registration-time concern, not a descriptor concern.

Note: `DynamicToolRegistrar` currently does NOT call `.setServerName()` on tool registration — it relies on the framework default. The bridge's config property follows the same pattern but makes it explicit.

**Sources:** `FeatureDefinition.setServerName()` (quarkus-mcp-server 1.11.1), `DynamicToolRegistrar.java` (no serverName call), `@McpServer("casehub")` annotation on `CaseHubMcpTools`
**Exploration:** quick (surfaced by reviewer R1-05/R1-11)
**Depends on:** D3 (SPI shape — builder pattern)
**Status:** captured

## D9: Push-only notification — no subscriber awareness in SPI

**Choice:** `McpResourceHandle.notifyUpdate(uri)` pushes notifications blindly. The SPI does not expose subscriber counts, subscription events, or the ability to suppress computation when no clients are listening. Subscription lifecycle management (`resources/subscribe`, `resources/unsubscribe`) is entirely the bridge's concern.

**Alternatives:**
- Subscriber-aware SPI — handle exposes `subscriberCount()` or `onSubscribe(callback)` / `onUnsubscribe(callback)`. Domains can suppress expensive state computation when count is zero.
- Lazy-pull model — domains register a change supplier; the bridge only calls it when subscribers exist. More efficient for high-frequency producers but complex SPI.

**Rationale:** The MCP protocol's `resources/subscribe`/`resources/unsubscribe` are managed by quarkus-mcp-server internally. `ResourceInfo.sendUpdateAndForget()` is already a no-op if no subscribers exist — the notification itself is cheap. The expensive part is the data production on the *read* path (handler invocation), which only happens when a client actually reads after receiving the notification. So even with blind push, no wasted computation occurs — the notification is just a signal, not a data payload.

For the first consumer (domain metadata), `subscribable=false` — notifications are not used. For IoT, device state changes happen regardless of MCP subscribers — the update signal is a lightweight side-effect of an event the domain already processes.

**Trade-offs:** If a future consumer has expensive pre-computation triggered by state changes (not by reads), subscriber awareness would help. This can be added to the builder (`.onSubscribe(callback)`) without breaking the push-only default.

**Sources:** `ResourceInfo.sendUpdateAndForget()` (quarkus-mcp-server — no-op when no subscribers), MCP protocol spec (subscribe/unsubscribe lifecycle)
**Exploration:** quick (surfaced by reviewer R1-13)
**Depends on:** D3 (SPI shape)
**Status:** captured
