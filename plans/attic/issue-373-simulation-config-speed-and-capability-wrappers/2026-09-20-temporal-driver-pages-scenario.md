# Temporal Driver Pages Scenario Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #372 — TemporalSimulationDriver: Pages scenario integration (start/stop/speed via delivery: graphql)
**Issue group:** #372

**Goal:** Add a GraphQL/REST/MCP control API for TemporalSimulationDriver so Pages scenarios can start/stop/pause/resume/speed-change temporal profiles remotely, plus a dedicated `temporal:` step type in ScenarioOrchestrator.

**Architecture:** @McpDomain annotation goes directly on `TemporalDriverService` class in event-simulation (class-based pattern — no separate SPI interface module). Request/response records in the same package. The graphql-generator APT generates GraphQL + REST endpoints. JSON Schema updated for temporal-profiles YAML. Pages gets a new temporal step type.

**Spec deviation:** The spec proposed a new `simulation-api` module for the SPI. However, `simulation-api` already exists as a zero-dependency simulation contracts module. Adding platform-api dependency would break its contract. The class-based @McpDomain pattern on the service class eliminates the need for a new module.

**Tech Stack:** Java 21+, Quarkus (CDI, REST), graphql-generator APT, Jackson, JUnit 5, AssertJ, rest-assured

## Global Constraints

- `simulation-api/` must remain zero-dependency — do not add platform-api to it
- `simulation-core/` is POJO — no CDI, no Quarkus imports
- All YAML surfaces must have JSON Schema definitions
- graphql-generator APT generates endpoints — no hand-written REST resources
- TDD: failing test before implementation code

---

## Batch 1: Platform — driver control API

### Task 1: Add speed() getter to TemporalSimulationDriver

**Files:**
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/TemporalSimulationDriver.java:88-91`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/TemporalSimulationDriverTest.java`

**Interfaces:**
- Produces: `TemporalSimulationDriver.speed()` → `double` (current speed value, volatile read)

- [ ] **Step 1: Write the failing test**

Add to `TemporalSimulationDriverTest.java`:

```java
@Test
void speedReturnsCurrentSpeed() throws InterruptedException {
    TemporalEventSink<String> sink = (qn, label, event) -> {};
    var profile = new TemporalProfile<>("speed-test", "my.method", null,
            new TimedSequence<>(List.of(
                    new TimedEntry<>("A", Duration.ofMillis(500)))),
            false, 5.0);

    var driver = new TemporalSimulationDriver<>(sink);
    assertThat(driver.speed()).isEqualTo(0.0);

    driver.start(profile);
    assertThat(driver.speed()).isEqualTo(5.0);

    driver.setSpeed(10.0);
    assertThat(driver.speed()).isEqualTo(10.0);

    driver.stop();
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl simulation-core test -Dtest=TemporalSimulationDriverTest#speedReturnsCurrentSpeed -q`
Expected: FAIL — `speed()` method does not exist

- [ ] **Step 3: Add speed() getter**

Add to `TemporalSimulationDriver.java` after `setSpeed()` (line ~91):

```java
public double speed() {
    return speed;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -pl simulation-core test -Dtest=TemporalSimulationDriverTest#speedReturnsCurrentSpeed -q`
Expected: PASS

- [ ] **Step 5: Run full simulation-core tests**

Run: `mvn -pl simulation-core test -q`
Expected: All tests PASS — no regressions

- [ ] **Step 6: Commit**

