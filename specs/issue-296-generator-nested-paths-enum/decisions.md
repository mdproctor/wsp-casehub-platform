## D1: Custom path segments — new @RestPath annotation

**Choice:** New `@RestPath("grants/batch")` annotation in `io.casehub.platform.api.mcp`. When present on an SPI method, the generator uses its value literally as the `@Path` segment instead of `toKebabCase(method.name())`. Slashes in the value produce nested path segments. When absent, existing kebab-case derivation is unchanged. `@PathParam` placeholders are appended after the `@RestPath` value.
**Alternatives:**
- Attribute on @RestMethod (`path = "grants"`) — overloads @RestMethod with two responsibilities; methods needing only path override must also declare a verb
- Attribute on @PlatformMutation/Query (`restPath = "grants"`) — pollutes transport-agnostic annotation with REST-specific metadata, same argument that #295 D1 rejected for verbs
**Rationale:** Follows the separation principle established by @RestMethod (D1 in #295): REST-specific metadata lives in REST-specific annotations. @PlatformMutation stays transport-agnostic. Independently useful — path override without verb override. One more annotation in platform-api.mcp, but the package already has five annotations (McpDomain, PlatformQuery, PlatformMutation, RestMethod, PathParam, HttpMethod) so the pattern is established.
**Trade-offs:** Methods that need both path and verb override now use three annotations (@PlatformMutation + @RestMethod + @RestPath). This is the minority case — most methods need at most one override.
**Sources:** GraphQLResolverProcessor.generateRestMethod() line 406 (current path derivation), AclResource lines 42-127 (nested paths: /grants, /grants/batch, /denies, /denies/batch), #295 decisions D1 (verb annotation separation principle)
**Exploration:** quick
**Status:** captured
