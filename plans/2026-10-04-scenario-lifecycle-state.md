# Scenario Lifecycle State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehub-pages#498 — Scenario lifecycle state
**Issue group:** casehub-pages#502 (epic)

**Goal:** Add lifecycle state (DRAFT/ACTIVE/ARCHIVED) to scenarios with OrcStateMachine transition enforcement and CDI events.

**Architecture:** ScriptLifecycleState enum and CDI event records in the `scenario` module (data types). OrcStateMachine instances, transition methods, and active filtering in `scenario-runtime` (UploadedScriptSource + ScriptRegistry). Uploaded scripts start DRAFT; bundled/external are implicitly ACTIVE.

**Tech Stack:** Java 21, yaml-core OrcStateMachine, CDI events, JUnit 5, AssertJ

## Global Constraints

- `scenario` module depends on `casehub-platform-yaml-core` (OrcStateMachine available)
- `scenario-runtime` depends on `scenario` + Quarkus CDI
- ScriptDescriptor compact constructor must default `state` to `ACTIVE` when null (backward compat)
- All work happens in the pages repo: `/Users/mdproctor/claude/casehub/slots/210/pages`

---

## Batch 1: Data Model — ScriptLifecycleState + ScriptDescriptor

### Task 1: ScriptLifecycleState enum and ScriptDescriptor state field

**Files:**
- Create: `backend/scenario/src/main/java/io/casehub/pages/scenario/ScriptLifecycleState.java`
- Modify: `backend/scenario/src/main/java/io/casehub/pages/scenario/ScriptDescriptor.java`
- Modify: `backend/scenario/src/main/java/io/casehub/pages/scenario/ScriptDescriptorExtractor.java:44` (pass state to constructor)
- Modify: `backend/scenario/src/test/java/io/casehub/pages/scenario/ScriptDescriptorTest.java`
- Modify: `packages/pages-aria/src/controller/library-view.ts:6-15` (add `state` to TS interface)

**Interfaces:**
- Produces: `ScriptLifecycleState` enum (DRAFT, ACTIVE, ARCHIVED), `ScriptDescriptor.state()` accessor

- [ ] **Step 1: Write the failing test**

Add a test in `ScriptDescriptorTest.java` that verifies the state field:

```java
@Test
void descriptor_hasState() {
    var desc = new ScriptDescriptor("test", "desc", List.of(), List.of(),
            List.of(), List.of(), ScriptProvenance.UPLOADED,
            ScriptLifecycleState.DRAFT, List.of());
    assertThat(desc.state()).isEqualTo(ScriptLifecycleState.DRAFT);
}

@Test
void descriptor_defaultsStateToActive_whenNull() {
    var desc = new ScriptDescriptor("test", "desc", List.of(), List.of(),
            List.of(), List.of(), ScriptProvenance.BUNDLED,
            null, List.of());
    assertThat(desc.state()).isEqualTo(ScriptLifecycleState.ACTIVE);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -f /Users/mdproctor/claude/casehub/slots/210/pages/backend/scenario/pom.xml test -pl . -Dtest=ScriptDescriptorTest -DfailIfNoTests=false --batch-mode`
Expected: compilation failure — `ScriptLifecycleState` doesn't exist

- [ ] **Step 3: Create ScriptLifecycleState enum**

Create `backend/scenario/src/main/java/io/casehub/pages/scenario/ScriptLifecycleState.java`:

```java
package io.casehub.pages.scenario;

public enum ScriptLifecycleState { DRAFT, ACTIVE, ARCHIVED }
```

- [ ] **Step 4: Add state field to ScriptDescriptor**

Modify the record to add `ScriptLifecycleState state` between `provenance` and `firstStepTargets`:

```java
public record ScriptDescriptor(String name, String description,
                                List<String> labels, List<String> tags,
                                List<ParamDescriptor> params, List<String> calls,
                                ScriptProvenance provenance,
                                ScriptLifecycleState state,
                                List<AriaTarget> firstStepTargets) {
    public ScriptDescriptor {
        if (labels == null) labels = List.of();
        if (tags == null) tags = List.of();
        if (params == null) params = List.of();
        if (calls == null) calls = List.of();
        if (firstStepTargets == null) firstStepTargets = List.of();
        if (state == null) state = ScriptLifecycleState.ACTIVE;
    }
}
```

- [ ] **Step 5: Fix ScriptDescriptorExtractor to pass state**

In `ScriptDescriptorExtractor.extract()`, change the constructor call at line 44 to pass a state based on provenance:

```java
ScriptLifecycleState state = provenance == ScriptProvenance.UPLOADED
        ? ScriptLifecycleState.DRAFT : ScriptLifecycleState.ACTIVE;

return new ScriptDescriptor(name, description, labels, tags,
        params, calls, provenance, state, firstStepTargets);
```

