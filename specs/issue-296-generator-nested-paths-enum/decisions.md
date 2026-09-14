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

## D2: Enum detection — pass IndexView to isSimpleType

**Choice:** Add `IndexView` parameter to `isSimpleType(String fqcn, IndexView index)`. Static FQCN set check is the fast path; for unknown types, call `index.getClassByName(fqcn)` and check `classInfo.isEnum()`. Existing no-arg signature stays as a package-private test helper.
**Depends on:** None
**Alternatives:**
- Build `Set<String> knownEnums` during scan phase, pass alongside IndexView — adds upfront scan of all indexed classes for no performance benefit since `getClassByName()` is O(1) in Jandex
**Rationale:** Minimal change. Jandex hash lookup is O(1), so per-parameter lookup is effectively free. No need for a separate collection pass. Enums like `AclAction`, `NotificationStatus`, `MuteScope` will be correctly classified as `@QueryParam` instead of request body.
**Trade-offs:** Requires `IndexView` to be threaded through to `generateRestMethod()`. This is already available at the processor level — just needs to be passed down.
**Sources:** GraphQLResolverProcessor.isSimpleType() line 610 (current static check), AclResource line 60 (`@QueryParam("action") AclAction action`), NotificationResource line 39 (`@QueryParam("status") NotificationStatus status`)
**Exploration:** quick
**Status:** captured

## D3: Notification + Suppression domain split — separate domains with distinct prefixes

**Choice:** Two separate `@McpDomain` SPIs: `@McpDomain("notifications")` for inbox CRUD (list, unreadCount, markRead, dismiss, markAllRead) and `@McpDomain("notification-suppression")` for suppression rules (addMute, listMutes, removeMute, activateSnooze, getSnooze, cancelSnooze). Each generates its own REST resource at its own path prefix (`/api/notifications`, `/api/notification-suppression`).
**Alternatives:**
- Single `@McpDomain("notifications")` combining all 11 methods — mixes inbox management and suppression in one SPI, large interface, undifferentiated MCP domain
- Separate domains but use @RestPath to keep shared `/notifications/` prefix — domain base path never used, every method overrides it, confusing
**Rationale:** Clean separation of concerns. Inbox CRUD and suppression rules have different authorization profiles and different consumers. MCP discovery benefits from focused domains — an LLM can request suppression operations without wading through inbox methods. Pre-release, no external consumers — path change is acceptable.
**Trade-offs:** Path prefix changes from `/notifications/mute` to `/api/notification-suppression/mute`. Acceptable for pre-release. Internal tests updated during migration.
**Sources:** NotificationResource (5 endpoints, /notifications prefix), SuppressionResource (6 endpoints, /notifications prefix, different injected SPI — SuppressionStore vs NotificationStore)
**Exploration:** quick
**Status:** captured
