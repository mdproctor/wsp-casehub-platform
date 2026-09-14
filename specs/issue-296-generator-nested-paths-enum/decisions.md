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

## D2: Simple type detection — enums + fromString/valueOf via Jandex

**Choice:** Add `IndexView` parameter to `isSimpleType(String fqcn, IndexView index)`. Static FQCN set check is the fast path; for unknown types, call `index.getClassByName(fqcn)` and check: (1) `classInfo.isEnum()`, (2) has a static `fromString(String)` method, (3) has a static `valueOf(String)` non-enum method. Any match → simple type. Existing no-arg signature stays as a package-private test helper.
**Depends on:** None
**Alternatives:**
- Check only `isEnum()` — misses types like `ResourceId` that have `fromString(String)` for JAX-RS auto-conversion
- Build `Set<String> knownEnums` during scan phase — adds upfront scan for no benefit
**Rationale:** JAX-RS classifies types as `@QueryParam`-convertible if they have `valueOf(String)` or `fromString(String)`. Matching this in the generator prevents misclassifying JAX-RS-convertible types as request body params. Covers enums (`AclAction`, `NotificationStatus`) and value types (`ResourceId`).
**Trade-offs:** Requires `IndexView` threading through to `generateRestMethod()`. Already available at processor level. Method scan on a class is O(n) but negligible for real-world classes.
**Sources:** GraphQLResolverProcessor.isSimpleType() line 610 (current static check), AclResource line 60 (`@QueryParam("action") AclAction action`), ResourceId.fromString() line 36, JAX-RS spec §3.2 (parameter conversion rules)
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

## D4: Non-standard response patterns — reshape SPI, keep ETag hand-written

**Choice:** Three strategies: (1) 201→200: service returns entity, generator wraps in `Response.ok()` — acceptable status change for pre-release. (2) boolean→void/Optional: service throws `NotFoundException` or returns `Optional` instead of boolean — generator's existing void→204 and Optional→404 paths handle it. (3) ETag conditional GET: keep `PreferenceSchemaResource` hand-written with `@McpDomain` + `@Path` annotations so the REST skip detection (D5 from #295) suppresses generation for its methods. A `PreferenceSchemaApi` SPI still exists for GraphQL + MCP generation.
**Depends on:** D1 (#295, REST skip detection)
**Alternatives:**
- New `@RestStatus(201)` annotation + generator support — premature for two methods; still doesn't solve ETag case
- Generator support for `@Context` injection — JAX-RS runtime concept that doesn't belong in SPI interfaces
**Rationale:** Generator stays simple. Edge cases are handled at the SPI contract level (reshape return types) or by keeping the hand-written resource (ETag). No new annotations for minority patterns. If more endpoints need custom status codes in future, `@RestStatus` can be added then.
**Trade-offs:** Two behavioral changes for pre-release: addMute/activateSnooze return 200 instead of 201, removeMute/cancelSnooze throw NotFoundException instead of returning 404 via boolean. Both are acceptable — no external consumers. PreferenceSchemaResource stays hand-written — one endpoint that doesn't benefit from generation.
**Sources:** SuppressionResource lines 51,106 (201 responses), SuppressionResource lines 85,138 (boolean→404), PreferenceSchemaResource lines 25-37 (ETag conditional GET)
**Exploration:** quick
**Status:** captured

## D5: ACL authorization — service-layer with imperative guards

**Choice:** Single `@McpDomain("acl")` with `AclService` impl. Mutation methods carry `@RolesAllowed(PlatformRoles.ADMIN)` on the service. Query methods (`check`, `accessible`) use imperative `requireAdminOrSelf(actorId)` guard that throws `ForbiddenException` — no `@RolesAllowed`. `AclEntryInput→AclEntryRequest` DTO mapping moves into the service. Generated endpoint is pure delegation.
**Depends on:** D4 (authorization at service layer pattern from #295 D7)
**Alternatives:**
- Split into two domains (`acl-admin` mutations + `acl` queries) — over-engineered, splits a cohesive domain for an authorization concern
**Rationale:** Follows established #295 pattern: CDI interceptors handle `@RolesAllowed`, imperative code handles fine-grained guards. One domain, one service, single MCP discoverable unit. The admin-or-self guard is a two-line method — doesn't warrant a separate domain.
**Trade-offs:** Mixed authorization model in one service class (some methods annotated, others imperative). Acceptable — the pattern is clear and the alternative (domain split) is worse.
**Sources:** AclResource lines 44-171 (13 endpoints, mixed auth), AclResource line 173 (isAdminOrSelf guard), #295 decisions D7 (authorization model)
**Exploration:** quick
**Status:** captured

## D6: Preference endpoint mapping — direct SPI, validation in service

**Choice:** `@McpDomain("preferences")` with separate methods per operation. `scope` is a String `@QueryParam` — `parseScopePath()` moves into `PreferenceService`. Two DELETE operations disambiguated via `@RestPath`: `delete` (single, requires namespace+name) and `delete-namespace` (bulk). Schema validation (`PreferenceValidator.validate()`) and null-check validation move into the service impl. `PreferenceSchemaResource` stays hand-written (D4 — ETag conditional GET).
**Depends on:** D1 (@RestPath for path disambiguation), D4 (ETag endpoint stays hand-written)
**Alternatives:**
- Single delete method with discriminator param — pushes dispatch logic into a conditional, unclear SPI contract
**Rationale:** Each SPI method has one clear purpose. @RestPath disambiguation is exactly what D1 was designed for. Validation belongs in the service layer, not the endpoint layer — consistent with #295 pattern.
**Trade-offs:** Two DELETE methods on the same domain produce different paths (`/api/preferences/delete` vs `/api/preferences/delete-namespace`). Previous paths were `/preferences` and `/preferences/by-namespace`. Path change acceptable for pre-release.
**Sources:** PreferenceResource lines 37-95 (5 endpoints, validation, scope parsing), PreferenceSchemaResource lines 25-37 (ETag — stays hand-written per D4)
**Exploration:** quick
**Status:** captured
