# Design: @McpDomain on Classes + Spring Drift Elimination

**Issue:** casehubio/parent#489 (DX audit), #490, #491, #492
**Branch:** issue-489-dx-audit
**Date:** 2026-09-16

## Problem

CaseHub's `@McpDomain` code generation requires a separate SPI interface even for simple single-action domains. For the simplest MCP domain, developers must create an interface (with annotations) plus an implementation class — two files where one would suffice. Additionally, 6 hand-coded Spring REST controllers in `platform-spring` duplicate Quarkus logic with no automated drift detection.

## Design

### 1. Enable @McpDomain on Implementation Classes

Three generator touch points, all in the platform repo:

#### 1a. GraphQLResolverProcessor (graphql-generator/)

The APT processor has two scanning paths, both filtering interfaces only:

- `scanAnnotatedInterfaces()` (line 264): `if (!isInterface(classInfo.flags())) {continue;}`
- `scanRoundEnvironment()` (line 470): `if (element.getKind() != INTERFACE) {continue;}`

**Changes:**
- Rename `scanAnnotatedInterfaces()` → `scanAnnotatedTypes()`
- Remove the `isInterface()` filter — process any `@McpDomain`-annotated class or interface
- In `scanRoundEnvironment()`, accept both `ElementKind.INTERFACE` and `ElementKind.CLASS`
- Generated code is unchanged — it already uses `op.declaringClassFqcn()` for injection and `op.declaringClassSimple()` for field naming

#### 1b. McpDomainJandexScanner (generator-common/)

The shared Jandex scanner used by Spring generators filters interfaces only at line 42:

```java
if (!java.lang.reflect.Modifier.isInterface(classInfo.flags())) { continue; }
```

**Changes:**
- Remove the interface filter
- Rename `DomainScanResult` fields: `spiInterfaceFqcn` → `declaringTypeFqcn`, `spiInterfaceSimple` → `declaringTypeSimple`
- Update factory methods: `of(domainName, declaringTypeFqcn, declaringTypeSimple, basePath)`
- Update all consumers of these fields in `graphql-spring-generator`

#### 1c. Duplicate Domain Prevention

When `@McpDomain("foo")` appears on both an interface and a class implementing it, the generator must not produce duplicate output. The existing deduplication mechanism handles this:

- APT processor: `allDomains.putAll(jandexDomains)` — Jandex domains take precedence over RoundEnv
- Within each scan: `domains.computeIfAbsent(domain, ...)` — first source for a domain name wins
- Interface-based domains (from dependency Jandex) take precedence over class-based domains (from RoundEnv)

No change needed — the existing deduplication is correct for the new case.

### 2. SpringModelScanner — Class Scanning Parity

`SpringModelScanner` in `mcp-spring/` currently only scans bean interfaces:

```java
for (Class<?> iface : beanType.getInterfaces()) {
    McpDomain mcpDomain = iface.getAnnotation(McpDomain.class);
```

The Quarkus equivalent (`GraphQLModelScanner`) does two passes: class-first, then interface-fallback.

**Changes:** Add class-first scan before the interface loop:

1. For each bean, check `beanType` itself (and supertypes via `findMcpDomain()`) for `@McpDomain`
2. If found: scan `beanType.getDeclaredMethods()` for `@PlatformQuery`/`@PlatformMutation`, register the domain
3. Then: iterate `beanType.getInterfaces()` for `@McpDomain` — skip domains already registered by the class-first pass

This mirrors `GraphQLModelScanner`'s scan() structure and ensures class-based `@McpDomain` works in Spring runtime MCP scanning.

### 3. Core POJO Migration — SubscriptionService + EventTypeService

Two core POJOs in `subscriptions-core/` receive `@McpDomain`:

**SubscriptionService:**
```java
@McpDomain("subscriptions")
public class SubscriptionService {

    @PlatformMutation("Create a subscription")
    public Subscription create(SubscriptionInput input) { ... }

    @PlatformQuery("List subscriptions")
    public SubscriptionPage list(Boolean enabled, SubscriptionScope scope,
                                  String cursor, int limit) { ... }

    @PlatformQuery("Get subscription by ID")
    public Optional<Subscription> getById(@PathParam String id) { ... }

    @PlatformMutation("Update a subscription")
    @RestMethod(HttpMethod.PATCH)
    public Optional<Subscription> update(@PathParam String id,
                                          SubscriptionUpdate update) { ... }

    @PlatformMutation("Delete a subscription")
    @RestMethod(HttpMethod.DELETE)
    public boolean delete(@PathParam String id) { ... }

    @PlatformMutation("Enable a subscription")
    @RestMethod(HttpMethod.PATCH)
    @RestPath("/{id}/enable")
    public Optional<Subscription> enable(@PathParam String id) { ... }

    @PlatformMutation("Disable a subscription")
    @RestMethod(HttpMethod.PATCH)
    @RestPath("/{id}/disable")
    public Optional<Subscription> disable(@PathParam String id) { ... }
}
```

