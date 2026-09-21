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

## D4: Adopt connectors#105 decisions D1, D5, D7 for platform generator enhancement

**Choice:** Use connectors#105 design spec decisions as the authoritative design for platform#375: recursive wrapper generation (D1), explicit `capabilities` attribute (D5), `supports()` override (D7). These were validated through adversarial review (R1-01 through R1-07).
**Alternatives:**
- Fresh design from the generator perspective — risk contradicting the consumer-facing spec that defines the contract
- Revisit specific decisions — no issues identified that warrant re-examination
**Rationale:** The connectors spec was written specifically to define the platform prerequisite. D1 (recursive wrappers), D5 (explicit capability declaration vs heuristic auto-detection), and D7 (supports() semantic coherence) are well-reasoned. The platform implementation is the server side of a contract already defined by the consumer.
**Trade-offs:** None significant — the spec already addressed generator complexity and backward compatibility.
**Sources:** connectors specs/issue-105-simulation-eligible-calendar-chat/decisions.md (D1, D5, D7), connectors specs/issue-105-simulation-eligible-calendar-chat/2026-09-20-simulation-eligible-calendar-chat-design.md
**Exploration:** quick
**Status:** captured

## D5: Capability wrappers as static inner classes

**Choice:** Generate capability wrapper classes as static inner classes of the decorator class. `SimulatedChatPlatform.Messaging_Wrapper` as a static inner class inside `SimulatedChatPlatform`.
**Alternatives:**
- Separate top-level classes — more files, each smaller, easier to debug individually
- Package-private top-level — cleaner for large SPIs but still more files
**Rationale:** Matches the connectors spec description ("inner class, not CDI-managed"). Co-locates all generated code for one SPI in a single source file. Inner classes have natural access to the decorator's `simulation` and `currentPrincipal` fields (or receive them via constructor). One file per SPI is easier to review and debug.
**Trade-offs:** Large SPIs with many capabilities produce a large source file. Acceptable for generated code — readability of generated code is secondary to correctness.
**Sources:** connectors specs/issue-105 design spec (generated code structure section)
**Exploration:** quick
**Depends on:** D4
**Status:** captured

## D6: Inline if-chain for supports() override

**Choice:** Generator emits an `if (cap == Messaging.class) return simulation.strategyFor("...").isPresent() || delegate.supports(cap)` chain. Direct, no data structures, zero allocation.
**Alternatives:**
- Static Map<Class, List<String>> — more structured but heavier for a fixed set of values known at generation time
**Rationale:** The mapping from capability class to method QNs is fixed at generation time — it doesn't change at runtime. An if-chain is the most direct representation. The JIT will compile it to a tableswitch or series of comparisons. No allocation, no iteration, no map lookup overhead.
**Trade-offs:** Verbose generated code for SPIs with many capabilities (9 for ChatPlatform). Acceptable — generated code verbosity is free.
**Sources:** connectors specs/issue-105 design spec (supports() override section, D7)
**Exploration:** quick
**Depends on:** D4
**Status:** captured

## D7: CAPABILITY_METHOD flat naming for QN constants

**Choice:** Uppercase capability + underscore + uppercase method name. `messaging.send` → `MESSAGING_SEND`. All constants in a single flat QN class per SPI.
**Alternatives:**
- Nested QN classes (ChatPlatformQN.Messaging.SEND) — more structured but deeper nesting for a constants class
**Rationale:** Matches the connectors spec example. Flat namespace is simpler to import and use in tests and verification assertions. Existing flat method QNs (`LISTCALENDARS`, `ID`) coexist naturally with dotted capability QNs (`MESSAGING_SEND`).
**Trade-offs:** Potential name collision if a flat method and a capability method produce the same constant name. Unlikely in practice — flat methods are direct SPI methods, capability methods are nested.
**Sources:** connectors specs/issue-105 design spec (QN constants section)
**Exploration:** quick
**Depends on:** D4
**Status:** captured
