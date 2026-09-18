# Strategy Configuration and Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #329 — strategy combination and lifecycle
**Issue group:** #312, #313, #314, #315, #317, #318, #319, #320, #321, #322, #323, #325, #326, #327, #328, #329, #330, #332

**Goal:** Add named simulation profiles that bundle per-method strategy configs with corpus data, activatable at boot time or runtime via the overlay stack.

**Architecture:** Profiles are a naming layer over the existing SimulationConfig + overlay stack. SmallRyeSimulationConfig parses profile config alongside flat config and implements a new ProfileSource functional interface. SimulationRuntime gains pushProfile(name) as a convenience over manual overlay construction. No new modules.

**Tech Stack:** Java 21, JUnit 5, AssertJ, SmallRye Config, Jackson/SnakeYAML (via YamlCorpusLoader)

## Global Constraints

- No new modules — all changes in simulation-core, simulation-config-core, simulation-config
- SimulationConfig interface is unchanged — no new methods
- Zero migration — existing flat configs keep working unchanged
- Single active profile at boot time (no comma-separated multi-profile)
- Profile corpus loaded by ProfileSource (simulation-config-core), not SimulationRuntime (simulation-core)

---

## Batch 1: Profile types and runtime support

### Task 1: ProfileSource and SimulationProfile types + SimulationRuntime.pushProfile()

**Files:**
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/ProfileSource.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationProfile.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/SimulationRuntimeTest.java`

**Interfaces:**
- Produces: `ProfileSource` — `@FunctionalInterface`, `Optional<SimulationProfile> resolve(String name)`
- Produces: `SimulationProfile` — `record(SimulationConfig config, SimulationCorpus<?, ?> corpus)`
- Produces: `SimulationRuntime.setProfileSource(ProfileSource)` — wires profile source
- Produces: `SimulationRuntime.pushProfile(String name)` — returns `SimulationOverlay`

- [ ] **Step 1: Write failing tests for pushProfile**

Add tests to the existing `SimulationRuntimeTest.java`. These tests use the existing `TestCorpus` and `stubConfig` helpers.

```java
// --- pushProfile ---

@Test
void pushProfileActivatesNamedProfile() {
    final var baseConfig = stubConfig(Optional.empty(), false, Optional.empty());
    final var runtime = new SimulationRuntime(baseConfig, new NoOpSimulationCorpus<>());

    final var profileCorpus = new TestCorpus();
    profileCorpus.seed(QN, List.of(new InvocationRecord<>("t1", null, "in", "profile-value", Instant.now())));
    final var profileConfig = MapSimulationConfig.of(Map.of(QN, "sequential"));
    final var profile = new SimulationProfile(profileConfig, profileCorpus);

    runtime.setProfileSource(name -> "test-profile".equals(name) ? Optional.of(profile) : Optional.empty());

    final var overlay = runtime.pushProfile("test-profile");
    final var strategy = runtime.<String, String>strategyFor(QN);
    assertThat(strategy).isPresent();
    assertThat(strategy.get().resolve("in")).isEqualTo("profile-value");

    runtime.popOverlay(overlay);
    assertThat(runtime.<String, String>strategyFor(QN)).isEmpty();
}

@Test
void pushProfileThrowsForUnknownProfile() {
    final var baseConfig = stubConfig(Optional.empty(), false, Optional.empty());
    final var runtime = new SimulationRuntime(baseConfig, new NoOpSimulationCorpus<>());
    runtime.setProfileSource(name -> Optional.empty());

    assertThatThrownBy(() -> runtime.pushProfile("nonexistent"))
            .isInstanceOf(SimulationConfigException.class)
            .hasMessageContaining("nonexistent");
}

