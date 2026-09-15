## D1: Platform Panache purge scope

**Choice:** Full purge — entities AND stores. Strip `extends PanacheEntityBase` from 11 entity files and port Panache query API usage in store implementations to EntityManager + JPQL. Remove `quarkus-hibernate-orm-panache` dependency.
**Alternatives:**
- Entities only — strip extends, leave stores. Quick but leaves half-done Panache dependency.
**Rationale:** Completing the purge means platform -jpa modules become usable from Spring immediately. Store implementations already have core-extracted equivalents so Panache query API is concentrated in a few files.
**Trade-offs:** Larger scope in Batch 1 but eliminates platform's Panache dependency entirely.
**Exploration:** quick
**Status:** captured

## D2: Generator plugin wiring strategy

**Choice:** Targeted — only add each generator plugin where the source module actually has matching annotations (@Path for rest, @McpDomain for graphql, @Tool for mcp).
**Alternatives:**
- Blanket — add all 3 plugins to every -spring pom. Uniform but runs plugins against empty indexes.
**Rationale:** A verify goal that always passes on zero-vs-zero gives false confidence. The IntelliJ audit data already tells us which modules have which annotations.
**Trade-offs:** Requires per-module annotation audit. New annotations added later won't be caught until someone adds the plugin.
**Exploration:** quick
**Status:** captured

## D3: mcp-spring and callback-spring scope

**Choice:** Both in scope — mcp-spring runtime module and callback-spring module included in this epic.
**Alternatives:**
- mcp-spring only, defer callback — callback is optional for initial Spring deployment.
- Defer both — focus on mechanical work only.
**Rationale:** Including both completes the full Spring deployment story. mcp-spring is required for MCP tools to work. callback-spring provides callback interception for Spring deployments.
**Trade-offs:** callback-spring is the most complex CDI pattern mapping (@Decorator → @Bean @Primary). Needs its own design attention within Batch 6.
**Exploration:** quick
**Status:** captured

## D4: Parent epic

**Choice:** Use parent#469 (dual-framework support) as the parent epic. File child issues under it.
**Alternatives:**
- New parent issue — separate tracking for "Spring deployment completion."
**Rationale:** parent#469 is open, all child issues closed. This work is the natural continuation. A new epic creates overhead for what's finishing #469's mission.
**Trade-offs:** None significant.
**Exploration:** quick
**Status:** captured
