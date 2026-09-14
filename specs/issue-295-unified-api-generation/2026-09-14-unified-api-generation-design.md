# Unified API Generation — Design Spec

**Issue:** casehubio/platform#295
**Date:** 2026-09-14
**Status:** Draft

## Summary

Harden the `graphql-generator` APT to produce production-quality JAX-RS REST resources alongside GraphQL resolvers from `@McpDomain` + `@PlatformQuery`/`@PlatformMutation` SPI interfaces. Then migrate platform's hand-written REST endpoints to the generated approach. One SPI interface → three API surfaces (REST, GraphQL, MCP), zero hand-written endpoints, zero drift.

Scope: child issue 1 (generator hardening) + child issue 2 (platform adoption). Cross-repo migration (work, ledger, engine) is deferred to a slot.

## Architecture

### Current State (PoC on main, commit d4af5260)

`GraphQLResolverProcessor` is a `javax.annotation.processing.AbstractProcessor` that:

1. Loads Jandex indexes from classpath `META-INF/jandex.idx` files
2. Scans for interfaces annotated with `@McpDomain`
3. Collects methods annotated with `@PlatformQuery` or `@PlatformMutation`
4. Scans for hand-written `@GraphQLApi` + `@McpDomain` classes to detect methods to skip
5. Generates per-domain:
   - `Generated{Domain}Resolver` — `@GraphQLApi @ApplicationScoped` with `@Query`/`@Mutation` methods
   - `Generated{Domain}Resource` — `@Path("/api/{domain}") @ApplicationScoped` with `@GET`/`@POST` methods

Generated classes delegate every call to the CDI-injected SPI implementation.

### Target State

The same pipeline, enhanced with:

- REST-specific annotations (`@RestMethod`, `@PathParam`) read from SPI interfaces
- Kebab-case path segments
- Proper HTTP verb mapping (GET/POST/PUT/DELETE/PATCH)
- Convention-based parameter binding (path, query, body)
- `@RunOnVirtualThread`, `@Consumes`, `@Produces` on all generated REST resources
- Independent hand-written REST skip detection (decoupled from GraphQL skip)
- Response wrapping (void→204, Optional→404)

```
@McpDomain SPI interface
    │
    ├── GraphQLResolverProcessor (APT, compile time)
    │     ├── scanHandWrittenGraphQLMethods()     ← existing
    │     ├── scanHandWrittenRestMethods()         ← new
    │     ├── generateResolverSource()             ← existing (GraphQL)
    │     └── generateRestResourceSource()         ← enhanced (REST)
    │
    └── GraphQLModelScanner (CDI, runtime)         ← unchanged (MCP)
```

### Authorization Model

Security is enforced at the service layer, not the generated endpoint layer. The `@ApplicationScoped` implementation of the `@McpDomain` interface carries `@RolesAllowed` and injects `CurrentPrincipal` for tenant-scoped authorization. Generated REST and GraphQL endpoints are pure delegation — CDI interceptors fire on the service bean. This is the established pattern from issue #291 (`LlmConfigService`).

## New Annotations in platform-api

Three new types in `io.casehub.platform.api.mcp`. All zero-dependency, pure Java.

### HttpMethod (D8)

```java
package io.casehub.platform.api.mcp;

public enum HttpMethod {
    GET, POST, PUT, DELETE, PATCH
}
```

### RestMethod (D1)

```java
package io.casehub.platform.api.mcp;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface RestMethod {
    HttpMethod value();
}
```

Applied alongside `@PlatformMutation` or `@PlatformQuery` to override the default HTTP verb. Without `@RestMethod`: `@PlatformQuery` → GET, `@PlatformMutation` → POST.

```java
@PlatformMutation("Remove a callback registration")
@RestMethod(HttpMethod.DELETE)
void deregister(@PathParam String id);
```

### PathParam (D3)

```java
package io.casehub.platform.api.mcp;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target(ElementType.PARAMETER)
@Retention(RetentionPolicy.RUNTIME)
public @interface PathParam {
    String value() default "";
}
```

When `value()` is empty, the generator uses the parameter name. The generator emits `jakarta.ws.rs.PathParam` in generated code and adds `/{paramName}` to the method's `@Path`.

## Generator Enhancements

### 4.1 Kebab-case Path Segments (D6)

