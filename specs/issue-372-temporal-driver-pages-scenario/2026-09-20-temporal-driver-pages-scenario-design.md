# Temporal Driver Pages Scenario Integration — Design Spec

**Branch:** issue-372-temporal-driver-pages-scenario
**Issue:** casehubio/platform#372
**Date:** 2026-09-20

## Overview

Adds a remote control API for `TemporalSimulationDriver` so that Pages scenarios (and other consumers) can start, stop, pause, resume, and change speed of temporal simulation profiles via GraphQL/REST/MCP. Also adds a dedicated `temporal:` step type in the Pages ScenarioOrchestrator for declarative simulation control from scenario YAML.

The driver and profile infrastructure already exist (#371). This issue builds the control and integration layer on top.

## Architecture

### New Module: simulation-api

Pure Java SPI module. Depends on platform-api only (for `@McpDomain`, `@PlatformQuery`, `@PlatformMutation` annotations). Zero runtime dependencies.

**`TemporalDriverApi`** — `@McpDomain("temporal-drivers")`:

```java
package io.casehub.platform.simulation.api;

@McpDomain("temporal-drivers")
public interface TemporalDriverApi {

    @PlatformMutation("Start a temporal simulation driver")
    TemporalDriverStatus start(TemporalDriverStartRequest request);

    @PlatformMutation("Stop a temporal simulation driver")
    @RestMethod(HttpMethod.DELETE)
    void stop(@PathParam String name);

    @PlatformMutation("Pause a temporal simulation driver")
    @RestMethod(HttpMethod.PUT)
    void pause(@PathParam String name);

    @PlatformMutation("Resume a paused temporal simulation driver")
    @RestMethod(HttpMethod.PUT)
    void resume(@PathParam String name);

    @PlatformMutation("Change speed of a temporal simulation driver")
    @RestMethod(HttpMethod.PUT)
    void setSpeed(TemporalDriverSpeedRequest request);

    @PlatformQuery("Get status of a temporal simulation driver")
    TemporalDriverStatus status(@PathParam String name);

    @PlatformQuery("List all active temporal simulation drivers")
    List<TemporalDriverStatus> list();
}
```

**Request/response records:**

```java
public record TemporalDriverStartRequest(
    String name,                          // driver key (required)
    String profileName,                   // resolve from registry (mutually exclusive with inline)
    String qualifiedName,                 // inline definition
    String tenancyId,                     // inline
    List<TemporalEventInput> events,      // inline
    Boolean loop,                         // inline, or override on named profile
    Double speed                          // inline, or override on named profile
) {}

public record TemporalEventInput(
    String delay,
    String label,
    Map<String, Object> payload
) {}

public record TemporalDriverSpeedRequest(
    String name,
    double speed
) {}

public record TemporalDriverStatus(
    String name,
    String profileName,
    String state,
    double speed,
    int emittedCount,
    int failureCount,
    int loopIterations,
    boolean hasFailures
) {}
```

**Start request modes:**

| Mode | Fields | Behaviour |
|------|--------|-----------|
| Named | `name`, `profileName`, optional `speed`/`loop` | Resolve profile from `TemporalProfileRegistry`, apply overrides |
| Inline | `name`, `qualifiedName`, `events`, optional `tenancyId`/`loop`/`speed` | Build `TemporalProfile` from request fields directly |

Validation: `profileName` and `qualifiedName` are mutually exclusive. One must be present. `name` is always required — it is the driver key for subsequent control operations. When `profileName` is set and `name` is omitted, `name` defaults to `profileName`.

**YAML/Java parity:** The inline mode mirrors the YAML `temporal-profiles:` config — whatever you can declare in `simulation.yaml`, you can express programmatically via the API.

### Implementation: event-simulation

`TemporalDriverService` @ApplicationScoped implements `TemporalDriverApi`:

```java
package io.casehub.platform.simulation.event.quarkus;

@ApplicationScoped
public class TemporalDriverService implements TemporalDriverApi {

    private final TemporalDriverFactory<Map<String, Object>> driverFactory;
    private final TemporalProfileRegistry profileRegistry;
    private final ConcurrentHashMap<String, ActiveDriver> activeDrivers = new ConcurrentHashMap<>();

    // package-private — holds driver + metadata for status reporting
    record ActiveDriver(
        String name,
        String profileName,
        TemporalSimulationDriver<Map<String, Object>> driver,
        double initialSpeed
    ) {}
}
```

**Dependencies injected:**
- `TemporalDriverFactory<Map<String, Object>>` — already produced by `EventSimulationBeans`
- `TemporalProfileRegistry` — already produced by `SimulationConfigBeans`

**Operations:**

| Method | Behaviour |
|--------|-----------|
| `start(request)` | Named mode: resolve from registry, apply speed/loop overrides. Inline mode: build `TemporalProfile` from request fields (parse delay strings via `DurationParser`). Check no existing active driver for `name` — error if conflict. Create driver via factory, start, store in map. Return status. |
| `stop(name)` | Lookup, call `driver.stop()`, remove from map. 404 if not found. |
| `pause(name)` | Lookup, call `driver.pause()`. 404 if not found. |
| `resume(name)` | Lookup, call `driver.resume()`. 404 if not found. |
| `setSpeed(request)` | Lookup, call `driver.setSpeed(speed)`. 404 if not found. |
| `status(name)` | Lookup, build `TemporalDriverStatus` from `driver.state()`, `driver.lastResult()`, speed. 404 if not found. |
| `list()` | Iterate map, build status for each. Includes COMPLETED/STOPPED drivers until explicitly stopped/removed. |

**Conflict handling:** `start()` with a name that already has a RUNNING or PAUSED driver throws `IllegalStateException`. Callers must stop first. COMPLETED and STOPPED drivers remain in the map until `stop()` is called — `stop()` on an already-COMPLETED driver is idempotent and removes it.

**Inline profile building:** When `profileName` is null and `qualifiedName` is set, the service builds a `TemporalProfile<Map<String, Object>>` directly from the request fields. Delay strings are parsed via `DurationParser` (already in simulation-config-core: `"5s"`, `"2m"`, `"500ms"`, bare millis). Events are converted to `TimedEntry<Map<String, Object>>` with payload as the event. `loop` defaults to `false`, `speed` defaults to `1.0`.

**GraphQL/REST/MCP generation:** The `graphql-generator` APT scans `@McpDomain` on `TemporalDriverApi` and generates both `@GraphQLApi` resolver and `@Path` JAX-RS REST resource. The MCP scanner in `casehub-platform-mcp` auto-discovers the domain at startup. No hand-written endpoints.

### JSON Schema Updates

**simulation.schema.json** — add `temporal-profiles` to the root and supporting `$defs`:

```json
"temporal-profiles": {
  "type": "object",
  "description": "Named temporal simulation profiles",
  "additionalProperties": {
    "$ref": "#/$defs/temporal-profile-config"
  }
}
```

New `$defs`:

```json
"temporal-profile-config": {
  "type": "object",
  "properties": {
    "qualified-name": { "type": "string" },
    "tenancy-id": { "type": "string" },
    "loop": { "type": "boolean", "default": false },
    "speed": { "type": "number", "exclusiveMinimum": 0, "default": 1.0 },
    "events": { "type": "array", "items": { "$ref": "#/$defs/temporal-event" } },
    "events-file": { "type": "string" },
    "from-corpus": { "type": "string" },
    "sequence": { "type": "array", "items": { "$ref": "#/$defs/sequence-ref" } }
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
  "properties": {
    "delay": { "type": ["string", "number"], "default": 0 },
    "label": { "type": "string" },
    "payload": { "type": "object" }
  }
},
"sequence-ref": {
  "type": "object",
  "required": ["ref"],
  "properties": {
    "ref": { "type": "string" },
    "delay": { "type": ["string", "number"] }
  }
}
```

Also update `profile-config` to include:

```json
"temporal": {
  "type": "array",
  "items": {
    "oneOf": [
      { "type": "string", "description": "Reference to a named temporal profile" },
      { "$ref": "#/$defs/temporal-profile-config" }
    ]
  }
}
```

### Pages Temporal Step Type (casehub-pages)

New `temporal:` step in `ScenarioOrchestrator`, independent from the existing `simulation:` overlay step.

**YAML schema:**

```yaml
# Named profile reference
- name: start-data-feed
  temporal:
    action: start
    profile: morning-routine
    speed: 20.0                # optional override

# Inline profile definition
- name: ad-hoc-burst
  temporal:
    action: start
    name: smoke-alarm
    qualified-name: iot.alarm
    loop: false
    speed: 5.0
    events:
      - delay: 0
        label: alarm-trigger
        payload: { deviceId: smoke-01, state: ALARM }
      - delay: 1s
        label: alarm-clear
        payload: { deviceId: smoke-01, state: CLEAR }

# Control actions
- name: pause-feed
  temporal:
    action: pause
    name: morning-routine

- name: speed-up
  temporal:
    action: set-speed
    name: morning-routine
    speed: 50.0

- name: stop-feed
  temporal:
    action: stop
    name: morning-routine
```

**Actions:** `start`, `stop`, `pause`, `resume`, `set-speed`.

**Conventions:**
- `profile:` implies `name = profileName` when `name` is omitted (shorthand for the common case)
- `name:` is the driver key for subsequent control actions
- `stop/pause/resume/set-speed` require `name:` to identify the target

**Execution:** The step handler calls `TemporalDriverApi` via the generated REST client (`@RegisterRestClient`) when Pages runs as a separate service, or via direct CDI injection when co-deployed. The step completes immediately — the driver runs on its own virtual thread in the platform service.

**JSON Schema:** A `temporal-step.schema.json` added to Pages, defining the step structure with `action` enum and conditional field requirements per action.

### Domain Integration

No new domain-specific code required. Domains integrate temporal simulation via existing infrastructure:

1. **Declare temporal profiles** in the domain's `simulation.yaml` — already supported by `YamlSimulationConfig` parser
2. **Events flow through the CDI bus** — `EventSimulationBeans.temporalDriverFactory()` converts `Map<String, Object>` payloads to CloudEvents with `qualifiedName` as the CloudEvent type
3. **Domain observers** receive CloudEvents via existing `@CloudEventType` qualifiers

The control API operates on profile names, not domain concepts. A domain's temporal profiles are entries in `simulation.yaml` with domain-specific `qualified-name` values matching the domain's CloudEvent observers.

## Module Change Summary

| Module | Changes |
|--------|---------|
| `simulation-api/` (new) | `TemporalDriverApi` @McpDomain SPI + request/response records |
| `event-simulation/` | `TemporalDriverService` @ApplicationScoped implements TemporalDriverApi |
| `simulation-config-core/` | Update `simulation.schema.json` — add temporal-profiles, temporal-event, sequence-ref definitions |
| casehub-pages (cross-repo) | New `temporal:` step type in ScenarioOrchestrator + JSON Schema |

## Testing

### simulation-api (unit tests)

| Test | What it verifies |
|------|-----------------|
| `TemporalDriverStartRequestTest` | Named vs inline mutual exclusivity validation, name defaulting from profileName |
| `TemporalEventInputTest` | Delay string formats, payload serialization |

### event-simulation (Quarkus integration)

| Test | What it verifies |
|------|-----------------|
| `TemporalDriverServiceTest` — start named | Resolves profile from registry, driver starts, status returns RUNNING |
| `TemporalDriverServiceTest` — start inline | Builds profile from request fields, driver starts, events fire as CloudEvents |
| `TemporalDriverServiceTest` — speed override | Named profile start with speed override, driver runs at overridden speed |
| `TemporalDriverServiceTest` — loop override | Named profile start with loop override |
| `TemporalDriverServiceTest` — stop | Running driver stops, removed from active map, status reflects STOPPED |
| `TemporalDriverServiceTest` — pause/resume | Paused driver stops emitting, resume continues |
| `TemporalDriverServiceTest` — setSpeed | Mid-flight speed change takes effect |
| `TemporalDriverServiceTest` — status | Returns current state, emitted count, failure count, speed |
| `TemporalDriverServiceTest` — list | Returns all active drivers |
| `TemporalDriverServiceTest` — conflict | Start on already-running name throws IllegalStateException |
| `TemporalDriverServiceTest` — not found | Stop/pause/resume/setSpeed/status on unknown name returns 404 |
| `TemporalDriverServiceTest` — stop completed | Stop on COMPLETED driver is idempotent, removes from map |
| `TemporalDriverServiceTest` — generated endpoints | @QuarkusTest verifying GraphQL + REST endpoints are accessible |

### simulation-config-core

| Test | What it verifies |
|------|-----------------|
| Schema validation | simulation.schema.json validates existing and new temporal-profiles YAML |

### casehub-pages (cross-repo)

| Test | What it verifies |
|------|-----------------|
| Temporal step parsing | YAML temporal: block parsed into action + parameters |
| Start named | Step calls TemporalDriverApi.start with profileName |
| Start inline | Step calls TemporalDriverApi.start with inline fields |
| Control actions | pause/resume/stop/set-speed steps call correct API methods |
| Name defaulting | profile: without name: uses profile as name |
| Schema validation | temporal-step.schema.json validates step YAML |

## Scope

| Deliverable | Module | Description |
|-------------|--------|-------------|
| `TemporalDriverApi` @McpDomain | simulation-api (new) | SPI interface — start/stop/pause/resume/setSpeed/status/list |
| Request/response records | simulation-api (new) | TemporalDriverStartRequest, TemporalDriverSpeedRequest, TemporalDriverStatus, TemporalEventInput |
| `TemporalDriverService` | event-simulation | @ApplicationScoped implementation — driver registry + lifecycle management |
| JSON Schema update | simulation-config-core | temporal-profiles, temporal-event, sequence-ref $defs in simulation.schema.json |
| `temporal:` step type | casehub-pages (cross-repo) | ScenarioOrchestrator step handler + JSON Schema |
| Unit + integration tests | simulation-api, event-simulation, simulation-config-core, casehub-pages | Validation, lifecycle, endpoint generation, step parsing |

## Deferred

| Item | Reason | Tracked |
|------|--------|---------|
| Speed synchronization with global SimulationConfig | Per-driver speed via setSpeed() is sufficient. Global speed coordination deferred. | casehubio/platform#373 |
| Temporal assertion step type | Assert on driver status (event count, state) in scenario YAML. Can be added as a follow-up once the control surface is proven. | Not yet tracked |

## References

- [platform#372](https://github.com/casehubio/platform/issues/372) — this issue
- [platform#371](https://github.com/casehubio/platform/issues/371) — parent: temporal simulation driver
- [2026-09-20-temporal-simulation-driver-design.md](../issue-371-temporal-simulation-driver/2026-09-20-temporal-simulation-driver-design.md) — driver spec
- [2026-09-16-pages-scenario-simulation-design.md](../feat-294-simulation-service/2026-09-16-pages-scenario-simulation-design.md) — overlay/scenario pattern
- simulation-core/TemporalSimulationDriver.java — driver lifecycle (start/pause/resume/stop/setSpeed)
- simulation-core/TemporalDriverFactory.java — factory functional interface
- simulation-config-core/TemporalProfileRegistry.java — named profile resolution
- simulation-config-core/YamlSimulationConfig.java — temporal-profiles YAML parsing
- simulation-config-core/src/main/resources/schema/simulation.schema.json — existing schema (needs update)
- event-simulation/EventSimulationBeans.java — CDI factory wiring (Map → CloudEvent)
- callback-api/CallbackApi.java — @McpDomain SPI pattern precedent
- callback/CallbackService.java — flat implementation pattern precedent
- D1-D7 in [decisions.md](decisions.md)