**EventTypeService:**
```java
@McpDomain("subscription-event-types")
public class EventTypeService {

    @PlatformQuery("List available subscription event types")
    public Set<EventTypeDescriptor> listEventTypes() { ... }
}
```

**Consequences:**
- APT processor generates `GeneratedSubscriptionsResolver` + `GeneratedSubscriptionsResource` (Quarkus)
- `graphql-spring-generator` generates Spring GraphQL controller + REST controller
- Hand-written Quarkus `@Path` resource in `subscriptions/` → deleted
- Hand-written `SubscriptionRestController` in `platform-spring/` → deleted
- Hand-written `EventTypeRestController` in `platform-spring/` → deleted

**Exception handling:** The current `SubscriptionRestController` has inline try/catch for `SecurityException` → 403 and `IllegalArgumentException` → 400. Per the unified API generation design (issue-295 D10), exceptions are handled by ExceptionMapper beans (Quarkus) / `@ControllerAdvice` (Spring), not the controller. If platform-wide exception mappers don't exist yet, they are created as part of this work.

### 4. rest-spring-generator for Transport-Specific Endpoints

Three Quarkus JAX-RS resources have HTTP-transport concerns (raw headers, special content types) that don't fit `@McpDomain`. The `rest-spring-generator` translates these to Spring:

| Quarkus Resource | Module | Spring Output |
|-----------------|--------|---------------|
| Webhook resource | `streams-webhook/` | `WebhookRestController` |
| CallbackDispatch resource | `callback-client/` | `CallbackDispatchRestController` |
| EngagementCallback resource | `notification-dispatch/` | `EngagementCallbackRestController` |

**Changes to `platform-spring/pom.xml`:**

Add `rest-spring-generator` plugin execution:
```xml
<plugin>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-rest-spring-generator</artifactId>
    <version>${project.version}</version>
    <executions>
        <execution>
            <id>generate</id>
            <goals><goal>generate</goal></goals>
            <configuration>
                <quarkusModules>
                    <quarkusModule>${project.basedir}/../streams-webhook</quarkusModule>
                    <quarkusModule>${project.basedir}/../callback-client</quarkusModule>
                    <quarkusModule>${project.basedir}/../notification-dispatch</quarkusModule>
                </quarkusModules>
            </configuration>
        </execution>
        <execution>
            <id>verify-rest-drift</id>
            <goals><goal>verify</goal></goals>
            <phase>verify</phase>
            <configuration>
                <quarkusModules>
                    <quarkusModule>${project.basedir}/../streams-webhook</quarkusModule>
                    <quarkusModule>${project.basedir}/../callback-client</quarkusModule>
                    <quarkusModule>${project.basedir}/../notification-dispatch</quarkusModule>
                </quarkusModules>
            </configuration>
        </execution>
    </executions>
</plugin>
```

Then delete the 3 hand-coded Spring controllers.

**Exception:** `PreferenceSchemaRestController` stays hand-coded — its ETag conditional GET logic (`WebRequest.checkNotModified()`) cannot be expressed through JAX-RS annotations.

### 5. Build Config & Cleanup

**graphql-spring-generator config:** Add `subscriptions-core` to the scanned modules:
```xml
<quarkusModules>
    <quarkusModule>${project.basedir}/../platform-api</quarkusModule>
    <quarkusModule>${project.basedir}/../preferences-editor-core</quarkusModule>
    <quarkusModule>${project.basedir}/../callback-api</quarkusModule>
    <quarkusModule>${project.basedir}/../llm-config-core</quarkusModule>
    <quarkusModule>${project.basedir}/../subscriptions-core</quarkusModule>
</quarkusModules>
```