Add a `toKebabCase(String camelCase)` utility to the processor. Algorithm:

- Insert hyphen before each uppercase letter that follows a lowercase letter or digit
- Collapse consecutive uppercase letters into a single word (treat the last uppercase before a lowercase as the start of a new word): `HTTPMethod` → `http-method`, `listHTTPMethods` → `list-http-methods`
- Lowercase the result

Generated paths: `@Path("/method-name")` instead of `@Path("/methodName")`.

Domain paths remain as declared in `@McpDomain("llm-config")` — the domain value is used verbatim in `@Path("/api/llm-config")`.

### 4.1b Domain Name to Class Name — toPascalCase

Kebab-case domain names (`"delivery-channels"`, `"notification-preferences"`) must be converted to valid Java identifiers for generated class names. Add `toPascalCase(String kebab)`: split on hyphens, capitalize each segment, join. Examples:

- `"delivery-channels"` → `DeliveryChannels` → `GeneratedDeliveryChannelsResolver`
- `"notification-preferences"` → `NotificationPreferences` → `GeneratedNotificationPreferencesResource`
- `"digest"` → `Digest` (no change — no hyphens)

The existing `capitalize()` is insufficient — it uppercases only the first character and produces invalid identifiers like `Delivery-channels`.

### 4.2 HTTP Verb Mapping (D1)

The REST generator reads `@RestMethod` from the SPI method via Jandex. If present, use its `HttpMethod` value. If absent, fall back to the default: `@PlatformQuery` → `@GET`, `@PlatformMutation` → `@POST`.

New Jandex DotName constants:

```java
private static final DotName REST_METHOD = DotName.createSimple("io.casehub.platform.api.mcp.RestMethod");
private static final DotName HTTP_METHOD = DotName.createSimple("io.casehub.platform.api.mcp.HttpMethod");
```

Mapping from `HttpMethod` enum to JAX-RS annotation import:

| HttpMethod | Import |
|-----------|--------|
| GET | `jakarta.ws.rs.GET` |
| POST | `jakarta.ws.rs.POST` |
| PUT | `jakarta.ws.rs.PUT` |
| DELETE | `jakarta.ws.rs.DELETE` |
| PATCH | `jakarta.ws.rs.PATCH` |

### 4.3 Parameter Binding (D2)

Convention-based classification of each SPI method parameter:

1. **@PathParam annotated** → `jakarta.ws.rs.PathParam` in generated code. Appends `/{paramName}` to the method's `@Path` segment.
2. **Complex type on a body-accepting method (POST/PUT/PATCH)** → request body (no annotation, JAX-RS convention). At most one complex body parameter per method.
3. **Everything else** → `@QueryParam("paramName")`.

**"Complex" type definition:** Any type that is NOT one of: `String`, a Java primitive, a primitive wrapper (`Integer`, `Long`, `Boolean`, etc.), an enum, a `java.time.*` type, or `java.util.UUID`.

**@Valid on body parameters:** When a complex parameter is classified as a request body, the generator also adds `jakarta.validation.Valid` to the parameter. This ensures Jakarta Bean Validation annotations on request DTOs (`@NotNull`, `@Size`, etc.) are enforced at the REST layer.

**Multiple complex params error (D2):** If a POST/PUT/PATCH method has more than one complex parameter (after excluding `@PathParam`-annotated params), the annotation processor emits a compile error:

```
ERROR: Method 'transfer' on domain 'acl' has 2 complex parameters (Source, Destination).
       Wrap them in a single request DTO or annotate path parameters with @PathParam.
```

### 4.4 @Consumes on Body-Accepting Methods (D9)

When a generated REST method has a request body parameter (per §4.3), generate `@Consumes(MediaType.APPLICATION_JSON)` on that method.

Required import: `jakarta.ws.rs.Consumes`.

### 4.5 @RunOnVirtualThread (D4)

All generated REST resource classes include `@RunOnVirtualThread` at class level, unconditionally.

Required import: `io.smallrye.common.annotation.RunOnVirtualThread`.

### 4.6 Hand-Written REST Skip Detection (D5)

Add a new `scanHandWrittenRestMethods(IndexView index)` method, independent from the existing `scanHandWrittenMethods()` (which scans GraphQL). The current code uses a single `handWrittenMethods` set for both GraphQL and REST — this must be split into two sets.

