# MCP Simulation Phase Inspection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #746 — MCP tool for runtime simulation phase inspection and manual triggers

**Goal:** Add MCP tools to inspect corpus selector phases and manually trigger transitions at runtime.

**Architecture:** Three-layer change — extend `CorpusSelector` SPI with `type()`/`reset()`, add accessor methods to `SimulationRuntime`, then expose as `@McpDomain("corpus-selectors")` in `event-simulation` following the `TemporalDriverService` pattern.

**Tech Stack:** Java 21, Quarkus CDI, graphql-generator APT, AssertJ

## Global Constraints

- `simulation-api` must remain zero-dependency
- `simulation-core` has no CDI imports
- `event-simulation` uses graphql-generator APT for REST endpoint generation
- All new methods on selectors must be thread-safe (j.u.c atomics, no synchronized)

---

## Batch 1: CorpusSelector SPI + selector implementations

### Task 1: Extend CorpusSelector interface and implement type()/reset() on all selectors

**Files:**
- Modify: `simulation-api/src/main/java/io/casehub/platform/simulation/CorpusSelector.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/selector/StateMachineSelector.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/selector/DurationSelector.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/selector/LookupCountSelector.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/selector/RandomSelector.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/selector/StateMachineSelectorTest.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/selector/DurationSelectorTest.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/selector/LookupCountSelectorTest.java`

**Interfaces:**
- Produces: `CorpusSelector.type()` → `String`, `CorpusSelector.reset()` → `void`

- [ ] **Step 1: Add default methods to CorpusSelector**

Add to `simulation-api/.../CorpusSelector.java`:

```java
default String type() { return "unknown"; }

default void reset() {}
```

- [ ] **Step 2: Write failing tests for StateMachineSelector reset**

Add to `StateMachineSelectorTest.java`:

```java
@Test
void typeReturnsStateMachine() {
    var selector = new StateMachineSelector("a", Map.of("a", Map.of("go", "b")));
    assertThat(selector.type()).isEqualTo("state-machine");
}

@Test
void resetRestoresInitialState() {
    var selector = new StateMachineSelector("a", Map.of(
            "a", Map.of("go", "b"),
            "b", Map.of("go", "c")));
    selector.advance("go");
    assertThat(selector.activePhase()).isEqualTo("b");

    selector.reset();
    assertThat(selector.activePhase()).isEqualTo("a");
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=StateMachineSelectorTest#typeReturnsStateMachine+resetRestoresInitialState -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — `type()` returns "unknown", `reset()` is no-op

- [ ] **Step 4: Implement type() and reset() on StateMachineSelector**

Modify `StateMachineSelector.java` — add a `private final String initial` field, set it in the constructor, override `type()` and `reset()`:

```java
public final class StateMachineSelector implements CorpusSelector {

    private final String initial;
    private final Map<String, Map<String, String>> transitions;
    private final AtomicReference<String> currentState;

    public StateMachineSelector(String initial, Map<String, Map<String, String>> transitions) {
        this.initial = initial;
        this.currentState = new AtomicReference<>(initial);
        this.transitions = Map.copyOf(transitions);
    }

    @Override
    public String activePhase() {
        return currentState.get();
    }

    @Override
    public String type() { return "state-machine"; }

    @Override
    public void reset() {
        currentState.set(initial);
    }

    public void advance(String trigger) {
        currentState.getAndUpdate(state -> {
            Map<String, String> stateTransitions = transitions.get(state);
            if (stateTransitions == null) return state;
            String next = stateTransitions.get(trigger);
            return next != null ? next : state;
        });
    }
}
```

- [ ] **Step 5: Run StateMachineSelector tests**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=StateMachineSelectorTest`
Expected: ALL PASS

- [ ] **Step 6: Write failing tests for DurationSelector reset**

Add to `DurationSelectorTest.java`:

