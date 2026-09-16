# Spring REST Non-Domain Resources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/parent#483 — Spring REST controllers for non-domain hand-written @Path resources
**Issue group:** #483

**Goal:** Core-extract business logic from 6 JAX-RS @Path resources into -core POJOs and write Spring @RestControllers in platform-spring.

**Architecture:** Each resource's business logic moves to a constructor-injected POJO in the appropriate -core module. The JAX-RS resource becomes a thin framework wrapper. A hand-written Spring @RestController in platform-spring delegates to the same POJO. Event<T> bridging uses Consumer<T> (GE-20260910-fc414e). Instance<T> becomes Map/List constructor params.

**Tech Stack:** Java 21, Maven, platform-api SPIs, Jackson, CloudEvents SDK

## Global Constraints

- -core modules: zero CDI, zero Spring, zero Quarkus imports. Pure Java + platform-api only.
- All -core POJOs use constructor injection — no field injection, no framework annotations.
- Spring controllers go in `io.casehub.platform.spring.rest` package in platform-spring.
- Existing tests must continue passing after resource refactoring.
- Jandex plugin required on all new modules.

---

## Batch 1: Module scaffolds + simple extractions

### Task 1: Create callback-client-core and streams-webhook-core modules

**Files:**
- Create: `callback-client-core/pom.xml`
- Create: `callback-client-core/src/main/java/io/casehub/platform/callback/client/CallbackDispatcher.java` (empty placeholder)
- Create: `streams-webhook-core/pom.xml`
- Create: `streams-webhook-core/src/main/java/io/casehub/platform/streams/webhook/WebhookReceiver.java` (empty placeholder)
- Modify: `pom.xml` (parent — add module declarations)

**Interfaces:**
- Produces: `callback-client-core` and `streams-webhook-core` Maven modules installable with `mvn install`

- [ ] **Step 1: Create callback-client-core/pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>
    <artifactId>casehub-platform-callback-client-core</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Callback Client Core</name>
    <description>Framework-neutral callback dispatch — reflection-based SPI routing.
        Pure Java — no CDI, no Spring.</description>
    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.core</groupId>
            <artifactId>jackson-databind</artifactId>
        </dependency>
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
    <build>
        <plugins>
            <plugin>
                <groupId>io.smallrye</groupId>
                <artifactId>jandex-maven-plugin</artifactId>
                <version>${jandex-maven-plugin.version}</version>
                <executions>
                    <execution>
                        <id>make-index</id>
                        <goals><goal>jandex</goal></goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Create streams-webhook-core/pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>
    <artifactId>casehub-platform-streams-webhook-core</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Streams Webhook Core</name>
    <description>Framework-neutral CloudEvents webhook receiver — credential validation,
        event enrichment. Pure Java — no CDI, no Spring.</description>
    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.cloudevents</groupId>
            <artifactId>cloudevents-core</artifactId>
        </dependency>
        <dependency>
            <groupId>io.cloudevents</groupId>
            <artifactId>cloudevents-json-jackson</artifactId>
        </dependency>
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
    <build>
        <plugins>
            <plugin>
                <groupId>io.smallrye</groupId>
                <artifactId>jandex-maven-plugin</artifactId>
                <version>${jandex-maven-plugin.version}</version>
                <executions>
                    <execution>
                        <id>make-index</id>
                        <goals><goal>jandex</goal></goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 3: Add modules to parent pom.xml**

Insert `callback-client-core` before `callback-client` and `streams-webhook-core` before `streams-webhook` in the `<modules>` section of the root `pom.xml`.

- [ ] **Step 4: Create placeholder classes and verify build**

Create minimal placeholder classes so modules compile:

`callback-client-core/src/main/java/io/casehub/platform/callback/client/CallbackDispatcher.java`:
```java
package io.casehub.platform.callback.client;

public class CallbackDispatcher {
}
```

`streams-webhook-core/src/main/java/io/casehub/platform/streams/webhook/WebhookReceiver.java`:
```java
package io.casehub.platform.streams.webhook;

public class WebhookReceiver {
}
```

Run: `mvn --batch-mode -pl callback-client-core,streams-webhook-core install -q`
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git add callback-client-core/ streams-webhook-core/ pom.xml
git commit -m "feat(#483): add callback-client-core and streams-webhook-core module scaffolds