New Jandex DotName constants for REST annotations:

```java
private static final DotName PATH       = DotName.createSimple("jakarta.ws.rs.Path");
private static final DotName JAX_GET    = DotName.createSimple("jakarta.ws.rs.GET");
private static final DotName JAX_POST   = DotName.createSimple("jakarta.ws.rs.POST");
private static final DotName JAX_PUT    = DotName.createSimple("jakarta.ws.rs.PUT");
private static final DotName JAX_DELETE = DotName.createSimple("jakarta.ws.rs.DELETE");
private static final DotName JAX_PATCH  = DotName.createSimple("jakarta.ws.rs.PATCH");
```

Scan logic:

1. Find all classes with both `@Path` and `@McpDomain`
2. Extract the domain name from `@McpDomain`
3. For each method with any JAX-RS verb annotation (`@GET`, `@POST`, `@PUT`, `@DELETE`, `@PATCH`), add `domain:methodName` to the REST skip set
4. Pass the REST skip set to `generateRestResourceSource()` (separate from the GraphQL skip set passed to `generateResolverSource()`)

### 4.7 Response Wrapping (D10)

The current generator returns the raw SPI return type. Enhanced behavior based on the SPI method's return type:

| SPI Return Type | Generated REST Method Return | Generated Body |
|----------------|------------------------------|----------------|
| `void` | `Response` | `spi.method(args); return Response.noContent().build();` |
| `Optional<T>` | `Response` | `return spi.method(args).map(v -> Response.ok(v).build()).orElse(Response.status(404).build());` |
| `T` (any other) | `Response` | `return Response.ok(spi.method(args)).build();` |

Required imports: `jakarta.ws.rs.core.Response` (always), `java.util.Optional` (for Optional detection).

The GraphQL generator is unchanged — it returns raw types. GraphQL has its own null/error semantics via the SmallRye framework.

## Migration Strategy (D7)

Full platform coverage, batched by complexity. Every REST endpoint gets an `@McpDomain` SPI so the platform is fully automatable via MCP and scriptable for scenario tests.

### Batch 1 — Simple Delegation

Endpoints where the REST resource is nearly pure passthrough to an existing SPI. Migration pattern: create `@McpDomain` interface, point it at the existing SPI bean, delete the hand-written resource.

| Endpoint | Module | Current Verbs | Migration Notes |
|----------|--------|--------------|-----------------|
| `DeliveryChannelResource` | notifications | GET | Trivial — single `listChannels()` delegates to `DeliveryChannelRegistry.discover()` |
| `DigestStatusResource` | notifications | GET | `status()` uses `CurrentPrincipal` — logic moves to service impl |
| `CallbackRegistrationResource` | callback | POST, PUT, DELETE | Uses `@PathParam` for heartbeat/deregister, class-level `@RolesAllowed` |
| `NotificationPreferenceResource` | notifications | GET, PUT | `update()` has validator call — logic moves to service impl |

For each endpoint:
1. Create an `@McpDomain` SPI interface (e.g., `CallbackApi`) with `@PlatformQuery`/`@PlatformMutation`/`@RestMethod`/`@PathParam` annotations
2. Create an `@ApplicationScoped` service implementation that injects the underlying SPI (`CallbackRegistry`, `CurrentPrincipal`, etc.) and carries any authorization annotations
3. Add the `graphql-generator` as an `<annotationProcessorPaths>` entry in the module's `pom.xml`
4. Verify generated REST matches the hand-written API contract (same paths, verbs, status codes)
5. Delete the hand-written resource class

### Batch 2 — Complex Refactoring (Deferred)

Endpoints with significant business logic in the REST layer. Requires extracting logic into `@McpDomain` service implementations.

| Endpoint | Module | Complexity Driver |
|----------|--------|-------------------|
| `AclResource` | acl-admin | Nested paths (`/grants`, `/denies`), per-method `@RolesAllowed`, admin-or-self guard, DTO mapping, batch endpoints |
| `PreferenceResource` | preferences-editor | Schema validation, scope path parsing, multiple `@DELETE` endpoints |
| `NotificationResource` | notifications | `@PATCH` verbs, `Optional→404`, `CurrentPrincipal`-derived queries |
| `SuppressionResource` | notifications | Mixed CRUD, `@PathParam`, validation, `CurrentPrincipal` |

