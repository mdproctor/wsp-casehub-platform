# CloudEvent Foundation and Platform Stream Modules — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce `io.cloudevents.CloudEvent` as the platform's typed CDI event type and ship five classpath-activated stream modules (`streams-kafka`, `streams-amqp`, `streams-webhook`, `streams-poll`, `streams-camel`) each firing `Event<CloudEvent>.fireAsync()` from their respective transports.

**Architecture:** `casehub-platform-api` gains a `cloudevents-core` compile dep, three new types (`EndpointRegistered`, `EndpointProtocol.AMQP`, `EndpointPropertyKeys.STREAM_EVENT_TYPE`), and Javadoc updates. `InMemoryEndpointRegistry` gains constructor injection of `Event<EndpointRegistered>` and fires it on every `register()` call. Each stream module is a Jandex library JAR (no `quarkus:build` goal) that activates by classpath presence.

**Tech Stack:** Java 21, Quarkus 3.32.2, CloudEvents Java SDK 4.0.1 (`cloudevents-core`, `cloudevents-json-jackson`), SmallRye Reactive Messaging (Kafka, AMQP), Quarkus REST, Quarkus Scheduler, Apache Camel Quarkus, `java.net.http.HttpClient` (stdlib), WireMock 3.13.0

---

## Spec reference

`docs/superpowers/specs/2026-06-14-cloudEvent-streams-design.md` on branch `issue-98-cloudEvent-streams`. Read it before starting.

---

## File map

**Modified:**
- `pom.xml` — version management (3 CloudEvents artifacts), 5 new `<module>` entries
- `platform-api/pom.xml` — `cloudevents-core` compile dep
- `platform-api/src/main/java/io/casehub/platform/api/endpoints/EndpointProtocol.java` — add `AMQP`
- `platform-api/src/main/java/io/casehub/platform/api/endpoints/EndpointPropertyKeys.java` — add `STREAM_EVENT_TYPE`; update `TOPIC`/`URL` Javadoc
- `platform-api/src/main/java/io/casehub/platform/api/endpoints/EndpointRegistry.java` — Javadoc only
- `endpoints-memory/pom.xml` — add `quarkus-maven-plugin` (generate-code + generate-code-tests) + `quarkus-junit5`
- `endpoints-memory/src/main/java/io/casehub/platform/endpoints/memory/InMemoryEndpointRegistry.java` — constructor injection, `fireAsync`
- `CLAUDE.md` — module table (5 new rows)
- `ARC42STORIES.MD` — §4 L10 layer entry, §5 L10 containers, missing L4 `endpoints-config` container

**Created:**
- `platform-api/src/main/java/io/casehub/platform/api/endpoints/EndpointRegistered.java`
- `platform-api/src/test/java/io/casehub/platform/api/endpoints/EndpointRegisteredTest.java`
- `endpoints-memory/src/test/java/io/casehub/platform/endpoints/memory/InMemoryEndpointRegistryEventTest.java`
- `streams-kafka/pom.xml`
- `streams-kafka/src/main/java/io/casehub/platform/streams/kafka/KafkaStreamProcessor.java`
- `streams-kafka/src/test/java/io/casehub/platform/streams/kafka/KafkaStreamProcessorTest.java`
- `streams-amqp/pom.xml`
- `streams-amqp/src/main/java/io/casehub/platform/streams/amqp/AmqpStreamProcessor.java`
- `streams-amqp/src/test/java/io/casehub/platform/streams/amqp/AmqpStreamProcessorTest.java`
- `streams-webhook/pom.xml`
- `streams-webhook/src/main/java/io/casehub/platform/streams/webhook/WebhookResource.java`
- `streams-webhook/src/test/java/io/casehub/platform/streams/webhook/WebhookResourceTest.java`
- `streams-poll/pom.xml`
- `streams-poll/src/main/java/io/casehub/platform/streams/poll/PollStreamProcessor.java`
- `streams-poll/src/test/java/io/casehub/platform/streams/poll/PollStreamProcessorTest.java`
- `streams-camel/pom.xml`
- `streams-camel/src/main/java/io/casehub/platform/streams/camel/CamelStreamProcessor.java`
- `streams-camel/src/test/java/io/casehub/platform/streams/camel/CamelStreamProcessorTest.java`

---

## Task 1 — Root pom.xml: version management and module declarations

**Files:**
- Modify: `pom.xml`

- [ ] **Step 1.1: Add CloudEvents version management**

In `pom.xml` `<dependencyManagement>` section, BEFORE the `<dependency>` for `sqlite-jdbc`, add:

```xml
<dependency>
    <groupId>io.cloudevents</groupId>
    <artifactId>cloudevents-api</artifactId>
    <version>4.0.1</version>
</dependency>
<dependency>
    <groupId>io.cloudevents</groupId>
    <artifactId>cloudevents-core</artifactId>
    <version>4.0.1</version>
</dependency>
<dependency>
    <groupId>io.cloudevents</groupId>
    <artifactId>cloudevents-json-jackson</artifactId>
    <version>4.0.1</version>
</dependency>
```

Placing these BEFORE the Quarkus BOM import ensures they override the Quarkus BOM's `cloudevents-api:3.0.0`. Maven direct-entry precedence handles this correctly.

- [ ] **Step 1.2: Add stream modules to `<modules>` list**

In the `<modules>` section of `pom.xml`, add after `acl-jpa`:

```xml
<module>streams-kafka</module>
<module>streams-amqp</module>
<module>streams-webhook</module>
<module>streams-poll</module>
<module>streams-camel</module>
```

- [ ] **Step 1.3: Verify root build still compiles**

```bash
mvn --batch-mode install -DskipTests -pl platform-api
```

