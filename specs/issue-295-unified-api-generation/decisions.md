## D1: HTTP method mapping — annotation parameter on @PlatformMutation

**Choice:** Add `method` attribute to `@PlatformMutation` with `HttpMethod` enum, defaulting to POST
**Alternatives:**
- Convention from method name (delete* → DELETE) — fragile, rename breaks the contract
- New annotations (@PlatformDelete, @PlatformPut, @PlatformPatch) — annotation proliferation, more to maintain
- Always POST — simplest but non-standard REST semantics
**Rationale:** Explicit, no guessing, zero new annotations beyond the enum. Familiar pattern (JAX-RS uses the same approach). Default to POST preserves backward compatibility with existing @PlatformMutation usages. Only SPI authors who need DELETE/PUT/PATCH annotate explicitly.
**Trade-offs:** Requires a new `HttpMethod` enum in platform-api (or reuse of a string constant). Slightly more verbose than convention-based for the DELETE case.
**Sources:** CallbackRegistrationResource (DELETE, PUT), AclResource (DELETE), NotificationResource (PATCH), GraphQLResolverProcessor.generateRestMethod() line 309
**Exploration:** quick
**Status:** captured

## D2: Parameter binding — convention-based with @PathParam

**Choice:** Convention: primitives/String → @QueryParam by default. Single complex-object param on POST/PUT/PATCH → request body (@Consumes). New `io.casehub.platform.api.mcp.PathParam` annotation on SPI parameters for path segments.
**Alternatives:**
- Explicit annotations on every parameter — most precise but verbose for obvious cases
- All @QueryParam, no @PathParam — simpler generator but non-standard REST URLs
**Rationale:** Minimizes annotation burden for the common case. Complex objects as request body is the JAX-RS convention. @PathParam annotation is opt-in for the minority of methods that need path segments (deregister, markRead, etc.). The convention matches what developers expect from JAX-RS.
**Trade-offs:** Convention can be surprising when a method has multiple complex params — needs a clear rule (first complex param wins, or error). The @PathParam annotation adds one more type to platform-api's mcp package.
**Sources:** AclResource lines 60-68 (DELETE with @QueryParam), CallbackRegistrationResource lines 34-49 (@PathParam on heartbeat/deregister), NotificationResource lines 58-72 (@PathParam on markRead/dismiss)
**Exploration:** quick
**Status:** captured

## D3: @PathParam annotation location — platform-api mcp package

**Choice:** New `io.casehub.platform.api.mcp.PathParam` annotation in platform-api. Same name as JAX-RS but different package. Generator maps it to `jakarta.ws.rs.PathParam` in generated code.
**Depends on:** D2 (parameter binding needs a @PathParam annotation)
**Alternatives:**
- Name it @RestPath — avoids name collision but unfamiliar
**Rationale:** Familiar semantics, zero JAX-RS dependency in platform-api (which must remain zero-dep). Same name means developers know what it does without documentation. Import disambiguation is handled by IDEs.
**Trade-offs:** Name collision with jakarta.ws.rs.PathParam requires import care in classes that use both. Unlikely in practice since SPI interfaces don't import JAX-RS.
**Sources:** platform-api zero-dependency rule (CLAUDE.md), io.casehub.platform.api.mcp package (McpDomain, PlatformQuery, PlatformMutation already live here)
**Exploration:** quick
**Status:** captured

## D4: @RunOnVirtualThread — always generated

**Choice:** All generated REST resources include `@RunOnVirtualThread` at class level, unconditionally.
**Alternatives:**
- Opt-in via @McpDomain attribute (blocking=true) — more control but every domain that touches a database would need to set it
**Rationale:** SPI implementations are blocking (JPA, HTTP calls, PreferenceStore). Virtual threads are always correct for blocking I/O. Adding an opt-in flag adds configuration burden for zero practical benefit — no current SPI implementation is reactive.
**Trade-offs:** If a future SPI is reactive/non-blocking, @RunOnVirtualThread is harmless (virtual thread just wraps the reactive chain). No downside.
**Sources:** AclResource line 27 (@RunOnVirtualThread), NotificationResource line 23 (@RunOnVirtualThread), all SPI implementations use blocking I/O
**Exploration:** quick
**Status:** captured

