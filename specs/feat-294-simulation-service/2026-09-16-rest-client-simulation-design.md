# REST Client Simulation — Design Spec

**Issue:** casehubio/platform#319
**Branch:** issue-294-simulation-service
**Decisions:** D32–D37

## Problem

External HTTP APIs (`@RegisterRestClient` interfaces) may be unavailable during
scenario execution — the service is down, rate-limited, or the environment lacks
credentials. The simulation framework handles SPI interception (Path A via
`@Decorator`) and agent routing (Path B via backend key), but has no mechanism
for REST client proxies.

Platform has 3 REST clients (ScimClient, Mem0Client, GraphitiClient). Consumer
repos have more (devtown: 5 GitHub APIs). Each needs simulation + capture support
without hand-writing decorators per client.

## Architecture

A new `RestClientSimulationProcessor` APT generates `@Decorator` classes for
`@RegisterRestClient` interfaces, following the same pattern as
`SimulationDecoratorProcessor` but with REST-specific concerns:

```
┌─────────────────────────────────┐    ┌────────────────────────────────────┐
│  simulation-generator (existing)│    │  rest-client-simulation-generator  │
│                                 │    │  (new)                             │
│  SimulationDecoratorProcessor   │    │  RestClientSimulationProcessor     │
│  - scans @SimulationEligible    │    │  - scans @RegisterRestClient       │
│  - scans simulation-eligible.txt│    │  - emits @RestClient on delegate   │
│  - emits @Decorator             │    │  - reads JAX-RS annotations        │
│  - generic SPI wrapping         │    │  - builds RestInvocation per call  │
│  - framework-agnostic           │    │  - emits @Decorator                │
└─────────────────────────────────┘    └────────────────────────────────────┘
              │                                        │
              └────────────┬───────────────────────────┘
                           ▼
              ┌─────────────────────────┐
              │  SimulationRuntime      │
              │  SimulationStrategy<I,O>│
              │  SimulationCorpus       │
              │  SimulationConfig       │
              └─────────────────────────┘
```

Both processors share the runtime infrastructure. The difference is what they
detect and how they construct the decorator's input.

## New Types

### RestInvocation (simulation-core)

```java
package io.casehub.platform.simulation;

public record RestInvocation(
    String spiName,
    String methodName,
    String httpMethod,
    String pathTemplate,
    Map<String, Object> params,
    Object body
) {}
```

- `spiName` — derived from `@RegisterRestClient(configKey=...)` or kebab-cased
  class name. First segment of the qualified name in config keys.
- `methodName` — Java method name. Second segment of the qualified name.
- `httpMethod` — from `@GET`/`@POST`/`@PUT`/`@DELETE`/`@PATCH` on the method.
  Null if no HTTP method annotation (unlikely for REST clients).
- `pathTemplate` — from `@Path` on class + method, combined. Preserves template
  variables: `/Groups/{id}/Members`.
- `params` — all method parameters keyed by name. Includes `@PathParam`,
  `@QueryParam`, `@HeaderParam`, and unannotated parameters. Parameter names
  come from Jandex (which reads them from bytecode debug info or `@PathParam`
  value attributes).
- `body` — the parameter without `@PathParam`/`@QueryParam`/`@HeaderParam`
  annotation, or null if all parameters are annotated. For REST clients, this
  is typically the request body (a POJO or String).

Placed in simulation-core (not simulation-api) because it introduces
REST-specific concepts that don't belong in the zero-dep SPI module (D36, R1-10).

### RestClientKeyExtractor (simulation-core)

```java
package io.casehub.platform.simulation.strategy;

public class RestClientKeyExtractor implements KeyExtractor<RestInvocation> {

    @Override
    public String extract(RestInvocation invocation) {
        // httpMethod + pathTemplate with param values substituted
        // GET /Groups/grp-1/Members
        String path = invocation.pathTemplate();
        for (var entry : invocation.params().entrySet()) {
            path = path.replace("{" + entry.getKey() + "}", String.valueOf(entry.getValue()));
        }
        return invocation.httpMethod() + " " + path;
    }
}
```

Default key extractor for REST client simulation. Registered automatically by
the `SimulationConfigBeans` startup when REST client simulation config is present.