Expected: `BUILD SUCCESS` (stream modules don't exist yet; add them after each module task).

- [ ] **Step 1.4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add pom.xml
git -C /Users/mdproctor/claude/casehub/platform commit -m "build(platform#98): add cloudevents-core:4.0.1 to version management"
```

---

## Task 2 — platform-api: EndpointRegistered, AMQP, STREAM_EVENT_TYPE, Javadoc, dep

**Files:**
- Modify: `platform-api/pom.xml`
- Create: `platform-api/src/main/java/io/casehub/platform/api/endpoints/EndpointRegistered.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/endpoints/EndpointProtocol.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/endpoints/EndpointPropertyKeys.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/endpoints/EndpointRegistry.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/endpoints/EndpointRegisteredTest.java`

- [ ] **Step 2.1: Write the failing test**

Create `platform-api/src/test/java/io/casehub/platform/api/endpoints/EndpointRegisteredTest.java`:

```java
package io.casehub.platform.api.endpoints;

import io.casehub.platform.api.path.Path;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class EndpointRegisteredTest {

    @Test
    void endpointRegistered_carries_descriptor() {
        var desc = new EndpointDescriptor(
            Path.of("platform", "streams", "webhook"),
            "platform",
            EndpointType.SERVICE,
            EndpointProtocol.HTTP,
            Map.of(),
            null,
            Set.of(EndpointCapability.RECEIVE));

        var event = new EndpointRegistered(desc);

        assertThat(event.descriptor()).isSameAs(desc);
    }

    @Test
    void endpointProtocol_amqp_exists() {
        assertThat(EndpointProtocol.valueOf("AMQP")).isEqualTo(EndpointProtocol.AMQP);
    }

    @Test
    void streamEventTypeKey_value() {
        assertThat(EndpointPropertyKeys.STREAM_EVENT_TYPE).isEqualTo("stream-event-type");
    }
}
```

- [ ] **Step 2.2: Run test to verify it fails**

```bash
mvn --batch-mode -pl platform-api test -Dtest=EndpointRegisteredTest
```

Expected: `COMPILATION ERROR` — `EndpointRegistered`, `EndpointProtocol.AMQP`, `EndpointPropertyKeys.STREAM_EVENT_TYPE` do not yet exist.

- [ ] **Step 2.3: Add cloudevents-core compile dep to platform-api/pom.xml**

In `platform-api/pom.xml`, add inside `<dependencies>` (after the `mutiny` dep):

```xml
<dependency>
    <groupId>io.cloudevents</groupId>
    <artifactId>cloudevents-core</artifactId>
    <scope>compile</scope>
</dependency>
```

- [ ] **Step 2.4: Create EndpointRegistered record**

Create `platform-api/src/main/java/io/casehub/platform/api/endpoints/EndpointRegistered.java`:

```java
package io.casehub.platform.api.endpoints;

/**
 * CDI event fired by non-no-op {@link EndpointRegistry} implementations after every
 * successful {@link EndpointRegistry#register(EndpointDescriptor)} call.
 *
 * <p>Consumers use this event to react to new endpoint registrations at runtime
 * (e.g. stream modules building Camel routes). The {@link io.casehub.platform.endpoints.NoOpEndpointRegistry}
 * default implementation must NOT fire this event — firing it would trigger route
 * creation for phantom endpoints that are never actually stored.
 *
 * <p>Any future non-no-op {@link EndpointRegistry} implementation has a required
 * obligation to fire this event after storing the descriptor.
 */
public record EndpointRegistered(EndpointDescriptor descriptor) {}
```

- [ ] **Step 2.5: Add AMQP to EndpointProtocol**

In `EndpointProtocol.java`, add `AMQP` after `KAFKA` and before `MCP`:

```java
/**
 * AMQP message broker transport. Use {@link EndpointPropertyKeys#TOPIC} for queue or
 * topic name. {@link EndpointPropertyKeys#URL} does not apply — broker connection
 * is Quarkus-managed via standard config (e.g. {@code amqp-host}, {@code amqp-port}).
 */
AMQP,
```

- [ ] **Step 2.6: Update EndpointPropertyKeys — add STREAM_EVENT_TYPE, update Javadoc**

In `EndpointPropertyKeys.java`:

**Add** `STREAM_EVENT_TYPE` as a new constant (after `TOPIC`):

```java
/**
 * Logical CloudEvent {@code type} for a stream source — reverse-DNS, e.g.
 * {@code io.casehub.iot.temperature}. Stream modules that build CloudEvents from
 * raw payloads read this from {@link EndpointDescriptor#properties()} to set the
 * CloudEvent {@code type} field.
 *
 * <p>Applies to: {@link EndpointProtocol#KAFKA}, {@link EndpointProtocol#AMQP},
 * {@link EndpointProtocol#HTTP} ({@code streams-poll} only),
 * {@link EndpointProtocol#CAMEL}.
 *
 * <p><b>Not used by {@code streams-webhook}.</b> Webhook requests are already
 * structured CloudEvents; their {@code type} field is preserved from the incoming
 * event and not overridden by the descriptor.
 */
public static final String STREAM_EVENT_TYPE = "stream-event-type";
```

**Update** `TOPIC` Javadoc — change "Applies to: {@link EndpointProtocol#KAFKA} only." to:
"Applies to: {@link EndpointProtocol#KAFKA} and {@link EndpointProtocol#AMQP}."

**Update** `URL` Javadoc — add at the end of the `<ul>` list (after the `QHORUS` entry):

```java
 * <p>KAFKA and AMQP are excluded — broker connection for both is Quarkus-managed
 * via standard config (e.g. {@code kafka.bootstrap.servers},
 * {@code amqp-host}/{@code amqp-port}).
```

- [ ] **Step 2.7: Update EndpointRegistry Javadoc**

In `EndpointRegistry.java`, add to the class-level Javadoc (before the `<h2>Tenant isolation</h2>` section):

```java
 * <h2>EndpointRegistered CDI event</h2>
 * <p>Non-no-op implementations have a required obligation to fire
 * {@link EndpointRegistered} via {@code Event<EndpointRegistered>.fireAsync()} after
 * every successful {@link #register(EndpointDescriptor)} call. The no-op
 * {@code @DefaultBean} implementation must NOT fire the event — it stores nothing,
 * and firing would trigger stream route creation for phantom endpoints.
```

- [ ] **Step 2.8: Run tests to verify they pass**

```bash
mvn --batch-mode -pl platform-api test -Dtest=EndpointRegisteredTest
```

Expected: `BUILD SUCCESS` — all 3 tests pass.

- [ ] **Step 2.9: Run full platform-api test suite**

```bash
mvn --batch-mode -pl platform-api test
```

Expected: `BUILD SUCCESS` — all existing tests still pass.

- [ ] **Step 2.10: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#98): add EndpointRegistered, AMQP enum, STREAM_EVENT_TYPE, cloudevents-core dep"
```

---

## Task 3 — endpoints-memory: constructor injection + EndpointRegistered firing

**Files:**
- Modify: `endpoints-memory/pom.xml`
- Modify: `endpoints-memory/src/main/java/io/casehub/platform/endpoints/memory/InMemoryEndpointRegistry.java`
- Create: `endpoints-memory/src/test/java/io/casehub/platform/endpoints/memory/InMemoryEndpointRegistryEventTest.java`

**Background:** `InMemoryEndpointRegistry` currently has no constructor and no CDI injection. All 14 existing unit tests use `new InMemoryEndpointRegistry()` directly (plain JUnit5, no CDI). Adding CDI field injection would NPE on all 14 tests. Use constructor injection with a package-private no-arg constructor for CDI proxy subclass + unit tests.

- [ ] **Step 3.1: Add Quarkus plugin and junit5 to endpoints-memory/pom.xml**

In `endpoints-memory/pom.xml`, add inside `<build><plugins>` (before the jandex plugin):

```xml
<!--
    generate-code + generate-code-tests only (no build goal) — library module.
    Required for @QuarkusTest in InMemoryEndpointRegistryEventTest.
-->
<plugin>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-maven-plugin</artifactId>
    <version>${quarkus.platform.version}</version>
    <extensions>true</extensions>
    <executions>
        <execution>
            <goals>
                <goal>generate-code</goal>
                <goal>generate-code-tests</goal>
            </goals>
        </execution>
    </executions>
</plugin>
```

And add `quarkus-junit5` test dep inside `<dependencies>`:

```xml
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-junit5</artifactId>
    <scope>test</scope>
</dependency>
```

- [ ] **Step 3.2: Write the failing @QuarkusTest**

Create `endpoints-memory/src/test/java/io/casehub/platform/endpoints/memory/InMemoryEndpointRegistryEventTest.java`:

```java
package io.casehub.platform.endpoints.memory;

import io.casehub.platform.api.endpoints.EndpointCapability;
import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointProtocol;
import io.casehub.platform.api.endpoints.EndpointPropertyKeys;
import io.casehub.platform.api.endpoints.EndpointRegistry;
import io.casehub.platform.api.endpoints.EndpointType;
import io.casehub.platform.api.path.Path;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThatCode;

/**
 * Verifies CDI wiring: when Event<EndpointRegistered> is injected, register()
 * completes without NPE. CDI async delivery is not testable in @QuarkusTest
 * (GE-20260513-b15933); what this test verifies is that the null guard is
 * bypassed (non-null event bus injected by CDI) and fireAsync() is invoked
 * without throwing.
 */
@QuarkusTest
class InMemoryEndpointRegistryEventTest {

    @Inject
    EndpointRegistry registry;   // CDI picks InMemoryEndpointRegistry @Alternative @Priority(100)

    @Test
    void register_completes_without_npe_when_event_bus_injected() {
        var desc = new EndpointDescriptor(
            Path.of("test", "endpoint"),
            "default-tenant",
            EndpointType.SERVICE,
            EndpointProtocol.HTTP,
            Map.of(EndpointPropertyKeys.URL, "https://example.com"),
            null,
            Set.of(EndpointCapability.SEND));

        assertThatCode(() -> registry.register(desc)).doesNotThrowAnyException();
    }
}
```

- [ ] **Step 3.3: Run test to verify it fails**

```bash
mvn --batch-mode -pl endpoints-memory test -Dtest=InMemoryEndpointRegistryEventTest
```

Expected: `BUILD FAILURE` — `InMemoryEndpointRegistry` has no `Event<EndpointRegistered>` field; `register()` has no null guard; CDI injection path may also fail compilation because `Event` is not yet imported. Let the compiler tell you the error.

- [ ] **Step 3.4: Update InMemoryEndpointRegistry — constructor injection + fireAsync**

Replace the existing `InMemoryEndpointRegistry.java` with:

```java
package io.casehub.platform.endpoints.memory;

import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointQuery;
import io.casehub.platform.api.endpoints.EndpointRegistered;
import io.casehub.platform.api.endpoints.EndpointRegistry;
import io.casehub.platform.api.identity.TenancyConstants;
import io.casehub.platform.api.path.Path;
import jakarta.annotation.Priority;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Event;
import jakarta.enterprise.inject.Alternative;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

import java.util.List;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Volatile in-memory {@link EndpointRegistry}.
 *
 * <p>Tier 4 in the CDI priority ladder — {@code @Alternative @Priority(100)} beats
 * both JPA (Tier 2) and NoSQL (Tier 3) when on the classpath, following
 * {@code persistence-backend-cdi-priority.md} (PP-20260522-0cfa30) convention.
 *
 * <p>Thread-safe. Data is ephemeral (lost on restart). Suitable for tests and
 * zero-config ephemeral single-node installs. Do NOT combine with a JPA or NoSQL
 * endpoints backend in the same deployment scope.
 *
 * <p>{@link EndpointRegistry#discover(EndpointQuery)} iteration is weakly consistent —
 * concurrent modifications (register/deregister) may or may not be visible to an
 * in-flight discover call. This is acceptable for the in-memory use case.
 *
 * <h2>EndpointRegistered CDI event</h2>
 * <p>Fires {@link EndpointRegistered} via {@code fireAsync()} after every successful
 * {@link #register(EndpointDescriptor)} call. Observer exceptions are WARN-logged;
 * the registry operation itself has already succeeded before the event fires.
 * The CDI-proxy path (and unit tests) use a package-private no-arg constructor
 * that leaves {@code endpointRegisteredEvent} null; the null guard in
 * {@code register()} prevents NPE in those paths.
 */
@Alternative
@Priority(100)
@ApplicationScoped
public class InMemoryEndpointRegistry implements EndpointRegistry {

    private static final Logger LOG = Logger.getLogger(InMemoryEndpointRegistry.class);

    private final ConcurrentHashMap<RegistryKey, EndpointDescriptor> store =
            new ConcurrentHashMap<>();

    private final Event<EndpointRegistered> endpointRegisteredEvent;

    @Inject
    public InMemoryEndpointRegistry(Event<EndpointRegistered> endpointRegisteredEvent) {
        this.endpointRegisteredEvent = endpointRegisteredEvent;
    }

    /** Used by CDI proxy subclass (synthetic bytecode) and plain JUnit5 unit tests (same package). */
    InMemoryEndpointRegistry() {
        this.endpointRegisteredEvent = null;
    }

    @Override
    public void register(final EndpointDescriptor endpoint) {
        store.put(new RegistryKey(endpoint.path().value(), endpoint.tenancyId()), endpoint);
        if (endpointRegisteredEvent != null) {
            endpointRegisteredEvent.fireAsync(new EndpointRegistered(endpoint))
                .whenComplete((e, t) -> {
                    if (t != null) {
                        LOG.warnf(t, "EndpointRegistered observer failed for path %s",
                            endpoint.path());
                    }
                });
        }
    }

    @Override
    public Optional<EndpointDescriptor> resolve(final Path path, final String tenancyId) {
        final EndpointDescriptor tenant = store.get(new RegistryKey(path.value(), tenancyId));
        if (tenant != null) return Optional.of(tenant);
        final EndpointDescriptor global = store.get(
                new RegistryKey(path.value(), TenancyConstants.PLATFORM_TENANT_ID));
        return Optional.ofNullable(global);
    }

    @Override
    public List<EndpointDescriptor> discover(final EndpointQuery query) {
        return store.values().stream()
                .filter(d -> matchesTenancy(d, query.tenancyId()))
                .filter(d -> query.type()     == null || d.type()     == query.type())
                .filter(d -> query.protocol() == null || d.protocol() == query.protocol())
                .filter(d -> d.capabilities().containsAll(query.requiredCapabilities()))
                .toList();
    }

    @Override
    public void deregister(final Path path, final String tenancyId) {
        store.remove(new RegistryKey(path.value(), tenancyId));
    }

    private static boolean matchesTenancy(final EndpointDescriptor d, final String tenancyId) {
        return d.tenancyId().equals(tenancyId)
                || d.tenancyId().equals(TenancyConstants.PLATFORM_TENANT_ID);
    }
}
```

- [ ] **Step 3.5: Run InMemoryEndpointRegistryEventTest**

```bash
mvn --batch-mode -pl endpoints-memory test -Dtest=InMemoryEndpointRegistryEventTest
```

Expected: `BUILD SUCCESS` — test passes (CDI wiring correct, register() completes without NPE).

- [ ] **Step 3.6: Run existing unit tests**

```bash
mvn --batch-mode -pl endpoints-memory test -Dtest=InMemoryEndpointRegistryTest
```

Expected: `BUILD SUCCESS` — all 14 existing tests pass. The package-private no-arg constructor is used by `new InMemoryEndpointRegistry()` in `@BeforeEach`; null guard prevents NPE.

- [ ] **Step 3.7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add endpoints-memory/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#98): InMemoryEndpointRegistry fires EndpointRegistered via constructor-injected Event<>"
```

---

## Task 4 — streams-kafka module

**Files:**
- Create: `streams-kafka/pom.xml`
- Create: `streams-kafka/src/main/java/io/casehub/platform/streams/kafka/KafkaStreamProcessor.java`
- Create: `streams-kafka/src/test/java/io/casehub/platform/streams/kafka/KafkaStreamProcessorTest.java`

**Design:** `@Startup @ApplicationScoped` bean. At `@Observes StartupEvent`, reads `mp.messaging.incoming.casehub-kafka-stream.topic` (or `.topics`) from MicroProfile Config, discovers KAFKA descriptors from the registry, builds a topic→descriptor map. The `@Incoming("casehub-kafka-stream")` method receives `Message<byte[]>`, extracts topic from `IncomingKafkaRecordMetadata`, looks up the descriptor, extracts `X-Tenancy-ID` header, builds a CloudEvent from scratch, fires it.

- [ ] **Step 4.1: Create pom.xml**

Create `streams-kafka/pom.xml`:

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

    <artifactId>casehub-platform-streams-kafka</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Streams — Kafka</name>
    <description>Classpath-activated Kafka stream ingestion module. Receives messages on
        a static SmallRye @Incoming channel (casehub-kafka-stream by default), always as
        raw byte[], and fires Event&lt;CloudEvent&gt;.fireAsync(). Does NOT observe
        EndpointRegistered — KAFKA descriptors must be registered before startup via
        endpoints-config YAML. For runtime-dynamic topics use streams-camel.
        No quarkus:build goal — library module.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-smallrye-reactive-messaging-kafka</artifactId>
        </dependency>

        <!-- Runtime: NoOpEndpointRegistry @DefaultBean for augmentation -->
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform</artifactId>
            <version>${project.version}</version>
            <scope>runtime</scope>
        </dependency>

        <!-- Test -->
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-junit5</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-endpoints-memory</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.quarkus</groupId>
                <artifactId>quarkus-maven-plugin</artifactId>
                <version>${quarkus.platform.version}</version>
                <extensions>true</extensions>
                <executions>
                    <execution>
                        <goals>
                            <goal>generate-code</goal>
                            <goal>generate-code-tests</goal>
                        </goals>
                    </execution>
                </executions>
            </plugin>
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

- [ ] **Step 4.2: Write the failing test**

Create `streams-kafka/src/test/java/io/casehub/platform/streams/kafka/KafkaStreamProcessorTest.java`:

```java
package io.casehub.platform.streams.kafka;

import io.casehub.platform.api.endpoints.EndpointCapability;
import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointPropertyKeys;
import io.casehub.platform.api.endpoints.EndpointProtocol;
import io.casehub.platform.api.endpoints.EndpointType;
import io.casehub.platform.api.identity.TenancyConstants;
import io.casehub.platform.api.path.Path;
import io.cloudevents.CloudEvent;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Unit tests for KafkaStreamProcessor.buildCloudEvent().
 * CDI async delivery is untestable in @QuarkusTest (GE-20260513-b15933);
 * we test the construction logic directly via the package-private method.
 */
class KafkaStreamProcessorTest {

    private final KafkaStreamProcessor processor = new KafkaStreamProcessor();

    private EndpointDescriptor descriptor(String streamType) {
        return new EndpointDescriptor(
            Path.of("streams", "iot-events"),
            TenancyConstants.DEFAULT_TENANT_ID,
            EndpointType.SYSTEM,
            EndpointProtocol.KAFKA,
            Map.of(EndpointPropertyKeys.TOPIC, "iot-temperature",
                   EndpointPropertyKeys.STREAM_EVENT_TYPE, streamType),
            null,
            Set.of(EndpointCapability.RECEIVE));
    }

    @Test
    void buildCloudEvent_sets_type_from_descriptor() {
        byte[] payload = "{}".getBytes(StandardCharsets.UTF_8);

        CloudEvent ce = processor.buildCloudEvent(payload, "iot-temperature", descriptor("io.casehub.iot.temperature"), "tenant-a");

        assertThat(ce.getType()).isEqualTo("io.casehub.iot.temperature");
    }

    @Test
    void buildCloudEvent_sets_tenancyid_from_header_when_present() {
        byte[] payload = "{}".getBytes(StandardCharsets.UTF_8);

        CloudEvent ce = processor.buildCloudEvent(payload, "iot-temperature", descriptor("io.casehub.iot.temperature"), "header-tenant");

        assertThat(ce.getExtension("tenancyid")).isEqualTo("header-tenant");
    }

    @Test
    void buildCloudEvent_falls_back_to_descriptor_tenancyid_when_header_absent() {
        byte[] payload = "{}".getBytes(StandardCharsets.UTF_8);

        CloudEvent ce = processor.buildCloudEvent(payload, "iot-temperature", descriptor("io.casehub.iot.temperature"), null);

        assertThat(ce.getExtension("tenancyid")).isEqualTo(TenancyConstants.DEFAULT_TENANT_ID);
    }

    @Test
    void buildCloudEvent_sets_data_to_raw_bytes() {
        byte[] payload = "hello".getBytes(StandardCharsets.UTF_8);

        CloudEvent ce = processor.buildCloudEvent(payload, "iot-temperature", descriptor("io.casehub.iot.temperature"), null);

        assertThat(ce.getData()).isNotNull();
        assertThat(new String(ce.getData().toBytes(), StandardCharsets.UTF_8)).isEqualTo("hello");
    }

    @Test
    void buildCloudEvent_source_contains_topic() {
        byte[] payload = new byte[0];

        CloudEvent ce = processor.buildCloudEvent(payload, "iot-temperature", descriptor("io.casehub.iot.temperature"), null);

        assertThat(ce.getSource().toString()).contains("iot-temperature");
    }

    @Test
    void buildCloudEvent_unregistered_type_used_when_no_descriptor() {
        byte[] payload = new byte[0];

        CloudEvent ce = processor.buildCloudEvent(payload, "unknown-topic", null, null);

        assertThat(ce.getType()).isEqualTo("io.casehub.platform.streams.kafka.unregistered");
    }
}
```

- [ ] **Step 4.3: Run test to verify it fails**

```bash
mvn --batch-mode -pl streams-kafka test -Dtest=KafkaStreamProcessorTest
```

Expected: `COMPILATION ERROR` — `KafkaStreamProcessor` and its `buildCloudEvent` method don't exist yet.

- [ ] **Step 4.4: Implement KafkaStreamProcessor**

Create `streams-kafka/src/main/java/io/casehub/platform/streams/kafka/KafkaStreamProcessor.java`:

```java
package io.casehub.platform.streams.kafka;

import io.casehub.platform.api.endpoints.EndpointCapability;
import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointPropertyKeys;
import io.casehub.platform.api.endpoints.EndpointProtocol;
import io.casehub.platform.api.endpoints.EndpointQuery;
import io.casehub.platform.api.endpoints.EndpointRegistry;
import io.casehub.platform.api.identity.TenancyConstants;
import io.casehub.platform.api.path.Path;
import io.cloudevents.CloudEvent;
import io.cloudevents.core.builder.CloudEventBuilder;
import io.quarkus.runtime.StartupEvent;
import io.smallrye.reactive.messaging.kafka.IncomingKafkaRecordMetadata;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Event;
import jakarta.enterprise.event.Observes;
import jakarta.inject.Inject;
import io.quarkus.runtime.Startup;
import org.apache.kafka.common.header.Header;
import org.eclipse.microprofile.config.ConfigProvider;
import org.eclipse.microprofile.reactive.messaging.Incoming;
import org.eclipse.microprofile.reactive.messaging.Message;
import org.jboss.logging.Logger;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.OffsetDateTime;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CompletionStage;

/**
 * Kafka stream ingestion processor.
 *
 * <p>Receives messages on a single static {@code @Incoming("casehub-kafka-stream")} channel.
 * Always receives as {@code Message<byte[]>} (P0 — no native CloudEvents deserialization).
 * Builds a CloudEvent from scratch and fires {@code Event<CloudEvent>.fireAsync()}.
 *
 * <p>Does NOT observe {@link io.casehub.platform.api.endpoints.EndpointRegistered} —
 * KAFKA descriptors must be registered before application startup via {@code endpoints-config}
 * YAML. For runtime-dynamic topics, use {@code streams-camel}.
 */
@Startup
@ApplicationScoped
public class KafkaStreamProcessor {

    private static final Logger LOG = Logger.getLogger(KafkaStreamProcessor.class);
    private static final String CHANNEL_NAME = "casehub-kafka-stream";
    private static final String UNREGISTERED_TYPE = "io.casehub.platform.streams.kafka.unregistered";

    @Inject
    EndpointRegistry endpointRegistry;

    @Inject
    Event<CloudEvent> cloudEventBus;

    /** topic → EndpointDescriptor, populated at startup. */
    private final Map<String, EndpointDescriptor> topicToDescriptor = new HashMap<>();

    void onStartup(@Observes StartupEvent ev) {
        String topicConfig = ConfigProvider.getConfig()
            .getOptionalValue("mp.messaging.incoming." + CHANNEL_NAME + ".topic", String.class)
            .or(() -> ConfigProvider.getConfig()
                .getOptionalValue("mp.messaging.incoming." + CHANNEL_NAME + ".topics", String.class))
            .orElse("");

        if (topicConfig.isBlank()) {
            LOG.warnf("No topic configured for channel '%s' — no KAFKA streams will be processed", CHANNEL_NAME);
            return;
        }

        var descriptors = endpointRegistry.discover(
            new EndpointQuery(TenancyConstants.DEFAULT_TENANT_ID, null, EndpointProtocol.KAFKA, Set.of(EndpointCapability.RECEIVE)));

        for (String raw : topicConfig.split(",")) {
            String topic = raw.strip();
            if (topic.isBlank()) continue;
            descriptors.stream()
                .filter(d -> topic.equals(d.properties().get(EndpointPropertyKeys.TOPIC)))
                .findFirst()
                .ifPresentOrElse(
                    d -> topicToDescriptor.put(topic, d),
                    () -> LOG.warnf("No EndpointDescriptor found for Kafka topic '%s'", topic));
        }
    }

    @Incoming(CHANNEL_NAME)
    public CompletionStage<Void> process(Message<byte[]> message) {
        Optional<IncomingKafkaRecordMetadata<?, byte[]>> meta =
            message.getMetadata(IncomingKafkaRecordMetadata.class);

        String topic = meta.map(m -> m.getRecord().topic()).orElse("unknown");

        String tenancyId = meta.map(m -> {
            Header header = m.getRecord().headers().lastHeader("X-Tenancy-ID");
            return header != null ? new String(header.value(), StandardCharsets.UTF_8) : null;
        }).orElse(null);

        EndpointDescriptor descriptor = topicToDescriptor.get(topic);
        CloudEvent ce = buildCloudEvent(message.getPayload(), topic, descriptor, tenancyId);

        return cloudEventBus.fireAsync(ce)
            .whenComplete((e, t) -> {
                if (t != null) LOG.warnf(t, "CloudEvent observer failed for Kafka topic %s", topic);
            })
            .thenCompose(ignored -> message.ack());
    }

    /**
     * Package-private: exposed for direct unit testing (CDI async delivery is
     * untestable in @QuarkusTest per GE-20260513-b15933).
     *
     * @param body       raw message bytes
     * @param topic      Kafka topic name
     * @param descriptor matched EndpointDescriptor, or {@code null} if unregistered
     * @param tenancyId  from Kafka header X-Tenancy-ID, or {@code null} to fall back to descriptor
     */
    CloudEvent buildCloudEvent(byte[] body, String topic, EndpointDescriptor descriptor, String tenancyId) {
        String type = descriptor != null
            ? descriptor.properties().getOrDefault(EndpointPropertyKeys.STREAM_EVENT_TYPE, UNREGISTERED_TYPE)
            : UNREGISTERED_TYPE;

        String effectiveTenancyId = tenancyId != null
            ? tenancyId
            : (descriptor != null ? descriptor.tenancyId() : TenancyConstants.DEFAULT_TENANT_ID);

        return CloudEventBuilder.v1()
            .withId(UUID.randomUUID().toString())
            .withType(type)
            .withSource(URI.create("/platform/streams/kafka/" + topic))
            .withTime(OffsetDateTime.now())
            .withData(body)
            .withExtension("tenancyid", effectiveTenancyId)
            .build();
    }
}
```

- [ ] **Step 4.5: Run unit tests**

```bash
mvn --batch-mode -pl streams-kafka test -Dtest=KafkaStreamProcessorTest
```

Expected: `BUILD SUCCESS` — all 6 tests pass.

- [ ] **Step 4.6: Run full module build**

```bash
mvn --batch-mode -pl streams-kafka install -DskipTests
```

Expected: `BUILD SUCCESS`.

- [ ] **Step 4.7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add streams-kafka/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#98): streams-kafka — classpath-activated Kafka stream ingestion"
```

---

## Task 5 — streams-amqp module

**Files:**
- Create: `streams-amqp/pom.xml`
- Create: `streams-amqp/src/main/java/io/casehub/platform/streams/amqp/AmqpStreamProcessor.java`
- Create: `streams-amqp/src/test/java/io/casehub/platform/streams/amqp/AmqpStreamProcessorTest.java`

**Design:** Broadly symmetric with streams-kafka. Key difference: SmallRye AMQP connector; `IncomingAmqpMetadata` for header extraction; single address per channel (no multi-address support); `EndpointProtocol.AMQP`.

- [ ] **Step 5.1: Create pom.xml**

Create `streams-amqp/pom.xml` — identical structure to streams-kafka's pom with:
- `<artifactId>casehub-platform-streams-amqp</artifactId>`
- `<name>CaseHub Platform Streams — AMQP</name>`
- `quarkus-smallrye-reactive-messaging-amqp` instead of `-kafka`
- Updated `<description>` referencing AMQP, single-address constraint, no multi-address support

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

    <artifactId>casehub-platform-streams-amqp</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Streams — AMQP</name>
    <description>Classpath-activated AMQP stream ingestion module. One address per channel
        (SmallRye AMQP does not support plural addresses like Kafka's topics=a,b; for
        multi-queue fan-in use streams-camel). Receives raw byte[], builds CloudEvent from
        scratch. Does NOT observe EndpointRegistered. No quarkus:build goal — library module.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-smallrye-reactive-messaging-amqp</artifactId>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform</artifactId>
            <version>${project.version}</version>
            <scope>runtime</scope>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-junit5</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-endpoints-memory</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.quarkus</groupId>
                <artifactId>quarkus-maven-plugin</artifactId>
                <version>${quarkus.platform.version}</version>
                <extensions>true</extensions>
                <executions>
                    <execution>
                        <goals>
                            <goal>generate-code</goal>
                            <goal>generate-code-tests</goal>
                        </goals>
                    </execution>
                </executions>
            </plugin>
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

- [ ] **Step 5.2: Write the failing test**

Create `streams-amqp/src/test/java/io/casehub/platform/streams/amqp/AmqpStreamProcessorTest.java`:

```java
package io.casehub.platform.streams.amqp;

import io.casehub.platform.api.endpoints.EndpointCapability;
import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointPropertyKeys;
import io.casehub.platform.api.endpoints.EndpointProtocol;
import io.casehub.platform.api.endpoints.EndpointType;
import io.casehub.platform.api.identity.TenancyConstants;
import io.casehub.platform.api.path.Path;
import io.cloudevents.CloudEvent;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class AmqpStreamProcessorTest {

    private final AmqpStreamProcessor processor = new AmqpStreamProcessor();

    private EndpointDescriptor descriptor(String queue, String streamType) {
        return new EndpointDescriptor(
            Path.of("streams", "amqp-events"),
            TenancyConstants.DEFAULT_TENANT_ID,
            EndpointType.SYSTEM,
            EndpointProtocol.AMQP,
            Map.of(EndpointPropertyKeys.TOPIC, queue,
                   EndpointPropertyKeys.STREAM_EVENT_TYPE, streamType),
            null,
            Set.of(EndpointCapability.RECEIVE));
    }

    @Test
    void buildCloudEvent_sets_type_from_descriptor() {
        CloudEvent ce = processor.buildCloudEvent(new byte[0], descriptor("orders", "io.casehub.orders.placed"), "tenant-a");
        assertThat(ce.getType()).isEqualTo("io.casehub.orders.placed");
    }

    @Test
    void buildCloudEvent_uses_header_tenancyid_when_present() {
        CloudEvent ce = processor.buildCloudEvent(new byte[0], descriptor("orders", "io.casehub.orders.placed"), "hdr-tenant");
        assertThat(ce.getExtension("tenancyid")).isEqualTo("hdr-tenant");
    }

    @Test
    void buildCloudEvent_falls_back_to_descriptor_tenancyid_when_header_absent() {
        CloudEvent ce = processor.buildCloudEvent(new byte[0], descriptor("orders", "io.casehub.orders.placed"), null);
        assertThat(ce.getExtension("tenancyid")).isEqualTo(TenancyConstants.DEFAULT_TENANT_ID);
    }

    @Test
    void buildCloudEvent_source_is_amqp_prefixed() {
        CloudEvent ce = processor.buildCloudEvent(new byte[0], descriptor("orders", "io.casehub.orders.placed"), null);
        assertThat(ce.getSource().toString()).startsWith("/platform/streams/amqp/");
    }

    @Test
    void buildCloudEvent_data_contains_raw_bytes() {
        byte[] payload = "test".getBytes(StandardCharsets.UTF_8);
        CloudEvent ce = processor.buildCloudEvent(payload, descriptor("orders", "io.casehub.orders.placed"), null);
        assertThat(new String(ce.getData().toBytes(), StandardCharsets.UTF_8)).isEqualTo("test");
    }
}
```

- [ ] **Step 5.3: Run test to verify it fails**

```bash
mvn --batch-mode -pl streams-amqp test -Dtest=AmqpStreamProcessorTest
```

Expected: `COMPILATION ERROR` — `AmqpStreamProcessor` doesn't exist yet.

- [ ] **Step 5.4: Implement AmqpStreamProcessor**

Create `streams-amqp/src/main/java/io/casehub/platform/streams/amqp/AmqpStreamProcessor.java`:

```java
package io.casehub.platform.streams.amqp;

import io.casehub.platform.api.endpoints.EndpointCapability;
import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointPropertyKeys;
import io.casehub.platform.api.endpoints.EndpointProtocol;
import io.casehub.platform.api.endpoints.EndpointQuery;
import io.casehub.platform.api.endpoints.EndpointRegistry;
import io.casehub.platform.api.identity.TenancyConstants;
import io.cloudevents.CloudEvent;
import io.cloudevents.core.builder.CloudEventBuilder;
import io.quarkus.runtime.Startup;
import io.quarkus.runtime.StartupEvent;
import io.smallrye.reactive.messaging.amqp.IncomingAmqpMetadata;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Event;
import jakarta.enterprise.event.Observes;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.ConfigProvider;
import org.eclipse.microprofile.reactive.messaging.Incoming;
import org.eclipse.microprofile.reactive.messaging.Message;
import org.jboss.logging.Logger;

import java.net.URI;
import java.time.OffsetDateTime;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CompletionStage;

/**
 * AMQP stream ingestion processor.
 *
 * <p>Single address per channel (SmallRye AMQP connector has no plural-address
 * equivalent to Kafka's {@code topics=a,b}). Does NOT observe
 * {@link io.casehub.platform.api.endpoints.EndpointRegistered}.
 */
@Startup
@ApplicationScoped
public class AmqpStreamProcessor {

    private static final Logger LOG = Logger.getLogger(AmqpStreamProcessor.class);
    private static final String CHANNEL_NAME = "casehub-amqp-stream";

    @Inject
    EndpointRegistry endpointRegistry;

    @Inject
    Event<CloudEvent> cloudEventBus;

    private final Map<String, EndpointDescriptor> addressToDescriptor = new HashMap<>();

    void onStartup(@Observes StartupEvent ev) {
        String addressConfig = ConfigProvider.getConfig()
            .getOptionalValue("mp.messaging.incoming." + CHANNEL_NAME + ".address", String.class)
            .orElse("");

        if (addressConfig.isBlank()) {
            LOG.warnf("No address configured for AMQP channel '%s'", CHANNEL_NAME);
            return;
        }

        endpointRegistry.discover(
            new EndpointQuery(TenancyConstants.DEFAULT_TENANT_ID, null, EndpointProtocol.AMQP, Set.of(EndpointCapability.RECEIVE)))
            .stream()
            .filter(d -> addressConfig.equals(d.properties().get(EndpointPropertyKeys.TOPIC)))
            .findFirst()
            .ifPresentOrElse(
                d -> addressToDescriptor.put(addressConfig, d),
                () -> LOG.warnf("No descriptor found for AMQP address '%s'", addressConfig));
    }

    @Incoming(CHANNEL_NAME)
    public CompletionStage<Void> process(Message<byte[]> message) {
        Optional<IncomingAmqpMetadata> meta = message.getMetadata(IncomingAmqpMetadata.class);

        String address = meta.map(m -> m.getMessage().getAddress()).orElse("unknown");

        Object tenancyHeader = meta.map(m -> m.getMessage().getApplicationProperties())
            .map(p -> p.getValue().get("X-Tenancy-ID"))
            .orElse(null);
        String tenancyId = tenancyHeader != null ? tenancyHeader.toString() : null;

        EndpointDescriptor descriptor = addressToDescriptor.get(address);
        CloudEvent ce = buildCloudEvent(message.getPayload(), descriptor, tenancyId);

        return cloudEventBus.fireAsync(ce)
            .whenComplete((e, t) -> {
                if (t != null) LOG.warnf(t, "CloudEvent observer failed for AMQP address %s", address);
            })
            .thenCompose(ignored -> message.ack());
    }

    /**
     * Package-private for direct unit testing.
     */
    CloudEvent buildCloudEvent(byte[] body, EndpointDescriptor descriptor, String tenancyId) {
        String type = descriptor != null
            ? descriptor.properties().getOrDefault(EndpointPropertyKeys.STREAM_EVENT_TYPE, "io.casehub.platform.streams.amqp.unregistered")
            : "io.casehub.platform.streams.amqp.unregistered";

        String address = descriptor != null
            ? descriptor.properties().getOrDefault(EndpointPropertyKeys.TOPIC, "unknown")
            : "unknown";

        String effectiveTenancyId = tenancyId != null
            ? tenancyId
            : (descriptor != null ? descriptor.tenancyId() : TenancyConstants.DEFAULT_TENANT_ID);

        return CloudEventBuilder.v1()
            .withId(UUID.randomUUID().toString())
            .withType(type)
            .withSource(URI.create("/platform/streams/amqp/" + address))
            .withTime(OffsetDateTime.now())
            .withData(body)
            .withExtension("tenancyid", effectiveTenancyId)
            .build();
    }
}
```

- [ ] **Step 5.5: Run unit tests**

```bash
mvn --batch-mode -pl streams-amqp test -Dtest=AmqpStreamProcessorTest
```

Expected: `BUILD SUCCESS`.

- [ ] **Step 5.6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add streams-amqp/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#98): streams-amqp — classpath-activated AMQP stream ingestion"
```

---

## Task 6 — streams-webhook module

**Files:**
- Create: `streams-webhook/pom.xml`
- Create: `streams-webhook/src/main/java/io/casehub/platform/streams/webhook/WebhookResource.java`
- Create: `streams-webhook/src/test/java/io/casehub/platform/streams/webhook/WebhookResourceTest.java`

**Design:** `@Startup @ApplicationScoped` JAX-RS resource. `@PostConstruct` resolves `EventFormatProvider`, registers the physical webhook receiver in `EndpointRegistry`. `@POST /{tenancyId}/{streamId}` accepts `byte[]`, deserializes via `EventFormat.deserialize()`, resolves logical stream descriptor, builds enriched CloudEvent preserving all fields and setting `tenancyid` from descriptor.

- [ ] **Step 6.1: Create pom.xml**

Create `streams-webhook/pom.xml`:

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

    <artifactId>casehub-platform-streams-webhook</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Streams — Webhook</name>
    <description>CloudEvents HTTP binding receiver. Accepts POST /streams/webhook/{tenancyId}/{streamId}
        with application/cloudevents+json. Preserves incoming CloudEvent fields; enriches tenancyid
        from the registered EndpointDescriptor (caller-supplied tenancyid is overridden).
        Requires casehub.streams.webhook.public-url config (fail-fast if absent).
        No quarkus:build goal — library module.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-rest-jackson</artifactId>
        </dependency>
        <dependency>
            <groupId>io.cloudevents</groupId>
            <artifactId>cloudevents-json-jackson</artifactId>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform</artifactId>
            <version>${project.version}</version>
            <scope>runtime</scope>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-junit5</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-rest-client-jackson</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.rest-assured</groupId>
            <artifactId>rest-assured</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-endpoints-memory</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.quarkus</groupId>
                <artifactId>quarkus-maven-plugin</artifactId>
                <version>${quarkus.platform.version}</version>
                <extensions>true</extensions>
                <executions>
                    <execution>
                        <goals>
                            <goal>generate-code</goal>
                            <goal>generate-code-tests</goal>
                        </goals>
                    </execution>
                </executions>
            </plugin>
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

- [ ] **Step 6.2: Write the failing test**

Create `streams-webhook/src/test/java/io/casehub/platform/streams/webhook/WebhookResourceTest.java`:

```java
package io.casehub.platform.streams.webhook;

import io.casehub.platform.api.endpoints.EndpointCapability;
import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointPropertyKeys;
import io.casehub.platform.api.endpoints.EndpointProtocol;
import io.casehub.platform.api.endpoints.EndpointRegistry;
import io.casehub.platform.api.endpoints.EndpointType;
import io.casehub.platform.api.identity.TenancyConstants;
import io.casehub.platform.api.path.Path;
import io.quarkus.test.junit.QuarkusTest;
import io.restassured.RestAssured;
import jakarta.inject.Inject;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Set;

import static org.hamcrest.Matchers.equalTo;

@QuarkusTest
class WebhookResourceTest {

    @Inject
    EndpointRegistry endpointRegistry;

    @BeforeEach
    void registerStream() {
        endpointRegistry.register(new EndpointDescriptor(
            Path.of("streams", "my-stream"),
            TenancyConstants.DEFAULT_TENANT_ID,
            EndpointType.SERVICE,
            EndpointProtocol.HTTP,
            Map.of(EndpointPropertyKeys.STREAM_EVENT_TYPE, "io.casehub.test.event",
                   EndpointPropertyKeys.URL, "https://external.example.com/my-stream"),
            null,
            Set.of(EndpointCapability.RECEIVE)));
    }

    @Test
    void receive_valid_cloudevent_returns_202() {
        String body = """
            {
              "specversion": "1.0",
              "type": "io.example.event",
              "source": "https://example.com",
              "id": "test-id-1",
              "data": {"key": "value"}
            }
            """;

        RestAssured.given()
            .contentType("application/cloudevents+json")
            .body(body)
            .when()
            .post("/streams/webhook/" + TenancyConstants.DEFAULT_TENANT_ID + "/my-stream")
            .then()
            .statusCode(202);
    }

    @Test
    void receive_invalid_body_returns_400() {
        RestAssured.given()
            .contentType("application/cloudevents+json")
            .body("not-valid-json")
            .when()
            .post("/streams/webhook/" + TenancyConstants.DEFAULT_TENANT_ID + "/my-stream")
            .then()
            .statusCode(400);
    }

    @Test
    void receive_unknown_stream_returns_404() {
        String body = """
            {"specversion":"1.0","type":"t","source":"s","id":"x"}
            """;

        RestAssured.given()
            .contentType("application/cloudevents+json")
            .body(body)
            .when()
            .post("/streams/webhook/" + TenancyConstants.DEFAULT_TENANT_ID + "/no-such-stream")
            .then()
            .statusCode(404);
    }

    @Test
    void receive_wrong_content_type_returns_415() {
        RestAssured.given()
            .contentType("application/json")
            .body("{}")
            .when()
            .post("/streams/webhook/" + TenancyConstants.DEFAULT_TENANT_ID + "/my-stream")
            .then()
            .statusCode(415);
    }
}
```

Add `src/test/resources/application.properties` for webhook tests:

```properties
casehub.streams.webhook.public-url=http://localhost:8081/streams/webhook
quarkus.arc.exclude-types=io.casehub.platform.mock.MockCurrentPrincipal
```

- [ ] **Step 6.3: Run test to verify it fails**

```bash
mvn --batch-mode -pl streams-webhook test -Dtest=WebhookResourceTest
```

Expected: `COMPILATION ERROR` — `WebhookResource` doesn't exist.

- [ ] **Step 6.4: Implement WebhookResource**

Create `streams-webhook/src/main/java/io/casehub/platform/streams/webhook/WebhookResource.java`:

```java
package io.casehub.platform.streams.webhook;

import io.casehub.platform.api.endpoints.EndpointCapability;
import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointPropertyKeys;
import io.casehub.platform.api.endpoints.EndpointProtocol;
import io.casehub.platform.api.endpoints.EndpointRegistry;
import io.casehub.platform.api.endpoints.EndpointType;
import io.casehub.platform.api.identity.TenancyConstants;
import io.casehub.platform.api.path.Path;
import io.cloudevents.CloudEvent;
import io.cloudevents.core.builder.CloudEventBuilder;
import io.cloudevents.core.format.EventFormat;
import io.cloudevents.core.provider.EventFormatProvider;
import io.cloudevents.jackson.JsonFormat;
import io.quarkus.runtime.Startup;
import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Event;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.util.Map;
import java.util.Optional;
import java.util.Set;

/**
 * CloudEvents HTTP binding receiver.
 *
 * <p>Accepts structured CloudEvents ({@code application/cloudevents+json}) only (P0).
 * Binary CloudEvents (ce-* headers) deferred to P1+.
 *
 * <p>{@link #publicUrl} is required — Quarkus throws {@code DeploymentException} at
 * startup if {@code casehub.streams.webhook.public-url} is absent.
 *
 * <p>Incoming CloudEvent fields are preserved; only {@code tenancyid} is set/replaced
 * from the registered {@link EndpointDescriptor} (caller-supplied value is overridden).
 *
 * <p>@Startup forces eager {@code @PostConstruct} so the EventFormat is resolved and
 * the physical receiver is registered before the first HTTP request arrives.
 */
@Startup
@ApplicationScoped
@jakarta.ws.rs.Path("/streams/webhook")
public class WebhookResource {

    private static final Logger LOG = Logger.getLogger(WebhookResource.class);

    @Inject
    Event<CloudEvent> cloudEventBus;

    @Inject
    EndpointRegistry endpointRegistry;

    @ConfigProperty(name = "casehub.streams.webhook.public-url")
    String publicUrl;   // required — Quarkus DeploymentException at startup if absent

    private EventFormat eventFormat;

    @PostConstruct
    void init() {
        // Validate CloudEvents format registration
        eventFormat = EventFormatProvider.getInstance().resolveFormat(JsonFormat.CONTENT_TYPE);
        if (eventFormat == null) {
            throw new IllegalStateException(
                "CloudEvents JSON format not registered — cloudevents-json-jackson missing from classpath");
        }

        // Self-register the physical webhook receiver as a platform-global endpoint.
        // PLATFORM_TENANT_ID makes it visible in all tenant-scoped discover() calls.
        endpointRegistry.register(new EndpointDescriptor(
            Path.of("platform", "streams", "webhook"),
            TenancyConstants.PLATFORM_TENANT_ID,
            EndpointType.SERVICE,
            EndpointProtocol.HTTP,
            Map.of(EndpointPropertyKeys.URL, publicUrl),
            null,
            Set.of(EndpointCapability.RECEIVE)));
    }

    @POST
    @jakarta.ws.rs.Path("/{tenancyId}/{streamId}")
    @Consumes("application/cloudevents+json")
    public Response receive(
            byte[] body,
            @PathParam("tenancyId") String tenancyIdFromPath,
            @PathParam("streamId") String streamId) {

        CloudEvent incoming;
        try {
            incoming = eventFormat.deserialize(body);
        } catch (RuntimeException e) {
            return Response.status(400)
                .entity("Invalid CloudEvent body: " + e.getMessage())
                .build();
        }

        Optional<EndpointDescriptor> descriptor =
            endpointRegistry.resolve(Path.of("streams", streamId), tenancyIdFromPath);
        if (descriptor.isEmpty()) {
            return Response.status(404).build();
        }

        // Preserve all incoming fields; set/replace tenancyid from operator-authoritative descriptor.
        CloudEvent enriched = CloudEventBuilder.from(incoming)
            .withExtension("tenancyid", descriptor.get().tenancyId())
            .build();

        cloudEventBus.fireAsync(enriched)
            .whenComplete((e, t) -> {
                if (t != null) LOG.warnf(t, "CloudEvent observer failed for stream %s", streamId);
            });

        return Response.accepted().build();
    }
}
```

- [ ] **Step 6.5: Run tests**

```bash
mvn --batch-mode -pl streams-webhook test
```

Expected: `BUILD SUCCESS` — all 4 tests pass.

- [ ] **Step 6.6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add streams-webhook/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#98): streams-webhook — CloudEvents HTTP binding receiver"
```

---

## Task 7 — streams-poll module

**Files:**
- Create: `streams-poll/pom.xml`
- Create: `streams-poll/src/main/java/io/casehub/platform/streams/poll/PollStreamProcessor.java`
- Create: `streams-poll/src/test/java/io/casehub/platform/streams/poll/PollStreamProcessorTest.java`
- Create: `streams-poll/src/test/resources/application.properties`

**Design:** `@Startup @ApplicationScoped` bean with `@Scheduled`. Uses `java.net.http.HttpClient` as a class field. `pollAndFire()` explicitly checks HTTP status code; catches `InterruptedException` with thread re-interrupt; catches per-endpoint exceptions in poll loop. P0: platform-global `HTTP + QUERY` endpoints only.

- [ ] **Step 7.1: Create pom.xml**

Create `streams-poll/pom.xml`:

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

    <artifactId>casehub-platform-streams-poll</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Streams — Poll</name>
    <description>Scheduled HTTP GET polling of EndpointRegistry HTTP+QUERY endpoints.
        Uses java.net.http.HttpClient (no extra dep). Explicit HTTP status code check
        (HttpClient.send() does not throw for 4xx/5xx). Per-endpoint failure handling.
        No quarkus:build goal — library module.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-scheduler</artifactId>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform</artifactId>
            <version>${project.version}</version>
            <scope>runtime</scope>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-junit5</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.wiremock</groupId>
            <artifactId>wiremock</artifactId>
            <version>3.13.0</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-endpoints-memory</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.quarkus</groupId>
                <artifactId>quarkus-maven-plugin</artifactId>
                <version>${quarkus.platform.version}</version>
                <extensions>true</extensions>
                <executions>
                    <execution>
                        <goals>
                            <goal>generate-code</goal>
                            <goal>generate-code-tests</goal>
                        </goals>
                    </execution>
                </executions>
            </plugin>
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

- [ ] **Step 7.2: Write the failing test**

Create `streams-poll/src/test/java/io/casehub/platform/streams/poll/PollStreamProcessorTest.java`:

```java
package io.casehub.platform.streams.poll;

import com.github.tomakehurst.wiremock.WireMockServer;
import io.casehub.platform.api.endpoints.EndpointCapability;
import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointPropertyKeys;
import io.casehub.platform.api.endpoints.EndpointProtocol;
import io.casehub.platform.api.endpoints.EndpointType;
import io.casehub.platform.api.identity.TenancyConstants;
import io.casehub.platform.api.path.Path;
import io.cloudevents.CloudEvent;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.util.Map;
import java.util.Set;

import static com.github.tomakehurst.wiremock.client.WireMock.*;
import static com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Unit tests for PollStreamProcessor.pollAndFire() — tests the HTTP polling
 * and CloudEvent construction logic directly without CDI.
 */
class PollStreamProcessorTest {

    private WireMockServer wireMock;
    private PollStreamProcessor processor;

    @BeforeEach
    void setUp() {
        wireMock = new WireMockServer(wireMockConfig().dynamicPort());
        wireMock.start();
        processor = new PollStreamProcessor();
    }

    @AfterEach
    void tearDown() {
        wireMock.stop();
    }

    private EndpointDescriptor descriptor(String url, String streamType) {
        return new EndpointDescriptor(
            Path.of("streams", "sensor-data"),
            TenancyConstants.DEFAULT_TENANT_ID,
            EndpointType.SYSTEM,
            EndpointProtocol.HTTP,
            Map.of(EndpointPropertyKeys.URL, url,
                   EndpointPropertyKeys.STREAM_EVENT_TYPE, streamType),
            null,
            Set.of(EndpointCapability.QUERY));
    }

    @Test
    void pollAndFire_builds_cloudevent_from_200_response() throws IOException {
        wireMock.stubFor(get(urlEqualTo("/data"))
            .willReturn(aResponse().withStatus(200).withBody("{\"temp\":22}")));

        EndpointDescriptor desc = descriptor("http://localhost:" + wireMock.port() + "/data",
            "io.casehub.sensor.temperature");

        CloudEvent ce = processor.buildCloudEvent("{\"temp\":22}".getBytes(), desc);

        assertThat(ce.getType()).isEqualTo("io.casehub.sensor.temperature");
        assertThat(ce.getExtension("tenancyid")).isEqualTo(TenancyConstants.DEFAULT_TENANT_ID);
    }

    @Test
    void pollAndFire_throws_IOException_on_non_2xx() {
        wireMock.stubFor(get(urlEqualTo("/data"))
            .willReturn(aResponse().withStatus(503).withBody("Service Unavailable")));

        EndpointDescriptor desc = descriptor("http://localhost:" + wireMock.port() + "/data",
            "io.casehub.sensor.temperature");

        assertThatThrownBy(() -> processor.pollAndFire(desc))
            .isInstanceOf(IOException.class)
            .hasMessageContaining("503");
    }

    @Test
    void pollAndFire_throws_IOException_on_404() throws Exception {
        wireMock.stubFor(get(urlEqualTo("/data"))
            .willReturn(aResponse().withStatus(404)));

        EndpointDescriptor desc = descriptor("http://localhost:" + wireMock.port() + "/data",
            "io.casehub.sensor.temperature");

        assertThatThrownBy(() -> processor.pollAndFire(desc))
            .isInstanceOf(IOException.class)
            .hasMessageContaining("404");
    }

    @Test
    void buildCloudEvent_type_from_descriptor() throws IOException {
        byte[] body = "data".getBytes();
        EndpointDescriptor desc = descriptor("http://localhost/data", "io.casehub.iot.temp");

        CloudEvent ce = processor.buildCloudEvent(body, desc);

        assertThat(ce.getType()).isEqualTo("io.casehub.iot.temp");
    }

    @Test
    void buildCloudEvent_source_is_poll_prefixed() throws IOException {
        CloudEvent ce = processor.buildCloudEvent(new byte[0],
            descriptor("http://example.com/api", "io.casehub.test"));
        assertThat(ce.getSource().toString()).startsWith("/platform/streams/poll/");
    }
}
```

- [ ] **Step 7.3: Run test to verify it fails**

```bash
mvn --batch-mode -pl streams-poll test -Dtest=PollStreamProcessorTest
```

Expected: `COMPILATION ERROR` — `PollStreamProcessor` doesn't exist yet.

- [ ] **Step 7.4: Implement PollStreamProcessor**

Create `streams-poll/src/main/java/io/casehub/platform/streams/poll/PollStreamProcessor.java`:

```java
package io.casehub.platform.streams.poll;

import io.casehub.platform.api.endpoints.EndpointCapability;
import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointPropertyKeys;
import io.casehub.platform.api.endpoints.EndpointProtocol;
import io.casehub.platform.api.endpoints.EndpointQuery;
import io.casehub.platform.api.endpoints.EndpointRegistry;
import io.casehub.platform.api.identity.TenancyConstants;
import io.cloudevents.CloudEvent;
import io.cloudevents.core.builder.CloudEventBuilder;
import io.quarkus.runtime.Startup;
import io.quarkus.scheduler.Scheduled;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Event;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpResponse.BodyHandlers;
import java.nio.charset.StandardCharsets;
import java.time.OffsetDateTime;
import java.util.Set;
import java.util.UUID;

/**
 * Scheduled HTTP GET poller.
 *
 * <p>Discovers {@link EndpointProtocol#HTTP} + {@link EndpointCapability#QUERY} endpoints
 * registered under {@link TenancyConstants#DEFAULT_TENANT_ID} (P0 — platform-global only).
 *
 * <p>{@link HttpClient#send(HttpRequest, HttpResponse.BodyHandler)} throws
 * {@code IOException} only for connection-level failures. HTTP 4xx/5xx responses are
 * returned as successful {@code HttpResponse<byte[]>} objects — the status code must be
 * checked explicitly. Swallowing {@code InterruptedException} without re-interrupting
 * would break Quarkus scheduler shutdown; always call
 * {@code Thread.currentThread().interrupt()} before re-throwing.
 */
@Startup
@ApplicationScoped
public class PollStreamProcessor {

    private static final Logger LOG = Logger.getLogger(PollStreamProcessor.class);

    @Inject
    EndpointRegistry endpointRegistry;

    @Inject
    Event<CloudEvent> cloudEventBus;

    // Class field — connection pool reused across poll cycles; per-call creation discards pool
    private final HttpClient httpClient = HttpClient.newHttpClient();

    @Scheduled(every = "${casehub.streams.poll.interval:60s}")
    void poll() {
        endpointRegistry.discover(
            new EndpointQuery(TenancyConstants.DEFAULT_TENANT_ID, null, EndpointProtocol.HTTP, Set.of(EndpointCapability.QUERY))
        ).forEach(descriptor -> {
            try {
                pollAndFire(descriptor);
            } catch (Exception e) {
                LOG.warnf(e, "Poll failed for endpoint %s — continuing to next endpoint",
                    descriptor.properties().get(EndpointPropertyKeys.URL));
            }
        });
    }

    /**
     * Package-private for direct unit testing.
     *
     * <p>HttpClient.send() throws IOException for connection errors and
     * InterruptedException if the thread is interrupted. Neither is thrown for
     * HTTP 4xx/5xx — those are returned as successful responses and require an
     * explicit status code check.
     */
    void pollAndFire(EndpointDescriptor descriptor) throws IOException {
        String url = descriptor.properties().get(EndpointPropertyKeys.URL);
        HttpRequest request = HttpRequest.newBuilder().GET().uri(URI.create(url)).build();
        HttpResponse<byte[]> response;
        try {
            response = httpClient.send(request, BodyHandlers.ofByteArray());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();                         // preserve interrupt flag
            throw new IOException("Poll interrupted for " + url, e);  // caught by poll loop
        }
        if (response.statusCode() < 200 || response.statusCode() >= 300) {
            throw new IOException("Poll returned HTTP " + response.statusCode() + " for " + url);
        }

        CloudEvent ce = buildCloudEvent(response.body(), descriptor);
        cloudEventBus.fireAsync(ce)
            .whenComplete((e, t) -> {
                if (t != null) LOG.warnf(t, "CloudEvent observer failed for poll endpoint %s", url);
            });
    }

    /**
     * Package-private for direct unit testing.
     */
    CloudEvent buildCloudEvent(byte[] body, EndpointDescriptor descriptor) {
        String type = descriptor.properties().getOrDefault(
            EndpointPropertyKeys.STREAM_EVENT_TYPE,
            "io.casehub.platform.streams.poll.unregistered");

        String urlEncoded = URLEncoder.encode(
            descriptor.properties().getOrDefault(EndpointPropertyKeys.URL, "unknown"),
            StandardCharsets.UTF_8);

        return CloudEventBuilder.v1()
            .withId(UUID.randomUUID().toString())
            .withType(type)
            .withSource(URI.create("/platform/streams/poll/" + urlEncoded))
            .withTime(OffsetDateTime.now())
            .withData(body)
            .withExtension("tenancyid", descriptor.tenancyId())
            .build();
    }
}
```

- [ ] **Step 7.5: Run tests**

```bash
mvn --batch-mode -pl streams-poll test -Dtest=PollStreamProcessorTest
```

Expected: `BUILD SUCCESS`.

- [ ] **Step 7.6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add streams-poll/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#98): streams-poll — scheduled HTTP GET poller with explicit status code check"
```

---

## Task 8 — streams-camel module

**Files:**
- Create: `streams-camel/pom.xml`
- Create: `streams-camel/src/main/java/io/casehub/platform/streams/camel/CamelStreamProcessor.java`
- Create: `streams-camel/src/test/java/io/casehub/platform/streams/camel/CamelStreamProcessorTest.java`
- Create: `streams-camel/src/test/resources/application.properties`

**Design:** `@ApplicationScoped` bean observing `@ObservesAsync EndpointRegistered` for `EndpointProtocol.CAMEL` endpoints. At `@Observes StartupEvent` discovers all pre-startup CAMEL descriptors from the registry and adds Camel routes. Idempotency via `ConcurrentHashMap.newKeySet()`. `CamelContext.addRoutes()` throws `Exception` — wrapped in RuntimeException; in `onStartup` this aborts startup with fail-fast; in async observer it propagates through CDI executor to WARN log.

- [ ] **Step 8.1: Create pom.xml**

Create `streams-camel/pom.xml`:

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

    <artifactId>casehub-platform-streams-camel</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Streams — Camel</name>
    <description>Dynamic Camel route builder for runtime-registered CAMEL endpoints.
        Observes EndpointRegistered for CAMEL protocol; discovers pre-startup endpoints at StartupEvent.
        P0 constraint: changing a Camel endpoint URI requires restart (old route is not stopped).
        CAMEL and KAFKA are mutually exclusive for the same Kafka topic: running both from the same
        consumer group causes silent message loss (Kafka partition-splits between two groups).
        Consumer application must add Camel component deps (e.g. camel-quarkus-kafka).
        No quarkus:build goal — library module.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>org.apache.camel.quarkus</groupId>
            <artifactId>camel-quarkus-core</artifactId>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform</artifactId>
            <version>${project.version}</version>
            <scope>runtime</scope>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-junit5</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.apache.camel.quarkus</groupId>
            <artifactId>camel-quarkus-mock</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-endpoints-memory</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.quarkus</groupId>
                <artifactId>quarkus-maven-plugin</artifactId>
                <version>${quarkus.platform.version}</version>
                <extensions>true</extensions>
                <executions>
                    <execution>
                        <goals>
                            <goal>generate-code</goal>
                            <goal>generate-code-tests</goal>
                        </goals>
                    </execution>
                </executions>
            </plugin>
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

- [ ] **Step 8.2: Write the failing test**

Create `streams-camel/src/test/java/io/casehub/platform/streams/camel/CamelStreamProcessorTest.java`:

```java
package io.casehub.platform.streams.camel;

import io.casehub.platform.api.endpoints.EndpointCapability;
import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointPropertyKeys;
import io.casehub.platform.api.endpoints.EndpointProtocol;
import io.casehub.platform.api.endpoints.EndpointType;
import io.casehub.platform.api.identity.TenancyConstants;
import io.casehub.platform.api.path.Path;
import io.cloudevents.CloudEvent;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Unit tests for CamelStreamProcessor.buildCloudEvent().
 * Route creation tests require a live CamelContext and belong in @QuarkusTest.
 * CDI async delivery is untestable in @QuarkusTest (GE-20260513-b15933).
 */
class CamelStreamProcessorTest {

    private final CamelStreamProcessor processor = new CamelStreamProcessor();

    private EndpointDescriptor descriptor(String uri, String streamType) {
        return new EndpointDescriptor(
            Path.of("streams", "camel-data"),
            TenancyConstants.DEFAULT_TENANT_ID,
            EndpointType.WORKER,
            EndpointProtocol.CAMEL,
            Map.of(EndpointPropertyKeys.URL, uri,
                   EndpointPropertyKeys.STREAM_EVENT_TYPE, streamType),
            null,
            Set.of(EndpointCapability.RECEIVE));
    }

    @Test
    void buildCloudEvent_type_from_descriptor() {
        CloudEvent ce = processor.buildCloudEvent(new byte[0], descriptor("direct:test", "io.casehub.camel.event"));
        assertThat(ce.getType()).isEqualTo("io.casehub.camel.event");
    }

    @Test
    void buildCloudEvent_tenancyid_from_descriptor() {
        CloudEvent ce = processor.buildCloudEvent(new byte[0], descriptor("direct:test", "io.casehub.camel.event"));
        assertThat(ce.getExtension("tenancyid")).isEqualTo(TenancyConstants.DEFAULT_TENANT_ID);
    }

    @Test
    void buildCloudEvent_source_contains_camel() {
        CloudEvent ce = processor.buildCloudEvent(new byte[0], descriptor("direct:test", "io.casehub.camel.event"));
        assertThat(ce.getSource().toString()).contains("camel");
    }

    @Test
    void buildCloudEvent_data_is_raw_bytes() {
        byte[] payload = "payload".getBytes();
        CloudEvent ce = processor.buildCloudEvent(payload, descriptor("direct:test", "io.casehub.camel.event"));
        assertThat(ce.getData().toBytes()).isEqualTo(payload);
    }
}
```

- [ ] **Step 8.3: Run test to verify it fails**

```bash
mvn --batch-mode -pl streams-camel test -Dtest=CamelStreamProcessorTest
```

Expected: `COMPILATION ERROR`.

- [ ] **Step 8.4: Implement CamelStreamProcessor**

Create `streams-camel/src/main/java/io/casehub/platform/streams/camel/CamelStreamProcessor.java`:

```java
package io.casehub.platform.streams.camel;

import io.casehub.platform.api.endpoints.EndpointCapability;
import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointPropertyKeys;
import io.casehub.platform.api.endpoints.EndpointProtocol;
import io.casehub.platform.api.endpoints.EndpointQuery;
import io.casehub.platform.api.endpoints.EndpointRegistered;
import io.casehub.platform.api.endpoints.EndpointRegistry;
import io.casehub.platform.api.identity.TenancyConstants;
import io.cloudevents.CloudEvent;
import io.cloudevents.core.builder.CloudEventBuilder;
import io.quarkus.runtime.StartupEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Event;
import jakarta.enterprise.event.ObservesAsync;
import jakarta.enterprise.event.Observes;
import jakarta.inject.Inject;
import org.apache.camel.CamelContext;
import org.apache.camel.builder.RouteBuilder;
import org.jboss.logging.Logger;

import java.net.URI;
import java.time.OffsetDateTime;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Dynamic Camel route builder for runtime-registered CAMEL endpoints.
 *
 * <p>Startup: {@code @Observes StartupEvent} discovers all pre-startup CAMEL endpoints
 * from the registry (which has the complete state by the time StartupEvent fires) and
 * adds routes. Sets {@code camelStarted = true} after processing.
 *
 * <p>Runtime: {@code @ObservesAsync EndpointRegistered} for CAMEL protocol — if
 * {@code camelStarted} is false, pre-startup events from the CDI async executor
 * (delivered late) are discarded (the startup handler already covered them via discover).
 * If {@code camelStarted} is true, adds a route idempotently via the {@code routedUris} set.
 *
 * <p><b>P0 constraint:</b> Changing a Camel endpoint URI requires restart — the old route
 * is not stopped; a second route is added for the new URI.
 *
 * <p><b>Known startup-window gap:</b> An endpoint registered AFTER {@code discover()} in
 * {@code onStartup} but BEFORE {@code camelStarted.set(true)} would be discarded.
 * In practice this window is zero (desiredstate reconciliation does not start until the
 * app is ready).
 */
@ApplicationScoped
public class CamelStreamProcessor {

    private static final Logger LOG = Logger.getLogger(CamelStreamProcessor.class);

    @Inject
    EndpointRegistry endpointRegistry;

    @Inject
    Event<CloudEvent> cloudEventBus;

    @Inject
    CamelContext camelContext;

    private final AtomicBoolean camelStarted = new AtomicBoolean(false);
    private final Set<String> routedUris = ConcurrentHashMap.newKeySet();

    void onStartup(@Observes StartupEvent ev) {
        // @Startup @ApplicationScoped beans complete @PostConstruct before StartupEvent;
        // discover() sees the complete pre-startup registry state.
        endpointRegistry.discover(
            new EndpointQuery(TenancyConstants.DEFAULT_TENANT_ID, null, EndpointProtocol.CAMEL, Set.of(EndpointCapability.RECEIVE))
        ).forEach(d -> {
            String uri = d.properties().get(EndpointPropertyKeys.URL);
            if (routedUris.add(uri)) addRoute(d);  // addRoute() rethrows as RuntimeException on failure,
                                                    // propagates out of forEach, aborts startup.
                                                    // Remaining descriptors in the forEach are not processed.
        });
        camelStarted.set(true);
    }

    void onEndpointRegistered(@ObservesAsync EndpointRegistered event) {
        EndpointDescriptor d = event.descriptor();
        if (d.protocol() != EndpointProtocol.CAMEL) return;
        if (!camelStarted.get()) return;  // Pre-startup events delivered late: already covered by onStartup's discover()
        String uri = d.properties().get(EndpointPropertyKeys.URL);
        if (routedUris.add(uri)) addRoute(d);  // idempotent: skip if URI already routed
    }

    /**
     * Package-private for direct unit testing.
     */
    CloudEvent buildCloudEvent(byte[] body, EndpointDescriptor descriptor) {
        String type = descriptor.properties().getOrDefault(
            EndpointPropertyKeys.STREAM_EVENT_TYPE,
            "io.casehub.platform.streams.camel.unregistered");

        return CloudEventBuilder.v1()
            .withId(UUID.randomUUID().toString())
            .withType(type)
            .withSource(URI.create("/platform/streams/camel"))
            .withTime(OffsetDateTime.now())
            .withData(body)
            .withExtension("tenancyid", descriptor.tenancyId())
            .build();
    }

    private void addRoute(EndpointDescriptor d) {
        String uri = d.properties().get(EndpointPropertyKeys.URL);
        try {
            camelContext.addRoutes(new RouteBuilder() {
                @Override
                public void configure() {
                    from(uri).process(exchange -> {
                        byte[] body = exchange.getIn().getBody(byte[].class);
                        CloudEvent ce = buildCloudEvent(body, d);
                        cloudEventBus.fireAsync(ce)
                            .whenComplete((e, t) -> {
                                if (t != null) LOG.warnf(t, "CloudEvent observer failed for Camel route %s", uri);
                            });
                    });
                }
            });
        } catch (Exception e) {
            // In onStartup: propagates out, aborts startup (remaining descriptors not processed — fail-fast is correct).
            // In onEndpointRegistered: CDI async executor catches RuntimeException, wraps in CompletionException,
            // which the fireAsync().whenComplete in InMemoryEndpointRegistry.register() WARN-logs.
            throw new RuntimeException("Failed to add Camel route for URI: " + uri, e);
        }
    }
}
```

- [ ] **Step 8.5: Run unit tests**

```bash
mvn --batch-mode -pl streams-camel test -Dtest=CamelStreamProcessorTest
```

Expected: `BUILD SUCCESS`.

- [ ] **Step 8.6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add streams-camel/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#98): streams-camel — dynamic Camel route builder via EndpointRegistered"
```

---

## Task 9 — root pom.xml: add stream modules + full build verification

- [ ] **Step 9.1: Verify all stream modules in root pom.xml**

The `<modules>` section should already contain all 5 stream modules from Task 1. Verify:

```bash
grep -A5 "streams-" /Users/mdproctor/claude/casehub/platform/pom.xml | head -20
```

Expected: all 5 `<module>streams-*</module>` entries present.

- [ ] **Step 9.2: Full build**

```bash
mvn --batch-mode install
```

Expected: `BUILD SUCCESS` — all modules compile and all tests pass.

- [ ] **Step 9.3: If any module fails, diagnose and fix before continuing**

Check for: missing CDI beans at augmentation time (add runtime dep on `casehub-platform`), missing config properties in test `application.properties`, Camel artifact version not managed by quarkus-bom (may need explicit version in streams-camel pom).

---

## Task 10 — Documentation: CLAUDE.md and ARC42STORIES.MD

**Files:**
- Modify: `CLAUDE.md`
- Modify: `ARC42STORIES.MD`

- [ ] **Step 10.1: Update CLAUDE.md module table**

In `CLAUDE.md`, in the `## Modules` table, add 5 rows after the `endpoints-config/` row:

```
| `streams-kafka/` | `casehub-platform-streams-kafka` | @Startup @ApplicationScoped @Incoming("casehub-kafka-stream") Kafka ingestion — static channel, always raw byte[], builds CloudEvent from STREAM_EVENT_TYPE. Does NOT observe EndpointRegistered. |
| `streams-amqp/` | `casehub-platform-streams-amqp` | @Startup @ApplicationScoped @Incoming("casehub-amqp-stream") AMQP ingestion — single address per channel (no multi-address like Kafka topics=a,b). |
| `streams-webhook/` | `casehub-platform-streams-webhook` | @Startup @ApplicationScoped JAX-RS @POST /streams/webhook/{tenancyId}/{streamId} — structured CloudEvents HTTP binding; preserves incoming CloudEvent fields; enriches tenancyid from descriptor. |
| `streams-poll/` | `casehub-platform-streams-poll` | @Startup @ApplicationScoped @Scheduled HTTP GET poller — java.net.http.HttpClient, explicit status code check, per-endpoint exception handling. |
| `streams-camel/` | `casehub-platform-streams-camel` | @ApplicationScoped dynamic Camel route builder — observes EndpointRegistered for CAMEL protocol; discovers pre-startup endpoints at StartupEvent; idempotent routedUris set. |
```

- [ ] **Step 10.2: Update CLAUDE.md package structure section**

In the `## Package Structure (platform-api)` section, update the `.endpoints` bullet to include the new types:

```
  .endpoints     — EndpointRegistry (SPI), EndpointDescriptor (record), EndpointRegistered (CDI event record),
                   EndpointType (enum), EndpointProtocol (enum: HTTP/GRPC/KAFKA/AMQP/MCP/CAMEL/QHORUS),
                   EndpointCapability (enum), EndpointQuery (record), EndpointPropertyKeys (URL, TOPIC, STREAM_EVENT_TYPE)
```

- [ ] **Step 10.3: Update ARC42STORIES.MD §4 — add L10 layer**

In `ARC42STORIES.MD`, §4 Solution Strategy, layer taxonomy table, add after the L9 row:

```markdown
| L10: Stream Ingestion | `streams-kafka/`, `streams-amqp/`, `streams-webhook/`, `streams-poll/`, `streams-camel/` | Classpath-activated transports firing `Event<CloudEvent>.fireAsync()` |
```

- [ ] **Step 10.4: Update ARC42STORIES.MD §5 — add L10 containers + missing L4 endpoints-config**

In §5 the C4Container diagram, add inside `Container_Boundary(l4, "L4: Platform Extensions")`:

```
Container(endpointsConfig, "casehub-platform-endpoints-config", "Quarkus", "@Startup @ApplicationScoped YAML-backed EndpointDescriptor populator")
```

And add a new boundary after L9:

```
Container_Boundary(l10, "L10: Stream Ingestion") {
    Container(streamsKafka, "casehub-platform-streams-kafka", "SmallRye Reactive Messaging", "@Startup @Incoming static Kafka channel")
    Container(streamsAmqp, "casehub-platform-streams-amqp", "SmallRye Reactive Messaging", "@Startup @Incoming static AMQP channel")
    Container(streamsWebhook, "casehub-platform-streams-webhook", "Quarkus REST", "@Startup JAX-RS POST /streams/webhook — structured CloudEvents HTTP binding")
    Container(streamsPoll, "casehub-platform-streams-poll", "Quarkus Scheduler", "@Startup @Scheduled HTTP GET — java.net.http.HttpClient")
    Container(streamsCamel, "casehub-platform-streams-camel", "Apache Camel Quarkus", "@ApplicationScoped dynamic route builder via EndpointRegistered")
}
```

- [ ] **Step 10.5: Commit documentation**

```bash
git -C /Users/mdproctor/claude/casehub/platform add CLAUDE.md ARC42STORIES.MD
git -C /Users/mdproctor/claude/casehub/platform commit -m "docs(platform#98): update CLAUDE.md module table and ARC42STORIES §4/§5 for stream modules"
```

---

## Task 11 — Final verification and issue close

- [ ] **Step 11.1: Full test suite**

```bash
mvn --batch-mode install
```

Expected: `BUILD SUCCESS` — 100% test pass.

- [ ] **Step 11.2: Verify all acceptance criteria**

Read the spec's acceptance criteria section (in `docs/superpowers/specs/2026-06-14-cloudEvent-streams-design.md`) and confirm each item is covered. Key checks:

- `EndpointRegistered` fires on every `InMemoryEndpointRegistry.register()` call (with null guard for plain-JUnit path)
- All four `discover()` calls use `DEFAULT_TENANT_ID`
- `streams-kafka` does NOT observe `EndpointRegistered`; Javadoc states this
- `streams-amqp` does NOT observe `EndpointRegistered`; Javadoc states this  
- Kafka multi-topic splitting splits on comma and matches each element independently
- `pollAndFire()` checks `response.statusCode()` and throws `IOException` on non-2xx
- `pollAndFire()` catches `InterruptedException`, re-interrupts thread, rethrows as `IOException`
- `WebhookResource` is `@Startup @ApplicationScoped` (not method-level)
- `WebhookResource.receive()` returns 202, 400, 404, 415 for the correct conditions
- Camel `addRoute()` wraps `throws Exception` in `RuntimeException`
- All five processor beans are `@ApplicationScoped`

- [ ] **Step 11.3: Update workspace journal**

```bash
git -C /Users/mdproctor/claude/public/casehub/platform add design/JOURNAL.md
git -C /Users/mdproctor/claude/public/casehub/platform commit -m "journal(#98): CloudEvent stream modules implementation complete"
```

- [ ] **Step 11.4: Final commit tag**

```bash
git -C /Users/mdproctor/claude/casehub/platform log --oneline -8
```

Review the commit history to verify all tasks are present. Then run `work-end` (or the equivalent closing procedure per the project workflow).
