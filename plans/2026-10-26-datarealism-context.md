# DataRealism Request-Scoped Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #660 — feat: DataRealism response metadata for simulation framework
**Issue group:** #660

**Goal:** Add a request-scoped DataRealismContext that lets callers check the realism level of the most recent SPI call at call time, without querying the journal.

**Architecture:** A plain mutable POJO (`DataRealismContext`) in simulation-core holds a last-write-wins `Observation` record (qualifiedName + DataRealism). CDI `@RequestScoped` producer in simulation-config provides per-request instances. The `SimulationDecoratorProcessor` generator is updated to inject and set the context in every generated decorator.

**Tech Stack:** Java 21, CDI (Jakarta), Jandex (annotation processor), JUnit 5, AssertJ

## Global Constraints

- simulation-core has no CDI, no Spring imports — DataRealismContext must be a plain POJO
- simulation-api must remain zero-dependency
- No ThreadLocal — scope-managed isolation only
- No changes to JournalEntry, SimulationStrategy, InvocationJournal, SimulationRuntime, or concrete strategies

---

## Batch 1: DataRealismContext POJO + CDI Producer

### Task 1: DataRealismContext class and unit test

**Files:**
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/DataRealismContext.java`
- Create: `simulation-core/src/test/java/io/casehub/platform/simulation/DataRealismContextTest.java`

**Interfaces:**
- Consumes: `DataRealism` enum from simulation-api
- Produces: `DataRealismContext` class with `set(String, DataRealism)`, `current()`, `dataRealism()` — used by Tasks 2, 3, 4

- [ ] **Step 1: Write the failing test**

```java
package io.casehub.platform.simulation;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class DataRealismContextTest {

    @Test
    void initialStateIsNull() {
        var context = new DataRealismContext();
        assertThat(context.current()).isNull();
        assertThat(context.dataRealism()).isNull();
    }

    @Test
    void setRecordsObservation() {
        var context = new DataRealismContext();
        context.set("acl.canAccess", DataRealism.DOMAIN_PLAUSIBLE);

        assertThat(context.current()).isNotNull();
        assertThat(context.current().qualifiedName()).isEqualTo("acl.canAccess");
        assertThat(context.current().dataRealism()).isEqualTo(DataRealism.DOMAIN_PLAUSIBLE);
        assertThat(context.dataRealism()).isEqualTo(DataRealism.DOMAIN_PLAUSIBLE);
    }

    @Test
    void lastWriteWins() {
        var context = new DataRealismContext();
        context.set("acl.canAccess", DataRealism.DOMAIN_PLAUSIBLE);
        context.set("memory.store", DataRealism.STRUCTURALLY_VALID);

        assertThat(context.current().qualifiedName()).isEqualTo("memory.store");
        assertThat(context.dataRealism()).isEqualTo(DataRealism.STRUCTURALLY_VALID);
    }

    @Test
    void nullDataRealismForDeterministicFallthrough() {
        var context = new DataRealismContext();
        context.set("registry.register", null);

        assertThat(context.current()).isNotNull();
        assertThat(context.current().qualifiedName()).isEqualTo("registry.register");
        assertThat(context.dataRealism()).isNull();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=DataRealismContextTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — `DataRealismContext` class does not exist

- [ ] **Step 3: Write the implementation**

```java
package io.casehub.platform.simulation;

public class DataRealismContext {

    public record Observation(String qualifiedName, DataRealism dataRealism) {}

    private Observation current;

    public void set(String qualifiedName, DataRealism dataRealism) {
        current = new Observation(qualifiedName, dataRealism);
    }

    public Observation current() {
        return current;
    }

    public DataRealism dataRealism() {
        return current != null ? current.dataRealism() : null;
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=DataRealismContextTest`
Expected: PASS — all 4 tests green

- [ ] **Step 5: Commit**

```bash
git add simulation-core/src/main/java/io/casehub/platform/simulation/DataRealismContext.java simulation-core/src/test/java/io/casehub/platform/simulation/DataRealismContextTest.java
git commit -m "feat(simulation-core): add DataRealismContext POJO Refs #660"
```

### Task 2: CDI @RequestScoped producer in SimulationConfigBeans

**Files:**
- Modify: `simulation-config/src/main/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigBeans.java`

**Interfaces:**
- Consumes: `DataRealismContext` class from Task 1
- Produces: CDI `@RequestScoped DataRealismContext` bean — available for injection in generated decorators and consumer code

- [ ] **Step 1: Add the @Produces method**

Add the following imports to `SimulationConfigBeans.java`:

```java
import io.casehub.platform.simulation.DataRealismContext;
import jakarta.enterprise.context.RequestScoped;
```

Add a new `@Produces` method after the existing `simulationRuntime` producer (after line 69):

```java
@Produces
@RequestScoped
public DataRealismContext dataRealismContext() {
    return new DataRealismContext();
}
```

- [ ] **Step 2: Verify compilation**

Run: `mvn --batch-mode compile -pl simulation-config`
Expected: BUILD SUCCESS

- [ ] **Step 3: Commit**

```bash
git add simulation-config/src/main/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigBeans.java
git commit -m "feat(simulation-config): add @RequestScoped DataRealismContext producer Refs #660"
```

## Batch 2: Generator Changes + End-to-End Tests

### Task 3: Update SimulationDecoratorProcessor to inject and set DataRealismContext

**Files:**
- Modify: `simulation-generator/src/main/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessor.java`
- Modify: `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessorTest.java`

**Interfaces:**
- Consumes: `DataRealismContext` class from Task 1
- Produces: Generated decorators now inject `DataRealismContext` and call `set()` on every SPI method invocation

- [ ] **Step 1: Write failing tests for the new generator behavior**

Add these tests to `SimulationDecoratorProcessorTest.java`:

```java
@Test
void generatedDecoratorInjectsDataRealismContext() {
    final var processor = new SimulationDecoratorProcessor();
    final List<SimulationDecoratorProcessor.GeneratedSource> sources = processor.generateFromIndex(index);
    final String code = findSource(sources, "TestSimpleService");

    assertThat(code).contains("@Inject DataRealismContext dataRealismContext");
    assertThat(code).contains("import io.casehub.platform.simulation.DataRealismContext;");
}

@Test
void simulatedPathSetsDataRealismContext() {
    final var processor = new SimulationDecoratorProcessor();
    final List<SimulationDecoratorProcessor.GeneratedSource> sources = processor.generateFromIndex(index);
    final String code = findSource(sources, "TestSimpleService");

    assertThat(code).contains("dataRealismContext.set(qualifiedName, strategy.get().dataRealism())");
}

@Test
void fallthroughPathSetsDataRealismContextWithCapturedVariable() {
    final var processor = new SimulationDecoratorProcessor();
    final List<SimulationDecoratorProcessor.GeneratedSource> sources = processor.generateFromIndex(index);
    final String code = findSource(sources, "TestSimpleService");

    assertThat(code).contains("DataRealism __ftRealism = simulation.fallthroughRealism(qualifiedName)");
    assertThat(code).contains("dataRealismContext.set(qualifiedName, __ftRealism)");
}

@Test
void capabilityWrapperReceivesDataRealismContextInConstructor() {
    var sources = new SimulationDecoratorProcessor().generateFromIndex(index);
    String source = findSource(sources, "SimulatedTestCapabilitySpi");

    assertThat(source).contains("private final DataRealismContext dataRealismContext;");
    assertThat(source).contains("new DoWork_Wrapper(delegate.doWork(), simulation, currentPrincipal, dataRealismContext)");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-generator -Dtest=SimulationDecoratorProcessorTest`
Expected: FAIL — generated code does not contain DataRealismContext references

- [ ] **Step 3: Update generateDecoratorSource to add the @Inject field**

In `SimulationDecoratorProcessor.java`, in the `generateDecoratorSource` method, after the line that emits `@Inject CurrentPrincipal currentPrincipal;` (around line 178), add:

```java
sb.append("    @Inject DataRealismContext dataRealismContext;\n\n");
```

Also add the import line in the same method. After the existing import for `DataRealism` (around line 158), the import is already there — `DataRealismContext` is in the same package as `DataRealism` (`io.casehub.platform.simulation`), so add:

```java
sb.append("import io.casehub.platform.simulation.DataRealismContext;\n");
```

- [ ] **Step 4: Update generateSimulatedMethod for strategy-resolved path**

In the `generateSimulatedMethod` method, in the strategy-resolved block (the `if (strategy.isPresent()...)` block):

For the **non-void** strategy path, after the `recordJournal` call and before the return, add:

```java
sb.append(indent).append("        dataRealismContext.set(qualifiedName, strategy.get().dataRealism());\n");
```

For the **void** strategy path, after the `recordJournal` call and before the return, add:

```java
sb.append(indent).append("        dataRealismContext.set(qualifiedName, strategy.get().dataRealism());\n");
```

- [ ] **Step 5: Update generateSimulatedMethod for fallthrough path**

In the fallthrough block (after the `if` block closes), replace the existing `recordJournal` pattern. Currently the fallthrough looks like:

For **non-void**:
```java
// Current:
simulation.recordJournal(qualifiedName, __simTenancyId, input, result, simulation.fallthroughRealism(qualifiedName));
```

Replace with a captured-variable pattern:
```java
sb.append(indent).append("    DataRealism __ftRealism = simulation.fallthroughRealism(qualifiedName);\n");
```

Then change the `recordJournal` call to use `__ftRealism` instead of `simulation.fallthroughRealism(qualifiedName)`:
```java
sb.append(indent).append("    simulation.recordJournal(qualifiedName, __simTenancyId, ").append(inputExpr).append(", result, __ftRealism);\n");
sb.append(indent).append("    dataRealismContext.set(qualifiedName, __ftRealism);\n");
```

Apply the same pattern for the **void** variant.

- [ ] **Step 6: Update generateWrapperInnerClass for capability wrappers**

In `generateWrapperInnerClass`, add `DataRealismContext dataRealismContext` as a fourth field and constructor parameter.

Add the field declaration:
```java
sb.append("        private final DataRealismContext dataRealismContext;\n\n");
```

Add the constructor parameter and assignment:
```java
// constructor signature adds: DataRealismContext dataRealismContext
// constructor body adds: this.dataRealismContext = dataRealismContext;
```

- [ ] **Step 7: Update generateCapabilityAccessor to pass dataRealismContext**

In `generateCapabilityAccessor`, change the wrapper constructor call to pass the fourth parameter:
```java
sb.append("        return new ").append(wrapperName)
  .append("(delegate.").append(method.name()).append("(), simulation, currentPrincipal, dataRealismContext);\n");
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-generator -Dtest=SimulationDecoratorProcessorTest`
Expected: PASS — all tests green (existing + new)

- [ ] **Step 9: Commit**

```bash
git add simulation-generator/src/main/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessor.java simulation-generator/src/test/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessorTest.java
git commit -m "feat(simulation-generator): inject and set DataRealismContext in generated decorators Refs #660"
```

### Task 4: Update DataRealismEndToEndTest to verify context is set

**Files:**
- Modify: `platform-simulation-core/src/test/java/io/casehub/platform/simulation/platform/DataRealismEndToEndTest.java`

**Interfaces:**
- Consumes: `DataRealismContext` from Task 1, generated decorators from Task 3

- [ ] **Step 1: Add DataRealismContext to test setUp**

In `DataRealismEndToEndTest.java`, add a field:
```java
private DataRealismContext dataRealismContext;
```

In `setUp()`, after the existing `inject(decorator, "currentPrincipal", principal)`, add:
```java
dataRealismContext = new DataRealismContext();
inject(decorator, "dataRealismContext", dataRealismContext);
```

Add the import:
```java
import io.casehub.platform.simulation.DataRealismContext;
```

- [ ] **Step 2: Add context assertions to existing tests**

In `strategyResolvedPath()`, after the existing journal assertions, add:
```java
assertThat(dataRealismContext.current()).isNotNull();
assertThat(dataRealismContext.current().qualifiedName()).isEqualTo(EndpointRegistryQN.DISCOVER);
assertThat(dataRealismContext.dataRealism()).isEqualTo(DataRealism.STRUCTURALLY_VALID);
```

In `interpretiveFallthroughPath()`, after the existing journal assertions, add:
```java
assertThat(dataRealismContext.current()).isNotNull();
assertThat(dataRealismContext.current().qualifiedName()).isEqualTo(EndpointRegistryQN.RESOLVE);
assertThat(dataRealismContext.dataRealism()).isEqualTo(DataRealism.DOMAIN_PLAUSIBLE);
```

In `deterministicDelegatePath()`, after the existing journal assertions, add:
```java
assertThat(dataRealismContext.current()).isNotNull();
assertThat(dataRealismContext.current().qualifiedName()).isEqualTo(EndpointRegistryQN.REGISTER);
assertThat(dataRealismContext.dataRealism()).isNull();
```

In `strategyCannotResolveFallsThrough()`, after the existing journal assertions, add:
```java
assertThat(dataRealismContext.current()).isNotNull();
assertThat(dataRealismContext.current().qualifiedName()).isEqualTo(EndpointRegistryQN.DEREGISTER);
assertThat(dataRealismContext.dataRealism()).isEqualTo(DataRealism.DOMAIN_PLAUSIBLE);
```

- [ ] **Step 3: Build to regenerate decorators, then run tests**

The generated `SimulatedEndpointRegistry` must be regenerated with the new DataRealismContext field. The regeneration happens during the compile phase because `SimulationDecoratorProcessor` is an APT.

Run: `mvn --batch-mode test -pl platform-simulation-core -Dtest=DataRealismEndToEndTest`
Expected: PASS — all 4 tests verify both journal AND context

If tests fail because the generated decorator wasn't regenerated, run a full compile first:
```bash
mvn --batch-mode compile -pl simulation-generator,platform-simulation-core
```
Then re-run the tests.

- [ ] **Step 4: Run full build to verify nothing else breaks**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and test, including consumer modules that use generated decorators

- [ ] **Step 5: Commit**

```bash
git add platform-simulation-core/src/test/java/io/casehub/platform/simulation/platform/DataRealismEndToEndTest.java
git commit -m "test(platform-simulation-core): verify DataRealismContext set in all decorator paths Refs #660"
```

## References

- [2026-10-26-datarealism-context-design.md] — design spec this plan implements
- SimulationDecoratorProcessor.java:332-416 — generateSimulatedMethod
- SimulationDecoratorProcessor.java:142-206 — generateDecoratorSource
- SimulationDecoratorProcessor.java:220-247 — generateWrapperInnerClass
- SimulationDecoratorProcessor.java:209-218 — generateCapabilityAccessor
- SimulationConfigBeans.java:63-69 — existing @Produces pattern
- DataRealismEndToEndTest.java — existing end-to-end test
- SimulationDecoratorProcessorTest.java — existing generator unit tests
- GitHub #660 — parent issue
