# SimulationConfig Global Speed + Capability Wrapper Generation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #373 — TemporalSimulationDriver: Global SimulationConfig speed synchronization
**Issue group:** #373, #375

**Goal:** Add a global speed multiplier to SimulationConfig with reactive driver synchronization, and enhance SimulationDecoratorProcessor to generate recursive wrappers for capability-based @SimulationEligible SPIs.

**Architecture:** Two independent features. #373 adds `speed()` to SimulationConfig as a multiplier (effective = profile.speed × global), with volatile poll for reactive driver sync and per-driver override via `setSpeed()`. #375 adds `capabilities` attribute to @SimulationEligible; the generator produces static inner wrapper classes for capability-returning methods, emits dotted QN constants, and generates a `supports()` override.

**Tech Stack:** Java 21, Jandex (annotation processing), JUnit 5 + AssertJ, Quarkus CDI

## Global Constraints

- `simulation-api` and `simulation-core` are zero-Quarkus — pure Java only
- `simulation-generator` is an APT processor — no CDI, no runtime dependencies
- All new default methods on interfaces must be backward compatible
- Speed values must be positive (> 0), validated at every entry point
- Generated code must compile standalone — all imports explicit

---

## Batch 1: Global Speed Foundation (#373)

### Task 1: SimulationConfig.speed() + MapSimulationConfig + tests

**Files:**
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationConfig.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/MapSimulationConfig.java`
- Modify: `simulation-core/src/test/java/io/casehub/platform/simulation/MapSimulationConfigTest.java`

**Interfaces:**
- Produces: `SimulationConfig.speed()` returning `double` (default 1.0), `MapSimulationConfig.Builder.speed(double)` returning `Builder`

- [ ] **Step 1: Write failing tests for SimulationConfig.speed() default and MapSimulationConfig.Builder.speed()**

Add to `MapSimulationConfigTest.java`:

```java
@Test
void defaultSpeedIsOne() {
    var config = MapSimulationConfig.builder().build();
    assertThat(config.speed()).isEqualTo(1.0);
}

@Test
void builderSpeed() {
    var config = MapSimulationConfig.builder()
            .speed(5.0)
            .build();
    assertThat(config.speed()).isEqualTo(5.0);
}

@Test
void builderSpeedRejectsZero() {
    assertThatThrownBy(() -> MapSimulationConfig.builder().speed(0))
            .isInstanceOf(IllegalArgumentException.class);
}

