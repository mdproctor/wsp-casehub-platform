## D1: Resource serving direction

**Choice:** Platform-serves-content (A) — the platform IS the MCP server, domain repos contribute resource content through a platform SPI. The platform registers resources with quarkus-mcp-server's `ResourceManager`/`ResourceTemplateManager` on behalf of domains.

**Alternatives:**
- (B) Proxy/aggregation — platform aggregates resources from remote MCP servers run by domain repos. Wrong abstraction — domains don't run their own MCP servers.

**Rationale:** Domain repos produce data (device state, case state, metrics). The platform's MCP server (`@McpServer("casehub")`) is the single MCP endpoint that clients connect to. Domains contribute content through SPIs, not by running separate servers. This matches the existing tool pattern: domains declare `@McpDomain` resolvers, the platform's `GraphQLModelScanner` discovers them and `DynamicToolRegistrar` registers tools.

**Trade-offs:** Domains cannot independently configure MCP server behavior (transport, auth). This is acceptable — the platform owns the MCP server configuration.

**Sources:** Issue #241 description, `DynamicToolRegistrar.java`, `GraphQLModelScanner.java`, `ResourceManagerImpl.java` (quarkus-mcp-server 1.11.1)
**Exploration:** quick
**Status:** captured
