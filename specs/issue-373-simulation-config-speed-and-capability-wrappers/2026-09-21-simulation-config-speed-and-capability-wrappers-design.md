# SimulationConfig Global Speed + Capability Wrapper Generation

**Branch:** issue-373-simulation-config-speed-and-capability-wrappers
**Issues:** casehubio/platform#373, casehubio/platform#375
**Date:** 2026-09-21
**Decisions:** [decisions.md](decisions.md)

## Overview

Two independent simulation framework enhancements on one branch:

1. **#373 — Global speed synchronization.** Add a global speed multiplier to `SimulationConfig` and synchronize running temporal drivers with it via volatile poll. Composes with existing per-profile and per-driver speed levels.

2. **#375 — Recursive wrapper generation for capability-based SPIs.** Enhance `SimulationDecoratorProcessor` to generate wrapper inner classes for capability-returning methods, emit dotted QN constants, and generate a `supports()` override. Unblocks connectors#105 (ChatPlatform @SimulationEligible).

## Part 1: Global Speed Synchronization (#373)

### Speed Composition Model

Three levels of speed, each serving a distinct purpose:

| Level | Where | Purpose | Example |
|-------|-------|---------|---------|
| Profile baseline | `TemporalProfile.speed()` | Author intent — how fast this profile should run relative to real-time | `morning-routine` at 10.0 |
| Global multiplier | `SimulationConfig.speed()` | Time scale for the whole simulation — demo slider, test acceleration | 2.0 = everything 2x faster |
| Per-driver override | `driver.setSpeed(double)` | Runtime debugging/demo — slow down one specific driver | 0.5 for debugging alarm-sequence |

Composition rule:

```
effectiveSpeed = localOverride          (if setSpeed() was called on this driver)
effectiveSpeed = profile.speed × global (otherwise)
```

Default global speed is 1.0 (no effect). Per-driver `setSpeed()` sets an absolute value that takes precedence over the composed value.

### SimulationConfig Change

```java
public interface SimulationConfig {
    Optional<String> strategyFor(String qualifiedName);
    boolean captureEnabled(String qualifiedName);
    Optional<ExhaustionPolicy> exhaustionPolicy(String qualifiedName);
    default Optional<Double> threshold(String qualifiedName) { return Optional.empty(); }

    // NEW — global speed multiplier, default 1.0 (no effect)
    default double speed() { return 1.0; }
}
```

Backward compatible — existing implementations return 1.0 via the default method.

### MapSimulationConfig Change

Add `speed` field + builder method:

```java
public final class MapSimulationConfig implements SimulationConfig {
    private final double speed;
    // ... existing fields ...

    @Override
    public double speed() { return speed; }

    public static final class Builder {
        private double speed = 1.0;

        public Builder speed(double speed) {
            if (speed <= 0) throw new IllegalArgumentException("speed must be positive");
            this.speed = speed;
            return this;
        }
    }
}
```

### YamlSimulationConfig Change

Parse new top-level `speed:` key:

```yaml
speed: 5.0          # global multiplier
default-tenancy-id: demo-tenant
methods:
  # ...
```

Default 1.0 when absent. Validation: must be positive.

### SimulationRuntime Change

Add mutable global speed field:

```java
public class SimulationRuntime {
    private volatile double globalSpeed;

    public SimulationRuntime(SimulationConfig config, SimulationCorpus corpus) {
        // ... existing init ...
        this.globalSpeed = config.speed();
    }

    public double globalSpeed() {
        return globalSpeed;
    }

    public void setGlobalSpeed(double speed) {
        if (speed <= 0) throw new IllegalArgumentException("speed must be positive");
        this.globalSpeed = speed;
    }
}
```

Initialized from `config.speed()` at construction. Mutable at runtime via `setGlobalSpeed()`. Volatile for thread-safe reads by driver threads.

### TemporalSimulationDriver Change