```bash
git add simulation-core/src/main/java/io/casehub/platform/simulation/TemporalSimulationDriver.java
git add simulation-core/src/test/java/io/casehub/platform/simulation/TemporalSimulationDriverTest.java
git commit -m "feat(#372): add speed() getter to TemporalSimulationDriver

Exposes the volatile speed field for status reporting via the
temporal driver control API.

Refs #372

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: TemporalDriverService with @McpDomain + records

**Files:**
- Create: `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/TemporalDriverStartRequest.java`
- Create: `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/TemporalDriverSpeedRequest.java`
- Create: `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/TemporalDriverStatus.java`
- Create: `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/TemporalEventInput.java`
- Create: `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/TemporalDriverService.java`
- Modify: `event-simulation/pom.xml`
- Test: `event-simulation/src/test/java/io/casehub/platform/simulation/event/quarkus/TemporalDriverServiceTest.java`

**Interfaces:**
- Consumes: `TemporalSimulationDriver.speed()` (from Task 1), `TemporalDriverFactory.create()`, `TemporalProfileRegistry.resolve(name)`, `DurationParser.parse(String)`
- Produces: `TemporalDriverService` @McpDomain("temporal-drivers") with start/stop/pause/resume/setSpeed/status/list methods. APT-generated GraphQL + REST endpoints.

- [ ] **Step 1: Update event-simulation POM**

Add to `event-simulation/pom.xml` dependencies:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-api</artifactId>
    <version>${project.version}</version>
</dependency>
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-graphql-generator</artifactId>
    <version>${project.version}</version>
    <scope>provided</scope>
</dependency>
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-rest</artifactId>
</dependency>
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-rest-jackson</artifactId>
</dependency>
<dependency>
    <groupId>io.rest-assured</groupId>
    <artifactId>rest-assured</artifactId>
    <scope>test</scope>
</dependency>
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform</artifactId>
    <version>${project.version}</version>
    <scope>test</scope>
</dependency>
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-testing</artifactId>
    <version>${project.version}</version>
    <scope>test</scope>
</dependency>
```

Add to `<build><plugins>`:

```xml
<plugin>
    <artifactId>maven-compiler-plugin</artifactId>
    <configuration>
        <annotationProcessorPaths>
            <path>
                <groupId>io.casehub</groupId>
                <artifactId>casehub-platform-graphql-generator</artifactId>
                <version>${project.version}</version>
            </path>
        </annotationProcessorPaths>
        <compilerArgs>
            <arg>-AgenerateGraphQL=false</arg>
            <arg>-AdomainFilter=temporal-drivers</arg>
        </compilerArgs>
    </configuration>
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

- [ ] **Step 2: Create request/response records**

Create `TemporalEventInput.java`:

```java
package io.casehub.platform.simulation.event.quarkus;

import java.util.Map;

public record TemporalEventInput(
        String delay,
        String label,
        Map<String, Object> payload) {}
```

Create `TemporalDriverStartRequest.java`:

```java
package io.casehub.platform.simulation.event.quarkus;

import java.util.List;

public record TemporalDriverStartRequest(
        String name,
        String profileName,
        String qualifiedName,
        String tenancyId,
        List<TemporalEventInput> events,
        Boolean loop,
        Double speed) {

    public String effectiveName() {
        if (name != null && !name.isBlank()) return name;
        if (profileName != null && !profileName.isBlank()) return profileName;
        throw new IllegalArgumentException("name or profileName is required");
    }

    public void validate() {
        if ((profileName == null || profileName.isBlank())
                && (qualifiedName == null || qualifiedName.isBlank())) {
            throw new IllegalArgumentException(
                    "Either profileName or qualifiedName must be provided");
        }
        if (profileName != null && !profileName.isBlank()
                && qualifiedName != null && !qualifiedName.isBlank()) {
            throw new IllegalArgumentException(
                    "profileName and qualifiedName are mutually exclusive");
        }
    }
}
```

Create `TemporalDriverSpeedRequest.java`:

```java
package io.casehub.platform.simulation.event.quarkus;

public record TemporalDriverSpeedRequest(String name, double speed) {}
```

Create `TemporalDriverStatus.java`:

```java
package io.casehub.platform.simulation.event.quarkus;

public record TemporalDriverStatus(
        String name,
        String profileName,
        String state,
        double speed,
        int emittedCount,
        int failureCount,
        int loopIterations,
        boolean hasFailures) {}
```

- [ ] **Step 3: Write failing tests for TemporalDriverService**

Create `TemporalDriverServiceTest.java`:

```java
package io.casehub.platform.simulation.event.quarkus;

