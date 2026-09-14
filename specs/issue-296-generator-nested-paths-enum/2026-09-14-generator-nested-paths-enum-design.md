# Generator Nested Paths + Enum Detection & Batch 2 Migration — Design Spec

**Issues:** casehubio/platform#296, casehubio/platform#297
**Date:** 2026-09-14
**Status:** Draft

## Summary

Two changes to the `graphql-generator` APT (#296) followed by migrating the remaining five hand-written REST endpoints to the generated `@McpDomain` approach (#297).

Generator enhancements:
1. **`@RestPath` annotation** — custom path segments on SPI methods, enabling nested REST paths (`/grants/batch`, `/mute/{id}`)
2. **Simple type detection via Jandex** — `isSimpleType()` uses `IndexView` to classify enums and JAX-RS-convertible types (with `fromString`/`valueOf`) as `@QueryParam` instead of request body. This is a correctness enhancement for future-proofing — no batch 2 endpoint is blocked by this gap, since enum parameters only appear on GET/DELETE methods where all non-`@PathParam` params are already classified as `@QueryParam`.
3. **SPI discovery via RoundEnvironment** — the APT is enhanced to also scan the current compilation unit via APT's TypeMirror API, enabling SPI interfaces to live in the same module as the generated code.

Batch 2 migration: AclResource, PreferenceResource, PreferenceSchemaResource, NotificationResource, SuppressionResource — completing full platform coverage. Zero hand-written REST resources remain after this work (PreferenceSchemaResource stays hand-written for ETag support but is annotated for skip detection).

## Issue #296 — Generator Enhancements

### @RestPath Annotation (D1)

New annotation in `io.casehub.platform.api.mcp`:

```java
package io.casehub.platform.api.mcp;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface RestPath {
    String value();
}
```

When present on an SPI method, the generator uses its value literally as the `@Path` segment instead of `toKebabCase(method.name())`. Slashes in the value produce nested path segments. `@PathParam` placeholders are appended after the `@RestPath` value.

**Examples:**

```java
@PlatformMutation("Grant access")
@RestPath("grants")
void grant(AclEntryInput input);
// Generates: @POST @Path("/grants")

@PlatformMutation("Grant access in batch")
@RestPath("grants/batch")
void grantBatch(List<AclEntryInput> inputs);
// Generates: @POST @Path("/grants/batch")

@PlatformMutation("Remove a mute rule")
@RestMethod(HttpMethod.DELETE)
@RestPath("mute")
void removeMute(@PathParam String id);
// Generates: @DELETE @Path("/mute/{id}")
```

When absent, the existing `toKebabCase(method.name())` derivation applies unchanged. This is backwards-compatible — all batch 1 migrated endpoints continue to work without modification.

**Generator changes:**

In `generateRestMethod()`, replace:
```java
pathSuffix.append("/").append(toKebabCase(method.name()));
```
with:
```java
String restPath = /* read @RestPath annotation via Jandex */;
if (restPath != null) {
    pathSuffix.append("/").append(restPath);
} else {
    pathSuffix.append("/").append(toKebabCase(method.name()));
}
```

New Jandex DotName constant:
```java
private static final DotName REST_PATH_ANN = DotName.createSimple("io.casehub.platform.api.mcp.RestPath");
```

The `@RestPath` value is read in `scanAnnotatedInterfaces()` and stored on `OperationInfo` (new field: `String restPathOverride`).

### Simple Type Detection via Jandex (D2)

Change `isSimpleType(String fqcn)` to `isSimpleType(String fqcn, IndexView index)`:

```java
static boolean isSimpleType(String fqcn, IndexView index) {
    if (SIMPLE_TYPES.contains(fqcn)) return true;
    if (fqcn.startsWith("java.time.")) return true;
    if (index != null) {
        ClassInfo ci = index.getClassByName(fqcn);
        if (ci != null) {
            if (ci.isEnum()) return true;
            if (hasStaticStringMethod(ci, "fromString")) return true;
            if (!ci.isEnum() && hasStaticStringMethod(ci, "valueOf")) return true;
        }
    }
    return false;
}

private static boolean hasStaticStringMethod(ClassInfo ci, String methodName) {
    DotName stringType = DotName.createSimple("java.lang.String");
    for (MethodInfo m : ci.methods()) {
        if (m.name().equals(methodName)
                && java.lang.reflect.Modifier.isStatic(m.flags())
                && m.parameterTypes().size() == 1
                && m.parameterTypes().get(0).name().equals(stringType)) {
            return true;
        }
    }
    return false;
}
```

Three Jandex checks for JAX-RS-convertible types:
1. **`isEnum()`** — enums like `AclAction`, `NotificationStatus`, `MuteScope`
2. **`fromString(String)`** — value types like `ResourceId` that implement JAX-RS parameter conversion
3. **`valueOf(String)` (non-enum)** — types following the `valueOf` convention

The `IndexView` is threaded from `process()` → `generateRestResourceSource()` → `generateRestMethod()`. The existing no-arg overload remains as a package-private test helper for static type checks.

`index.getClassByName()` is O(1) in Jandex (hash lookup). Method scanning is O(n) per class but negligible for any real-world type.

### SPI Discovery — APT Enhancement (D7)

The current APT discovers `@McpDomain` SPI interfaces exclusively via Jandex indexes loaded from dependency JARs (`META-INF/jandex.idx` on the classpath). This works for SPIs in separate API modules (e.g., `CallbackApi` in `callback-api/`, which is a dependency of `callback/`). However, batch 2 SPIs live in the same module as the APT configuration (e.g., `AclApi` in `acl-admin/`). These classes are not yet compiled into a JAR with a Jandex index when the APT runs during the `compile` phase — the jandex-maven-plugin runs at `process-classes`, after compilation.

**Fix:** Enhance `scanAnnotatedInterfaces()` to use a dual-scan approach:

1. **Jandex scan (existing)** — discovers SPIs from dependency JARs. Handles cross-module SPIs like `CallbackApi`.
2. **APT TypeMirror scan (new)** — discovers SPIs being compiled in the current module. Uses `roundEnv.getElementsAnnotatedWith()` or `processingEnv.getElementUtils()` to find `@McpDomain`-annotated interfaces in the current compilation unit. Converts TypeMirror/Element API data into the same `DomainOperations`/`OperationInfo` structures used by Jandex.

The TypeMirror scan runs after the Jandex scan. If both find the same domain (same `@McpDomain` value), the Jandex result takes precedence — this prevents double-generation when a dependency JAR contains a previously compiled version of the same SPI.

This enhancement is a prerequisite for batch 2 migration. Without it, SPIs in `acl-admin/`, `preferences-editor/`, and `notifications/` would be invisible to the APT.

## Issue #297 — Batch 2 Migration

### Migration Pattern (established in #295)

1. Create `@McpDomain` SPI interface with `@PlatformQuery`/`@PlatformMutation`/`@RestMethod`/`@PathParam`/`@RestPath`
2. Create `@ApplicationScoped` service implementation (absorbs business logic, carries `@RolesAllowed`)
3. Generator produces REST + GraphQL + MCP endpoints
4. Delete hand-written resource, update tests

### Endpoint 1: AclResource → AclApi (D5)

**Module:** `acl-admin/`
**Domain:** `@McpDomain("acl")`
**Endpoints:** 12

The `AclApi` SPI interface uses `@RestPath` for nested path segments:

```java
@McpDomain("acl")
public interface AclApi {
    // --- Grants ---
    @PlatformMutation("Grant access to a resource")
    @RestPath("grants")
    void grant(AclEntryInput input);

    @PlatformMutation("Grant access in batch")
    @RestPath("grants/batch")
    void grantBatch(List<AclEntryInput> inputs);

    @PlatformMutation("Revoke a grant")
    @RestMethod(HttpMethod.DELETE)
    @RestPath("grants")
    void revoke(String actorId, ResourceId resourceId, AclAction action);

    @PlatformMutation("Revoke grants in batch")
    @RestPath("grants/revoke-batch")
    void revokeBatch(List<AclEntryInput> inputs);

    @PlatformMutation("Revoke all grants for an actor on a resource")
    @RestMethod(HttpMethod.DELETE)
    @RestPath("grants/all")
    void revokeAll(String actorId, ResourceId resourceId);

    // --- Denies ---
    @PlatformMutation("Add a deny entry")
    @RestPath("denies")
    void deny(AclEntryInput input);

    @PlatformMutation("Add deny entries in batch")
    @RestPath("denies/batch")
    void denyBatch(List<AclEntryInput> inputs);

    @PlatformMutation("Remove a deny entry")
    @RestMethod(HttpMethod.DELETE)
    @RestPath("denies")
    void removeDeny(String actorId, ResourceId resourceId, AclAction action);

    @PlatformMutation("Remove deny entries in batch")
    @RestPath("denies/revoke-batch")
    void removeDenyBatch(List<AclEntryInput> inputs);

    // --- Parents ---
    @PlatformMutation("Register a parent resource relationship")
    @RestPath("parents")
    void registerParent(ParentInput input);

    // --- Queries ---
    @PlatformQuery("Check if an actor has access to a resource")
    @RestPath("check")
    AccessCheckResponse check(String actorId, ResourceId resourceId, AclAction action);

    @PlatformQuery("List accessible resources for an actor")
    @RestPath("accessible")
    AclPage accessible(String actorId, String resourceType, AclAction action, String cursor, Integer limit);
}
```

**Batch DELETE→POST verb change:** The original `AclResource` uses `@DELETE` with request body for `revokeBatch` and `removeDenyBatch`. HTTP DELETE with a request body is non-standard (RFC 9110 §9.3.5: "a client SHOULD NOT generate content in a DELETE request"). The generator only classifies POST/PUT/PATCH as body-accepting verbs — DELETE parameters would be misclassified as `@QueryParam`. These two methods are changed to POST with distinct `@RestPath` values (`grants/revoke-batch`, `denies/revoke-batch`). Verb change is acceptable for pre-release.

**AclService** (`@ApplicationScoped implements AclApi`):
- Mutation methods: `@RolesAllowed(PlatformRoles.ADMIN)`, delegates to `AccessControlProvider`
- `AclEntryInput→AclEntryRequest` mapping in service (private helper)
- Query methods: imperative `requireAdminOrSelf(actorId)` guard, throws `ForbiddenException`
- Input validation (null checks on required params) in service — returns 400 via `BadRequestException`; validation runs after `@RolesAllowed` CDI interceptor (authorization before validation)
- Injects: `AccessControlProvider`, `CurrentPrincipal`

**Note on `AclAction` and `ResourceId` as query params:** With D2 (enum detection), `AclAction` is correctly classified as simple. `ResourceId` has `fromString(String)` — JAX-RS uses this for automatic `@QueryParam` conversion. No `ParamConverter` needed.

### Endpoint 2: PreferenceResource → PreferenceApi (D6)

**Module:** `preferences-editor/`
**Domain:** `@McpDomain("preferences")`
**Endpoints:** 5

```java
@McpDomain("preferences")
public interface PreferenceApi {
    @PlatformMutation("Set a preference value")
    @RestMethod(HttpMethod.PUT)
    void set(String scope, PreferenceInput input);

    @PlatformMutation("Delete a single preference")
    @RestMethod(HttpMethod.DELETE)
    @RestPath("delete")
    void delete(String scope, String namespace, String name, String subKey);

    @PlatformMutation("Delete all preferences in a namespace")
    @RestMethod(HttpMethod.DELETE)
    @RestPath("delete-namespace")
    void deleteNamespace(String scope, String namespace);

    @PlatformQuery("List raw preference records")
    List<PreferenceRecord> list(String scope);

    @PlatformQuery("Get resolved preferences for a scope")
    ResolvedPreferencesResponse resolved(String scope);
}
```

**PreferenceService** (`@ApplicationScoped implements PreferenceApi`):
- `parseScopePath(String scope)` — converts scope string to `Path`
- `set()`: schema validation via `PreferenceValidator`, delegates to `PreferenceStore`
- `delete()`: null checks on namespace + name, throws `BadRequestException`
- `deleteNamespace()`: null check on namespace, delegates to `store.deleteAll()`
- Injects: `PreferenceStore`, `PreferenceProvider`, `PreferenceSchemaRegistry`, `PreferenceValidator`, `CurrentPrincipal`

### Endpoint 3: PreferenceSchemaResource — stays hand-written (D4)

**Module:** `preferences-editor/`
**Domain:** `@McpDomain("preference-schemas")`

The ETag conditional GET pattern requires `@Context Request` — a JAX-RS runtime concept that doesn't belong in an SPI interface. This endpoint uses a three-part approach:

1. **`PreferenceSchemaApi`** — SPI interface for GraphQL/MCP generation only:
   ```java
   @McpDomain("preference-schemas")
   public interface PreferenceSchemaApi {
       @PlatformQuery("List preference schema descriptors")
       List<PreferenceSchemaDescriptor> schema(String namespace);
   }
   ```

2. **`PreferenceSchemaService`** (`@ApplicationScoped implements PreferenceSchemaApi`) — handles the GraphQL/MCP path. Returns `List<PreferenceSchemaDescriptor>` without ETag. Delegates to `PreferenceSchemaRegistry.discover()` with namespace filtering — same logic as the hand-written resource minus ETag.

3. **`PreferenceSchemaResource`** — stays hand-written, unchanged. Gets `@McpDomain("preference-schemas")` added to its class-level annotations (alongside existing `@Path`). This enables REST skip detection: the generator sees `@Path` + `@McpDomain` + `@GET` and skips generating a REST method for `schema`. The hand-written resource does NOT implement `PreferenceSchemaApi` — their signatures differ (`Response` with `@Context Request` vs `List<PreferenceSchemaDescriptor>`). The hand-written REST endpoint and the generated GraphQL/MCP endpoints coexist independently.

**Path note:** The hand-written resource stays at `/preferences/schema` (no `/api/` prefix). Generated GraphQL/MCP endpoints use the `preference-schemas` domain name. This path inconsistency is acceptable — the REST endpoint is hand-written specifically because it needs ETag support that the generator can't express.

### Endpoint 4: NotificationResource → NotificationApi (D3)

**Module:** `notifications/`
**Domain:** `@McpDomain("notifications")`
**Endpoints:** 5

```java
@McpDomain("notifications")
public interface NotificationApi {
    @PlatformQuery("List notifications for the current user")
    NotificationPage list(NotificationStatus status, String category, String cursor, Integer limit);

    @PlatformQuery("Get unread notification count")
    @RestPath("unread-count")
    Map<String, Long> unreadCount();

    @PlatformMutation("Mark a notification as read")
    @RestMethod(HttpMethod.PATCH)
    @RestPath("read")
    Optional<Notification> markRead(@PathParam String id);

    @PlatformMutation("Dismiss a notification")
    @RestMethod(HttpMethod.PATCH)
    @RestPath("dismiss")
    Optional<Notification> dismiss(@PathParam String id);

    @PlatformMutation("Mark all notifications as read")
    @RestPath("mark-all-read")
    Map<String, Integer> markAllRead();
}
```

**NotificationService** (`@ApplicationScoped implements NotificationApi`):
- All methods derive userId/tenancyId from `CurrentPrincipal`
- `list()`: builds `NotificationQuery` from params + principal
- `markRead()`/`dismiss()`: delegates to `NotificationStore`, returns `Optional` (generator handles 200/404)
- Injects: `NotificationStore`, `CurrentPrincipal`

**Note on `markRead`/`dismiss` paths:** These use `@RestPath("read")` and `@RestPath("dismiss")` with `@PathParam String id`. The generator appends `/{id}` after the `@RestPath` value, producing `@Path("/read/{id}")` and `@Path("/dismiss/{id}")`. This preserves the semantic path structure.

### Endpoint 5: SuppressionResource → NotificationSuppressionApi (D3)

**Module:** `notifications/`
**Domain:** `@McpDomain("notification-suppression")`
**Endpoints:** 6

```java
@McpDomain("notification-suppression")
public interface NotificationSuppressionApi {
    // --- Mute ---
    @PlatformMutation("Add a mute rule")
    @RestPath("mute")
    MuteRule addMute(MuteRuleInput input);

    @PlatformQuery("List active mute rules")
    @RestPath("mute")
    List<MuteRule> listMutes();

    @PlatformMutation("Remove a mute rule")
    @RestMethod(HttpMethod.DELETE)
    @RestPath("mute")
    void removeMute(@PathParam String id);

    // --- Snooze ---
    @PlatformMutation("Activate snooze")
    @RestPath("snooze")
    Snooze activateSnooze(SnoozeInput input);

    @PlatformQuery("Get active snooze")
    @RestPath("snooze")
    Optional<Snooze> getSnooze();

    @PlatformMutation("Cancel snooze")
    @RestMethod(HttpMethod.DELETE)
    @RestPath("snooze")
    void cancelSnooze();
}
```

**NotificationSuppressionService** (`@ApplicationScoped implements NotificationSuppressionApi`):
- All methods derive userId/tenancyId from `CurrentPrincipal`
- `addMute()`: sanitizes input (overrides userId/tenancyId from principal), returns entity (200, was 201 — D4)
- `removeMute()`: throws `NotFoundException` if not found (was boolean→404 — D4)
- `cancelSnooze()`: throws `NotFoundException` if no active snooze (was boolean→404 — D4)
- `activateSnooze()`: sanitizes input, returns entity (200, was 201 — D4)
- Injects: `SuppressionStore`, `CurrentPrincipal`

## SPI Interface Placement

All `@McpDomain` SPI interfaces live in their respective modules, not in `platform-api`:
- `AclApi` in `acl-admin/`
- `PreferenceApi`, `PreferenceSchemaApi` in `preferences-editor/`
- `NotificationApi`, `NotificationSuppressionApi` in `notifications/`

This follows the pattern established in #295 (D7). These are generation sources for REST/GraphQL/MCP endpoints, not cross-module contracts. Service implementations inject module-internal dependencies that don't belong in `platform-api`.

## Test Strategy

### Generator Unit Tests (#296)

Extend `GraphQLResolverProcessorTest`:

1. **@RestPath override** — verify `@RestPath("grants")` produces `@Path("/grants")` instead of `@Path("/grant")`
2. **@RestPath with nested segments** — verify `@RestPath("grants/batch")` produces `@Path("/grants/batch")`
3. **@RestPath + @PathParam** — verify `@RestPath("mute")` with `@PathParam String id` produces `@Path("/mute/{id}")`
4. **@RestPath absent** — verify existing kebab-case derivation unchanged
5. **Enum detection** — verify `isSimpleType("io.casehub.platform.api.acl.AclAction", index)` returns `true` when Jandex index contains the enum
6. **Enum as @QueryParam** — verify enum parameters are classified as `@QueryParam`, not body
7. **fromString detection** — verify `isSimpleType("io.casehub.platform.api.acl.ResourceId", index)` returns `true` when Jandex index contains the type with `fromString(String)`
8. **RoundEnvironment discovery** — verify the APT finds `@McpDomain` interfaces from the current compilation unit (not just from Jandex dependency indexes)

### Migration Integration Tests (#297)

For each migrated endpoint:
1. **API contract parity** — REST test exercising generated endpoint with expected verbs, paths, status codes
2. **Authorization** — verify `@RolesAllowed` enforcement on mutations, admin-or-self guard on ACL queries
3. **Validation** — verify 400 responses for missing required params (ACL, preferences)
4. **GraphQL generation** — verify `@Query`/`@Mutation` methods callable
5. **MCP discovery** — verify `GraphQLModelScanner` discovers all new domains

## Files Changed

### platform-api (new annotation)

| File | Action |
|------|--------|
| `platform-api/.../mcp/RestPath.java` | New |

### graphql-generator (enhancements)

| File | Action |
|------|--------|
| `graphql-generator/.../GraphQLResolverProcessor.java` | Modified — @RestPath support, simple type detection (enum + fromString/valueOf), IndexView threading, dual-scan SPI discovery (Jandex + RoundEnvironment) |
| `graphql-generator/.../GraphQLResolverProcessorTest.java` | Modified — new tests for @RestPath, simple type detection, and RoundEnvironment discovery |

### acl-admin (migration)

| File | Action |
|------|--------|
| `acl-admin/.../AclApi.java` | New — `@McpDomain("acl")` SPI |
| `acl-admin/.../AclService.java` | New — `@ApplicationScoped` impl with auth |
| `acl-admin/.../AclResource.java` | Deleted |
| `acl-admin/pom.xml` | Modified — add graphql-generator APT |

### preferences-editor (migration)

| File | Action |
|------|--------|
| `preferences-editor/.../PreferenceApi.java` | New — `@McpDomain("preferences")` SPI |
| `preferences-editor/.../PreferenceService.java` | New — `@ApplicationScoped` impl with validation |
| `preferences-editor/.../PreferenceSchemaApi.java` | New — `@McpDomain("preference-schemas")` SPI (GraphQL/MCP only) |
| `preferences-editor/.../PreferenceSchemaService.java` | New — `@ApplicationScoped` impl (no ETag, delegates to registry) |
| `preferences-editor/.../PreferenceResource.java` | Deleted |
| `preferences-editor/.../PreferenceSchemaResource.java` | Modified — add `@McpDomain` for skip detection |
| `preferences-editor/pom.xml` | Modified — add graphql-generator APT |

### notifications (migration)

| File | Action |
|------|--------|
| `notifications/.../NotificationApi.java` | New — `@McpDomain("notifications")` SPI |
| `notifications/.../NotificationService.java` | New — `@ApplicationScoped` impl |
| `notifications/.../NotificationSuppressionApi.java` | New — `@McpDomain("notification-suppression")` SPI |
| `notifications/.../NotificationSuppressionService.java` | New — `@ApplicationScoped` impl |
| `notifications/.../NotificationResource.java` | Deleted |
| `notifications/.../SuppressionResource.java` | Deleted |
| `notifications/pom.xml` | Modified — add graphql-generator APT (may already be present from batch 1) |

## Known Limitations

1. **PreferenceSchemaResource stays hand-written** — ETag conditional GET requires `@Context Request` which is a JAX-RS runtime concept. GraphQL/MCP generation works via separate `PreferenceSchemaApi` SPI. The hand-written REST endpoint stays at `/preferences/schema` (no `/api/` prefix), while generated GraphQL/MCP use the `preference-schemas` domain.
2. **Response status changes** — `addMute`/`activateSnooze` return 200 (was 201), `removeMute`/`cancelSnooze` throw NotFoundException (was boolean→404). Acceptable for pre-release.
3. **Path and verb changes** — all generated endpoints use `/api/{domain}/...` prefix. Pre-release, no external consumers. Specific changes:
   - **Prefix addition:** `/acl/grants` → `/api/acl/grants`
   - **Segment reordering:** `/notifications/{id}/read` → `/api/notifications/read/{id}` (action-first URL ordering — `@RestPath` + `@PathParam` always appends the path param after the rest path)
   - **Domain regrouping:** `/notifications/mute` → `/api/notification-suppression/mute` (D3 domain split)
   - **Path renaming:** `/preferences` (root DELETE) → `/api/preferences/delete`, `/preferences/by-namespace` → `/api/preferences/delete-namespace`
   - **Verb changes:** `revokeBatch`/`removeDenyBatch` changed from DELETE to POST (DELETE with request body is non-standard HTTP); `set` explicitly annotated `@RestMethod(HttpMethod.PUT)` to preserve PUT verb
4. **`fromString`/`valueOf` detection scope** — D2 detects enums, `fromString(String)`, and `valueOf(String)` via Jandex. Types with other JAX-RS conversion mechanisms (single-String constructors, `ParamConverter` implementations) are not detected — they would need to be added to the static `SIMPLE_TYPES` set manually or accepted as `String` in the SPI.
5. **D2 is not a batch 2 blocker** — no batch 2 endpoint has an enum parameter on a body-accepting HTTP verb (POST/PUT/PATCH). Enum params only appear on GET and DELETE methods where all non-`@PathParam` params are already classified as `@QueryParam` regardless of `isSimpleType()`. D2 is a correctness enhancement for future-proofing, not a migration prerequisite.

## References

- `GraphQLResolverProcessor.java` — existing APT (lines 366-452: generateRestMethod, lines 603-614: isSimpleType)
- `AclResource.java` — 12 endpoints with nested paths (lines 42-171)
- `NotificationResource.java` — 5 endpoints, PATCH verbs, Optional returns
- `SuppressionResource.java` — 6 endpoints, boolean→404 patterns, 201 status
- `PreferenceResource.java` — 5 endpoints, schema validation, scope parsing
- `PreferenceSchemaResource.java` — ETag conditional GET
- `CallbackApi.java` — batch 1 reference SPI (established pattern)
- #295 design spec — generator architecture, migration pattern, decisions D1-D10
- GE-20260612-4f9a47 — JAX-RS on SPI interface causes Quarkus registration conflict (why platform-specific annotations)