- [ ] **Step 6: Fix all compilation errors in call sites**

The ScriptDescriptor constructor signature changed. Fix these call sites that construct ScriptDescriptor directly:

- `UploadedScriptSource.updateMeta()` (line 55) — pass `existing.state()` as the new parameter
- `BundledScriptSource` — uses `ScriptDescriptorExtractor.extract()`, no change needed
- `ScriptRegistryTest` — any direct constructor calls need the state parameter added (pass `ScriptLifecycleState.ACTIVE` for test bundled sources, `null` for backward-compat tests)

- [ ] **Step 7: Update TypeScript interface**

In `packages/pages-aria/src/controller/library-view.ts`, add `state` to the interface:

```typescript
export interface ScriptDescriptor {
  name: string;
  description?: string;
  labels: string[];
  tags: string[];
  params: { name: string; type: string; required: boolean }[];
  calls: string[];
  provenance: string;
  state: string;
  firstStepTargets: AriaTarget[];
}
```

- [ ] **Step 8: Run tests to verify everything passes**

Run: `mvn -f /Users/mdproctor/claude/casehub/slots/210/pages/backend/scenario/pom.xml test --batch-mode`
Expected: all tests PASS including the two new state tests

- [ ] **Step 9: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/210/pages add backend/scenario/ packages/pages-aria/src/controller/library-view.ts
git -C /Users/mdproctor/claude/casehub/slots/210/pages commit -m "feat(#498): add ScriptLifecycleState enum and state field to ScriptDescriptor"
```

---

## Batch 2: State Machine + Transitions + CDI Events

### Task 2: CDI event records

**Files:**
- Create: `backend/scenario/src/main/java/io/casehub/pages/scenario/ScriptActivated.java`
- Create: `backend/scenario/src/main/java/io/casehub/pages/scenario/ScriptArchived.java`
- Create: `backend/scenario/src/main/java/io/casehub/pages/scenario/ScriptRevised.java`

**Interfaces:**
- Produces: `ScriptActivated(String name, ScriptDescriptor descriptor)`, `ScriptArchived(...)`, `ScriptRevised(...)` CDI event records

- [ ] **Step 1: Create the three event records**

`ScriptActivated.java`:
```java
package io.casehub.pages.scenario;

public record ScriptActivated(String name, ScriptDescriptor descriptor) {}
```

`ScriptArchived.java`:
```java
package io.casehub.pages.scenario;

public record ScriptArchived(String name, ScriptDescriptor descriptor) {}
```

`ScriptRevised.java`:
```java
package io.casehub.pages.scenario;

public record ScriptRevised(String name, ScriptDescriptor descriptor) {}
```

- [ ] **Step 2: Verify compilation**

Run: `mvn -f /Users/mdproctor/claude/casehub/slots/210/pages/backend/scenario/pom.xml compile --batch-mode`
Expected: BUILD SUCCESS

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/210/pages add backend/scenario/src/main/java/io/casehub/pages/scenario/ScriptActivated.java backend/scenario/src/main/java/io/casehub/pages/scenario/ScriptArchived.java backend/scenario/src/main/java/io/casehub/pages/scenario/ScriptRevised.java
git -C /Users/mdproctor/claude/casehub/slots/210/pages commit -m "feat(#498): add ScriptActivated/Archived/Revised CDI event records"
```

### Task 3: OrcStateMachine in UploadedScriptSource + transition methods on ScriptRegistry

**Files:**
- Modify: `backend/scenario-runtime/src/main/java/io/casehub/pages/scenario/runtime/UploadedScriptSource.java`
- Modify: `backend/scenario-runtime/src/main/java/io/casehub/pages/scenario/runtime/ScriptRegistry.java`
- Create: `backend/scenario-runtime/src/test/java/io/casehub/pages/scenario/runtime/ScriptLifecycleTest.java`

**Interfaces:**
- Consumes: `ScriptLifecycleState`, `ScriptDescriptor.state()`, `DefaultOrcStateMachine` from yaml-core
- Produces: `ScriptRegistry.activate(String name)`, `ScriptRegistry.archive(String name)`, `ScriptRegistry.revise(String name)`, `ScriptRegistry.listActive(List<String> labels, List<String> tags)`

- [ ] **Step 1: Write failing tests for lifecycle transitions**

Create `ScriptLifecycleTest.java`:

```java
package io.casehub.pages.scenario.runtime;

import io.casehub.pages.scenario.ScriptDescriptor;
import io.casehub.pages.scenario.ScriptLifecycleState;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ScriptLifecycleTest {

    static final String SAMPLE_YAML = """
            scenario: test-script
            meta:
              description: A test script
              labels:
                - domain:test
              tags:
                - demo
            steps:
              - action: click
                role: button
                name: Submit
            """;

    @TempDir Path tempDir;
    ScriptRegistry registry;

    @BeforeEach
    void setUp() {
        var bundled = new BundledScriptSource(List.of());
        var uploaded = new UploadedScriptSource(tempDir);
        registry = new ScriptRegistry(bundled, uploaded);
    }

    @Test
    void uploaded_startsAsDraft() {
        ScriptDescriptor desc = registry.upload(SAMPLE_YAML);
        assertThat(desc.state()).isEqualTo(ScriptLifecycleState.DRAFT);
    }

    @Test
    void activate_movesToActive() {
        registry.upload(SAMPLE_YAML);
        ScriptDescriptor activated = registry.activate("test-script");
        assertThat(activated.state()).isEqualTo(ScriptLifecycleState.ACTIVE);
    }

    @Test
    void archive_movesToArchived() {
        registry.upload(SAMPLE_YAML);
        registry.activate("test-script");
        ScriptDescriptor archived = registry.archive("test-script");
        assertThat(archived.state()).isEqualTo(ScriptLifecycleState.ARCHIVED);
    }

    @Test
    void revise_movesActiveBackToDraft() {
        registry.upload(SAMPLE_YAML);
        registry.activate("test-script");
        ScriptDescriptor revised = registry.revise("test-script");
        assertThat(revised.state()).isEqualTo(ScriptLifecycleState.DRAFT);
    }

    @Test
    void activate_fromArchived_throws() {
        registry.upload(SAMPLE_YAML);
        registry.activate("test-script");
        registry.archive("test-script");
        assertThatThrownBy(() -> registry.activate("test-script"))
                .isInstanceOf(IllegalStateException.class);
    }

    @Test
    void archive_fromDraft_throws() {
        registry.upload(SAMPLE_YAML);
        assertThatThrownBy(() -> registry.archive("test-script"))
                .isInstanceOf(IllegalStateException.class);
    }

    @Test
    void activate_nonUploaded_throws() {
        assertThatThrownBy(() -> registry.activate("nonexistent"))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void listActive_excludesDraftAndArchived() {
        registry.upload(SAMPLE_YAML);
        assertThat(registry.listActive(List.of(), List.of())).isEmpty();

        registry.activate("test-script");
        assertThat(registry.listActive(List.of(), List.of())).hasSize(1);

        registry.archive("test-script");
        assertThat(registry.listActive(List.of(), List.of())).isEmpty();
    }

    @Test
    void updateMeta_onlyAllowedOnDraft() {
        registry.upload(SAMPLE_YAML);
        registry.activate("test-script");
        assertThatThrownBy(() -> registry.updateMeta("test-script",
                new io.casehub.pages.scenario.ScriptMeta("new desc", List.of(), List.of())))
                .isInstanceOf(IllegalStateException.class);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -f /Users/mdproctor/claude/casehub/slots/210/pages/backend/scenario-runtime/pom.xml test -Dtest=ScriptLifecycleTest -DfailIfNoTests=false --batch-mode`
Expected: compilation failure — `activate()`, `archive()`, `revise()`, `listActive()` don't exist

- [ ] **Step 3: Add OrcStateMachine to UploadedScriptSource**

Modify `UploadedScriptSource.java` to add:

1. A new field: `private final Map<String, OrcStateMachine<ScriptLifecycleState>> stateMachines = new LinkedHashMap<>();`
2. Import: `io.casehub.yaml.core.orchestration.DefaultOrcStateMachine` and `io.casehub.yaml.core.orchestration.OrcStateMachine`
3. A factory method:

```java
private OrcStateMachine<ScriptLifecycleState> createStateMachine(String name) {
    return DefaultOrcStateMachine.<ScriptLifecycleState>builder(
            "script:" + name, ScriptLifecycleState.class, ScriptLifecycleState.DRAFT)
            .transition(ScriptLifecycleState.DRAFT, ScriptLifecycleState.ACTIVE)
            .transition(ScriptLifecycleState.ACTIVE, ScriptLifecycleState.ARCHIVED)
            .transition(ScriptLifecycleState.ACTIVE, ScriptLifecycleState.DRAFT)
            .build();
}
```

4. In `upload()`, after creating the descriptor, create a state machine: `stateMachines.put(desc.name(), createStateMachine(desc.name()));`
5. In `scanDirectory()`, after extracting each descriptor, create a state machine with initial state DRAFT
6. In `delete()`, also remove from `stateMachines`
7. Add a `transition()` method:

```java
public ScriptDescriptor transition(String name, ScriptLifecycleState target) {
    OrcStateMachine<ScriptLifecycleState> sm = stateMachines.get(name);
    if (sm == null) throw new IllegalArgumentException("Not an uploaded script: " + name);
    ScriptLifecycleState current = sm.currentState();
    if (!sm.transition(current, target)) {
        throw new IllegalStateException(
                "Cannot transition '" + name + "' from " + current + " to " + target);
    }
    ScriptDescriptor existing = descriptors.get(name);
    ScriptDescriptor updated = new ScriptDescriptor(existing.name(), existing.description(),
            existing.labels(), existing.tags(), existing.params(), existing.calls(),
            existing.provenance(), target, existing.firstStepTargets());
    descriptors.put(name, updated);
    return updated;
}

public ScriptLifecycleState stateOf(String name) {
    OrcStateMachine<ScriptLifecycleState> sm = stateMachines.get(name);
    return sm != null ? sm.currentState() : null;
}
```

- [ ] **Step 4: Add transition methods and listActive to ScriptRegistry**

Add to `ScriptRegistry.java`:

```java
public ScriptDescriptor activate(String name) {
    if (!uploaded.contains(name)) {
        throw new IllegalArgumentException("Cannot activate '" + name + "': not an uploaded script");
    }
    return uploaded.transition(name, ScriptLifecycleState.ACTIVE);
}

public ScriptDescriptor archive(String name) {
    if (!uploaded.contains(name)) {
        throw new IllegalArgumentException("Cannot archive '" + name + "': not an uploaded script");
    }
    return uploaded.transition(name, ScriptLifecycleState.ARCHIVED);
}

public ScriptDescriptor revise(String name) {
    if (!uploaded.contains(name)) {
        throw new IllegalArgumentException("Cannot revise '" + name + "': not an uploaded script");
    }
    return uploaded.transition(name, ScriptLifecycleState.DRAFT);
}

public List<ScriptDescriptor> listActive(List<String> labels, List<String> tags) {
    return allDescriptors()
            .filter(d -> d.state() == ScriptLifecycleState.ACTIVE)
            .filter(d -> matchesLabels(d, labels))
            .filter(d -> matchesTags(d, tags))
            .toList();
}
```

Also modify `updateMeta()` to enforce DRAFT-only:

```java
public ScriptDescriptor updateMeta(String name, ScriptMeta meta) {
    if (!uploaded.contains(name)) {
        throw new IllegalArgumentException(
                "Cannot update metadata for '" + name + "': not an uploaded script");
    }
    ScriptLifecycleState state = uploaded.stateOf(name);
    if (state != null && state != ScriptLifecycleState.DRAFT) {
        throw new IllegalStateException(
                "Cannot update metadata for '" + name + "': script is " + state + ", must be DRAFT");
    }
    return uploaded.updateMeta(name, meta);
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -f /Users/mdproctor/claude/casehub/slots/210/pages/backend/scenario-runtime/pom.xml test --batch-mode`
Expected: all tests PASS, including all existing ScriptRegistryTest tests and the new ScriptLifecycleTest

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/210/pages add backend/scenario-runtime/
git -C /Users/mdproctor/claude/casehub/slots/210/pages commit -m "feat(#498): add OrcStateMachine lifecycle transitions to ScriptRegistry"
```

---

## Batch 3: Verify full build

### Task 4: Full build verification and issue update

**Files:**
- No new files

- [ ] **Step 1: Run full backend build**

Run: `mvn -f /Users/mdproctor/claude/casehub/slots/210/pages/backend/pom.xml test --batch-mode`
Expected: BUILD SUCCESS — all modules compile, all tests pass

- [ ] **Step 2: Verify TypeScript compilation**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && yarn tsc --noEmit` (or equivalent TS build command)
Expected: no type errors from the ScriptDescriptor interface change

- [ ] **Step 3: Commit any fixes**

If fixes were needed, commit them:
```bash
git -C /Users/mdproctor/claude/casehub/slots/210/pages add -A
git -C /Users/mdproctor/claude/casehub/slots/210/pages commit -m "fix(#498): build fixes for lifecycle state integration"
```

## References

- [2026-10-04-scenario-lifecycle-state-design.md] — design spec this plan implements
- ScriptDescriptor.java — data model being extended
- UploadedScriptSource.java — mutable source gaining state machines
- ScriptRegistry.java — registry gaining transition methods
- ScriptRegistryTest.java — existing tests that must continue passing
- OrcStateMachine.java, DefaultOrcStateMachine.java — state machine primitives (yaml-core)
- TemporalSimulationDriver.java — OrcStateMachine lifecycle precedent
- casehub-pages#498 — source issue
- casehub-pages#517 — Serverless Workflow executor (approval workflows separated here)