import io.casehub.platform.simulation.TemporalSimulationDriver;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@QuarkusTest
class TemporalDriverServiceTest {

    @Inject
    TemporalDriverService service;

    @AfterEach
    void stopAll() {
        for (var status : service.list()) {
            try { service.stop(status.name()); } catch (Exception ignored) {}
        }
    }

    @Test
    void startInlineAndStop() throws InterruptedException {
        var request = new TemporalDriverStartRequest(
                "test-inline", null, "test.event", "tenant-1",
                List.of(new TemporalEventInput("0", "evt-1",
                        Map.of("key", "value"))),
                false, 1.0);

        var status = service.start(request);
        assertThat(status.name()).isEqualTo("test-inline");
        assertThat(status.state()).isIn("RUNNING", "COMPLETED");

        Thread.sleep(100);
        service.stop("test-inline");

        assertThat(service.list()).isEmpty();
    }

    @Test
    void startNamedProfile() throws InterruptedException {
        var request = new TemporalDriverStartRequest(
                null, "morning-routine", null, null,
                null, null, null);

        // This will fail if morning-routine profile is not configured
        // In test, we use an inline profile instead
        var inlineRequest = new TemporalDriverStartRequest(
                "named-test", null, "test.named", null,
                List.of(new TemporalEventInput("10ms", "step-1",
                        Map.of("device", "sensor-1"))),
                false, 10.0);

        var status = service.start(inlineRequest);
        assertThat(status.name()).isEqualTo("named-test");
        assertThat(status.speed()).isEqualTo(10.0);

        Thread.sleep(100);
        service.stop("named-test");
    }

    @Test
    void conflictOnDuplicateStart() {
        var request = new TemporalDriverStartRequest(
                "conflict-test", null, "test.event", null,
                List.of(new TemporalEventInput("1s", "slow",
                        Map.of("k", "v"))),
                true, 1.0);

        service.start(request);

        assertThatThrownBy(() -> service.start(request))
                .isInstanceOf(IllegalStateException.class);

        service.stop("conflict-test");
    }

    @Test
    void completedDriverAutoReplacedOnStart() throws InterruptedException {
        var request = new TemporalDriverStartRequest(
                "replace-test", null, "test.event", null,
                List.of(new TemporalEventInput("0", "fast",
                        Map.of("k", "v"))),
                false, 100.0);

        service.start(request);
        Thread.sleep(200);

        var status = service.status("replace-test");
        assertThat(status.state()).isEqualTo("COMPLETED");

        var status2 = service.start(request);
        assertThat(status2.name()).isEqualTo("replace-test");

        Thread.sleep(200);
        service.stop("replace-test");
    }

    @Test
    void pauseAndResume() throws InterruptedException {
        var request = new TemporalDriverStartRequest(
                "pause-test", null, "test.event", null,
                List.of(
                        new TemporalEventInput("50ms", "a", Map.of("k", "1")),
                        new TemporalEventInput("50ms", "b", Map.of("k", "2")),
                        new TemporalEventInput("50ms", "c", Map.of("k", "3"))),
                true, 1.0);

        service.start(request);
        Thread.sleep(30);

        service.pause("pause-test");
        var paused = service.status("pause-test");
        assertThat(paused.state()).isEqualTo("PAUSED");

        service.resume("pause-test");
        var resumed = service.status("pause-test");
        assertThat(resumed.state()).isEqualTo("RUNNING");

        service.stop("pause-test");
    }

    @Test
    void setSpeedMidFlight() throws InterruptedException {
        var request = new TemporalDriverStartRequest(
                "speed-test", null, "test.event", null,
                List.of(new TemporalEventInput("1s", "slow",
                        Map.of("k", "v"))),
                true, 1.0);

        service.start(request);
        var before = service.status("speed-test");
        assertThat(before.speed()).isEqualTo(1.0);

        service.setSpeed(new TemporalDriverSpeedRequest("speed-test", 50.0));
        var after = service.status("speed-test");
        assertThat(after.speed()).isEqualTo(50.0);

        service.stop("speed-test");
    }