```java
@Test
void typeReturnsDuration() {
    var selector = new DurationSelector(
            List.of(new CorpusSelectorConfig.DurationPhase("a", Duration.ofSeconds(10))),
            () -> 1.0);
    assertThat(selector.type()).isEqualTo("duration");
}

@Test
void resetRestartsTimer() {
    AtomicLong clock = new AtomicLong(0);
    var selector = new DurationSelector(
            List.of(
                    new CorpusSelectorConfig.DurationPhase("a", Duration.ofSeconds(10)),
                    new CorpusSelectorConfig.DurationPhase("b", null)),
            () -> 1.0,
            clock::get);
    assertThat(selector.activePhase()).isEqualTo("a");

    clock.set(Duration.ofSeconds(15).toNanos());
    assertThat(selector.activePhase()).isEqualTo("b");

    selector.reset();
    assertThat(selector.activePhase()).isEqualTo("a");
}
```

- [ ] **Step 7: Implement type() and reset() on DurationSelector**

Change `startNanos` from `final long` to `AtomicLong`:

```java
public final class DurationSelector implements CorpusSelector {

    private final List<CorpusSelectorConfig.DurationPhase> phases;
    private final SpeedMultiplier speedMultiplier;
    private final LongSupplier nanoSource;
    private final AtomicLong startNanos;

    public DurationSelector(List<CorpusSelectorConfig.DurationPhase> phases,
                            SpeedMultiplier speedMultiplier) {
        this(phases, speedMultiplier, System::nanoTime);
    }

    DurationSelector(List<CorpusSelectorConfig.DurationPhase> phases,
                     SpeedMultiplier speedMultiplier,
                     LongSupplier nanoSource) {
        this.phases = List.copyOf(phases);
        this.speedMultiplier = speedMultiplier;
        this.nanoSource = nanoSource;
        this.startNanos = new AtomicLong(nanoSource.getAsLong());
    }

    @Override
    public String activePhase() {
        long elapsed = nanoSource.getAsLong() - startNanos.get();
        double speed = speedMultiplier.currentSpeed();
        long simulatedNanos = (long) (elapsed * speed);

        long cumulative = 0;
        for (var phase : phases) {
            if (phase.duration() == null || simulatedNanos < cumulative + phase.duration().toNanos()) {
                return phase.name();
            }
            cumulative += phase.duration().toNanos();
        }
        return phases.getLast().name();
    }

    @Override
    public String type() { return "duration"; }

    @Override
    public void reset() {
        startNanos.set(nanoSource.getAsLong());
    }
}
```

Add import: `java.util.concurrent.atomic.AtomicLong`

- [ ] **Step 8: Run DurationSelector tests**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=DurationSelectorTest`
Expected: ALL PASS

- [ ] **Step 9: Write failing test for LookupCountSelector reset**

Add to `LookupCountSelectorTest.java`:

```java
@Test
void typeReturnsLookupCount() {
    var selector = new LookupCountSelector(
            List.of(new CorpusSelectorConfig.CountPhase("a", 5)));
    assertThat(selector.type()).isEqualTo("lookup-count");
}

@Test
void resetZeroesCounter() {
    var selector = new LookupCountSelector(
            List.of(
                    new CorpusSelectorConfig.CountPhase("a", 2),
                    new CorpusSelectorConfig.CountPhase("b", 0)));
    selector.onResolved();
    selector.onResolved();
    assertThat(selector.activePhase()).isEqualTo("b");

    selector.reset();
    assertThat(selector.activePhase()).isEqualTo("a");
}
```

- [ ] **Step 10: Implement type() and reset() on LookupCountSelector**

Add overrides to `LookupCountSelector.java`:

```java
@Override
public String type() { return "lookup-count"; }