Consumers can override with the existing declarative config:
`casehub.simulation.scim-client.membersOf.key-extractor=field:spiName,methodName`

## RestClientSimulationProcessor

### Module: rest-client-simulation-generator

`jar` packaging. Follows the same structure as `simulation-generator`:

**Dependencies:**
- `casehub-platform-simulation-core` (RestInvocation, SimulationRuntime)
- `io.smallrye:jandex` (Jandex index scanning)

**Compiler config:** `<proc>none</proc>` to prevent self-processing.

**Service registration:** `META-INF/services/javax.annotation.processing.Processor`
→ `io.casehub.platform.simulation.restclient.generator.RestClientSimulationProcessor`

### Detection

The processor scans Jandex indexes from dependency JARs for interfaces annotated
with `@RegisterRestClient` (`org.eclipse.microprofile.rest.client.inject.RegisterRestClient`).

For each detected interface:
1. Read `configKey` from `@RegisterRestClient`. If empty, kebab-case the simple
   class name (e.g., `ScimClient` → `scim-client`).
2. Skip if the interface is also annotated with `@SimulationEligible` — the base
   generator handles those.
3. Generate a decorator class.

### Generated Decorator

For `ScimClient` with `configKey = "scim"`:

```java
package io.casehub.platform.simulation.generated;

import jakarta.decorator.Decorator;
import jakarta.decorator.Delegate;
import jakarta.inject.Inject;
import jakarta.annotation.Priority;
import org.eclipse.microprofile.rest.client.inject.RestClient;
import io.casehub.platform.simulation.SimulationRuntime;
import io.casehub.platform.simulation.RestInvocation;
import io.casehub.platform.api.identity.CurrentPrincipal;
import java.util.Map;

@Decorator
@Priority(jakarta.interceptor.Interceptor.Priority.APPLICATION + 200)
public abstract class SimulatedScimClient implements ScimClient {

    @Inject @Delegate @RestClient
    ScimClient delegate;

    @Inject
    SimulationRuntime simulation;

    @Inject
    CurrentPrincipal currentPrincipal;

    @Override
    public ScimListResponse<ScimGroupResource> membersOf(String groupId) {
        String qualifiedName = "scim.membersOf";
        RestInvocation input = new RestInvocation(
            "scim", "membersOf", "GET", "/Groups/{id}/Members",
            Map.of("id", groupId), null);
        var strategy = simulation.strategyFor(qualifiedName);
        if (strategy.isPresent() && strategy.get().canResolve(input)) {
            return (ScimListResponse<ScimGroupResource>) strategy.get().resolve(input);
        }
        var result = delegate.membersOf(groupId);
        if (simulation.captureEnabled(qualifiedName)) {
            simulation.capture(qualifiedName, currentPrincipal.tenancyId(), input, result);
        }
        return result;
    }

    // ... other methods follow same pattern
}
```

Key differences from the base generator's output:
- `@Inject @Delegate @RestClient` — adds `@RestClient` qualifier to match
  the Quarkus-generated REST client proxy bean
- Input is `RestInvocation` instead of raw method params / `Object[]`
- HTTP metadata (`httpMethod`, `pathTemplate`) extracted from JAX-RS annotations
  at compile time and embedded as string literals in generated code

### JAX-RS Annotation Reading

The processor reads these annotations from the Jandex index at generation time:

| Annotation | Source | Used for |
|-----------|--------|----------|
| `@Path` (class) | `jakarta.ws.rs.Path` | Base path template |
| `@Path` (method) | `jakarta.ws.rs.Path` | Method path template (appended to class) |
| `@GET/POST/PUT/DELETE/PATCH` | `jakarta.ws.rs.*` | `httpMethod` field |
| `@PathParam` | `jakarta.ws.rs.PathParam` | Identifies path parameters in `params` map |
| `@QueryParam` | `jakarta.ws.rs.QueryParam` | Identifies query parameters in `params` map |
| `@HeaderParam` | `jakarta.ws.rs.HeaderParam` | Identifies header parameters in `params` map |

Parameters without JAX-RS annotations are treated as the request body.

### Reactive Return Types

Not in scope for #319 (D37). Methods returning `Uni<T>` or `Multi<T>` are
generated as pass-throughs to the delegate — no simulation or capture.