@Test
void builderSpeedRejectsNegative() {
    assertThatThrownBy(() -> MapSimulationConfig.builder().speed(-1.0))
            .isInstanceOf(IllegalArgumentException.class);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl simulation-core test -Dtest=MapSimulationConfigTest -Dsurefire.failIfNoSpecifiedTests=false --batch-mode -q`
Expected: FAIL — `speed()` method not found

- [ ] **Step 3: Add speed() default method to SimulationConfig**

Add to `SimulationConfig.java` after the `threshold` method:

```java
default double speed() {
    return 1.0;
}
```

- [ ] **Step 4: Add speed field to MapSimulationConfig**

Add `speed` field and constructor parameter to `MapSimulationConfig`:

```java
private final double speed;
```

Add to the private constructor parameters and body:
```java
private MapSimulationConfig(final Map<String, String> strategies,
                             final Map<String, Boolean> captures,
                             final Map<String, ExhaustionPolicy> exhaustionPolicies,
                             final Map<String, Double> thresholds,
                             final double speed) {
    // ... existing assignments ...
    this.speed = speed;
}
```

Add override:
```java
@Override
public double speed() {
    return speed;
}
```

Update `of()` factory methods to pass `1.0` as speed.

Add to Builder:
```java
private double speed = 1.0;

public Builder speed(final double speed) {
    if (speed <= 0) throw new IllegalArgumentException("speed must be positive");
    this.speed = speed;
    return this;
}
```

Update `Builder.build()` to pass `speed`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -pl simulation-core test -Dtest=MapSimulationConfigTest --batch-mode -q`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add simulation-core/src/main/java/io/casehub/platform/simulation/SimulationConfig.java simulation-core/src/main/java/io/casehub/platform/simulation/MapSimulationConfig.java simulation-core/src/test/java/io/casehub/platform/simulation/MapSimulationConfigTest.java
git commit -m "feat(#373): add speed() to SimulationConfig + MapSimulationConfig builder"
```

### Task 2: SimulationRuntime.globalSpeed() + TemporalSimulationDriver speed composition + tests

**Files:**
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/TemporalSimulationDriver.java`
- Modify: `simulation-core/src/test/java/io/casehub/platform/simulation/TemporalSimulationDriverTest.java`

**Interfaces:**
- Consumes: `SimulationConfig.speed()` from Task 1
- Produces: `SimulationRuntime.globalSpeed()` returning `double`, `SimulationRuntime.setGlobalSpeed(double)`, `TemporalSimulationDriver.resetSpeed()`, `TemporalSimulationDriver.effectiveSpeed()` (private)

- [ ] **Step 1: Write failing tests for global speed composition**

Add to `TemporalSimulationDriverTest.java`:

```java
@Test
void globalSpeedComposesWithProfileSpeed() throws Exception {
    var config = MapSimulationConfig.builder().speed(2.0).build();
    var runtime = new SimulationRuntime(config, new NoOpSimulationCorpus<>());
    var events = new CopyOnWriteArrayList<String>();
    var driver = new TemporalSimulationDriver<String>(
            (qn, label, event) -> events.add(event), runtime);

    var profile = new TemporalProfile<>("test", "test.qn", null,
            new TimedSequence<>(List.of(
                    new TimedEntry<>("a", Duration.ofMillis(50)),
                    new TimedEntry<>("b", Duration.ofMillis(50)))),
            false, 10.0);

    // effective = 10.0 * 2.0 = 20.0 → 50ms delay becomes 2.5ms
    driver.start(profile);
    Thread.sleep(200);
    driver.stop();

    assertThat(events).containsExactly("a", "b");
    assertThat(driver.speed()).isEqualTo(20.0);
}

@Test
void localOverrideTakesPrecedence() throws Exception {
    var config = MapSimulationConfig.builder().speed(2.0).build();
    var runtime = new SimulationRuntime(config, new NoOpSimulationCorpus<>());
    var driver = new TemporalSimulationDriver<String>(
            (qn, label, event) -> {}, runtime);

    var profile = new TemporalProfile<>("test", "test.qn", null,
            new TimedSequence<>(List.of(new TimedEntry<>("a", Duration.ofMillis(10)))),
            false, 10.0);

    driver.start(profile);
    driver.setSpeed(5.0);
    assertThat(driver.speed()).isEqualTo(5.0);
    driver.stop();
}

@Test
void resetSpeedRevertsToGlobalComposition() throws Exception {
    var config = MapSimulationConfig.builder().speed(2.0).build();
    var runtime = new SimulationRuntime(config, new NoOpSimulationCorpus<>());
    var driver = new TemporalSimulationDriver<String>(
            (qn, label, event) -> {}, runtime);

    var profile = new TemporalProfile<>("test", "test.qn", null,
            new TimedSequence<>(List.of(new TimedEntry<>("a", Duration.ofMillis(10)))),
            false, 10.0);

    driver.start(profile);
    driver.setSpeed(5.0);
    assertThat(driver.speed()).isEqualTo(5.0);
    driver.resetSpeed();
    assertThat(driver.speed()).isEqualTo(20.0); // 10.0 * 2.0
    driver.stop();
}

@Test
void reactiveGlobalSpeedSync() throws Exception {
    var config = MapSimulationConfig.builder().speed(1.0).build();
    var runtime = new SimulationRuntime(config, new NoOpSimulationCorpus<>());
    var driver = new TemporalSimulationDriver<String>(
            (qn, label, event) -> {}, runtime);

    var profile = new TemporalProfile<>("test", "test.qn", null,
            new TimedSequence<>(List.of(new TimedEntry<>("a", Duration.ofMillis(10)))),
            true, 10.0);

    driver.start(profile);
    assertThat(driver.speed()).isEqualTo(10.0); // 10.0 * 1.0

    runtime.setGlobalSpeed(3.0);
    assertThat(driver.speed()).isEqualTo(30.0); // 10.0 * 3.0

    driver.stop();
}

@Test
void preStartSpeedReflectsGlobal() {
    var config = MapSimulationConfig.builder().speed(5.0).build();
    var runtime = new SimulationRuntime(config, new NoOpSimulationCorpus<>());
    var driver = new TemporalSimulationDriver<String>(
            (qn, label, event) -> {}, runtime);

    // Before start(), activeProfile is null → profileSpeed = 1.0
    assertThat(driver.speed()).isEqualTo(5.0); // 1.0 * 5.0
}

@Test
void nullRuntimeFallsBackToOne() {
    var driver = new TemporalSimulationDriver<String>(
            (qn, label, event) -> {});

    var profile = new TemporalProfile<>("test", "test.qn", null,
            new TimedSequence<>(List.of(new TimedEntry<>("a", Duration.ofMillis(10)))),
            false, 10.0);

    driver.start(profile);
    assertThat(driver.speed()).isEqualTo(10.0); // 10.0 * 1.0 (no runtime)
    driver.stop();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl simulation-core test -Dtest=TemporalSimulationDriverTest --batch-mode -q`
Expected: FAIL — `resetSpeed()` and `globalSpeed()` not found

- [ ] **Step 3: Add globalSpeed to SimulationRuntime**

Add field and methods to `SimulationRuntime.java`:

```java
private volatile double globalSpeed;
```

Initialize in constructor after existing init:
```java
this.globalSpeed = config.speed();
```

Add methods:
```java
public double globalSpeed() {
    return globalSpeed;
}

public void setGlobalSpeed(double speed) {
    if (speed <= 0) throw new IllegalArgumentException("speed must be positive");
    this.globalSpeed = speed;
}
```

- [ ] **Step 4: Refactor TemporalSimulationDriver for three-level speed**

Replace `private volatile double speed;` with:
```java
private volatile Double localSpeedOverride;
private volatile TemporalProfile<E> activeProfile;
```

In `start()`, replace `speed = profile.speed();` with:
```java
this.activeProfile = profile;
this.localSpeedOverride = null;
```

Replace `setSpeed()`:
```java
public void setSpeed(double speed) {
    if (speed <= 0) throw new IllegalArgumentException("speed must be positive");
    this.localSpeedOverride = speed;
}
```

Add `resetSpeed()`:
```java
public void resetSpeed() {
    this.localSpeedOverride = null;
}
```

Replace `speed()`:
```java
public double speed() {
    return effectiveSpeed();
}

private double effectiveSpeed() {
    Double local = localSpeedOverride;
    if (local != null) return local;
    double global = (simulation != null) ? simulation.globalSpeed() : 1.0;
    double profileSpeed = (activeProfile != null) ? activeProfile.speed() : 1.0;
    return profileSpeed * global;
}
```

In `runLoop()`, replace `long delayMs = (long) (entry.delay().toMillis() / speed);` with:
```java
long delayMs = (long) (entry.delay().toMillis() / effectiveSpeed());
```

- [ ] **Step 5: Run ALL driver tests to verify they pass (including existing)**

Run: `mvn -pl simulation-core test -Dtest=TemporalSimulationDriverTest --batch-mode -q`
Expected: PASS (all tests, including existing ones)

- [ ] **Step 6: Commit**

```bash
git add simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java simulation-core/src/main/java/io/casehub/platform/simulation/TemporalSimulationDriver.java simulation-core/src/test/java/io/casehub/platform/simulation/TemporalSimulationDriverTest.java
git commit -m "feat(#373): global speed multiplier on SimulationRuntime + 3-level driver composition"
```

### Task 3: YamlSimulationConfig speed parsing + schema + TemporalDriverService API

**Files:**
- Modify: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/YamlSimulationConfig.java`
- Modify: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/YamlSimulationConfigTest.java`
- Modify: `simulation-config-core/src/main/resources/schema/simulation.schema.json`
- Modify: `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/TemporalDriverService.java`

**Interfaces:**
- Consumes: `SimulationConfig.speed()` from Task 1, `SimulationRuntime.globalSpeed()`/`setGlobalSpeed()` from Task 2
- Produces: `YamlSimulationConfig.speed()` (parsed from YAML), `TemporalDriverService.setGlobalSpeed(double)`, `TemporalDriverService.globalSpeed()`, `TemporalDriverService.resetSpeed(String)`

- [ ] **Step 1: Write failing test for YAML speed parsing**

Add to `YamlSimulationConfigTest.java`:

```java
@Test
void speedParsedFromYaml() {
    String yaml = """
            speed: 5.0
            methods:
              spi.query:
                strategy: seq
            """;
    var config = new YamlSimulationConfig(new ByteArrayInputStream(yaml.getBytes()));
    assertThat(config.speed()).isEqualTo(5.0);
}

@Test
void speedDefaultsToOneWhenAbsent() {
    String yaml = """
            methods:
              spi.query:
                strategy: seq
            """;
    var config = new YamlSimulationConfig(new ByteArrayInputStream(yaml.getBytes()));
    assertThat(config.speed()).isEqualTo(1.0);
}

@Test
void speedRejectsNonPositive() {
    String yaml = """
            speed: 0
            methods:
              spi.query:
                strategy: seq
            """;
    assertThatThrownBy(() -> new YamlSimulationConfig(
            new ByteArrayInputStream(yaml.getBytes())))
            .isInstanceOf(SimulationConfigException.class);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl simulation-config-core test -Dtest=YamlSimulationConfigTest#speedParsedFromYaml --batch-mode -q`
Expected: FAIL

- [ ] **Step 3: Implement YamlSimulationConfig.speed()**

Add field `private final double speed;` to YamlSimulationConfig alongside existing fields.

In the constructor, after the `defaultTenancyId` assignment and before the `parseMethods` call, add:

```java
this.speed = root.containsKey("speed")
        ? ((Number) root.get("speed")).doubleValue() : 1.0;
if (this.speed <= 0) {
    throw new SimulationConfigException("speed must be positive, got: " + this.speed);
}
```

Add override method:
```java
@Override
public double speed() {
    return speed;
}
```

Update `KNOWN_TOP_LEVEL_KEYS` to include `"speed"`:
```java
private static final Set<String> KNOWN_TOP_LEVEL_KEYS =
        Set.of("default-tenancy-id", "methods", "profiles", "temporal-profiles", "speed");
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl simulation-config-core test -Dtest=YamlSimulationConfigTest --batch-mode -q`
Expected: PASS

- [ ] **Step 5: Update JSON schema**

Add `speed` property to the top-level `properties` in `simulation-config-core/src/main/resources/schema/simulation.schema.json`:

```json
"speed": {
  "type": "number",
  "exclusiveMinimum": 0,
  "default": 1.0,
  "description": "Global speed multiplier applied to all temporal drivers"
}
```

- [ ] **Step 6: Add TemporalDriverService global speed API**

Add `SimulationRuntime` as a constructor parameter to `TemporalDriverService`:

```java
private final SimulationRuntime simulationRuntime;

@Inject
public TemporalDriverService(
        TemporalDriverFactory<Map<String, Object>> driverFactory,
        TemporalProfileRegistry profileRegistry,
        SimulationRuntime simulationRuntime) {
    this.driverFactory = driverFactory;
    this.profileRegistry = profileRegistry;
    this.simulationRuntime = simulationRuntime;
}
```

Add methods:

```java
@PlatformMutation
public void setGlobalSpeed(double speed) {
    simulationRuntime.setGlobalSpeed(speed);
}

@PlatformQuery
public double globalSpeed() {
    return simulationRuntime.globalSpeed();
}

@PlatformMutation
public void resetSpeed(String name) {
    requireDriver(name).driver().resetSpeed();
}
```

- [ ] **Step 7: Run full build to verify compilation**

Run: `mvn --batch-mode install -DskipTests -q`
Expected: BUILD SUCCESS

- [ ] **Step 8: Commit**

```bash
git add simulation-config-core/src/main/java/io/casehub/platform/simulation/config/YamlSimulationConfig.java simulation-config-core/src/test/java/io/casehub/platform/simulation/config/YamlSimulationConfigTest.java simulation-config-core/src/main/resources/schema/simulation.schema.json event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/TemporalDriverService.java
git commit -m "feat(#373): YAML speed parsing, JSON schema, TemporalDriverService global speed API"
```

---

## Batch 2: Capability Wrapper Generation (#375)

### Task 4: @SimulationEligible.capabilities attribute + test fixture SPI

**Files:**
- Modify: `simulation-api/src/main/java/io/casehub/platform/simulation/SimulationEligible.java`
- Create: `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/test/TestCapabilitySpi.java`
- Create: `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/test/TestCapability.java`

**Interfaces:**
- Produces: `SimulationEligible.capabilities()` returning `String[]` (default empty), `TestCapabilitySpi` and `TestCapability` test fixture interfaces

- [ ] **Step 1: Add capabilities attribute to @SimulationEligible**

Modify `simulation-api/src/main/java/io/casehub/platform/simulation/SimulationEligible.java`:

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
public @interface SimulationEligible {
    String name() default "";
    String[] capabilities() default {};
}
```

- [ ] **Step 2: Create test base interface (for inheritance testing)**

Create `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/test/TestBaseCapability.java`:

```java
package io.casehub.platform.simulation.generator.test;

public interface TestBaseCapability {
    void close() throws Exception;
}
```

- [ ] **Step 3: Create test capability interface extending base**

Create `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/test/TestCapability.java`:

```java
package io.casehub.platform.simulation.generator.test;

public interface TestCapability extends TestBaseCapability {
    String process(String input);
    void execute();

    static TestCapability noOp() {
        return new TestCapability() {
            @Override public String process(String input) { return null; }
            @Override public void execute() {}
            @Override public void close() {}
        };
    }

    private void internalHelper() {}
}
```

The `extends TestBaseCapability` tests inherited method generation. The `static noOp()` and `private internalHelper()` test filtering of non-overridable methods.

- [ ] **Step 4: Create test SPI with capabilities**

Create `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/test/TestCapabilitySpi.java`:

```java
package io.casehub.platform.simulation.generator.test;

import io.casehub.platform.simulation.SimulationEligible;

@SimulationEligible(name = "capability-spi", capabilities = {"doWork"})
public interface TestCapabilitySpi {
    String id();
    TestCapability doWork();
    boolean supports(Class<?> capability);
}
```

- [ ] **Step 5: Rebuild Jandex index for test fixtures**

Run: `mvn -pl simulation-generator process-test-classes --batch-mode -q`
Expected: Jandex index includes new test classes

- [ ] **Step 6: Commit**

```bash
git add simulation-api/src/main/java/io/casehub/platform/simulation/SimulationEligible.java simulation-generator/src/test/java/io/casehub/platform/simulation/generator/test/TestCapabilitySpi.java simulation-generator/src/test/java/io/casehub/platform/simulation/generator/test/TestCapability.java simulation-generator/src/test/java/io/casehub/platform/simulation/generator/test/TestBaseCapability.java
git commit -m "feat(#375): add capabilities attribute to @SimulationEligible + test fixtures"
```

### Task 5: SimulationDecoratorProcessor — capability detection, wrapper generation, supports(), QN constants

**Files:**
- Modify: `simulation-generator/src/main/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessor.java`
- Modify: `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessorTest.java`

**Interfaces:**
- Consumes: `SimulationEligible.capabilities()` from Task 4, `TestCapabilitySpi`/`TestCapability` fixtures
- Produces: Generated `SimulatedCapabilitySpi` with `DoWork_Wrapper` inner class, `CapabilitySpiQN` with dotted constants, generated `supports()` override

- [ ] **Step 1: Write failing tests for capability wrapper generation**

Add to `SimulationDecoratorProcessorTest.java`:

```java
@Test
void capabilityMethodGeneratesWrapperInnerClass() {
    var sources = new SimulationDecoratorProcessor().generateFromIndex(index);
    String source = findSource(sources, "SimulatedCapabilitySpi");
    assertThat(source).contains("static class DoWork_Wrapper implements TestCapability");
    assertThat(source).contains("new DoWork_Wrapper(delegate.doWork(), simulation, currentPrincipal)");
}

@Test
void wrapperMethodsUseDottedQualifiedNames() {
    var sources = new SimulationDecoratorProcessor().generateFromIndex(index);
    String source = findSource(sources, "SimulatedCapabilitySpi");
    assertThat(source).contains("\"capability-spi.doWork.process\"");
    assertThat(source).contains("\"capability-spi.doWork.execute\"");
}

@Test
void supportsOverrideGenerated() {
    var sources = new SimulationDecoratorProcessor().generateFromIndex(index);
    String source = findSource(sources, "SimulatedCapabilitySpi");
    assertThat(source).contains("public boolean supports(Class<?> capability)");
    assertThat(source).contains("capability == TestCapability.class");
    assertThat(source).contains("simulation.strategyFor(\"capability-spi.doWork.process\")");
    assertThat(source).contains("delegate.supports(capability)");
}

@Test
void qnConstantsIncludeDottedCapabilityMethods() {
    var sources = new SimulationDecoratorProcessor().generateFromIndex(index);
    String source = findSource(sources, "CapabilitySpiQN");
    assertThat(source).contains("DOWORK_PROCESS = \"capability-spi.doWork.process\"");
    assertThat(source).contains("DOWORK_EXECUTE = \"capability-spi.doWork.execute\"");
    assertThat(source).contains("ID = \"capability-spi.id\"");
}

@Test
void inheritedMethodsGenerated() {
    var sources = new SimulationDecoratorProcessor().generateFromIndex(index);
    String source = findSource(sources, "SimulatedCapabilitySpi");
    // close() is inherited from TestBaseCapability
    assertThat(source).contains("\"capability-spi.doWork.close\"");
    // throws clause preserved
    assertThat(source).contains("throws Exception");
}

@Test
void staticAndPrivateMethodsFiltered() {
    var sources = new SimulationDecoratorProcessor().generateFromIndex(index);
    String source = findSource(sources, "SimulatedCapabilitySpi");
    // static noOp() and private internalHelper() must NOT appear
    assertThat(source).doesNotContain("noOp");
    assertThat(source).doesNotContain("internalHelper");
}

@Test
void capabilityInterfaceTypeImported() {
    var sources = new SimulationDecoratorProcessor().generateFromIndex(index);
    String source = findSource(sources, "SimulatedCapabilitySpi");
    assertThat(source).contains("import io.casehub.platform.simulation.generator.test.TestCapability;");
}

@Test
void flatSpiUnchangedWithEmptyCapabilities() {
    var sources = new SimulationDecoratorProcessor().generateFromIndex(index);
    String source = findSource(sources, "SimulatedTestSimpleService");
    // No wrapper classes, no supports override
    assertThat(source).doesNotContain("_Wrapper");
    assertThat(source).doesNotContain("supports(Class<?>");
}

@Test
void parameterEntriesIncludeCapabilityMethods() {
    var entries = new SimulationDecoratorProcessor().generateParameterEntries(index);
    assertThat(entries).containsKey("capability-spi.doWork.process");
    assertThat(entries).containsKey("capability-spi.doWork.execute");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl simulation-generator test -Dtest=SimulationDecoratorProcessorTest#capabilityMethodGeneratesWrapperInnerClass --batch-mode -q`
Expected: FAIL — no wrapper class generated

- [ ] **Step 3: Implement capability detection in generateFromIndex()**

In `generateFromIndex()`, after reading `nameVal`, add:

```java
final AnnotationValue capVal = ann.value("capabilities");
final String[] capabilities = (capVal != null) ? capVal.asStringArray() : new String[0];
final Set<String> capabilitySet = Set.of(capabilities);
```

Pass `capabilitySet` to `generateDecoratorSource()` (add parameter).

- [ ] **Step 4: Implement helper method to collect all methods from an interface hierarchy**

Add new method to `SimulationDecoratorProcessor`:

```java
private List<MethodInfo> collectAllMethods(ClassInfo classInfo, IndexView index) {
    List<MethodInfo> allMethods = new ArrayList<>();
    Set<String> visited = new HashSet<>();
    collectMethodsRecursive(classInfo, index, allMethods, visited);
    return allMethods;
}

private void collectMethodsRecursive(ClassInfo classInfo, IndexView index,
                                      List<MethodInfo> result, Set<String> visited) {
    if (classInfo == null || !visited.add(classInfo.name().toString())) return;

    for (MethodInfo method : classInfo.methods()) {
        if (method.isSynthetic()) continue;
        if (java.lang.reflect.Modifier.isStatic(method.flags())) continue;
        if (!java.lang.reflect.Modifier.isPublic(method.flags())) continue;
        result.add(method);
    }

    for (Type iface : classInfo.interfaceTypes()) {
        ClassInfo parent = index.getClassByName(iface.name());
        if (parent == null) parent = indexClassFromClasspath(iface.name().toString());
        collectMethodsRecursive(parent, index, result, visited);
    }
}
```

- [ ] **Step 5: Implement wrapper inner class generation**

Modify `generateDecoratorSource()` to accept `Set<String> capabilitySet`. For each method whose name is in `capabilitySet`:

1. Skip `generateSimulatedMethod()` for this method
2. Instead, emit the capability accessor that returns a wrapper instance
3. Resolve the return type's ClassInfo via Jandex
4. Collect all methods from the capability interface hierarchy via `collectAllMethods()`
5. Generate a static inner class with each method following the intercept-or-delegate pattern using dotted QNs

The wrapper accessor method:
```java
sb.append("    @Override\n");
sb.append("    public ").append(capReturnType).append(" ").append(method.name()).append("() {\n");
sb.append("        return new ").append(wrapperName)
  .append("(delegate.").append(method.name()).append("(), simulation, currentPrincipal);\n");
sb.append("    }\n\n");
```

The inner class:
```java
sb.append("    static class ").append(wrapperName)
  .append(" implements ").append(capReturnType).append(" {\n");
sb.append("        private final ").append(capReturnType).append(" delegate;\n");
sb.append("        private final SimulationRuntime simulation;\n");
sb.append("        private final CurrentPrincipal currentPrincipal;\n\n");
// constructor
// each method via generateSimulatedMethod() with spiName + "." + capMethodName prefix
sb.append("    }\n\n");
```

For each method in the wrapper, use `spiName + "." + capabilityMethodName + "." + method.name()` as the qualified name.

Also update `generateSimulatedMethod()` to emit throws clauses. After `(params)` and before `{`, check `method.exceptions()` and emit `throws ExType1, ExType2` if non-empty:

```java
if (!method.exceptions().isEmpty()) {
    sb.append(" throws ");
    for (int i = 0; i < method.exceptions().size(); i++) {
        if (i > 0) sb.append(", ");
        sb.append(typeToJava(method.exceptions().get(i)));
    }
}
```

Add the exception types to `collectParameterImports()` as well.

- [ ] **Step 6: Implement supports() override generation**

After generating all methods, check if the SPI has a `supports(Class<?>)` method and `capabilitySet` is non-empty. If so, generate the override:

```java
if (!capabilitySet.isEmpty() && hasSupportsMethod(spiClass)) {
    sb.append("    @Override\n");
    sb.append("    public boolean supports(Class<?> capability) {\n");
    for (String capName : capabilitySet) {
        // Find the method, get its return type
        MethodInfo capMethod = findMethod(spiClass, capName);
        ClassInfo capInterface = index.getClassByName(capMethod.returnType().name());
        List<MethodInfo> capMethods = collectAllMethods(capInterface, index);

        sb.append("        if (capability == ").append(capInterface.simpleName()).append(".class) {\n");
        sb.append("            return ");
        boolean first = true;
        for (MethodInfo m : capMethods) {
            if (!first) sb.append("\n                    || ");
            String qn = spiName + "." + capName + "." + m.name();
            sb.append("simulation.strategyFor(\"").append(qn).append("\").isPresent()");
            first = false;
        }
        sb.append("\n                    || delegate.supports(capability);\n");
        sb.append("        }\n");
    }
    sb.append("        return delegate.supports(capability);\n");
    sb.append("    }\n\n");
}
```

- [ ] **Step 7: Update QN constant generation for dotted capability names**

Modify `generateQNSource()` to accept `capabilitySet` and `IndexView`. For capability methods, recurse into the capability interface and generate dotted constants:

```java
for (String capName : capabilitySet) {
    MethodInfo capMethod = findMethod(spiClass, capName);
    ClassInfo capInterface = index.getClassByName(capMethod.returnType().name());
    List<MethodInfo> capMethods = collectAllMethods(capInterface, index);
    for (MethodInfo m : capMethods) {
        String constName = capName.toUpperCase() + "_" + m.name().toUpperCase();
        String qn = spiName + "." + capName + "." + m.name();
        sb.append("    public static final String ").append(constName)
          .append(" = \"").append(qn).append("\";\n");
    }
}
```

- [ ] **Step 8: Update parameter entries for capability methods**

Modify `addParameterEntries()` to accept `capabilitySet` and `IndexView`. For capability methods, recurse and emit dotted QN entries:

```java
for (String capName : capabilitySet) {
    MethodInfo capMethod = findMethod(classInfo, capName);
    if (capMethod == null) continue;
    ClassInfo capInterface = index.getClassByName(capMethod.returnType().name());
    if (capInterface == null) capInterface = indexClassFromClasspath(capMethod.returnType().name().toString());
    if (capInterface == null) continue;
    List<MethodInfo> capMethods = collectAllMethods(capInterface, index);
    for (MethodInfo m : capMethods) {
        String qn = spiName + "." + capName + "." + m.name();
        // same parameter entry logic as existing addParameterEntries
    }
}
```

- [ ] **Step 9: Update collectParameterImports() for capability interfaces**

Modify `collectParameterImports()` to accept `capabilitySet` and `IndexView`. For each capability method, add the capability interface type import and all parameter/return type imports from its methods:

```java
for (String capName : capabilitySet) {
    MethodInfo capMethod = findMethod(spiClass, capName);
    if (capMethod == null) continue;
    addTypeImport(imports, capMethod.returnType());
    ClassInfo capInterface = index.getClassByName(capMethod.returnType().name());
    if (capInterface != null) {
        List<MethodInfo> capMethods = collectAllMethods(capInterface, index);
        for (MethodInfo m : capMethods) {
            for (Type paramType : m.parameterTypes()) {
                addTypeImport(imports, paramType);
            }
            if (m.returnType().kind() != Type.Kind.VOID) {
                addTypeImport(imports, m.returnType());
            }
        }
    }
}
```

- [ ] **Step 10: Run all generator tests**

Run: `mvn -pl simulation-generator test --batch-mode -q`
Expected: ALL PASS (both new capability tests and existing flat tests)

- [ ] **Step 11: Run full build**

Run: `mvn --batch-mode install -DskipTests -q`
Expected: BUILD SUCCESS

- [ ] **Step 12: Commit**

```bash
git add simulation-generator/src/main/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessor.java simulation-generator/src/test/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessorTest.java
git commit -m "feat(#375): recursive wrapper generation for capability-based @SimulationEligible SPIs"
```

---

## References

- [2026-09-21-simulation-config-speed-and-capability-wrappers-design.md](../specs/issue-373-simulation-config-speed-and-capability-wrappers/2026-09-21-simulation-config-speed-and-capability-wrappers-design.md) — design spec this plan implements
- simulation-core/SimulationConfig.java:5 — interface to extend with speed()
- simulation-core/MapSimulationConfig.java:7 — builder to extend with speed field
- simulation-core/SimulationRuntime.java:18 — runtime to add globalSpeed field
- simulation-core/TemporalSimulationDriver.java:8 — driver to refactor for 3-level speed
- simulation-config-core/YamlSimulationConfig.java:31 — YAML parser to add speed parsing
- simulation-generator/SimulationDecoratorProcessor.java:37 — generator to enhance for capabilities
- simulation-api/SimulationEligible.java:10 — annotation to add capabilities attribute
- event-simulation/TemporalDriverService.java:27 — service to add global speed API
- connectors specs/issue-105-simulation-eligible-calendar-chat/decisions.md — D1, D5, D7 design basis
- [GitHub #373](https://github.com/casehubio/platform/issues/373) — global speed issue
- [GitHub #375](https://github.com/casehubio/platform/issues/375) — capability wrappers issue