@Test
void pushProfileThrowsWhenNoProfileSource() {
    final var baseConfig = stubConfig(Optional.empty(), false, Optional.empty());
    final var runtime = new SimulationRuntime(baseConfig, new NoOpSimulationCorpus<>());

    assertThatThrownBy(() -> runtime.pushProfile("any"))
            .isInstanceOf(SimulationConfigException.class)
            .hasMessageContaining("ProfileSource");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=SimulationRuntimeTest#pushProfile* -Dsurefire.failIfNoSpecifiedTests=false`
Expected: Compilation failure — `ProfileSource`, `SimulationProfile` don't exist yet.

- [ ] **Step 3: Create ProfileSource interface**

Create `simulation-core/src/main/java/io/casehub/platform/simulation/ProfileSource.java`:

```java
package io.casehub.platform.simulation;

import java.util.Optional;

@FunctionalInterface
public interface ProfileSource {
    Optional<SimulationProfile> resolve(String name);
}
```

- [ ] **Step 4: Create SimulationProfile record**

Create `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationProfile.java`:

```java
package io.casehub.platform.simulation;

public record SimulationProfile(SimulationConfig config,
                                SimulationCorpus<?, ?> corpus) {}
```

- [ ] **Step 5: Add setProfileSource and pushProfile to SimulationRuntime**

Add a `profileSource` field and two methods to `SimulationRuntime`:

```java
private ProfileSource profileSource;

public void setProfileSource(final ProfileSource profileSource) {
    this.profileSource = profileSource;
}

@SuppressWarnings({"rawtypes", "unchecked"})
public SimulationOverlay pushProfile(final String name) {
    if (profileSource == null) {
        throw new SimulationConfigException(
                "No ProfileSource registered — cannot resolve profile '" + name + "'");
    }
    final SimulationProfile profile = profileSource.resolve(name)
            .orElseThrow(() -> new SimulationConfigException(
                    "Unknown simulation profile: '" + name + "'"));
    return pushOverlay(profile.config(), (SimulationCorpus) profile.corpus());
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=SimulationRuntimeTest`
Expected: All tests PASS (including existing overlay tests).

- [ ] **Step 7: Commit**

```bash
git add simulation-core/src/main/java/io/casehub/platform/simulation/ProfileSource.java simulation-core/src/main/java/io/casehub/platform/simulation/SimulationProfile.java simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java simulation-core/src/test/java/io/casehub/platform/simulation/SimulationRuntimeTest.java
git commit -m "feat(#329): add ProfileSource, SimulationProfile, and pushProfile to SimulationRuntime

Refs #329"
```

---

## Batch 2: Profile parsing and active profile

### Task 2: SmallRyeSimulationConfig profile parsing + ProfileSource implementation

**Files:**
- Modify: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/SmallRyeSimulationConfig.java`
- Test: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/SmallRyeSimulationConfigTest.java`

**Interfaces:**
- Consumes: `ProfileSource` from Task 1 — `Optional<SimulationProfile> resolve(String name)`
- Consumes: `SimulationProfile` from Task 1 — `record(SimulationConfig, SimulationCorpus<?, ?>)`
- Consumes: `MapSimulationConfig` — `MapSimulationConfig.of(Map<String, String>)` for composed fallback config
- Produces: `SmallRyeSimulationConfig implements ProfileSource`
- Produces: `SmallRyeSimulationConfig.profileNames()` — `Set<String>`
- Produces: `SmallRyeSimulationConfig.activeProfileCorpusFiles()` — `Optional<List<String>>`

- [ ] **Step 1: Write failing tests for profile parsing**

Add to `SmallRyeSimulationConfigTest.java`:

```java
@Test
void parsesProfileEntries() {
    var config = new SmallRyeConfigBuilder()
            .withDefaultValue("casehub.simulation.profiles.ci-replay.agent-provider.invoke.strategy", "recorded-replay")
            .withDefaultValue("casehub.simulation.profiles.ci-replay.notification-store.store.strategy", "sequential")
            .build();
    var simConfig = new SmallRyeSimulationConfig(config);

    assertThat(simConfig.profileNames()).containsExactly("ci-replay");
}

@Test
void parsesProfileCorpusFiles() {
    var config = new SmallRyeConfigBuilder()
            .withDefaultValue("casehub.simulation.profiles.ci-replay.corpus.files", "fixtures/captured.yaml")
            .withDefaultValue("casehub.simulation.profiles.ci-replay.agent-provider.invoke.strategy", "recorded-replay")
            .build();
    var simConfig = new SmallRyeSimulationConfig(config);

    assertThat(simConfig.profileNames()).containsExactly("ci-replay");
}

@Test
void profileDoesNotAffectFlatConfig() {
    var config = new SmallRyeConfigBuilder()
            .withDefaultValue("casehub.simulation.agent-provider.invoke.strategy", "key-lookup")
            .withDefaultValue("casehub.simulation.profiles.ci-replay.agent-provider.invoke.strategy", "recorded-replay")
            .build();
    var simConfig = new SmallRyeSimulationConfig(config);

    assertThat(simConfig.strategyFor("agent-provider.invoke")).hasValue("key-lookup");
}

@Test
void activeProfileOverridesFlatConfig() {
    var config = new SmallRyeConfigBuilder()
            .withDefaultValue("casehub.simulation.agent-provider.invoke.strategy", "key-lookup")
            .withDefaultValue("casehub.simulation.profiles.ci-replay.agent-provider.invoke.strategy", "recorded-replay")
            .withDefaultValue("casehub.simulation.active-profile", "ci-replay")
            .build();
    var simConfig = new SmallRyeSimulationConfig(config);

    assertThat(simConfig.strategyFor("agent-provider.invoke")).hasValue("recorded-replay");
}

@Test
void activeProfileFallsBackToFlatForUnconfiguredMethods() {
    var config = new SmallRyeConfigBuilder()
            .withDefaultValue("casehub.simulation.case-memory-store.query.capture", "true")
            .withDefaultValue("casehub.simulation.profiles.ci-replay.agent-provider.invoke.strategy", "recorded-replay")
            .withDefaultValue("casehub.simulation.active-profile", "ci-replay")
            .build();
    var simConfig = new SmallRyeSimulationConfig(config);

    assertThat(simConfig.strategyFor("agent-provider.invoke")).hasValue("recorded-replay");
    assertThat(simConfig.captureEnabled("case-memory-store.query")).isTrue();
}

@Test
void resolveProfileReturnsSimulationProfile() {
    var config = new SmallRyeConfigBuilder()
            .withDefaultValue("casehub.simulation.agent-provider.invoke.strategy", "key-lookup")
            .withDefaultValue("casehub.simulation.profiles.ci-replay.agent-provider.invoke.strategy", "recorded-replay")
            .build();
    var simConfig = new SmallRyeSimulationConfig(config);

    var profile = simConfig.resolve("ci-replay");
    assertThat(profile).isPresent();
    assertThat(profile.get().config().strategyFor("agent-provider.invoke"))
            .hasValue("recorded-replay");
    // Fallback to flat for unconfigured method
    assertThat(profile.get().config().strategyFor("agent-provider.invoke"))
            .hasValue("recorded-replay");
}

@Test
void resolveProfileFallsBackToFlatConfig() {
    var config = new SmallRyeConfigBuilder()
            .withDefaultValue("casehub.simulation.agent-provider.invoke.strategy", "key-lookup")
            .withDefaultValue("casehub.simulation.profiles.ci-replay.notification-store.store.strategy", "sequential")
            .build();
    var simConfig = new SmallRyeSimulationConfig(config);

    var profile = simConfig.resolve("ci-replay");
    assertThat(profile).isPresent();
    // Profile has notification-store config
    assertThat(profile.get().config().strategyFor("notification-store.store"))
            .hasValue("sequential");
    // Falls back to flat for agent-provider
    assertThat(profile.get().config().strategyFor("agent-provider.invoke"))
            .hasValue("key-lookup");
}

@Test
void resolveUnknownProfileReturnsEmpty() {
    var config = new SmallRyeConfigBuilder()
            .withDefaultValue("casehub.simulation.profiles.ci-replay.agent-provider.invoke.strategy", "recorded-replay")
            .build();
    var simConfig = new SmallRyeSimulationConfig(config);

    assertThat(simConfig.resolve("nonexistent")).isEmpty();
}

@Test
void multipleProfilesParsedIndependently() {
    var config = new SmallRyeConfigBuilder()
            .withDefaultValue("casehub.simulation.profiles.ci-replay.agent-provider.invoke.strategy", "recorded-replay")
            .withDefaultValue("casehub.simulation.profiles.dev-demo.agent-provider.invoke.strategy", "sequential")
            .build();
    var simConfig = new SmallRyeSimulationConfig(config);

    assertThat(simConfig.profileNames()).containsExactlyInAnyOrder("ci-replay", "dev-demo");

    var ciProfile = simConfig.resolve("ci-replay");
    assertThat(ciProfile.get().config().strategyFor("agent-provider.invoke"))
            .hasValue("recorded-replay");

    var devProfile = simConfig.resolve("dev-demo");
    assertThat(devProfile.get().config().strategyFor("agent-provider.invoke"))
            .hasValue("sequential");
}

@Test
void activeProfileCorpusFilesReturnedWhenConfigured() {
    var config = new SmallRyeConfigBuilder()
            .withDefaultValue("casehub.simulation.profiles.ci-replay.corpus.files", "fixtures/captured.yaml")
            .withDefaultValue("casehub.simulation.profiles.ci-replay.agent-provider.invoke.strategy", "recorded-replay")
            .withDefaultValue("casehub.simulation.active-profile", "ci-replay")
            .build();
    var simConfig = new SmallRyeSimulationConfig(config);

    assertThat(simConfig.activeProfileCorpusFiles())
            .isPresent()
            .hasValueSatisfying(files -> assertThat(files).containsExactly("fixtures/captured.yaml"));
}

@Test
void activeProfileCorpusFilesEmptyWhenNoActiveProfile() {
    var config = new SmallRyeConfigBuilder()
            .withDefaultValue("casehub.simulation.agent-provider.invoke.strategy", "key-lookup")
            .build();
    var simConfig = new SmallRyeSimulationConfig(config);

    assertThat(simConfig.activeProfileCorpusFiles()).isEmpty();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=SmallRyeSimulationConfigTest`
Expected: Compilation failure — `profileNames()`, `resolve()`, `activeProfileCorpusFiles()` don't exist yet.

- [ ] **Step 3: Implement profile parsing in SmallRyeSimulationConfig**

Modify the constructor to parse profile entries alongside flat entries. Add profile-related fields and methods. The key parsing logic:

- `casehub.simulation.profiles.<name>.corpus.files` → stored in `Map<String, List<String>> profileCorpusFiles`
- `casehub.simulation.profiles.<name>.<spi>.<method>.<property>` → stored in `Map<String, Map<String, MethodSimulationConfig>> profiles`
- `casehub.simulation.active-profile` → stored as `String activeProfile`
- All existing flat parsing (`parts.length == 3`) remains unchanged

Add these fields:

```java
private final Map<String, Map<String, MethodSimulationConfig>> profiles;
private final Map<String, List<String>> profileCorpusFiles;
private final String activeProfile;
```

Modified constructor — after the existing prefix/suffix parsing, add:
- When `parts[0].equals("profiles")` and `parts.length >= 5`: route to profile map
- When `parts[0].equals("profiles")` and the remainder is `<name>.corpus.files`: route to profileCorpusFiles
- When `parts[0].equals("active-profile")`: store as activeProfile
- Existing `parts.length == 3` path remains for flat config

Override `strategyFor()`, `captureEnabled()`, `exhaustionPolicy()`, `threshold()` to check active profile first, then flat.

Add methods:
- `Set<String> profileNames()` — returns `profiles.keySet()`
- `Optional<List<String>> activeProfileCorpusFiles()` — returns corpus files for the active profile
- `Optional<SimulationProfile> resolve(String name)` — implements `ProfileSource`:
  1. Look up profile method configs
  2. Build composed config (profile entries → flat fallback) using `MapSimulationConfig` for profile entries and delegating unconfigured methods to `this` (flat config)
  3. Create `InMemorySimulationCorpus` and load corpus files if declared
  4. Return `SimulationProfile(composedConfig, corpus)`

The composed config for the profile can be a simple anonymous `SimulationConfig` that checks profile methods first, then delegates to the flat config instance (`this`).

Make `SmallRyeSimulationConfig implements ProfileSource`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=SmallRyeSimulationConfigTest`
Expected: All tests PASS.

- [ ] **Step 5: Run full simulation-config-core test suite**

Run: `mvn --batch-mode test -pl simulation-config-core`
Expected: All existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add simulation-config-core/src/main/java/io/casehub/platform/simulation/config/SmallRyeSimulationConfig.java simulation-config-core/src/test/java/io/casehub/platform/simulation/config/SmallRyeSimulationConfigTest.java
git commit -m "feat(#329): add profile parsing and ProfileSource to SmallRyeSimulationConfig

Refs #329"
```

---

## Batch 3: CDI wiring and documentation

### Task 3: SimulationConfigBeans wiring + integration test

**Files:**
- Modify: `simulation-config/src/main/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigBeans.java`
- Modify: `simulation-config/src/test/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigIT.java`

**Interfaces:**
- Consumes: `SmallRyeSimulationConfig implements ProfileSource` from Task 2
- Consumes: `SmallRyeSimulationConfig.activeProfileCorpusFiles()` from Task 2
- Consumes: `SimulationRuntime.setProfileSource(ProfileSource)` from Task 1
- Consumes: `SimulationRuntime.pushProfile(String)` from Task 1

- [ ] **Step 1: Read the existing SimulationConfigIT to understand the test pattern**

Read: `simulation-config/src/test/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigIT.java`

Understand the existing `@QuarkusTest` pattern — how config properties are set, how runtime/corpus/config are injected.

- [ ] **Step 2: Write failing integration test**

Add to `SimulationConfigIT.java` (or create a new `SimulationProfileIT.java` if the existing IT doesn't support additional config properties):

```java
@Test
void pushProfileActivatesNamedProfileWithCorpus() {
    // This test requires profile config in application.properties
    // Add to src/test/resources/application.properties:
    // casehub.simulation.profiles.test-profile.test-spi.query.strategy=sequential
    var overlay = runtime.pushProfile("test-profile");
    try {
        var strategy = runtime.strategyFor("test-spi.query");
        assertThat(strategy).isPresent();
    } finally {
        runtime.popOverlay(overlay);
    }
}
```

- [ ] **Step 3: Modify SimulationConfigBeans**

Change the `@Produces` method to return `SmallRyeSimulationConfig` (the concrete type) instead of `SimulationConfig`:

```java
@Produces
@ApplicationScoped
public SmallRyeSimulationConfig simulationConfig() {
    return new SmallRyeSimulationConfig(ConfigProvider.getConfig());
}
```

In the `onStartup` method, add profile wiring after existing corpus loading and extractor registration:

```java
runtime.setProfileSource(config);

config.activeProfileCorpusFiles().ifPresent(files -> {
    var loader = new YamlCorpusLoader();
    var loaded = loader.loadFromPaths(files);
    loaded.forEach(corpus::seed);
});
```

Update the `onStartup` method signature to inject `SmallRyeSimulationConfig` instead of depending on the cast.

- [ ] **Step 4: Add test config properties**

Add to `simulation-config/src/test/resources/application.properties`:

```properties
casehub.simulation.profiles.test-profile.test-spi.query.strategy=sequential
```

- [ ] **Step 5: Run integration test**

Run: `mvn --batch-mode test -pl simulation-config -Dtest=SimulationConfigIT`
Expected: All tests PASS.

- [ ] **Step 6: Run full build to verify no regressions**

Run: `mvn --batch-mode test -pl simulation-core,simulation-config-core,simulation-config`
Expected: All tests PASS across all three modules.

- [ ] **Step 7: Commit**

```bash
git add simulation-config/src/main/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigBeans.java simulation-config/src/test/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigIT.java simulation-config/src/test/resources/application.properties
git commit -m "feat(#329): wire ProfileSource in SimulationConfigBeans, add integration test

Refs #329"
```

### Task 4: Lifecycle progression guide + configuration reference update

**Files:**
- Modify: `docs/guides/simulation-guide.md`

**Interfaces:**
- Consumes: Profile config namespace from spec section 1
- Consumes: Quarkus profile interaction from spec section 2
- Consumes: Lifecycle stages from spec section 8

- [ ] **Step 1: Add Simulation Profiles section to the guide**

Add a new section after the existing "Configuration Reference" section in `docs/guides/simulation-guide.md`. Include:

1. **Simulation Profiles** heading with explanation of the concept
2. **Declaring a profile** — config namespace with example
3. **Activating a profile** — `active-profile` property at boot time
4. **Profile corpus files** — bundling data with profiles
5. **Runtime activation** — `pushProfile(name)` for scenarios
6. **Quarkus profile interaction** — how the two mechanisms complement each other
7. **Configuration Reference update** — add profile namespace to existing reference table

- [ ] **Step 2: Add Lifecycle Progression section**

Add a new section "Simulation Maturity Stages" with the five stages:

- Stage 0: No simulation — no config
- Stage 1: Capture — `capture-all` profile with capture enabled on target SPIs
- Stage 2: Recorded replay — `ci-replay` profile with recorded-replay strategy
- Stage 3: Curated — `curated-test` profile with key-lookup + hand-curated fixtures
- Stage 4: Synthetic — `load-test` profile with sequential + CorpusSeed-built data

Each stage gets a complete, copy-paste-ready profile config block and a "When to advance" paragraph.

- [ ] **Step 3: Commit**

```bash
git add docs/guides/simulation-guide.md
git commit -m "docs(#329): add simulation profiles and lifecycle progression guide

Refs #329"
```

- [ ] **Step 4: Update CLAUDE.md module descriptions**

Update the simulation-core and simulation-config-core entries in CLAUDE.md to mention ProfileSource and profile parsing.

- [ ] **Step 5: Commit CLAUDE.md update**

```bash
git add CLAUDE.md
git commit -m "docs(#329): update CLAUDE.md with profile support in simulation modules

Refs #329"
```

---

## References

- [2026-09-18-strategy-profiles-design.md] — design spec this plan implements
- [SimulationRuntime.java] — overlay stack, strategyFor(), pushOverlay()
- [SimulationConfig.java] — 4-method strategy dispatch SPI
- [SmallRyeSimulationConfig.java] — prefix scanning, MethodSimulationConfig
- [SimulationConfigBeans.java] — CDI wiring, startup corpus loading
- [YamlCorpusLoader.java] — YAML corpus parsing
- [SimulationRuntimeTest.java] — existing test patterns (stubConfig, TestCorpus)
- [SmallRyeSimulationConfigTest.java] — existing test patterns (SmallRyeConfigBuilder)
- [SimulationConfigIT.java] — existing @QuarkusTest integration test
- [MapSimulationConfig.java] — programmatic config for composed fallback
- [InMemorySimulationCorpus.java] — corpus created by profile resolution
- [GitHub #329] — strategy combination and lifecycle