**RestControllersAutoConfiguration cleanup:** Remove bean definitions for services now produced by generators. Specifically: `SubscriptionService`, `EventTypeService`, `CallbackDispatcher`. If the `spring-generator` already produces these from Quarkus CDI wiring, the manual definitions are duplicates.

**PlatformDefaultsManualConfig:** Stays — out of scope for this work. MockCurrentPrincipal / MockPreferenceProvider registration uses `@Value` config property injection.

### 6. Ceremony Gap Measurement (Issue #490 Deliverable)

Before/after comparison for a minimal MCP domain:

| Aspect | Before (interface required) | After (@McpDomain on class) | Embabel |
|--------|:-:|:-:|:-:|
| Source files | 2 (interface + impl) | **1** | 1 |
| Class-level annotations | 2 | 2 (`@McpDomain` + `@ApplicationScoped`) | 1 (`@Agent`) |
| Per-method annotations | 1 (`@PlatformQuery`/`@PlatformMutation`) | 1 | 2-3 (`@Action` + `@AchievesGoal` + `@Export`) |
| pom.xml config | annotationProcessorPaths | annotationProcessorPaths | none (auto-config) |
| Generated outputs | 2 (GraphQL + REST, Quarkus only) | **4** (GraphQL + REST × Quarkus + Spring) | 0 (runtime) |
| MCP tools | runtime registered | runtime registered | runtime |

**Remaining ceremony vs Embabel:**
- `annotationProcessorPaths` in pom.xml (inherited from parent BOM — one-time setup per module)
- `@ApplicationScoped` (CDI scope — Embabel manages lifecycle differently)
- CaseHub has **fewer** per-method annotations than Embabel

### 7. Spring Drift Scorecard

After this work:

| Layer | Files | Status |
|-------|:-----:|--------|
| Hand-coded Spring REST controllers | **1** (ETag) | Down from 6 |
| Generated Spring REST controllers | **5** | From @McpDomain (2) + rest-spring-generator (3) |
| SpringModelScanner | 1 | Fixed for class+interface parity |
| @Bean auto-configuration | Generated + verified | Unchanged |
| spring-generator drift detection | Active | Unchanged |
| graphql-spring-generator drift detection | Active | Unchanged |
| rest-spring-generator drift detection | **New** | Added for transport controllers |

## Testing Strategy

- **Generator tests:** Add class-based domain test cases alongside existing interface-based tests in `GraphQLResolverProcessorTest`, `McpDomainJandexScanner` tests, and `graphql-spring-generator` tests
- **SpringModelScanner test:** Add test case with `@McpDomain` on a bean class (no interface)
- **Integration:** Build platform with `mvn install` — APT generates from @McpDomain classes, Spring generators produce output, verify goals catch any gaps
- **Subscription endpoints:** Verify generated REST endpoints match the current hand-written API contract (paths, HTTP methods, status codes)

## Out of Scope

- ETag/conditional-GET annotation for `PreferenceSchemaRestController`
- `PlatformDefaultsManualConfig` generation via `spring-generator`
- Embabel-style `withToolObject()` (reflection-based tool discovery without annotations)
- `@Agent` convenience annotation (Embabel parity for agent definition)
- Removing `@PlatformQuery`/`@PlatformMutation` annotation requirement (operation type inference)

## References

- [issue-295 decisions.md](/Users/mdproctor/claude/casehub/slots/198/wsp-casehub-platform/specs/issue-295-unified-api-generation/decisions.md) — REST generation design (D1-D10)
- [issue-469 decisions.md](/Users/mdproctor/claude/casehub/slots/198/wsp-casehub-platform/specs/issue-469-dual-framework-core-extraction/decisions.md) — core extraction design (D1-D8)
- [issue-474 decisions.md](/Users/mdproctor/claude/casehub/slots/198/wsp-casehub-platform/specs/issue-474-spring-boot-generators/decisions.md) — Spring generator design (D1-D9)
- `graphql-generator/GraphQLResolverProcessor.java` — APT processor (interface filter at lines 264, 470)
- `generator-common/McpDomainJandexScanner.java` — shared scanner (interface filter at line 42)
- `generator-common/DomainScanResult.java` — field naming (`spiInterface*` → `declaringType*`)
- `mcp-spring/SpringModelScanner.java` — interface-only scanning (line 59)
- `mcp/GraphQLModelScanner.java` — two-pass class+interface scanning (lines 55-102)
- `platform-spring/pom.xml` — current generator config (spring-generator + graphql-spring-generator only)