```java
@Override
public Uni<SomeResponse> reactiveMethod(String arg) {
    return delegate.reactiveMethod(arg);
}
```

When reactive support is needed, the processor can detect return types at compile
time and wrap `strategy.resolve()` in `Uni.createFrom().item()`.

### Void Methods

Same pattern as the base generator. Void methods delegate to the real client.
Capture records the input with `null` output.

### Default Methods

Same pattern as the base generator. Default methods pass through to delegate
without simulation logic.

## Configuration

Follows the existing `casehub.simulation.<spi>.<method>.<property>` pattern.
The `<spi>` segment is the `configKey` from `@RegisterRestClient`.

```properties
# Enable simulation for ScimClient.membersOf
casehub.simulation.scim.membersOf.strategy=key-lookup
casehub.simulation.scim.membersOf.key-extractor=rest-client

# Enable capture for ScimClient.getGroup
casehub.simulation.scim.getGroup.capture=true
```

The `rest-client` key-extractor name maps to `RestClientKeyExtractor`, registered
at startup alongside existing extractors (`identity`, `field:*`, `composite:*`).

## Consumer Wiring

Consumers add the processor to their build the same way as the base generator.
Example for a platform module that wants to simulate ScimClient:

```xml
<!-- In the consuming module's pom.xml -->
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-rest-client-simulation-generator</artifactId>
    <scope>provided</scope>
</dependency>
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-simulation-core</artifactId>
</dependency>
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-simulation-config</artifactId>
</dependency>
```

The processor runs at compile time, generates decorators into
`target/generated-sources/annotations/`. The consumer provides corpus YAML and
config via `application.properties`.

## Testing

### Processor Tests (rest-client-simulation-generator)

Follow the existing `SimulationDecoratorProcessorTest` pattern:

1. Build Jandex index in-memory from test REST client interfaces
2. Call `generateFromIndex(index)` on the processor
3. Assert generated source contains:
   - `@Decorator`, `@Priority(APPLICATION + 200)`
   - `@Inject @Delegate @RestClient` on delegate field
   - `RestInvocation` construction with correct HTTP metadata
   - Strategy lookup with correct qualified name
   - `canResolve`/`resolve` flow
   - Capture fallback
   - Pass-through for reactive return types
   - Pass-through for default methods

Test interfaces:
- `TestRestClient` — `@RegisterRestClient(configKey = "test-api")` with `@GET`,
  `@POST`, `@Path`, `@PathParam`, `@QueryParam` methods
- `TestNoConfigKeyClient` — `@RegisterRestClient` without configKey (tests
  kebab-case fallback)
- `TestMixedClient` — both `@SimulationEligible` and `@RegisterRestClient`
  (tests skip logic)

### Integration Test (RestClientKeyExtractor)

Unit test in simulation-core verifying key extraction:
- `GET /Groups/grp-1/Members` from `RestInvocation("scim", "membersOf", "GET", "/Groups/{id}/Members", Map.of("id", "grp-1"), null)`
- Multiple path params substituted correctly
- Null httpMethod handled gracefully

## Scope

**In scope:**
- `RestInvocation` record in simulation-core
- `RestClientKeyExtractor` in simulation-core
- `RestClientSimulationProcessor` APT in new rest-client-simulation-generator module
- Processor tests
- Key extractor tests
- Documentation update (simulation-guide.md, CLAUDE.md)

**Not in scope:**
- Reactive return type support (D37 — deferred)
- Production safeguards / build-profile gates (R1-07 — separate issue)
- Tenant-aware strategy resolution (R1-08 — pre-existing gap)
- Consumer-side wiring in platform modules (separate follow-up to wire ScimClient)

## References

- `simulation-generator/src/main/java/.../SimulationDecoratorProcessor.java` — base generator pattern
- `memory-simulation-core/` — generated decorator example (SimulatedCaseMemoryStore)
- `scim/src/main/java/.../ScimClient.java` — platform REST client example
- `simulation-core/src/main/java/.../SimulationRuntime.java` — strategy resolution
- D32–D37 in `specs/feat-294-simulation-service/decisions.md`
- Decision review: R1-03 (opt-in), R1-06 (framework-agnosticism), R1-10 (API coupling), R1-13 (YAGNI reactive)