@Override
public void reset() {
    resolveCount.set(0);
}
```

- [ ] **Step 11: Implement type() on RandomSelector**

Add override to `RandomSelector.java` (no reset needed — stateless):

```java
@Override
public String type() { return "weighted"; }
```

- [ ] **Step 12: Run all selector tests**

Run: `mvn --batch-mode test -pl simulation-core -Dtest="StateMachineSelectorTest,DurationSelectorTest,LookupCountSelectorTest,RandomSelectorTest"`
Expected: ALL PASS

- [ ] **Step 13: Commit**

```bash
git add simulation-api/src/main/java/io/casehub/platform/simulation/CorpusSelector.java simulation-core/src/main/java/io/casehub/platform/simulation/selector/ simulation-core/src/test/java/io/casehub/platform/simulation/selector/
git commit -m "feat: add type() and reset() to CorpusSelector SPI and implementations (#746)"
```

## Batch 2: SimulationRuntime accessor methods

### Task 2: Add allSelectorInfo(), resetSelector(), advanceStateMachine() to SimulationRuntime

**Files:**
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/SelectorPhaseInfo.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/SimulationRuntimeTest.java`

**Interfaces:**
- Consumes: `CorpusSelector.type()`, `CorpusSelector.reset()`, `CorpusSelector.activePhase()`
- Produces: `SimulationRuntime.allSelectorInfo()` → `Map<String, SelectorPhaseInfo>`, `SimulationRuntime.resetSelector(String)` → `void`, `SimulationRuntime.advanceStateMachine(String, String)` → `void`

- [ ] **Step 1: Create SelectorPhaseInfo record**

Create `simulation-core/src/main/java/io/casehub/platform/simulation/SelectorPhaseInfo.java`:

```java
package io.casehub.platform.simulation;

public record SelectorPhaseInfo(String type, String activePhase) {}
```

- [ ] **Step 2: Write failing tests for SimulationRuntime selector methods**

Add to `SimulationRuntimeTest.java`:

```java
@Test
void allSelectorInfoReturnsAllSelectors() {
    var config = MapSimulationConfig.builder()
            .strategy(QN, "sequential")
            .corpusSelection(QN, new CorpusSelectorConfig.StateMachine(
                    "idle", Map.of("idle", Map.of("go", "active")),
                    Map.of("idle", List.of(), "active", List.of())))
            .build();
    var runtime = new SimulationRuntime(config, new NoOpSimulationCorpus<>());
    runtime.strategyFor(QN);

    var info = runtime.allSelectorInfo();
    assertThat(info).containsKey(QN);
    assertThat(info.get(QN).type()).isEqualTo("state-machine");
    assertThat(info.get(QN).activePhase()).isEqualTo("idle");
}

@Test
void resetSelectorResetsToInitial() {
    var config = MapSimulationConfig.builder()
            .strategy(QN, "sequential")
            .corpusSelection(QN, new CorpusSelectorConfig.StateMachine(
                    "idle", Map.of("idle", Map.of("go", "active")),
                    Map.of("idle", List.of(), "active", List.of())))
            .build();
    var runtime = new SimulationRuntime(config, new NoOpSimulationCorpus<>());
    runtime.strategyFor(QN);
    runtime.advanceStateMachine(QN, "go");
    assertThat(runtime.allSelectorInfo().get(QN).activePhase()).isEqualTo("active");

    runtime.resetSelector(QN);
    assertThat(runtime.allSelectorInfo().get(QN).activePhase()).isEqualTo("idle");
}

@Test
void advanceStateMachineTargetsSpecificSelector() {
    String qn2 = "other-spi.query";
    var config = MapSimulationConfig.builder()
            .strategy(QN, "sequential")
            .corpusSelection(QN, new CorpusSelectorConfig.StateMachine(
                    "a", Map.of("a", Map.of("go", "b")),
                    Map.of("a", List.of(), "b", List.of())))
            .strategy(qn2, "sequential")
            .corpusSelection(qn2, new CorpusSelectorConfig.StateMachine(
                    "x", Map.of("x", Map.of("go", "y")),
                    Map.of("x", List.of(), "y", List.of())))
            .build();
    var runtime = new SimulationRuntime(config, new NoOpSimulationCorpus<>());
    runtime.strategyFor(QN);
    runtime.strategyFor(qn2);

    runtime.advanceStateMachine(QN, "go");
    assertThat(runtime.allSelectorInfo().get(QN).activePhase()).isEqualTo("b");
    assertThat(runtime.allSelectorInfo().get(qn2).activePhase()).isEqualTo("x");
}

@Test
void advanceStateMachineThrowsForNonStateMachine() {
    var config = MapSimulationConfig.builder()
            .strategy(QN, "sequential")
            .corpusSelection(QN, new CorpusSelectorConfig.LookupCount(
                    List.of(new CorpusSelectorConfig.CountPhase("a", 5)),
                    Map.of("a", List.of())))
            .build();
    var runtime = new SimulationRuntime(config, new NoOpSimulationCorpus<>());
    runtime.strategyFor(QN);

    assertThatThrownBy(() -> runtime.advanceStateMachine(QN, "go"))
            .isInstanceOf(IllegalArgumentException.class);
}

@Test
void resetSelectorThrowsForUnknown() {
    var config = MapSimulationConfig.builder().build();
    var runtime = new SimulationRuntime(config, new NoOpSimulationCorpus<>());

    assertThatThrownBy(() -> runtime.resetSelector("nonexistent"))
            .isInstanceOf(IllegalArgumentException.class);
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-core -Dtest="SimulationRuntimeTest#allSelectorInfoReturnsAllSelectors+resetSelectorResetsToInitial+advanceStateMachineTargetsSpecificSelector+advanceStateMachineThrowsForNonStateMachine+resetSelectorThrowsForUnknown" -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — methods don't exist

- [ ] **Step 4: Implement the three methods on SimulationRuntime**

Add to `SimulationRuntime.java`:

```java
public Map<String, SelectorPhaseInfo> allSelectorInfo() {
    var result = new java.util.LinkedHashMap<String, SelectorPhaseInfo>();
    for (var entry : corpusSelectors.entrySet()) {
        var selector = entry.getValue();
        result.put(entry.getKey(), new SelectorPhaseInfo(selector.type(), selector.activePhase()));
    }
    return result;
}

