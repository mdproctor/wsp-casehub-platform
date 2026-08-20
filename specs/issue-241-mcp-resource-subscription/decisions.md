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
- Extend EndpointRegistry — conflates connection routing with content serving (ruled out by D1)

**Rationale:** `platform-api` is the established home for pure Java SPIs used by domain repos. `McpDomain` and `ModelEnricher` are already there. Adding resource contribution types follows the same pattern. No new dependency edges needed.

**Trade-offs:** `platform-api` grows slightly. Acceptable — it's the foundational SPI module and is expected to grow as the platform adds capabilities.

**Sources:** `io.casehub.platform.api.mcp` package, `EndpointRegistry` placement rationale in endpoint-registry-design spec
**Exploration:** quick
**Depends on:** D1 (resource serving direction)
**Status:** captured

## D3: SPI shape — registry with handle

**Choice:** `McpResourceRegistry` SPI in `platform-api` with `register(descriptor, handler)` returning a `McpResourceHandle`. Domains inject the registry, call `register()` at startup, receive a handle for signaling updates via `handle.notifyUpdate(uri)`.

**Alternatives:**
- CDI-discovered providers — domains implement `McpResourceProvider` interface, platform discovers via `Instance<>`. More declarative but less explicit; harder for domains to control registration timing and lifecycle. No natural place for the update notification handle.
- CDI event registration — domains fire `McpResourceRegistered` events. Most decoupled but no registry to query, handler lifecycle unclear, no handle returned.

**Rationale:** Registry SPI parallels established platform patterns (`EndpointRegistry`, `DataSourceRegistry`). Explicit `register()` call gives domains control over timing. Returned handle gives domains a clean way to signal updates without looking anything up — parallels `ResourceInfo.sendUpdateAndForget()` from quarkus-mcp-server. The handler functional interface keeps content provision in the domain's code.

**Trade-offs:** Domains must explicitly inject and call the registry. This is intentional — MCP resource registration is an opt-in concern, not something that happens automatically.

**Sources:** `EndpointRegistry` SPI pattern, `DataSourceRegistry` SPI pattern, `ResourceManager.newResource()` builder pattern (quarkus-mcp-server)
**Exploration:** quick
**Depends on:** D1 (resource serving direction), D2 (SPI location)
**Status:** captured

## D4: Resource type representation

**Choice:** Single `McpResourceDescriptor` record with `Kind` enum (`STATIC`/`TEMPLATE`). Factory methods `McpResourceDescriptor.of(...)` and `McpResourceDescriptor.template(...)` for ergonomic construction. The `mcp/` bridge routes to `ResourceManager` or `ResourceTemplateManager` based on kind.

**Alternatives:**
- Sealed hierarchy (`StaticResource`/`TemplateResource` records) — type-safe at compile time but more types to maintain for minimal benefit. Pattern matching adds verbosity at every call site.

**Rationale:** Single record is simpler. The `uri` field carries either a literal URI or a URI template — the `kind` field disambiguates. Factory methods enforce correct construction. The bridge is the only consumer that needs to distinguish; domains just call the appropriate factory.

**Trade-offs:** `uri` field is overloaded (literal or template). Mitigated by factory methods and Javadoc.

**Sources:** `ResourceManager` vs `ResourceTemplateManager` (quarkus-mcp-server), `McpResourceDescriptor` preview
**Exploration:** quick
**Depends on:** D3 (SPI shape)
**Status:** captured

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

## D6: Template completions on descriptor

**Choice:** Completions provided at registration time via an optional `Map<String, Supplier<List<String>>>` parameter on `register()`. Each entry maps a template variable name to a supplier of valid values. The bridge registers completions with `ResourceTemplateCompletionManager`.

**Alternatives:**
- Defer completions — misses an explicit requirement from #240 design review
- Separate `registerCompletions()` API — more flexible but more API surface; domains would need two calls instead of one

**Rationale:** Completions are needed for the domain metadata consumer (`{domain}` variable needs valid domain names). Providing them at registration time keeps the API cohesive — one `register()` call sets up the resource, handler, and completions together. `Supplier<List<String>>` allows dynamic values (domain list can change at runtime if hot-deploy ever lands).

**Trade-offs:** `register()` method gets a third parameter. Use overloads: `register(desc, handler)` for no completions, `register(desc, handler, completions)` for templates with completions.

**Sources:** #240 spec §3.5 (template completions), `ResourceTemplateCompletionManager` (quarkus-mcp-server 1.11.1)
**Exploration:** quick
**Depends on:** D4 (resource type representation)
**Status:** captured
