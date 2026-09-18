# Strategy Configuration and Profiles — Design Spec

**Issue:** casehubio/platform#329
**Branch:** issue-294-simulation-service
**Date:** 2026-09-18

---

## Problem

The simulation framework treats strategies as isolated per-method choices.
A developer configuring a realistic scenario must set individual properties
for every SPI method involved — there's no way to declare "this scenario
uses these strategies with this data" as a named, reusable unit.

Three dimensions are missing:

1. **Per-method bundling** — a multi-method SPI needs different strategies
   per method simultaneously (query → key-lookup, store → passthrough +
   capture). This works today via per-method config keys, but there's no
   tooling to declare a bundle.

2. **Cross-SPI coordination** — a realistic scenario simulates multiple
   SPIs together (AgentProvider + CaseMemoryStore + NotificationStore +
   AccessControlProvider). Each SPI configured independently, but the
   scenario as a whole is a coherent test case. No mechanism declares
   the full set.

3. **Lifecycle progression** — a team's simulation maturity evolves
   (no-sim → capture → replay → curated → synthetic). Each stage changes
   config, but there's no guidance on which profiles to use at each stage.

## Scope

**In scope:**
- Named simulation profiles (config + corpus bundles)
- Profile-aware overlay integration (`pushProfile(name)`)
- Boot-time profile activation (`active-profile=<name>`)
- Lifecycle progression guide section in simulation-guide.md

**Out of scope:**
- CLI scaffolding (deferred until profile format stabilizes — D68)
- Multi-profile boot-time composition (single active profile — D70)
- Profile inheritance/extension between profiles

## Design

### 1. Profile config namespace

Profiles are declared as a parallel namespace under `casehub.simulation.profiles.<name>`:

```properties
# Flat config (always active — implicit default)
casehub.simulation.agent-provider.invoke.strategy=key-lookup
casehub.simulation.case-memory-store.query.capture=true

# Named profile — overrides flat entries when activated
casehub.simulation.profiles.ci-replay.agent-provider.invoke.strategy=recorded-replay
casehub.simulation.profiles.ci-replay.notification-store.store.strategy=sequential
casehub.simulation.profiles.ci-replay.corpus.files=fixtures/captured-traffic.yaml

# Activate a profile
casehub.simulation.active-profile=ci-replay
```

**Resolution order** (boot time, with active profile):
1. Active profile entries (for matching qualified names)
2. Flat config entries (fallback)
3. Empty (no strategy configured)

**Zero migration:** Existing flat configs keep working unchanged. Profiles
are purely additive — you opt in by declaring a profile and activating it.

### 2. Quarkus profile interaction

SmallRye Config resolves Quarkus profile-qualified properties (`%test.*`)
before SmallRyeSimulationConfig scans property names. Quarkus-profiled
values are indistinguishable from flat values at scan time.

Common patterns:

```properties
# Quarkus profile selects which simulation profile to activate
%test.casehub.simulation.active-profile=ci-replay
%dev.casehub.simulation.active-profile=dev-demo

# Quarkus profile scopes simulation profile definitions
%test.casehub.simulation.profiles.ci-replay.agent-provider.invoke.strategy=recorded-replay
```

The two profiling mechanisms are complementary:
- **Quarkus profiles** → environment-level switching (test/dev/prod)
- **Simulation profiles** → cross-SPI strategy+corpus bundles within an environment
- **Overlay stack** → runtime scenario switching

### 3. Profile corpus bundling

Each profile can declare corpus files via
`casehub.simulation.profiles.<name>.corpus.files=<comma-separated paths>`.

**Boot-time activation:** The active profile's corpus files are loaded
and merged into the base corpus alongside base corpus files. Both are
treated identically at runtime — the profile's corpus entries are
indistinguishable from base entries.

**Runtime activation (pushProfile):** The profile's corpus files are
loaded into an overlay-isolated InMemorySimulationCorpus. On
`popOverlay()`, the corpus is discarded. Consistent with D44 (scenario
isolation).

### 4. New types

All new types live in **simulation-core** (no new modules):

```java
// Functional interface — resolves profile names to hydrated profiles
@FunctionalInterface
public interface ProfileSource {
    Optional<SimulationProfile> resolve(String name);
}

// Carries pre-populated config + corpus — ready to push as overlay
public record SimulationProfile(SimulationConfig config,
                                SimulationCorpus<?, ?> corpus) {}
```

**SimulationConfig interface is unchanged.** Profile resolution is
orthogonal to strategy dispatch.

### 5. SmallRyeSimulationConfig changes

SmallRyeSimulationConfig (in simulation-config-core) gains:

- **Profile parsing in the constructor.** Properties with a
  `profiles.<name>.` segment after the `casehub.simulation.` prefix are
  routed into a `Map<String, Map<String, MethodSimulationConfig>>`.
  The property `profiles.<name>.corpus.files` is stored separately
  per profile.

- **`implements ProfileSource`.** The `resolve(name)` method:
  1. Looks up the named profile's method configs
  2. Builds a composed `SimulationConfig` (profile entries → flat fallback)
  3. Loads corpus files via `YamlCorpusLoader` into a fresh
     `InMemorySimulationCorpus`
  4. Returns `SimulationProfile(composedConfig, corpus)`

- **`profileNames()`** — returns the set of declared profile names
  (discovery for tooling/MCP).

- **Active-profile resolution at construction time.** Reads
  `casehub.simulation.active-profile` and composes the boot-time
  `SimulationConfig` by overlaying the active profile onto the flat
  config.