public void resetSelector(String qualifiedName) {
    CorpusSelector selector = corpusSelectors.get(qualifiedName);
    if (selector == null) {
        throw new IllegalArgumentException("No selector registered for: " + qualifiedName);
    }
    selector.reset();
}

public void advanceStateMachine(String qualifiedName, String trigger) {
    CorpusSelector selector = corpusSelectors.get(qualifiedName);
    if (selector == null) {
        throw new IllegalArgumentException("No selector registered for: " + qualifiedName);
    }
    if (!(selector instanceof io.casehub.platform.simulation.selector.StateMachineSelector sms)) {
        throw new IllegalArgumentException(
                "Selector '" + qualifiedName + "' is type '" + selector.type() + "', not a state machine");
    }
    sms.advance(trigger);
}
```

- [ ] **Step 5: Run all SimulationRuntime tests**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=SimulationRuntimeTest`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add simulation-core/src/main/java/io/casehub/platform/simulation/SelectorPhaseInfo.java simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java simulation-core/src/test/java/io/casehub/platform/simulation/SimulationRuntimeTest.java
git commit -m "feat: add selector inspection and control methods to SimulationRuntime (#746)"
```

## Batch 3: MCP domain service

### Task 3: Create CorpusSelectorService @McpDomain and records

**Files:**
- Create: `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/CorpusSelectorService.java`
- Create: `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/CorpusSelectorStatus.java`
- Create: `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/CorpusSelectorAdvanceRequest.java`
- Modify: `event-simulation/pom.xml` (domainFilter)
- Create: `event-simulation/src/test/resources/simulation.yaml`
- Create: `event-simulation/src/test/java/io/casehub/platform/simulation/event/quarkus/CorpusSelectorServiceTest.java`

**Interfaces:**
- Consumes: `SimulationRuntime.allSelectorInfo()`, `SimulationRuntime.resetSelector(String)`, `SimulationRuntime.advanceStateMachine(String, String)`

- [ ] **Step 1: Create CorpusSelectorStatus record**

Create `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/CorpusSelectorStatus.java`:

```java
package io.casehub.platform.simulation.event.quarkus;