These require the generator enhancements from this branch to be complete and validated by batch 1 before starting.

### SPI Interface Placement

`@McpDomain` SPI interfaces for migration live in their respective modules (e.g., `CallbackApi` in `callback/`, `DeliveryChannelApi` in `notifications/`), not in `platform-api`. These are generation sources for REST/GraphQL/MCP endpoints, not cross-module contracts. The service implementations inject module-internal dependencies (`PreferenceValidator`, `CurrentPrincipal`) that don't belong in `platform-api`.

This differs from `ModelRegistryApi` (in `platform-api`) which defines a cross-module query contract. `LlmConfigApi` follows the same module-local pattern — it lives in `llm-config/`, not `platform-api`.

### Domain Naming Convention

`@McpDomain` values use kebab-case to match the generated REST path prefix:

| SPI Interface | @McpDomain Value | REST Base Path |
|--------------|------------------|----------------|
| `CallbackApi` | `"callbacks"` | `/api/callbacks` |
| `DeliveryChannelApi` | `"delivery-channels"` | `/api/delivery-channels` |
| `DigestApi` | `"digest"` | `/api/digest` |
| `NotificationPreferenceApi` | `"notification-preferences"` | `/api/notification-preferences` |

## Path Changes (Pre-release)

Generated endpoints use `/api/{domain}/{method-name}` paths. Hand-written endpoints use module-specific prefixes (`/casehub/callbacks`, `/notifications/channels`). Migration changes all URL paths. This is acceptable for pre-release — there are no external consumers. Internal callers (tests, `callback-client/`) are updated as part of each batch 1 migration.

## Migration Behavioral Notes

- **NotificationPreferenceResource.get()**: The current endpoint returns default preferences (empty map, `Instant.EPOCH`) when none exist — not 404. The `NotificationPreferenceApi.get()` SPI method must return `NotificationPreferences` (not `Optional`), with the default-if-absent logic in the service impl. This preserves current behavior.
- **CallbackRegistrationResource.heartbeat()**: The current endpoint composes `findById()` + conditional 404 + `heartbeat()`. The `CallbackService.heartbeat()` impl absorbs this logic — throws `NotFoundException` when callback doesn't exist, which JAX-RS maps to 404.

## Known Limitations

1. **No nested resource paths.** The generator produces flat `@Path("/method-name")` segments under the domain prefix. Hierarchical URL structures (like `/grants/batch`) require hand-written resources or future generator enhancement. Batch 2 endpoints may hit this limitation.
2. **No security annotation generation.** The generator does not produce `@RolesAllowed` or other security annotations. Authorization is enforced at the service layer via CDI interceptors. This is intentional (see §Authorization Model) but means generated resources are open to any authenticated caller — the service impl must enforce access control.
3. **Single request body per method.** Methods with multiple complex parameters on a body-accepting verb cause a compile error (D2). SPI authors must consolidate into a single request DTO.
4. **No response header or cookie support.** Generated methods return `Response` with body only. Custom headers, cookies, or cache-control require hand-written overrides.
5. **GraphQL and REST paths may diverge.** GraphQL uses the Java method name directly; REST uses kebab-case. This is intentional (each transport follows its own convention) but callers must be aware.

## Test Strategy

### Generator Unit Tests

Extend `GraphQLResolverProcessorTest` with compile-testing:

1. **Kebab-case conversion** — unit test `toKebabCase()`: `markAllRead` → `mark-all-read`, `HTTPMethod` → `http-method`, `vendors` → `vendors`, `listHTTPMethods` → `list-http-methods`
2. **@RestMethod verb mapping** — compile a test SPI with `@RestMethod(HttpMethod.DELETE)`, verify generated source contains `@DELETE`
3. **@PathParam binding** — compile a test SPI with `@PathParam String id`, verify generated `@Path("/{id}")` and `@jakarta.ws.rs.PathParam("id")`
4. **Body parameter detection** — compile a test SPI with a complex object param on POST, verify no `@QueryParam`, verify `@Consumes(MediaType.APPLICATION_JSON)`
5. **Multiple complex params error** — compile a test SPI with two complex params on POST, verify compilation fails with expected error message
6. **void→204** — verify generated method wraps in `Response.noContent()`
7. **Optional→404** — verify generated method wraps in `Optional.map(...).orElse(Response.status(404)...)`
8. **REST skip detection** — compile with a hand-written `@Path @McpDomain` class, verify skipped methods are not generated
9. **REST and GraphQL skip independence** — hand-written GraphQL method should not suppress REST generation for the same method, and vice versa
10. **@RunOnVirtualThread** — verify class-level annotation on all generated REST resources
11. **@Produces(APPLICATION_JSON)** — verify class-level annotation on all generated REST resources