Replace the current simple volatile speed field with a three-level speed resolution:

```java
public class TemporalSimulationDriver<E> {
    private final SimulationRuntime simulation;
    private volatile Double localSpeedOverride;  // null = follow global
    private volatile TemporalProfile<E> activeProfile;

    public void start(TemporalProfile<E> profile) {
        // ... existing lock/state check ...
        this.activeProfile = profile;
        this.localSpeedOverride = null;  // start fresh, follow global
        // ... spawn virtual thread ...
    }

    public void setSpeed(double speed) {
        if (speed <= 0) throw new IllegalArgumentException("speed must be positive");
        this.localSpeedOverride = speed;  // absolute override
    }

    public void resetSpeed() {
        this.localSpeedOverride = null;  // revert to global composition
    }

    public double speed() {
        return effectiveSpeed();
    }

    private double effectiveSpeed() {
        Double local = localSpeedOverride;
        if (local != null) return local;
        double global = (simulation != null) ? simulation.globalSpeed() : 1.0;
        return activeProfile.speed() * global;
    }
}
```

The `runLoop()` calls `effectiveSpeed()` each iteration instead of reading the volatile `speed` field directly. This is the reactive synchronization — no listener registration needed.

`resetSpeed()` is new — clears the local override so the driver follows global again.

When `simulation` is null (no-journal constructor), globalSpeed falls back to 1.0.

### TemporalDriverService Change

Add `setGlobalSpeed` and `resetSpeed` operations:

```java
@McpDomain("temporal-drivers")
public class TemporalDriverService {
    // existing: start, stop, pause, resume, setSpeed, status, list

    @PlatformMutation
    public void setGlobalSpeed(double speed) {
        simulationRuntime.setGlobalSpeed(speed);
    }

    @PlatformQuery
    public double globalSpeed() {
        return simulationRuntime.globalSpeed();
    }

    @PlatformMutation
    public void resetSpeed(String driverName) {
        // find driver, call driver.resetSpeed()
    }
}
```

### JSON Schema Update

Add `speed` property to `simulation.schema.json` at the top level:

```json
{
  "speed": {
    "type": "number",
    "exclusiveMinimum": 0,
    "default": 1.0,
    "description": "Global speed multiplier applied to all temporal drivers"
  }
}
```

## Part 2: Recursive Wrapper Generation (#375)

### @SimulationEligible Annotation Change

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
public @interface SimulationEligible {
    String name() default "";
    String[] capabilities() default {};
}
```

When `capabilities` is empty (default), all methods get standard flat interception — fully backward compatible with BankFeedPlatform and EmailPlatform.

### SimulationDecoratorProcessor Enhancement

#### New: Capability Detection

In `generateFromIndex()`, after reading the `name` annotation value, also read the `capabilities` value:

```java
AnnotationValue capVal = ann.value("capabilities");
String[] capabilities = (capVal != null) ? capVal.asStringArray() : new String[0];
Set<String> capabilitySet = Set.of(capabilities);
```

Pass `capabilitySet` to `generateDecoratorSource()`.

#### New: Wrapper Inner Class Generation

For each method whose name is in `capabilitySet`:

1. Resolve the return type via Jandex — it must be an interface (error if not)
2. Generate a static inner class implementing the return type's interface
3. The inner class constructor takes: the delegate's capability return value + SimulationRuntime + CurrentPrincipal
4. Each method on the inner class follows the same intercept-or-delegate pattern as `generateSimulatedMethod()`, using dotted QNs (`spi.capability.method`)
5. The top-level decorator's capability method returns an instance of the wrapper, passing `delegate.capability()` as the inner delegate

Generated structure for `@SimulationEligible(name = "chat-platform", capabilities = {"messaging"})`:

```java
@Decorator
@Priority(APPLICATION + 200)
public class SimulatedChatPlatform implements ChatPlatform {