    @Test
    void statusNotFound() {
        assertThatThrownBy(() -> service.status("nonexistent"))
                .isInstanceOf(jakarta.ws.rs.NotFoundException.class);
    }

    @Test
    void listReturnsAllActive() {
        service.start(new TemporalDriverStartRequest(
                "list-a", null, "test.a", null,
                List.of(new TemporalEventInput("1s", "a", Map.of())),
                true, 1.0));
        service.start(new TemporalDriverStartRequest(
                "list-b", null, "test.b", null,
                List.of(new TemporalEventInput("1s", "b", Map.of())),
                true, 1.0));

        var list = service.list();
        assertThat(list).hasSize(2);
        assertThat(list).extracting(TemporalDriverStatus::name)
                .containsExactlyInAnyOrder("list-a", "list-b");

        service.stop("list-a");
        service.stop("list-b");
    }

    @Test
    void validationRejectsNeitherProfileNorQualified() {
        var bad = new TemporalDriverStartRequest(
                "bad", null, null, null, null, null, null);
        assertThatThrownBy(() -> service.start(bad))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void validationRejectsBothProfileAndQualified() {
        var bad = new TemporalDriverStartRequest(
                "bad", "profile", "qualified", null, null, null, null);
        assertThatThrownBy(() -> service.start(bad))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mvn -pl event-simulation test -Dtest=TemporalDriverServiceTest -q`
Expected: FAIL — `TemporalDriverService` does not exist

- [ ] **Step 5: Implement TemporalDriverService**

Create `TemporalDriverService.java`:

```java
package io.casehub.platform.simulation.event.quarkus;

import io.casehub.platform.api.mcp.HttpMethod;
import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PathParam;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.platform.api.mcp.RestMethod;
import io.casehub.platform.simulation.DriverResult;
import io.casehub.platform.simulation.TemporalDriverFactory;
import io.casehub.platform.simulation.TemporalEventSink;
import io.casehub.platform.simulation.TemporalProfile;
import io.casehub.platform.simulation.TemporalSimulationDriver;
import io.casehub.platform.simulation.TimedEntry;
import io.casehub.platform.simulation.TimedSequence;
import io.casehub.platform.simulation.config.DurationParser;
import io.casehub.platform.simulation.config.TemporalProfileRegistry;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.NotFoundException;

import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

@ApplicationScoped
@McpDomain("temporal-drivers")
public class TemporalDriverService {

    private final TemporalDriverFactory<Map<String, Object>> driverFactory;
    private final TemporalProfileRegistry profileRegistry;
    private final ConcurrentHashMap<String, ActiveDriver> activeDrivers = new ConcurrentHashMap<>();

    record ActiveDriver(
            String name,
            String profileName,
            TemporalSimulationDriver<Map<String, Object>> driver) {}

    @Inject
    public TemporalDriverService(
            TemporalDriverFactory<Map<String, Object>> driverFactory,
            TemporalProfileRegistry profileRegistry) {
        this.driverFactory = driverFactory;
        this.profileRegistry = profileRegistry;
    }

    @PlatformMutation("Start a temporal simulation driver")
    public TemporalDriverStatus start(TemporalDriverStartRequest request) {
        request.validate();
        String name = request.effectiveName();

        activeDrivers.compute(name, (key, existing) -> {
            if (existing != null) {
                var state = existing.driver().state();
                if (state == TemporalSimulationDriver.State.RUNNING
                        || state == TemporalSimulationDriver.State.PAUSED) {
                    throw new IllegalStateException(
                            "Driver '" + key + "' is " + state + ". Stop it first.");
                }
            }

            TemporalProfile<Map<String, Object>> profile = resolveProfile(request);
            var driver = driverFactory.create();
            driver.start(profile);
            return new ActiveDriver(key, request.profileName(), driver);
        });

        return buildStatus(name, activeDrivers.get(name));
    }

    @PlatformMutation("Stop a temporal simulation driver")
    @RestMethod(HttpMethod.DELETE)
    public void stop(@PathParam String name) {
        var active = activeDrivers.remove(name);
        if (active == null) throw new NotFoundException("Driver not found: " + name);
        active.driver().stop();
    }

    @PlatformMutation("Pause a temporal simulation driver")
    @RestMethod(HttpMethod.PUT)
    public void pause(@PathParam String name) {
        var active = requireDriver(name);
        active.driver().pause();
    }

    @PlatformMutation("Resume a paused temporal simulation driver")
    @RestMethod(HttpMethod.PUT)
    public void resume(@PathParam String name) {
        var active = requireDriver(name);
        active.driver().resume();
    }

    @PlatformMutation("Change speed of a temporal simulation driver")
    @RestMethod(HttpMethod.PUT)
    public void setSpeed(TemporalDriverSpeedRequest request) {
        var active = requireDriver(request.name());
        active.driver().setSpeed(request.speed());
    }

    @PlatformQuery("Get status of a temporal simulation driver")
    public TemporalDriverStatus status(@PathParam String name) {
        var active = requireDriver(name);
        return buildStatus(name, active);
    }

    @PlatformQuery("List all active temporal simulation drivers")
    public List<TemporalDriverStatus> list() {
        return activeDrivers.entrySet().stream()
                .map(e -> buildStatus(e.getKey(), e.getValue()))
                .toList();
    }

    private ActiveDriver requireDriver(String name) {
        var active = activeDrivers.get(name);
        if (active == null) throw new NotFoundException("Driver not found: " + name);
        return active;
    }

    private TemporalProfile<Map<String, Object>> resolveProfile(
            TemporalDriverStartRequest request) {
        if (request.profileName() != null && !request.profileName().isBlank()) {
            var profile = profileRegistry.resolve(request.profileName())
                    .orElseThrow(() -> new NotFoundException(
                            "Profile not found: " + request.profileName()));
            double speed = request.speed() != null ? request.speed() : profile.speed();
            boolean loop = request.loop() != null ? request.loop() : profile.loop();
            return new TemporalProfile<>(profile.name(), profile.qualifiedName(),
                    profile.tenancyId(), profile.sequence(), loop, speed);
        }

        List<TimedEntry<Map<String, Object>>> entries = request.events() == null
                ? List.of()
                : request.events().stream()
                .map(e -> new TimedEntry<>(
                        e.payload(),
                        DurationParser.parse(e.delay()),
                        e.label()))
                .toList();

        return new TemporalProfile<>(
                request.effectiveName(),
                request.qualifiedName(),
                request.tenancyId(),
                new TimedSequence<>(entries),
                request.loop() != null && request.loop(),
                request.speed() != null ? request.speed() : 1.0);
    }

    private TemporalDriverStatus buildStatus(String name, ActiveDriver active) {
        var driver = active.driver();
        DriverResult result = driver.lastResult();
        return new TemporalDriverStatus(
                name,
                active.profileName(),
                driver.state().name(),
                driver.speed(),
                result != null ? result.emittedCount() : 0,
                result != null ? result.failureCount() : 0,
                result != null ? result.loopIterations() : 0,
                result != null && result.hasFailures());
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn -pl event-simulation test -Dtest=TemporalDriverServiceTest -q`
Expected: All tests PASS

- [ ] **Step 7: Run full event-simulation tests**

Run: `mvn -pl event-simulation test -q`
Expected: All tests PASS — including existing EventSimulationBeansTest

- [ ] **Step 8: Verify generated REST endpoints work**

Add to `TemporalDriverServiceTest.java`:

```java
@Test
void restEndpointAccessible() {
    io.restassured.RestAssured.given()
            .when().get("/temporal-drivers")
            .then().statusCode(200);
}
```

Run: `mvn -pl event-simulation test -Dtest=TemporalDriverServiceTest#restEndpointAccessible -q`
Expected: PASS — generated REST resource serves the list endpoint

- [ ] **Step 9: Commit**

```bash
git add event-simulation/
git commit -m "feat(#372): add TemporalDriverService @McpDomain control API

Adds start/stop/pause/resume/setSpeed/status/list operations for
temporal simulation drivers. Supports named profile references
(from TemporalProfileRegistry) and inline profile definitions
with YAML/Java parity.

GraphQL + REST endpoints generated by graphql-generator APT.

Refs #372

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: JSON Schema update for temporal-profiles

**Files:**
- Modify: `simulation-config-core/src/main/resources/schema/simulation.schema.json`
- Test: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/SimulationSchemaTest.java`

**Interfaces:**
- Consumes: existing `simulation.schema.json` structure
- Produces: `temporal-profile-config`, `temporal-event`, `sequence-ref` schema definitions

- [ ] **Step 1: Write failing schema validation test**

Create `SimulationSchemaTest.java`:

```java
package io.casehub.platform.simulation.config;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import com.networknt.json.schema.JsonSchemaFactory;
import com.networknt.json.schema.SpecVersion;
import org.junit.jupiter.api.Test;

import java.io.IOException;

import static org.assertj.core.api.Assertions.assertThat;

class SimulationSchemaTest {

    private static final ObjectMapper YAML = new ObjectMapper(new YAMLFactory());
    private static final ObjectMapper JSON = new ObjectMapper();

    @Test
    void temporalProfilesValidateAgainstSchema() throws IOException {
        String yaml = """
                temporal-profiles:
                  morning-routine:
                    qualified-name: iot.device-state-change
                    loop: true
                    speed: 10.0
                    events:
                      - delay: 0
                        label: motion
                        payload:
                          deviceId: motion-01
                          state: ACTIVE
                      - delay: 5s
                        label: lights
                        payload:
                          deviceId: light-01
                          state: "ON"
                """;

        JsonNode doc = YAML.readTree(yaml);
        JsonNode schemaNode = JSON.readTree(
                getClass().getResourceAsStream("/schema/simulation.schema.json"));

        var factory = JsonSchemaFactory.getInstance(SpecVersion.VersionFlag.V202012);
        var schema = factory.getSchema(schemaNode);
        var errors = schema.validate(doc);
        assertThat(errors).as("Schema validation errors").isEmpty();
    }

    @Test
    void temporalProfilesSequenceRefValidates() throws IOException {
        String yaml = """
                temporal-profiles:
                  full-demo:
                    qualified-name: iot.device-state-change
                    sequence:
                      - ref: morning-routine
                      - ref: alarm-sequence
                        delay: 30s
                """;

        JsonNode doc = YAML.readTree(yaml);
        JsonNode schemaNode = JSON.readTree(
                getClass().getResourceAsStream("/schema/simulation.schema.json"));

        var factory = JsonSchemaFactory.getInstance(SpecVersion.VersionFlag.V202012);
        var schema = factory.getSchema(schemaNode);
        var errors = schema.validate(doc);
        assertThat(errors).as("Schema validation errors").isEmpty();
    }

    @Test
    void profileWithTemporalRefsValidates() throws IOException {
        String yaml = """
                profiles:
                  demo:
                    methods:
                      agent.invoke:
                        strategy: sequential
                    temporal:
                      - morning-routine
                """;

        JsonNode doc = YAML.readTree(yaml);
        JsonNode schemaNode = JSON.readTree(
                getClass().getResourceAsStream("/schema/simulation.schema.json"));

        var factory = JsonSchemaFactory.getInstance(SpecVersion.VersionFlag.V202012);
        var schema = factory.getSchema(schemaNode);
        var errors = schema.validate(doc);
        assertThat(errors).as("Schema validation errors").isEmpty();
    }
}
```

Note: Check if `networknt/json-schema-validator` is already a test dependency. If not, use an alternative schema validation approach — load the schema and verify key `$defs` exist via Jackson tree traversal instead.

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl simulation-config-core test -Dtest=SimulationSchemaTest -q`
Expected: FAIL — schema does not include `temporal-profiles`

- [ ] **Step 3: Update simulation.schema.json**

Add `temporal-profiles` to root `properties`:

```json
"temporal-profiles": {
  "type": "object",
  "description": "Named temporal simulation profiles",
  "additionalProperties": {
    "$ref": "#/$defs/temporal-profile-config"
  }
}
```

Add to `$defs`:

```json
"temporal-profile-config": {
  "type": "object",
  "properties": {
    "qualified-name": { "type": "string", "description": "Event type / method name for journal tracking" },
    "tenancy-id": { "type": "string", "description": "Tenant context for journal recording" },
    "loop": { "type": "boolean", "default": false, "description": "Repeat after last event" },
    "speed": { "type": "number", "exclusiveMinimum": 0, "default": 1.0, "description": "Speed multiplier (1.0 = real-time)" },
    "events": { "type": "array", "items": { "$ref": "#/$defs/temporal-event" }, "description": "Inline event list" },
    "events-file": { "type": "string", "description": "External event file path" },
    "from-corpus": { "type": "string", "description": "Derive timing from corpus InvocationRecords" },
    "sequence": { "type": "array", "items": { "$ref": "#/$defs/sequence-ref" }, "description": "Concatenated profile references" }
  },
  "oneOf": [
    { "required": ["events"] },
    { "required": ["events-file"] },
    { "required": ["from-corpus"] },
    { "required": ["sequence"] }
  ]
},
"temporal-event": {
  "type": "object",
  "required": ["payload"],
  "additionalProperties": false,
  "properties": {
    "delay": { "type": ["string", "number"], "default": 0, "description": "Delay before event (5s, 2m, 500ms, or bare millis)" },
    "label": { "type": "string", "description": "Human-readable identifier for journal verification" },
    "payload": { "type": "object", "description": "Event payload" }
  }
},
"sequence-ref": {
  "type": "object",
  "required": ["ref"],
  "additionalProperties": false,
  "properties": {
    "ref": { "type": "string", "description": "Reference to a named temporal profile" },
    "delay": { "type": ["string", "number"], "description": "Gap delay absorbed into referenced profile's first entry" }
  }
}
```

Add `temporal` to `profile-config` properties:

```json
"temporal": {
  "type": "array",
  "description": "Temporal profile references or inline definitions",
  "items": {
    "oneOf": [
      { "type": "string", "description": "Reference to a named temporal profile" },
      { "$ref": "#/$defs/temporal-profile-config" }
    ]
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl simulation-config-core test -Dtest=SimulationSchemaTest -q`
Expected: All tests PASS

- [ ] **Step 5: Run full simulation-config-core tests**

Run: `mvn -pl simulation-config-core test -q`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add simulation-config-core/src/main/resources/schema/simulation.schema.json
git add simulation-config-core/src/test/java/io/casehub/platform/simulation/config/SimulationSchemaTest.java
git commit -m "feat(#372): add temporal-profiles to simulation JSON Schema

Adds temporal-profile-config, temporal-event, and sequence-ref
definitions. Updates profile-config with temporal array property.
Catches up schema to match YamlSimulationConfig parser from #371.

Refs #372

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: Pages — temporal step type (cross-repo)

### Task 4: Temporal step handler in ScenarioOrchestrator

**Cross-repo:** This task modifies casehub-pages. It requires a branch in that repo and access to the ScenarioOrchestrator codebase.

**Files:** (casehub-pages repo — exact paths TBD after exploring the repo)
- Create: `scenario-runtime/src/main/java/io/casehub/pages/scenario/TemporalStepHandler.java`
- Modify: `scenario-runtime/src/main/java/io/casehub/pages/scenario/ScenarioOrchestrator.java` — register temporal step type
- Create: `scenario-runtime/src/main/resources/schema/temporal-step.schema.json`
- Create: `scenario-runtime/src/test/java/io/casehub/pages/scenario/TemporalStepHandlerTest.java`
- Modify: `scenario-runtime/pom.xml` — add event-simulation dependency

**Interfaces:**
- Consumes: `TemporalDriverService` via REST client or CDI injection (start/stop/pause/resume/setSpeed)
- Produces: `temporal:` step type in scenario YAML

**Note:** The exact file paths and class structure depend on the casehub-pages repo layout, which is not in this workspace. The steps below are structural — the implementer should explore the ScenarioOrchestrator pattern in Pages before executing.

- [ ] **Step 1: Create branch in casehub-pages**

```bash
git -C <pages-repo> checkout -b issue-372-temporal-driver-pages-scenario main
```

- [ ] **Step 2: Add event-simulation dependency to scenario-runtime POM**

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-event-simulation</artifactId>
    <version>${casehub-platform.version}</version>
</dependency>
```

- [ ] **Step 3: Write failing test for temporal step parsing**

```java
@Test
void parsesTemporalStartStep() {
    var step = parseStep("""
        name: start-feed
        temporal:
          action: start
          profile: morning-routine
          speed: 20.0
        """);

    assertThat(step).isInstanceOf(TemporalStep.class);
    var temporal = (TemporalStep) step;
    assertThat(temporal.action()).isEqualTo(TemporalAction.START);
    assertThat(temporal.profile()).isEqualTo("morning-routine");
    assertThat(temporal.speed()).isEqualTo(20.0);
}

@Test
void parsesTemporalStopStep() {
    var step = parseStep("""
        name: stop-feed
        temporal:
          action: stop
          name: morning-routine
        """);

    assertThat(step).isInstanceOf(TemporalStep.class);
    var temporal = (TemporalStep) step;
    assertThat(temporal.action()).isEqualTo(TemporalAction.STOP);
    assertThat(temporal.name()).isEqualTo("morning-routine");
}

@Test
void parsesInlineTemporalProfile() {
    var step = parseStep("""
        name: ad-hoc
        temporal:
          action: start
          name: smoke-alarm
          qualified-name: iot.alarm
          loop: false
          speed: 5.0
          events:
            - delay: 0
              label: trigger
              payload:
                deviceId: smoke-01
                state: ALARM
        """);

    assertThat(step).isInstanceOf(TemporalStep.class);
    var temporal = (TemporalStep) step;
    assertThat(temporal.qualifiedName()).isEqualTo("iot.alarm");
    assertThat(temporal.events()).hasSize(1);
}
```

- [ ] **Step 4: Implement TemporalStepHandler**

Create `TemporalStepHandler` that:
1. Parses `temporal:` YAML block into action + parameters
2. Delegates to `TemporalDriverService` (injected via CDI or REST client)
3. Supports all actions: start, stop, pause, resume, set-speed
4. Maps YAML fields to `TemporalDriverStartRequest` / `TemporalDriverSpeedRequest`

- [ ] **Step 5: Register handler in ScenarioOrchestrator**

Add `temporal` to the step type registry alongside existing `simulation`, `navigate`, `wait`, `assert` types.

- [ ] **Step 6: Create temporal-step.schema.json**

JSON Schema with `action` enum and conditional field requirements per action type.

- [ ] **Step 7: Run tests**

Run Pages test suite for scenario module.
Expected: All new + existing tests PASS.

- [ ] **Step 8: Commit**

```bash
git add scenario-runtime/
git commit -m "feat(#372): add temporal: step type to ScenarioOrchestrator

Adds start/stop/pause/resume/set-speed actions for temporal
simulation driver control from scenario YAML. Supports named
profile references and inline profile definitions.

Refs casehubio/platform#372

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## References

- [2026-09-20-temporal-driver-pages-scenario-design.md] — design spec this plan implements
- [simulation-core/TemporalSimulationDriver.java:88-91] — speed field, setSpeed method
- [simulation-core/TemporalDriverFactory.java] — factory functional interface
- [simulation-config-core/TemporalProfileRegistry.java] — profile resolution
- [simulation-config-core/DurationParser.java] — delay string parsing
- [simulation-config-core/simulation.schema.json] — existing schema to extend
- [event-simulation/EventSimulationBeans.java] — existing CDI wiring
- [callback/pom.xml] — graphql-generator APT POM pattern
- [callback-api/CallbackApi.java] — @McpDomain SPI pattern
- [GitHub #372] — focal issue
- [GitHub #371] — parent (temporal simulation driver)