## D5: Hand-written REST skip detection — @Path + @McpDomain scan

**Choice:** Mirror the GraphQL pattern: scan Jandex for classes with both `@Path` and `@McpDomain`. Extract method names from JAX-RS-annotated methods (@GET, @POST, @DELETE, @PUT, @PATCH). Skip generating methods where domain:methodName matches.
**Alternatives:**
- Scan @Path only, match by domain path prefix (/api/{domain}) — less annotation but fragile if paths don't follow the convention
**Rationale:** Consistent with the existing GraphQL skip detection (lines 99-114 of GraphQLResolverProcessor). Requires the hand-written class to declare @McpDomain, which is a reasonable expectation — it explicitly marks the class as a domain participant. This enables incremental migration: hand-write some methods, generate the rest.
**Trade-offs:** Hand-written REST resources must add @McpDomain annotation to be detected. Without it, both hand-written and generated resources would exist, causing JAX-RS path conflicts at startup.
**Sources:** GraphQLResolverProcessor.scanHandWrittenMethods() lines 99-114 (existing GraphQL pattern)
**Exploration:** quick
**Status:** captured

## D6: Path convention — kebab-case

**Choice:** Generated REST paths use kebab-case transformation of Java method names: markAllRead → /mark-all-read, unreadCount → /unread-count.
**Alternatives:**
- camelCase as-is — less processing but non-standard for URLs
**Rationale:** Standard REST convention. Consistent with existing hand-written endpoints (e.g., NotificationResource uses /unread-count, /mark-all-read). URLs are case-insensitive by convention; kebab-case is the universal REST standard.
**Trade-offs:** Requires a camelCase → kebab-case converter in the generator. Simple utility but must handle edge cases (consecutive uppercase: HTTPMethod → http-method, not h-t-t-p-method). Single-word methods (vendors, configured) are unaffected.
**Sources:** NotificationResource lines 53, 76 (existing kebab-case paths), REST conventions
**Exploration:** quick
**Status:** captured

## D7: Migration scope — full platform coverage, batched by complexity

**Choice:** Every platform REST endpoint gets an @McpDomain SPI so the entire platform is automatable via MCP. Batched: simple delegation endpoints first (callbacks, delivery channels, digest status, notification preferences), then complex refactoring (AclResource, PreferenceResource, notification endpoints with business logic).
**Alternatives:**
- Only endpoints that are already thin delegation — leaves the platform partially automatable
- Big bang — all endpoints at once, high risk, long branch
**Rationale:** Full MCP coverage enables complete LLM automation and scenario scripting. Batching by complexity reduces risk per batch and provides early validation of the generator's production readiness.
**Trade-offs:** Complex endpoints (AclResource, PreferenceResource) require extracting business logic from the REST layer into @McpDomain service implementations. This is beneficial refactoring (separates concerns) but takes more effort than simple endpoint migration.
**Sources:** Issue #295 child issues 1-2, user directive ("entire platform automated by LLM and MCP")
**Exploration:** quick
**Status:** captured

## D8: @PlatformMutation HttpMethod enum — platform-api

**Choice:** New `io.casehub.platform.api.mcp.HttpMethod` enum in platform-api with values: POST, PUT, DELETE, PATCH. Used as the type for `@PlatformMutation(method=...)`. Default: POST.
**Depends on:** D1 (HTTP method mapping needs this enum)
**Alternatives:**
- String constant ("DELETE") — stringly-typed, no compile-time validation
- Reuse jakarta.ws.rs.HttpMethod — violates platform-api zero-dependency rule
**Rationale:** Type-safe, zero external dependencies. Small enum (4 values). Lives alongside the other MCP annotations in `io.casehub.platform.api.mcp`.
**Trade-offs:** One more type in platform-api. Minimal — the enum is tiny and scoped.
**Sources:** platform-api zero-dependency rule (CLAUDE.md), @PlatformMutation annotation
**Exploration:** quick
**Status:** captured