    @Inject @Delegate ChatPlatform delegate;
    @Inject SimulationRuntime simulation;
    @Inject CurrentPrincipal currentPrincipal;

    // --- Flat methods (not in capabilities) ---
    @Override
    public String id() {
        // standard intercept-or-delegate (existing pattern)
    }

    // --- Capability method ---
    @Override
    public Messaging messaging() {
        return new Messaging_Wrapper(delegate.messaging(), simulation, currentPrincipal);
    }

    // --- supports() override ---
    @Override
    public boolean supports(Class<?> capability) {
        if (capability == Messaging.class) {
            return simulation.strategyFor("chat-platform.messaging.send").isPresent()
                    || delegate.supports(capability);
        }
        // ... one if-block per capability ...
        return delegate.supports(capability);
    }

    // --- Wrapper inner class ---
    static class Messaging_Wrapper implements Messaging {
        private final Messaging delegate;
        private final SimulationRuntime simulation;
        private final CurrentPrincipal currentPrincipal;

        Messaging_Wrapper(Messaging delegate, SimulationRuntime simulation,
                          CurrentPrincipal currentPrincipal) {
            this.delegate = delegate;
            this.simulation = simulation;
            this.currentPrincipal = currentPrincipal;
        }

        @Override
        public SendResult send(ChannelRef channel, MessageContent content) {
            String qualifiedName = "chat-platform.messaging.send";
            // same intercept-or-delegate pattern as generateSimulatedMethod()
        }
    }
}
```

#### Wrapper Class Naming

`<CapabilityMethodName>_Wrapper` with first letter uppercased. `messaging()` → `Messaging_Wrapper`. The underscore avoids collision with the capability interface name itself.

#### supports() Override Generation

Only generated when `capabilities` is non-empty AND the SPI has a `supports(Class<?>)` method (detected via Jandex). For each capability class listed:

1. Resolve the capability interface class from the return type of the capability method
2. Collect all method QNs for that capability
3. Emit an if-block checking `simulation.strategyFor()` for ANY of those QNs

The check uses OR across all methods — if any method in the capability has an active strategy, the capability is considered supported by the simulation.

#### QN Constant Generation

Existing flat methods produce: `ID = "chat-platform.id"`, `SUPPORTS = "chat-platform.supports"`.

Capability methods produce dotted constants: `MESSAGING_SEND = "chat-platform.messaging.send"`.

Naming convention: `UPPER(capabilityName) + "_" + UPPER(methodName)`.

#### Parameter Entries for Capability Methods

`addParameterEntries()` must recurse into capability interfaces to emit parameter metadata for capability methods (dotted QNs). This feeds `simulation-parameters.properties` and the `DeclarativeExtractorFactory` for key-extractor resolution.

### Backward Compatibility

- Empty `capabilities` (default) → all methods get flat interception, identical to current behavior
- No `supports()` method on SPI → no supports override generated
- Existing listing file (`META-INF/simulation-eligible.txt`) entries have no capability info → flat interception only. Listing-file-based SPIs that need capabilities must switch to annotation-based declaration.

### Module Changes

| Module | Changes |
|--------|---------|
| `simulation-api` | + `String[] capabilities()` on `@SimulationEligible` |
| `simulation-core` | + `speed()` default on `SimulationConfig`, + `speed` field on `MapSimulationConfig` + builder, + `globalSpeed`/`setGlobalSpeed` on `SimulationRuntime`, + `resetSpeed()`/`effectiveSpeed()` on `TemporalSimulationDriver` |
| `simulation-config-core` | + `speed` parsing in `YamlSimulationConfig`, + `speed` in schema |
| `simulation-generator` | + capability detection, wrapper class generation, supports() override, dotted QN constants, recursive parameter entries |
| `event-simulation` | + `setGlobalSpeed`/`globalSpeed`/`resetSpeed` on `TemporalDriverService` |

## Testing

### #373 — Global Speed

| Test | Module | What it verifies |
|------|--------|-----------------|
| SimulationConfig default speed | simulation-core | `speed()` default returns 1.0 |
| MapSimulationConfig speed builder | simulation-core | Builder sets speed, validation rejects ≤ 0 |
| SimulationRuntime globalSpeed | simulation-core | Initial from config, mutable via setGlobalSpeed, validation |
| TemporalSimulationDriver — global speed composition | simulation-core | effectiveSpeed = profile.speed × globalSpeed |
| TemporalSimulationDriver — local override | simulation-core | setSpeed() overrides composition |
| TemporalSimulationDriver — resetSpeed | simulation-core | resetSpeed() reverts to global composition |
| TemporalSimulationDriver — reactive sync | simulation-core | Changing globalSpeed mid-flight affects next delay |
| TemporalSimulationDriver — null runtime fallback | simulation-core | No runtime → global defaults to 1.0 |
| YamlSimulationConfig — speed parsing | simulation-config-core | Parses `speed:` from YAML, defaults to 1.0 |
| TemporalDriverService — global speed API | event-simulation | setGlobalSpeed/globalSpeed via MCP |

### #375 — Capability Wrappers

| Test | Module | What it verifies |
|------|--------|-----------------|
| Flat SPI unchanged | simulation-generator | @SimulationEligible without capabilities produces identical output to current |
| Capability annotation parsed | simulation-generator | capabilities attribute read correctly |
| Wrapper inner class generated | simulation-generator | Static inner class for each capability method |
| Wrapper methods intercept-or-delegate | simulation-generator | Same pattern as flat methods, dotted QNs |
| supports() override generated | simulation-generator | If-chain checking strategyFor per capability |
| supports() not generated without supports method | simulation-generator | SPIs without supports(Class) skip override |
| QN constants — flat + dotted | simulation-generator | Flat methods = UPPER(name), capability methods = CAPABILITY_METHOD |
| Parameter entries for capability methods | simulation-generator | Dotted QN entries in simulation-parameters.properties |
| Non-interface return type error | simulation-generator | Capability method returning non-interface → compilation error |

## Scope

### In scope
- `SimulationConfig.speed()` default method
- `MapSimulationConfig` speed field + builder
- `YamlSimulationConfig` speed parsing + schema
- `SimulationRuntime.globalSpeed()` / `setGlobalSpeed()`
- `TemporalSimulationDriver` three-level speed composition + `resetSpeed()`
- `TemporalDriverService` global speed MCP operations
- `@SimulationEligible.capabilities` attribute
- `SimulationDecoratorProcessor` recursive wrapper generation
- `supports()` override generation
- Dotted QN constant generation
- Recursive parameter entry generation

### Out of scope
- Per-profile speed overrides in SimulationConfig (different from global multiplier — would need per-QN speed map)
- CDI event on speed change (volatile poll is sufficient)
- Capability auto-detection heuristic (explicit declaration per D5)
- Connectors-side adoption (connectors#105 — separate branch/repo)

## References

- [platform#373](https://github.com/casehubio/platform/issues/373) — global speed issue
- [platform#375](https://github.com/casehubio/platform/issues/375) — capability wrappers issue
- [platform#371 design spec](../issue-371-temporal-simulation-driver/2026-09-20-temporal-simulation-driver-design.md) — parent temporal driver design (deferred #373)
- [connectors#105 design spec](https://github.com/casehubio/connectors) — consumer-facing capability wrapper spec (D1, D5, D7)
- simulation-core/SimulationConfig.java — current 4-method interface
- simulation-core/TemporalSimulationDriver.java — current driver with per-driver speed
- simulation-core/TemporalProfile.java — profile baseline speed
- simulation-core/SimulationRuntime.java — overlay stack, journal recording
- simulation-generator/SimulationDecoratorProcessor.java — current flat generator
- simulation-api/SimulationEligible.java — current annotation (name only)
- D1–D7 in [decisions.md](decisions.md)
