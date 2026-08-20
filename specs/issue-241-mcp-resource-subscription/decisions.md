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