public record CorpusSelectorStatus(
        String qualifiedName,
        String type,
        String activePhase) {}
```

- [ ] **Step 2: Create CorpusSelectorAdvanceRequest record**

Create `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/CorpusSelectorAdvanceRequest.java`:

```java
package io.casehub.platform.simulation.event.quarkus;

public record CorpusSelectorAdvanceRequest(String qualifiedName, String trigger) {

    public void validate() {
        if (qualifiedName == null || qualifiedName.isBlank()) {
            throw new IllegalArgumentException("qualifiedName is required");
        }
        if (trigger == null || trigger.isBlank()) {
            throw new IllegalArgumentException("trigger is required");
        }
    }
}
```

- [ ] **Step 3: Create CorpusSelectorService**

Create `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/CorpusSelectorService.java`:

```java
package io.casehub.platform.simulation.event.quarkus;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PathParam;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.platform.api.mcp.RestMethod;
import io.casehub.platform.api.mcp.HttpMethod;
import io.casehub.platform.simulation.SimulationRuntime;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.NotFoundException;

import java.util.List;

@ApplicationScoped
@McpDomain("corpus-selectors")
public class CorpusSelectorService {

    private final SimulationRuntime simulationRuntime;

    @Inject
    public CorpusSelectorService(SimulationRuntime simulationRuntime) {
        this.simulationRuntime = simulationRuntime;
    }

    @PlatformQuery("List all active corpus selectors with type and current phase")
    public List<CorpusSelectorStatus> list() {
        return simulationRuntime.allSelectorInfo().entrySet().stream()
                .map(e -> new CorpusSelectorStatus(e.getKey(), e.getValue().type(), e.getValue().activePhase()))
                .toList();
    }

    @PlatformQuery("Get status of a specific corpus selector")
    public CorpusSelectorStatus status(@PathParam String qualifiedName) {
        var info = simulationRuntime.allSelectorInfo().get(qualifiedName);
        if (info == null) {
            throw new NotFoundException("Selector not found: " + qualifiedName);
        }
        return new CorpusSelectorStatus(qualifiedName, info.type(), info.activePhase());
    }

    @PlatformMutation("Advance a state machine corpus selector by trigger")
    public CorpusSelectorStatus advance(CorpusSelectorAdvanceRequest request) {
        request.validate();
        simulationRuntime.advanceStateMachine(request.qualifiedName(), request.trigger());
        return status(request.qualifiedName());
    }

    @PlatformMutation("Reset a corpus selector to its initial state")
    @RestMethod(HttpMethod.PUT)
    public CorpusSelectorStatus reset(@PathParam String qualifiedName) {
        var info = simulationRuntime.allSelectorInfo().get(qualifiedName);
        if (info == null) {
            throw new NotFoundException("Selector not found: " + qualifiedName);
        }
        simulationRuntime.resetSelector(qualifiedName);
        return status(qualifiedName);
    }
}
```

- [ ] **Step 4: Update domainFilter in event-simulation/pom.xml**

Change the compiler arg from:
```xml
<arg>-AdomainFilter=temporal-drivers</arg>
```
to:
```xml
<arg>-AdomainFilter=temporal-drivers,corpus-selectors</arg>
```

- [ ] **Step 5: Create test simulation.yaml**

Create `event-simulation/src/test/resources/simulation.yaml`:

```yaml
methods:
  test-spi.invoke:
    strategy: sequential
    corpus-selection:
      type: state-machine
      initial: idle
      transitions:
        idle:
          activate: active
        active:
          complete: done
      phases:
        idle:
          - output: "idle response"
        active:
          - output: "active response"
        done:
          - output: "done response"
