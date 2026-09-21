## D1: Global speed as multiplier, composing with per-driver override

**Choice:** Add `speed()` to `SimulationConfig` as a global multiplier (default 1.0). Effective speed = `profile.speed × globalMultiplier`. Per-driver `setSpeed()` sets an absolute local override that takes precedence over the composed value.
**Alternatives:**
- Global as absolute replacement — destroys relative speed relationships between profiles (morning-routine at 10x and alarm-sequence at 1x both become 5x)
- Global replaces per-driver — removes a useful level of control for debugging and selective slow-motion
**Rationale:** Three levels of speed serve distinct purposes: profile baseline (author intent), global multiplier (time scale for the whole simulation), per-driver override (runtime debugging/demo). The multiplier model preserves relative speeds between profiles, matches the standard model in game engines and animation systems, and composes additively with existing per-driver `setSpeed()`.
**Trade-offs:** Three levels to understand. But each serves a clear use case (demo slider, scenario acceleration, per-driver debugging) and the composition rule is simple.
**Sources:** simulation-core/TemporalSimulationDriver.java (existing per-driver setSpeed), simulation-core/TemporalProfile.java (profile baseline speed), issue #373 body, #371 deferred items
**Exploration:** deep-analysis
**Status:** captured

## D2: speed() on SimulationConfig interface

**Choice:** Add `default double speed() { return 1.0; }` to `SimulationConfig`. Backward compatible — existing implementations return 1.0 (no global speed).
**Alternatives:**
- New SimulationSpeedConfig interface — keeps SimulationConfig focused but adds another type to inject
- On SimulationRuntime directly — muddies config vs runtime distinction
**Rationale:** SimulationConfig already owns simulation behavior settings (strategy, capture, exhaustion, threshold). Speed is the same kind of concern — a simulation behavior parameter. Default method ensures backward compatibility. YamlSimulationConfig and MapSimulationConfig gain the field naturally.
**Trade-offs:** SimulationConfig gains a 5th method. Acceptable — it's still a focused interface.
**Sources:** simulation-core/SimulationConfig.java (current 4-method interface), simulation-core/MapSimulationConfig.java (builder pattern)
**Exploration:** quick
**Depends on:** D1
**Status:** captured

## D3: Volatile poll for reactive speed synchronization

**Choice:** Drivers read global speed from SimulationRuntime's volatile field each sleep iteration. No listener registration or CDI events.
**Alternatives:**
- Listener callback — explicit notification on change, but requires registration lifecycle (add on start, remove on stop)
- CDI event — heavier, only works for CDI-managed drivers, not plain POJOs
**Rationale:** The driver already uses a volatile double for speed. Adding a volatile globalSpeed field on SimulationRuntime and reading it each iteration is zero-allocation, no lifecycle management, and naturally thread-safe. Each sleep cycle recalculates effective speed from `profile.speed * runtime.globalSpeed()`.
**Trade-offs:** Speed change takes effect on next sleep, not mid-sleep. Acceptable — the existing per-driver setSpeed() has the same characteristic.
**Sources:** simulation-core/TemporalSimulationDriver.java:19 (volatile speed field), simulation-core/TemporalSimulationDriver.java:126 (sleep loop reads speed)
**Exploration:** quick
**Depends on:** D1
**Status:** captured