Refs casehubio/parent#483"
```

### Task 2: EventTypeService extraction

**Files:**
- Create: `subscriptions-core/src/main/java/io/casehub/platform/subscription/EventTypeService.java`
- Create: `subscriptions-core/src/test/java/io/casehub/platform/subscription/EventTypeServiceTest.java`
- Modify: `subscriptions/src/main/java/io/casehub/platform/subscription/rest/EventTypeResource.java`

**Interfaces:**
- Consumes: `EventTypeRegistry` (platform-api SPI)
- Produces: `EventTypeService.listEventTypes()` → `Set<EventTypeDescriptor>`

- [ ] **Step 1: Write the failing test**

`subscriptions-core/src/test/java/io/casehub/platform/subscription/EventTypeServiceTest.java`:
```java
package io.casehub.platform.subscription;

import io.casehub.platform.api.subscription.EventTypeDescriptor;
import io.casehub.platform.api.subscription.EventTypeRegistry;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;

class EventTypeServiceTest {

    @Test
    void listEventTypes_delegates_to_registry() {
        var descriptor = new EventTypeDescriptor("test.event", "Test", "desc", List.of());
        EventTypeRegistry registry = () -> Set.of(descriptor);
        var service = new EventTypeService(registry);

        assertThat(service.listEventTypes()).containsExactly(descriptor);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode -pl subscriptions-core test -Dtest=EventTypeServiceTest -q`
Expected: FAIL — `EventTypeService` has no constructor taking `EventTypeRegistry`

- [ ] **Step 3: Implement EventTypeService**

`subscriptions-core/src/main/java/io/casehub/platform/subscription/EventTypeService.java`:
```java
package io.casehub.platform.subscription;

import io.casehub.platform.api.subscription.EventTypeDescriptor;
import io.casehub.platform.api.subscription.EventTypeRegistry;
import java.util.Set;

public class EventTypeService {

    private final EventTypeRegistry eventTypeRegistry;

    public EventTypeService(EventTypeRegistry eventTypeRegistry) {
        this.eventTypeRegistry = eventTypeRegistry;
    }

    public Set<EventTypeDescriptor> listEventTypes() {
        return eventTypeRegistry.discover();
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode -pl subscriptions-core test -Dtest=EventTypeServiceTest -q`
Expected: PASS

- [ ] **Step 5: Refactor EventTypeResource to delegate**

Replace `EventTypeResource` body — inject `EventTypeService` instead of `EventTypeRegistry`:
```java
package io.casehub.platform.subscription.rest;

import io.casehub.platform.api.subscription.EventTypeDescriptor;
import io.casehub.platform.subscription.EventTypeService;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import java.util.Set;

@ApplicationScoped
@Path("/subscriptions/event-types")
public class EventTypeResource {

    private final EventTypeService eventTypeService;

    @Inject
    public EventTypeResource(EventTypeService eventTypeService) {
        this.eventTypeService = eventTypeService;
    }

    @GET
    public Set<EventTypeDescriptor> listEventTypes() {
        return eventTypeService.listEventTypes();
    }
}
```

Add `subscriptions-core` dependency to `subscriptions/pom.xml` if not already present.

Add Quarkus `@Produces` for `EventTypeService` in the subscriptions module (or let CDI discover it via the Jandex index).

- [ ] **Step 6: Run existing tests**

Run: `mvn --batch-mode -pl subscriptions-core,subscriptions test -q`
Expected: All existing tests pass

- [ ] **Step 7: Commit**

```bash
git add subscriptions-core/ subscriptions/
git commit -m "feat(#483): extract EventTypeService to subscriptions-core

Refs casehubio/parent#483"
```

### Task 3: PreferenceSchemaService extraction

**Files:**
- Create: `preferences-editor-core/src/main/java/io/casehub/platform/preferences/editor/PreferenceSchemaService.java`
- Create: `preferences-editor-core/src/main/java/io/casehub/platform/preferences/editor/SchemaResult.java`
- Create: `preferences-editor-core/src/test/java/io/casehub/platform/preferences/editor/PreferenceSchemaServiceTest.java`
- Modify: `preferences-editor/src/main/java/io/casehub/platform/preferences/editor/PreferenceSchemaResource.java`

**Interfaces:**
- Consumes: `PreferenceSchemaRegistry` (platform-api SPI)
- Produces: `PreferenceSchemaService.schema(String namespace)` → `SchemaResult(List<PreferenceSchemaDescriptor>, String)`

- [ ] **Step 1: Create SchemaResult record**

`preferences-editor-core/src/main/java/io/casehub/platform/preferences/editor/SchemaResult.java`:
```java
package io.casehub.platform.preferences.editor;

import io.casehub.platform.api.preferences.PreferenceSchemaDescriptor;
import java.util.List;

public record SchemaResult(List<PreferenceSchemaDescriptor> schemas, String version) {}
```

- [ ] **Step 2: Write the failing test**

`preferences-editor-core/src/test/java/io/casehub/platform/preferences/editor/PreferenceSchemaServiceTest.java`:
```java
package io.casehub.platform.preferences.editor;

import io.casehub.platform.api.preferences.PreferenceSchemaDescriptor;
import io.casehub.platform.api.preferences.PreferenceSchemaRegistry;
import org.junit.jupiter.api.Test;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;

class PreferenceSchemaServiceTest {

    private final PreferenceSchemaDescriptor desc1 = PreferenceSchemaDescriptor.builder()
            .namespace("b-ns").name("key1").qualifiedName("b-ns.key1")
            .type("STRING").label("Key 1").build();
    private final PreferenceSchemaDescriptor desc2 = PreferenceSchemaDescriptor.builder()
            .namespace("a-ns").name("key2").qualifiedName("a-ns.key2")
            .type("STRING").label("Key 2").build();

    private final PreferenceSchemaRegistry registry = new PreferenceSchemaRegistry() {
        @Override public void register(PreferenceSchemaDescriptor d) {}
        @Override public Set<PreferenceSchemaDescriptor> discover() { return Set.of(desc1, desc2); }
        @Override public long version() { return 42; }
    };

    @Test
    void schema_returns_sorted_by_qualifiedName() {
        var service = new PreferenceSchemaService(registry);
        var result = service.schema(null);
        assertThat(result.schemas()).extracting(PreferenceSchemaDescriptor::qualifiedName)
                .containsExactly("a-ns.key2", "b-ns.key1");
        assertThat(result.version()).isEqualTo("42");
    }

    @Test
    void schema_filters_by_namespace() {
        var service = new PreferenceSchemaService(registry);
        var result = service.schema("a-ns");
        assertThat(result.schemas()).hasSize(1);
        assertThat(result.schemas().get(0).namespace()).isEqualTo("a-ns");
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mvn --batch-mode -pl preferences-editor-core test -Dtest=PreferenceSchemaServiceTest -q`
Expected: FAIL

- [ ] **Step 4: Implement PreferenceSchemaService**

`preferences-editor-core/src/main/java/io/casehub/platform/preferences/editor/PreferenceSchemaService.java`:
```java
package io.casehub.platform.preferences.editor;

import io.casehub.platform.api.preferences.PreferenceSchemaDescriptor;
import io.casehub.platform.api.preferences.PreferenceSchemaRegistry;
import java.util.Comparator;
import java.util.List;

public class PreferenceSchemaService {

    private final PreferenceSchemaRegistry registry;

    public PreferenceSchemaService(PreferenceSchemaRegistry registry) {
        this.registry = registry;
    }

    public SchemaResult schema(String namespace) {
        List<PreferenceSchemaDescriptor> result = registry.discover().stream()
                .filter(d -> namespace == null || namespace.isBlank() || d.namespace().equals(namespace))
                .sorted(Comparator.comparing(PreferenceSchemaDescriptor::qualifiedName))
                .toList();
        return new SchemaResult(result, String.valueOf(registry.version()));
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn --batch-mode -pl preferences-editor-core test -Dtest=PreferenceSchemaServiceTest -q`
Expected: PASS

- [ ] **Step 6: Refactor PreferenceSchemaResource to delegate**

Replace `PreferenceSchemaResource` body — inject `PreferenceSchemaService`, use it for schema + version:
```java
package io.casehub.platform.preferences.editor;

import io.casehub.platform.api.mcp.McpDomain;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.Context;
import jakarta.ws.rs.core.EntityTag;
import jakarta.ws.rs.core.Request;
import jakarta.ws.rs.core.Response;

@ApplicationScoped
@Path("/preferences/schema")
@McpDomain("preference-schemas")
public class PreferenceSchemaResource {

    @Inject PreferenceSchemaService schemaService;

    @GET
    public Response schema(@QueryParam("namespace") String namespace,
                           @Context Request request) {
        var result = schemaService.schema(namespace);
        EntityTag etag = new EntityTag(result.version());
        Response.ResponseBuilder notModified = request.evaluatePreconditions(etag);
        if (notModified != null) {
            return notModified.build();
        }
        return Response.ok(result.schemas()).tag(etag).build();
    }
}
```

- [ ] **Step 7: Run existing tests**

Run: `mvn --batch-mode -pl preferences-editor-core,preferences-editor test -q`
Expected: All existing tests pass

- [ ] **Step 8: Commit**

```bash
git add preferences-editor-core/ preferences-editor/
git commit -m "feat(#483): extract PreferenceSchemaService to preferences-editor-core

Refs casehubio/parent#483"
```

## Batch 2: Complex extractions

### Task 4: SubscriptionService extraction

**Files:**
- Create: `subscriptions-core/src/main/java/io/casehub/platform/subscription/SubscriptionService.java`
- Create: `subscriptions-core/src/test/java/io/casehub/platform/subscription/SubscriptionServiceTest.java`
- Modify: `subscriptions/src/main/java/io/casehub/platform/subscription/rest/SubscriptionResource.java`

**Interfaces:**
- Consumes: `SubscriptionStore`, `CurrentPrincipal`, `ExpressionEngineRegistry` (all platform-api)
- Produces: `SubscriptionService` with 7 methods returning domain types (no Response)

- [ ] **Step 1: Write the failing test**

`subscriptions-core/src/test/java/io/casehub/platform/subscription/SubscriptionServiceTest.java`:

Test `create` with SYSTEM scope unauthorized, `create` with valid input, `list` delegation, `getById` found/not-found, `delete` with auth check. Use mock implementations of the 3 SPIs. Key test cases:
- create with SYSTEM scope without admin group → throws `SecurityException`
- create with SYSTEM scope + `$me` filter → throws `IllegalArgumentException`
- create with USER scope auto-adds principal as target
- list delegates to store with correct query
- getById returns Optional
- delete checks auth before delegating

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode -pl subscriptions-core test -Dtest=SubscriptionServiceTest -q`
Expected: FAIL

- [ ] **Step 3: Implement SubscriptionService**

`subscriptions-core/src/main/java/io/casehub/platform/subscription/SubscriptionService.java`:

Move all business logic from `SubscriptionResource`:
- Constructor takes `SubscriptionStore`, `CurrentPrincipal`, `ExpressionEngineRegistry`
- `create(SubscriptionInput)` → `Subscription` (throws SecurityException/IllegalArgumentException)
- `list(Boolean enabled, SubscriptionScope scope, String cursor, int limit)` → `SubscriptionPage`
- `getById(String id)` → `Optional<Subscription>`
- `update(String id, SubscriptionUpdate)` → `Optional<Subscription>` (throws SecurityException)
- `delete(String id)` → `boolean` (throws SecurityException)
- `enable(String id)` → `Optional<Subscription>` (throws SecurityException)
- `disable(String id)` → `Optional<Subscription>` (throws SecurityException)
- Private: `extractExpression(ExpressionEvaluator)`, `isUnauthorizedSystemAccess(SubscriptionScope)`

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode -pl subscriptions-core test -Dtest=SubscriptionServiceTest -q`
Expected: PASS

- [ ] **Step 5: Refactor SubscriptionResource to thin wrapper**

Replace body — inject `SubscriptionService`, catch exceptions → Response status codes:
- `SecurityException` → 403
- `IllegalArgumentException` → 400
- `Optional.empty()` → 404
- Successful create → 201
- Successful delete → 204

- [ ] **Step 6: Run existing tests**

Run: `mvn --batch-mode -pl subscriptions-core,subscriptions test -q`
Expected: All existing tests pass

- [ ] **Step 7: Commit**

```bash
git add subscriptions-core/ subscriptions/
git commit -m "feat(#483): extract SubscriptionService to subscriptions-core

Refs casehubio/parent#483"
```

### Task 5: EngagementCallbackService extraction

**Files:**
- Create: `notification-dispatch-core/src/main/java/io/casehub/platform/notification/dispatch/EngagementCallbackService.java`
- Create: `notification-dispatch-core/src/main/java/io/casehub/platform/notification/dispatch/DirectEngagementRequest.java`
- Create: `notification-dispatch-core/src/test/java/io/casehub/platform/notification/dispatch/EngagementCallbackServiceTest.java`
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/EngagementCallbackResource.java`

**Interfaces:**
- Consumes: `DeliveryAttemptStore`, `EngagementRecorder`, `CurrentPrincipal`, `Map<String, EngagementCallbackHandler>`, `PreferenceProvider`
- Produces: `EngagementCallbackService.handleCallback(channelId, rawPayload, headers)`, `.recordDirect(attemptId, type, metadata)`

- [ ] **Step 1: Create DirectEngagementRequest record in -core**

`notification-dispatch-core/src/main/java/io/casehub/platform/notification/dispatch/DirectEngagementRequest.java`:
```java
package io.casehub.platform.notification.dispatch;

import io.casehub.platform.api.delivery.EngagementType;

public record DirectEngagementRequest(EngagementType type, String metadata) {}
```

- [ ] **Step 2: Write the failing test**

Test key paths: engagement disabled → throws, unknown channelId → throws, successful callback routing, successful direct recording.

- [ ] **Step 3: Implement EngagementCallbackService**

Constructor takes 5 deps (Map instead of Instance<>). Methods throw typed exceptions instead of returning Response:
- `handleCallback` throws `IllegalStateException` (disabled), `IllegalArgumentException` (unknown channel), `SecurityException` (handler rejection)
- `recordDirect` throws `IllegalStateException` (disabled), `IllegalArgumentException` (null type), returns void

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode -pl notification-dispatch-core test -Dtest=EngagementCallbackServiceTest -q`

- [ ] **Step 5: Refactor EngagementCallbackResource to thin wrapper**

Inject `EngagementCallbackService`. CDI constructor converts `Instance<EngagementCallbackHandler>` to `Map` and passes to service. `@Context HttpHeaders` extraction stays in resource, passes as `Map<String, String>` to service.

- [ ] **Step 6: Run existing tests**

Run: `mvn --batch-mode -pl notification-dispatch-core,notification-dispatch test -q`

- [ ] **Step 7: Commit**

```bash
git add notification-dispatch-core/ notification-dispatch/
git commit -m "feat(#483): extract EngagementCallbackService to notification-dispatch-core

Refs casehubio/parent#483"
```

### Task 6: CallbackDispatcher extraction

**Files:**
- Modify: `callback-client-core/src/main/java/io/casehub/platform/callback/client/CallbackDispatcher.java`
- Create: `callback-client-core/src/main/java/io/casehub/platform/callback/client/DispatchResult.java`
- Create: `callback-client-core/src/test/java/io/casehub/platform/callback/client/CallbackDispatcherTest.java`
- Modify: `callback-client/src/main/java/io/casehub/platform/callback/client/CallbackDispatchResource.java`
- Modify: `callback-client/src/main/java/io/casehub/platform/callback/client/CallbackAutoRegistrar.java`
- Modify: `callback-client/pom.xml` (add callback-client-core dependency)

**Interfaces:**
- Consumes: `ObjectMapper` (jackson)
- Produces: `CallbackDispatcher.registerSpi(spiName, bean)`, `.dispatch(spiName, methodName, spiHeader, argsJson)` → `DispatchResult`

- [ ] **Step 1: Create DispatchResult record**

`callback-client-core/src/main/java/io/casehub/platform/callback/client/DispatchResult.java`:
```java
package io.casehub.platform.callback.client;

public record DispatchResult(int status, Object body) {

    public static DispatchResult ok(Object body) { return new DispatchResult(200, body); }
    public static DispatchResult noContent() { return new DispatchResult(204, null); }
    public static DispatchResult notFound(String message) { return new DispatchResult(404, java.util.Map.of("error", message)); }
    public static DispatchResult forbidden(String message) { return new DispatchResult(403, java.util.Map.of("error", message)); }
    public static DispatchResult error(String message) { return new DispatchResult(500, java.util.Map.of("error", message)); }
}
```

- [ ] **Step 2: Write the failing test**

Test: missing SPI header → forbidden, unknown SPI → not found, successful dispatch, void return → noContent, InvocationTargetException → error.

- [ ] **Step 3: Implement CallbackDispatcher**

Move the reflection logic from `CallbackDispatchResource`:
```java
package io.casehub.platform.callback.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public class CallbackDispatcher {

    private final ObjectMapper objectMapper;
    private final Map<String, Object> spiRegistry = new ConcurrentHashMap<>();

    public CallbackDispatcher(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    public void registerSpi(String spiName, Object bean) {
        spiRegistry.put(spiName, bean);
    }

    public DispatchResult dispatch(String spiName, String methodName,
                                    String spiHeader, JsonNode argsNode) {
        if (spiHeader == null || spiHeader.isBlank()) {
            return DispatchResult.forbidden("Missing X-CaseHub-SPI header");
        }
        Object bean = spiRegistry.get(spiName);
        if (bean == null) {
            return DispatchResult.notFound("No SPI registered for: " + spiName);
        }
        try {
            int argCount = (argsNode != null && argsNode.isArray()) ? argsNode.size() : 0;
            Method method = findMethod(bean.getClass(), methodName, argCount);
            if (method == null) {
                return DispatchResult.notFound(
                    "No method '" + methodName + "' with " + argCount + " args on SPI " + spiName);
            }
            Object[] args = deserializeArgs(argsNode, method);
            Object result = method.invoke(bean, args);
            return method.getReturnType() == void.class
                    ? DispatchResult.noContent() : DispatchResult.ok(result);
        } catch (InvocationTargetException e) {
            return DispatchResult.error(e.getCause().getMessage());
        } catch (Exception e) {
            return DispatchResult.error(e.getMessage());
        }
    }

    private Method findMethod(Class<?> clazz, String name, int argCount) {
        for (Method m : clazz.getMethods()) {
            if (m.getName().equals(name) && !m.isSynthetic()
                    && m.getParameterCount() == argCount) {
                return m;
            }
        }
        return null;
    }

    private Object[] deserializeArgs(JsonNode argsNode, Method method) throws Exception {
        Class<?>[] paramTypes = method.getParameterTypes();
        Object[] args = new Object[paramTypes.length];
        if (argsNode == null || argsNode.isNull() || !argsNode.isArray()) {
            return args;
        }
        for (int i = 0; i < paramTypes.length && i < argsNode.size(); i++) {
            args[i] = objectMapper.treeToValue(argsNode.get(i), paramTypes[i]);
        }
        return args;
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode -pl callback-client-core test -Dtest=CallbackDispatcherTest -q`

- [ ] **Step 5: Refactor CallbackDispatchResource + CallbackAutoRegistrar**

`CallbackDispatchResource` → thin wrapper injecting `CallbackDispatcher`, converting `DispatchResult` to `Response`.

`CallbackAutoRegistrar` → inject `CallbackDispatcher` instead of `CallbackDispatchResource`, call `dispatcher.registerSpi()`.

Add `callback-client-core` dependency to `callback-client/pom.xml`.

- [ ] **Step 6: Run existing tests**

Run: `mvn --batch-mode -pl callback-client-core,callback-client test -q`

- [ ] **Step 7: Commit**

```bash
git add callback-client-core/ callback-client/
git commit -m "feat(#483): extract CallbackDispatcher to callback-client-core

Refs casehubio/parent#483"
```

### Task 7: WebhookReceiver extraction

**Files:**
- Modify: `streams-webhook-core/src/main/java/io/casehub/platform/streams/webhook/WebhookReceiver.java`
- Create: `streams-webhook-core/src/main/java/io/casehub/platform/streams/webhook/WebhookResult.java`
- Create: `streams-webhook-core/src/test/java/io/casehub/platform/streams/webhook/WebhookReceiverTest.java`
- Modify: `streams-webhook/src/main/java/io/casehub/platform/streams/webhook/WebhookResource.java`
- Modify: `streams-webhook/pom.xml` (add streams-webhook-core dependency)

**Interfaces:**
- Consumes: `EndpointRegistry`, `CredentialResolver` (platform-api), `Consumer<CloudEvent>` (callback), `String publicUrl`, `boolean requireAuth`
- Produces: `WebhookReceiver.init()`, `.receive(body, tenancyId, streamId, headers)` → `WebhookResult`

- [ ] **Step 1: Create WebhookResult record**

`streams-webhook-core/src/main/java/io/casehub/platform/streams/webhook/WebhookResult.java`:
```java
package io.casehub.platform.streams.webhook;

public record WebhookResult(int status, String errorMessage) {

    public static WebhookResult accepted() { return new WebhookResult(202, null); }
    public static WebhookResult badRequest(String msg) { return new WebhookResult(400, msg); }
    public static WebhookResult unauthorized() { return new WebhookResult(401, null); }
    public static WebhookResult notFound() { return new WebhookResult(404, null); }
}
```

- [ ] **Step 2: Write the failing test**

Test: invalid CloudEvent body → badRequest, unknown stream → notFound, missing credentials → unauthorized (when requireAuth=true), successful receive fires callback.

- [ ] **Step 3: Implement WebhookReceiver**

Constructor takes 5 params. `init()` registers endpoint descriptor + initializes EventFormat. `receive()` deserializes, validates, enriches, fires via Consumer callback. `validateCredentials()` checks bearer token. Uses `Consumer<CloudEvent>` instead of CDI `Event<CloudEvent>`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode -pl streams-webhook-core test -Dtest=WebhookReceiverTest -q`

- [ ] **Step 5: Refactor WebhookResource to thin wrapper**

Inject `WebhookReceiver` (produced via `@Produces` in the streams-webhook module). Wire `Consumer<CloudEvent> = cloudEventBus::fireAsync`, pass config values. `@PostConstruct` calls `receiver.init()`. `receive()` delegates and converts `WebhookResult` → `Response`.

Add `streams-webhook-core` dependency to `streams-webhook/pom.xml`.

- [ ] **Step 6: Run existing tests**

Run: `mvn --batch-mode -pl streams-webhook-core,streams-webhook test -q`

- [ ] **Step 7: Commit**

```bash
git add streams-webhook-core/ streams-webhook/
git commit -m "feat(#483): extract WebhookReceiver to streams-webhook-core

Refs casehubio/parent#483"
```

## Batch 3: Spring controllers

### Task 8: Spring @RestControllers in platform-spring

**Files:**
- Create: `platform-spring/src/main/java/io/casehub/platform/spring/rest/EventTypeRestController.java`
- Create: `platform-spring/src/main/java/io/casehub/platform/spring/rest/SubscriptionRestController.java`
- Create: `platform-spring/src/main/java/io/casehub/platform/spring/rest/PreferenceSchemaRestController.java`
- Create: `platform-spring/src/main/java/io/casehub/platform/spring/rest/EngagementCallbackRestController.java`
- Create: `platform-spring/src/main/java/io/casehub/platform/spring/rest/CallbackDispatchRestController.java`
- Create: `platform-spring/src/main/java/io/casehub/platform/spring/rest/WebhookRestController.java`
- Create: `platform-spring/src/main/java/io/casehub/platform/spring/rest/RestControllersAutoConfiguration.java`
- Modify: `platform-spring/pom.xml` (add -core dependencies)
- Create: `platform-spring/src/test/java/io/casehub/platform/spring/rest/EventTypeRestControllerTest.java`
- Create: `platform-spring/src/test/java/io/casehub/platform/spring/rest/SubscriptionRestControllerTest.java`

**Interfaces:**
- Consumes: All 6 -core service POJOs
- Produces: Spring REST endpoints matching the JAX-RS paths

- [ ] **Step 1: Add -core dependencies to platform-spring/pom.xml**

Add `subscriptions-core`, `notification-dispatch-core`, `callback-client-core`, `streams-webhook-core` dependencies. (`preferences-editor-core` already present.)

- [ ] **Step 2: Create RestControllersAutoConfiguration**

`platform-spring/src/main/java/io/casehub/platform/spring/rest/RestControllersAutoConfiguration.java`:
```java
package io.casehub.platform.spring.rest;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.casehub.platform.api.credentials.CredentialResolver;
import io.casehub.platform.api.delivery.DeliveryAttemptStore;
import io.casehub.platform.api.delivery.EngagementCallbackHandler;
import io.casehub.platform.api.endpoints.EndpointRegistry;
import io.casehub.platform.api.expression.ExpressionEngineRegistry;
import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.preferences.PreferenceProvider;
import io.casehub.platform.api.preferences.PreferenceSchemaRegistry;
import io.casehub.platform.api.subscription.EventTypeRegistry;
import io.casehub.platform.api.subscription.SubscriptionStore;
import io.casehub.platform.callback.client.CallbackDispatcher;
import io.casehub.platform.notification.dispatch.EngagementCallbackService;
import io.casehub.platform.notification.dispatch.EngagementRecorder;
import io.casehub.platform.preferences.editor.PreferenceSchemaService;
import io.casehub.platform.subscription.EventTypeService;
import io.casehub.platform.subscription.SubscriptionService;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.context.annotation.Bean;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

@AutoConfiguration
public class RestControllersAutoConfiguration {

    @Bean
    @ConditionalOnBean(EventTypeRegistry.class)
    public EventTypeService eventTypeService(EventTypeRegistry registry) {
        return new EventTypeService(registry);
    }

    @Bean
    @ConditionalOnBean(SubscriptionStore.class)
    public SubscriptionService subscriptionService(SubscriptionStore store,
                                                    CurrentPrincipal principal,
                                                    ExpressionEngineRegistry expressionRegistry) {
        return new SubscriptionService(store, principal, expressionRegistry);
    }

    @Bean
    @ConditionalOnBean(PreferenceSchemaRegistry.class)
    public PreferenceSchemaService preferenceSchemaService(PreferenceSchemaRegistry registry) {
        return new PreferenceSchemaService(registry);
    }

    @Bean
    @ConditionalOnBean(DeliveryAttemptStore.class)
    public EngagementCallbackService engagementCallbackService(
            DeliveryAttemptStore store,
            EngagementRecorder recorder,
            CurrentPrincipal principal,
            ObjectProvider<EngagementCallbackHandler> handlers,
            PreferenceProvider preferenceProvider) {
        Map<String, EngagementCallbackHandler> handlerMap = handlers.stream()
                .collect(Collectors.toMap(EngagementCallbackHandler::channelId, h -> h));
        return new EngagementCallbackService(store, recorder, principal, handlerMap, preferenceProvider);
    }

    @Bean
    public CallbackDispatcher callbackDispatcher(ObjectMapper objectMapper) {
        return new CallbackDispatcher(objectMapper);
    }
}
```

Register in `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`.

- [ ] **Step 3: Write EventTypeRestController**

```java
package io.casehub.platform.spring.rest;

import io.casehub.platform.api.subscription.EventTypeDescriptor;
import io.casehub.platform.subscription.EventTypeService;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import java.util.Set;

@RestController
@RequestMapping("/subscriptions/event-types")
public class EventTypeRestController {

    private final EventTypeService service;

    public EventTypeRestController(EventTypeService service) {
        this.service = service;
    }

    @GetMapping
    public Set<EventTypeDescriptor> listEventTypes() {
        return service.listEventTypes();
    }
}
```

- [ ] **Step 4: Write SubscriptionRestController**

Maps SubscriptionService methods. Exception → ResponseEntity: SecurityException → 403, IllegalArgumentException → 400, Optional.empty → 404.

- [ ] **Step 5: Write PreferenceSchemaRestController**

Uses Spring's `WebRequest.checkNotModified(etag)` for ETag support.

- [ ] **Step 6: Write EngagementCallbackRestController**

Two POST endpoints. Extracts headers from `HttpServletRequest`. Exception → ResponseEntity mapping.

- [ ] **Step 7: Write CallbackDispatchRestController**

Delegates to `CallbackDispatcher`, converts `DispatchResult.status` → `ResponseEntity`.

- [ ] **Step 8: Write WebhookRestController**

`@PostMapping(consumes = "application/cloudevents+json")`. Delegates to `WebhookReceiver`, converts `WebhookResult` → `ResponseEntity`. The `WebhookReceiver` bean is not auto-configured here — it requires framework-specific wiring (Consumer<CloudEvent>, config values) that a consuming app provides.

- [ ] **Step 9: Write unit tests for EventTypeRestController and SubscriptionRestController**

Direct invocation tests with mocked services — verify correct delegation and status code mapping.

- [ ] **Step 10: Build platform-spring**

Run: `mvn --batch-mode -pl platform-spring install -q`
Expected: BUILD SUCCESS — all generated + hand-written controllers compile

- [ ] **Step 11: Commit**

```bash
git add platform-spring/
git commit -m "feat(#483): add 6 hand-written Spring @RestControllers for non-domain resources

EventType, Subscription, PreferenceSchema, EngagementCallback,
CallbackDispatch, Webhook — all delegating to -core POJOs.

Refs casehubio/parent#483"
```

## References

- specs/issue-478-spring-deployment-completion/2026-09-15-spring-rest-non-domain-design.md — design spec
- GE-20260910-fc414e — Event<T> to Consumer<T> core extraction pattern
- GE-20260909-c81437 — module-core/module/module-spring naming convention
- GE-20260910-8ecdb7 — Core extraction breaks downstream test constructors
- casehubio/parent#483 — tracking issue
- subscriptions/src/main/java/io/casehub/platform/subscription/rest/SubscriptionResource.java — source resource
- notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/EngagementCallbackResource.java — source resource
- callback-client/src/main/java/io/casehub/platform/callback/client/CallbackDispatchResource.java — source resource
- streams-webhook/src/main/java/io/casehub/platform/streams/webhook/WebhookResource.java — source resource
- preferences-editor/src/main/java/io/casehub/platform/preferences/editor/PreferenceSchemaResource.java — source resource