```

- [ ] **Step 6: Write CorpusSelectorServiceTest**

Create `event-simulation/src/test/java/io/casehub/platform/simulation/event/quarkus/CorpusSelectorServiceTest.java`:

```java
package io.casehub.platform.simulation.event.quarkus;

import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@QuarkusTest
class CorpusSelectorServiceTest {

    @Inject
    CorpusSelectorService service;

    @Test
    void listReturnsRegisteredSelectors() {
        var selectors = service.list();
        assertThat(selectors).isNotEmpty();
        assertThat(selectors).anyMatch(s -> s.qualifiedName().equals("test-spi.invoke"));
    }

    @Test
    void statusReturnsSpecificSelector() {
        var status = service.status("test-spi.invoke");
        assertThat(status.qualifiedName()).isEqualTo("test-spi.invoke");
        assertThat(status.type()).isEqualTo("state-machine");
        assertThat(status.activePhase()).isEqualTo("idle");
    }

    @Test
    void statusThrowsForUnknown() {
        assertThatThrownBy(() -> service.status("nonexistent"))
                .isInstanceOf(jakarta.ws.rs.NotFoundException.class);
    }

    @Test
    void advanceTransitionsStateMachine() {
        service.reset("test-spi.invoke");
        var result = service.advance(
                new CorpusSelectorAdvanceRequest("test-spi.invoke", "activate"));
        assertThat(result.activePhase()).isEqualTo("active");

        service.reset("test-spi.invoke");
    }

    @Test
    void advanceValidatesInput() {
        assertThatThrownBy(() -> service.advance(
                new CorpusSelectorAdvanceRequest(null, "trigger")))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> service.advance(
                new CorpusSelectorAdvanceRequest("qn", null)))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void resetRestoresInitialPhase() {
        service.advance(new CorpusSelectorAdvanceRequest("test-spi.invoke", "activate"));
        assertThat(service.status("test-spi.invoke").activePhase()).isEqualTo("active");

        var result = service.reset("test-spi.invoke");
        assertThat(result.activePhase()).isEqualTo("idle");
    }

    @Test
    void resetThrowsForUnknown() {
        assertThatThrownBy(() -> service.reset("nonexistent"))
                .isInstanceOf(jakarta.ws.rs.NotFoundException.class);
    }
}
```

- [ ] **Step 7: Build and run tests**

Run: `mvn --batch-mode test -pl event-simulation -Dtest=CorpusSelectorServiceTest`
Expected: ALL PASS

- [ ] **Step 8: Run full event-simulation test suite**

Run: `mvn --batch-mode test -pl event-simulation`
Expected: ALL PASS (existing TemporalDriverServiceTest still passes)

- [ ] **Step 9: Commit**

```bash
git add event-simulation/
git commit -m "feat: add CorpusSelectorService @McpDomain for phase inspection (#746)"
```

### Task 4: Full build verification

**Files:** None (verification only)

- [ ] **Step 1: Run full project build**

Run: `mvn --batch-mode install -pl simulation-api,simulation-core,event-simulation -amd`
Expected: BUILD SUCCESS

- [ ] **Step 2: Verify no regressions in downstream modules**

Run: `mvn --batch-mode test -pl simulation-config`
Expected: ALL PASS

## References

- [2026-11-08-mcp-simulation-phase-inspection-design.md] — design spec
- [event-simulation/src/main/java/.../TemporalDriverService.java] — MCP domain pattern
- [simulation-api/src/main/java/.../CorpusSelector.java] — SPI to extend
- [simulation-core/src/main/java/.../SimulationRuntime.java:215-268] — existing selector methods
- [simulation-core/src/main/java/.../selector/] — all four selector implementations
- [GitHub #746] — feat: MCP tool for runtime simulation phase inspection and manual triggers