### Migration Integration Tests

For each migrated endpoint (batch 1):

1. **API contract parity** — REST test exercising the generated endpoint with the same HTTP verb, path, and expected status codes as the deleted hand-written endpoint
2. **GraphQL generation** — verify `@Query`/`@Mutation` methods are generated and callable
3. **MCP discovery** — verify `GraphQLModelScanner` discovers the domain's operations

## Files Changed

### platform-api (new annotations)

| File | Action |
|------|--------|
| `platform-api/.../mcp/HttpMethod.java` | New — enum (GET, POST, PUT, DELETE, PATCH) |
| `platform-api/.../mcp/RestMethod.java` | New — annotation for HTTP verb override |
| `platform-api/.../mcp/PathParam.java` | New — annotation for path parameter binding |

### graphql-generator (hardening)

| File | Action |
|------|--------|
| `graphql-generator/.../GraphQLResolverProcessor.java` | Modified — all enhancements (§4.1–4.7) |
| `graphql-generator/.../GraphQLResolverProcessorTest.java` | Modified — expanded test suite |

### Batch 1 migration — callbacks

| File | Action |
|------|--------|
| `callback/.../CallbackApi.java` | New — `@McpDomain("callbacks")` SPI interface |
| `callback/.../CallbackService.java` | New — `@ApplicationScoped` impl with `@RolesAllowed` |
| `callback/.../CallbackRegistrationResource.java` | Deleted — replaced by generated resource |
| `callback/.../CallbackRegistrationResourceTest.java` | Modified — points to generated endpoint |
| `callback/pom.xml` | Modified — add `graphql-generator` to annotation processor paths |

### Batch 1 migration — delivery channels

| File | Action |
|------|--------|
| `notifications/.../DeliveryChannelApi.java` | New — `@McpDomain("delivery-channels")` SPI interface |
| `notifications/.../DeliveryChannelService.java` | New — `@ApplicationScoped` impl (trivial delegation) |
| `notifications/.../DeliveryChannelResource.java` | Deleted — replaced by generated resource |

### Batch 1 migration — digest status

| File | Action |
|------|--------|
| `notifications/.../DigestApi.java` | New — `@McpDomain("digest")` SPI interface |
| `notifications/.../DigestService.java` | New — `@ApplicationScoped` impl with `CurrentPrincipal` |
| `notifications/.../DigestStatusResource.java` | Deleted — replaced by generated resource |

### Batch 1 migration — notification preferences

| File | Action |
|------|--------|
| `notifications/.../NotificationPreferenceApi.java` | New — `@McpDomain("notification-preferences")` SPI interface |
| `notifications/.../NotificationPreferenceService.java` | New — `@ApplicationScoped` impl with validator |
| `notifications/.../NotificationPreferenceResource.java` | Deleted — replaced by generated resource |
| `notifications/.../NotificationPreferenceResourceTest.java` | Modified — points to generated endpoint |

## References

- `io.casehub.platform.graphql.generator.GraphQLResolverProcessor` — existing APT (PoC, commit d4af5260)
- `io.casehub.platform.api.mcp.McpDomain` — domain grouping annotation
- `io.casehub.platform.api.mcp.PlatformQuery` — query method annotation
- `io.casehub.platform.api.mcp.PlatformMutation` — mutation method annotation
- `io.casehub.platform.mcp.GraphQLModelScanner` — runtime MCP tool discovery
- `io.casehub.platform.llm.config.LlmConfigApi` — reference `@McpDomain` SPI (issue #291)
- `io.casehub.platform.llm.config.LlmConfigService` — reference service-layer auth pattern
- casehubio/platform#291 — LLM config wizard (PoC origin, closed)
- casehubio/platform#295 — this epic
- Issue #291 design spec (decisions D6: API surface pattern)
- Review findings: R1-01 (separation of concerns), R1-03 (@Consumes), R1-07 (GET symmetry), R1-08 (Response wrapping)