The existing `strategyFor()`, `captureEnabled()`, `exhaustionPolicy()`,
and `threshold()` methods now check the active profile first, then flat
config.

### 6. SimulationRuntime changes

SimulationRuntime (in simulation-core) gains:

```java
public void setProfileSource(ProfileSource profileSource) {
    this.profileSource = profileSource;
}

public SimulationOverlay pushProfile(String name) {
    if (profileSource == null) {
        throw new SimulationConfigException(
            "No ProfileSource registered — cannot resolve profile '" + name + "'");
    }
    SimulationProfile profile = profileSource.resolve(name)
        .orElseThrow(() -> new SimulationConfigException(
            "Unknown simulation profile: '" + name + "'"));
    return pushOverlay(profile.config(), profile.corpus());
}
```

`setProfileSource()` is called by `SimulationConfigBeans` at startup.
`pushProfile()` is the single-action entry point for scenario consumers.

### 7. SimulationConfigBeans changes

SimulationConfigBeans (in simulation-config) gains:

```java
void onStartup(@Observes StartupEvent event, ...) {
    // Existing: load base corpus files
    // Existing: register declarative extractors/scorers

    // New: wire profile source
    runtime.setProfileSource((SmallRyeSimulationConfig) config);

    // New: load active profile corpus into base corpus
    var smConfig = (SmallRyeSimulationConfig) config;
    smConfig.activeProfileCorpusFiles().ifPresent(files -> {
        var loader = new YamlCorpusLoader();
        loader.loadFromPaths(files).forEach(corpus::seed);
    });
}
```

### 8. Lifecycle progression guide

A new section in simulation-guide.md documenting the maturity stages
with concrete profile examples:

| Stage | Description | Profile example |
|-------|-------------|-----------------|
| 0. No simulation | Real backends everywhere | No config |
| 1. Capture | Record real traffic for corpus building | `capture-all` — enables capture on target SPIs |
| 2. Recorded replay | Replay captured traffic in CI | `ci-replay` — recorded-replay with captured corpus |
| 3. Curated | Key-lookup with hand-curated fixtures | `curated-test` — key-lookup with domain fixtures |
| 4. Synthetic | Sequential/random with generated data | `load-test` — sequential with CorpusSeed-built data |

Each stage gets a complete profile declaration block (copy-paste ready)
and guidance on when to advance to the next stage.

## Deliverables

1. **ProfileSource interface** — in simulation-core
2. **SimulationProfile record** — in simulation-core
3. **SmallRyeSimulationConfig profile parsing** — in simulation-config-core
4. **SmallRyeSimulationConfig implements ProfileSource** — in simulation-config-core
5. **SimulationRuntime.setProfileSource() + pushProfile()** — in simulation-core
6. **SimulationConfigBeans wiring** — in simulation-config
7. **Profile parsing tests** — SmallRyeSimulationConfig profile resolution
8. **pushProfile integration test** — overlay with profile-scoped corpus
9. **Lifecycle progression guide section** — in simulation-guide.md
10. **Configuration Reference update** — profile namespace documentation

## Testing

- **Unit:** SmallRyeSimulationConfig parses profile entries alongside
  flat entries. Profile resolution composes correctly (profile → flat
  fallback). Active profile overrides flat config at boot time. Profile
  corpus files are loaded into the returned SimulationProfile.

- **Integration:** `pushProfile("test-profile")` activates a named
  profile as an overlay. SPI calls resolve against the profile's
  strategies. Profile corpus data is isolated — not visible after
  `popOverlay()`. Unknown profile name throws
  `SimulationConfigException`.

- **Boot-time:** Active profile's corpus entries are merged into base
  corpus. Active profile's strategies override flat config.

## Trade-offs

- **Single active profile at boot time** (D70) — no comma-separated
  multi-profile composition. The overlay stack handles runtime layering;
  boot-time composition is achieved by building a single profile that
  combines the needed entries. Backward-compatible extension if needed.

- **Eager corpus loading on resolve** (D73) — `ProfileSource.resolve()`
  loads YAML files immediately. If a profile has large corpus files,
  the cost is paid even if the profile is resolved but never pushed.
  Acceptable — corpus files are small fixtures and profiles are resolved
  infrequently.

- **Two profiling mechanisms** (D69) — simulation profiles coexist with
  Quarkus profiles. The interaction is well-defined (Quarkus resolves
  first, simulation profiles layer on top) but developers must understand
  both. The lifecycle guide makes this explicit.

## References

- SimulationRuntime.java — overlay stack, strategyFor(), pushOverlay()
- SimulationConfig.java — 4-method strategy dispatch SPI
- SmallRyeSimulationConfig.java — prefix scanning, MethodSimulationConfig
- SimulationConfigBeans.java — CDI wiring, startup corpus loading
- YamlCorpusLoader.java — YAML corpus parsing
- SimulationOverlay.java — isolated config + corpus + journal
- MapSimulationConfig.java — programmatic config for tests
- D43 — overlay stack design (layered runtime overlay)
- D44 — isolated corpus per overlay
- D11 — boot-time config (profiles extend this)
- D13 — prefix scanning pattern (SmallRye gotchas)
- D53 — Quarkus profile-based CI guidance
- R1-02 — dependency direction: corpus hydration in ProfileSource
- R1-03 — Quarkus profile interaction semantics
- Issue #329 — strategy combination and lifecycle
