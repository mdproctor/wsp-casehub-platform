# Engine Worker Rights Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #902 — feat: migrate to generalized worker rights types from platform-api
**Issue group:** #902, #237, #238

**Goal:** Migrate the engine to use the generalized worker rights SPI types
from platform-api (WorkerAction record, ResourceId, WorkerAuthorizationContext,
reusable WorkerCredentialFilter from acl-worker).

**Architecture:** Platform commit `cafb326` changed WorkerAction from an enum
to a record, replaced `UUID caseId` with `ResourceId` on WorkerCredential,
and replaced `String caseDefinitionId` with `WorkerAuthorizationContext` on
WorkerPermissionRequest. The engine defines its own action constants in
`EngineWorkerActions`, wraps engine-specific context in
`EngineAuthorizationContext`, and deletes its local `WorkerCredentialFilter`
in favor of platform's `acl-worker` module with a `CaseScopeExtractor`.

**Tech Stack:** Java 21, Quarkus, Maven, JUnit 5, Mockito, AssertJ

## Global Constraints

- engine-api must not introduce new external dependencies
- All `WorkerAction` enum references become `EngineWorkerActions` constant references
- `WorkerCredential` construction uses `ResourceId` (not `UUID`)
- YAML `permissionIntent` values are kebab-case strings — parser must convert
- Platform's `acl-worker` replaces engine's local filter — classpath activation

---

### Task 1: EngineWorkerActions constants + EngineAuthorizationContext

Foundation types that all subsequent tasks depend on.

**Files:**
- Create: `api/src/main/java/io/casehub/api/acl/EngineWorkerActions.java`
- Create: `api/src/main/java/io/casehub/api/acl/EngineAuthorizationContext.java`
- Test: `api/src/test/java/io/casehub/api/acl/EngineWorkerActionsTest.java`

**Interfaces:**
- Consumes: `io.casehub.platform.api.acl.WorkerAction` (record), `io.casehub.platform.api.acl.AclAction` (enum), `io.casehub.platform.api.acl.WorkerAuthorizationContext` (marker interface)
- Produces: `EngineWorkerActions.READ_CONTEXT` (and 7 others), `EngineWorkerActions.fromKebabCase(String)`, `EngineAuthorizationContext(String caseDefinitionId)`

- [ ] **Step 1: Write the failing tests for EngineWorkerActions**

```java
package io.casehub.api.acl;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.casehub.platform.api.acl.AclAction;
import io.casehub.platform.api.acl.WorkerAction;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

class EngineWorkerActionsTest {

    @Test
    void allConstantsHaveCorrectAclAction() {
        assertThat(EngineWorkerActions.READ_CONTEXT.aclAction()).isEqualTo(AclAction.READ);
        assertThat(EngineWorkerActions.WRITE_CONTEXT.aclAction()).isEqualTo(AclAction.WRITE);
        assertThat(EngineWorkerActions.SIGNAL_CASE.aclAction()).isEqualTo(AclAction.WRITE);
        assertThat(EngineWorkerActions.READ_EVENT_LOG.aclAction()).isEqualTo(AclAction.READ);
        assertThat(EngineWorkerActions.READ_PLAN_ITEMS.aclAction()).isEqualTo(AclAction.READ);
        assertThat(EngineWorkerActions.SPAWN_SUB_CASE.aclAction()).isEqualTo(AclAction.WRITE);
        assertThat(EngineWorkerActions.CLAIM_WORK_ITEM.aclAction()).isEqualTo(AclAction.CLAIM);
        assertThat(EngineWorkerActions.ADMIN.aclAction()).isEqualTo(AclAction.ADMIN);
    }

    @ParameterizedTest
    @CsvSource({
        "read-context, READ_CONTEXT",
        "write-context, WRITE_CONTEXT",
        "signal-case, SIGNAL_CASE",
        "read-event-log, READ_EVENT_LOG",
        "read-plan-items, READ_PLAN_ITEMS",
        "spawn-sub-case, SPAWN_SUB_CASE",
        "claim-work-item, CLAIM_WORK_ITEM",
        "admin, ADMIN"
    })
    void fromKebabCase_roundTrip(String kebab, String expectedName) {
        WorkerAction action = EngineWorkerActions.fromKebabCase(kebab);
        assertThat(action.name()).isEqualTo(expectedName);
    }

    @Test
    void fromKebabCase_unknownName_throws() {
        assertThatThrownBy(() -> EngineWorkerActions.fromKebabCase("unknown-action"))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("unknown-action");
    }

    @Test
    void fromKebabCase_null_throws() {
        assertThatThrownBy(() -> EngineWorkerActions.fromKebabCase(null))
            .isInstanceOf(IllegalArgumentException.class);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -f /Users/mdproctor/claude/casehub/slots/117/engine/pom.xml test -pl api -Dtest=EngineWorkerActionsTest -DfailIfNoTests=false --batch-mode`
Expected: Compilation failure — `EngineWorkerActions` does not exist.

- [ ] **Step 3: Implement EngineWorkerActions**

Create `api/src/main/java/io/casehub/api/acl/EngineWorkerActions.java`:

```java
package io.casehub.api.acl;

import io.casehub.platform.api.acl.AclAction;
import io.casehub.platform.api.acl.WorkerAction;
import java.util.Map;

public final class EngineWorkerActions {

    public static final WorkerAction READ_CONTEXT =
        new WorkerAction("READ_CONTEXT", AclAction.READ);
    public static final WorkerAction WRITE_CONTEXT =
        new WorkerAction("WRITE_CONTEXT", AclAction.WRITE);
    public static final WorkerAction SIGNAL_CASE =
        new WorkerAction("SIGNAL_CASE", AclAction.WRITE);
    public static final WorkerAction READ_EVENT_LOG =
        new WorkerAction("READ_EVENT_LOG", AclAction.READ);
    public static final WorkerAction READ_PLAN_ITEMS =
        new WorkerAction("READ_PLAN_ITEMS", AclAction.READ);
    public static final WorkerAction SPAWN_SUB_CASE =
        new WorkerAction("SPAWN_SUB_CASE", AclAction.WRITE);
    public static final WorkerAction CLAIM_WORK_ITEM =
        new WorkerAction("CLAIM_WORK_ITEM", AclAction.CLAIM);
    public static final WorkerAction ADMIN =
        new WorkerAction("ADMIN", AclAction.ADMIN);

    private static final Map<String, WorkerAction> BY_NAME = Map.of(
        "READ_CONTEXT", READ_CONTEXT,
        "WRITE_CONTEXT", WRITE_CONTEXT,
        "SIGNAL_CASE", SIGNAL_CASE,
        "READ_EVENT_LOG", READ_EVENT_LOG,
        "READ_PLAN_ITEMS", READ_PLAN_ITEMS,
        "SPAWN_SUB_CASE", SPAWN_SUB_CASE,
        "CLAIM_WORK_ITEM", CLAIM_WORK_ITEM,
        "ADMIN", ADMIN);

    private EngineWorkerActions() {}

    public static WorkerAction fromKebabCase(String kebab) {
        if (kebab == null) {
            throw new IllegalArgumentException("action name must not be null");
        }
        String key = kebab.toUpperCase().replace('-', '_');
        WorkerAction action = BY_NAME.get(key);
        if (action == null) {
            throw new IllegalArgumentException(
                "Unknown engine worker action: " + kebab);
        }
        return action;
    }
}
```

- [ ] **Step 4: Implement EngineAuthorizationContext**

Create `api/src/main/java/io/casehub/api/acl/EngineAuthorizationContext.java`:

```java
package io.casehub.api.acl;

import io.casehub.platform.api.acl.WorkerAuthorizationContext;

public record EngineAuthorizationContext(String caseDefinitionId)
    implements WorkerAuthorizationContext {}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -f /Users/mdproctor/claude/casehub/slots/117/engine/pom.xml test -pl api -Dtest=EngineWorkerActionsTest --batch-mode`
Expected: All 4 tests PASS.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/117/engine add \
  api/src/main/java/io/casehub/api/acl/EngineWorkerActions.java \
  api/src/main/java/io/casehub/api/acl/EngineAuthorizationContext.java \
  api/src/test/java/io/casehub/api/acl/EngineWorkerActionsTest.java
git -C /Users/mdproctor/claude/casehub/slots/117/engine commit -m "feat(#902): add EngineWorkerActions constants and EngineAuthorizationContext"
```

---

### Task 2: WorkerGrantOrchestrator + CaseContextChangedEventHandler migration

Migrate the orchestrator to use `ResourceId` and `EngineAuthorizationContext`.
Fix the handler's action constant references.

**Files:**
- Modify: `runtime/src/main/java/io/casehub/engine/internal/acl/WorkerGrantOrchestrator.java`
- Modify: `runtime/src/main/java/io/casehub/engine/internal/engine/handler/CaseContextChangedEventHandler.java` (lines 570-573, 891-894)
- Test: `runtime/src/test/java/io/casehub/engine/internal/acl/WorkerGrantOrchestratorTest.java`

**Interfaces:**
- Consumes: `EngineWorkerActions` (Task 1), `EngineAuthorizationContext` (Task 1), `ResourceId`, `WorkerCredentialStore.revokeByResource()`, `WorkerCredentialStore.findActiveByActorAndResource()`
- Produces: `WorkerGrantOrchestrator.grantAndMint(String, List<WorkerAction>, UUID, String, Instant, String)` — same signature, different internal behavior

- [ ] **Step 1: Write/update the failing unit tests**

Replace `WorkerGrantOrchestratorTest` entirely. Key changes:
- All `WorkerAction.X` → `EngineWorkerActions.X`
- `WorkerCredential` construction: `caseId` (UUID) → `new ResourceId(AclResourceType.CASE, caseId.toString())`
- `credential.caseId()` → `credential.resourceId()` assertions
- `credentialStore.findActiveByActorAndCase(...)` → `findActiveByActorAndResource(...)`
- `credentialStore.revokeByCase(...)` references in helper → not used in unit test (uses InMemoryWorkerCredentialStore which is already updated)

The test file helper `credential(...)` method:

```java
private WorkerCredential credential(String token, String actorId, UUID caseId) {
    return new WorkerCredential(
        token,
        actorId,
        new ResourceId(AclResourceType.CASE, caseId.toString()),
        "tenant-1",
        Set.of(EngineWorkerActions.READ_CONTEXT),
        Instant.now().plusSeconds(3600),
        Instant.now());
}
```

All test methods constructing `WorkerCredential` inline follow the same pattern.

Assertion changes:
- `assertEquals(caseId, credential.caseId())` →
  `assertEquals(new ResourceId(AclResourceType.CASE, caseId.toString()), credential.resourceId())`

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -f /Users/mdproctor/claude/casehub/slots/117/engine/pom.xml test -pl runtime -am -Dtest=WorkerGrantOrchestratorTest -DfailIfNoTests=false --batch-mode`
Expected: Compilation failures — orchestrator still uses old API.

- [ ] **Step 3: Update WorkerGrantOrchestrator**

Key changes to `WorkerGrantOrchestrator.java`:

**Imports:** Add `ResourceId`, `AclResourceType`, `EngineAuthorizationContext`. Remove `UUID` import if no longer needed (UUID is still a parameter type).

**`grantAndMint` method:**
- Replace `new WorkerPermissionRequest(identity.actorId(), AclResourceType.CASE, Set.copyOf(actions), caseDefinitionId, tenancyId)` with `new WorkerPermissionRequest(identity.actorId(), AclResourceType.CASE, Set.copyOf(actions), new EngineAuthorizationContext(caseDefinitionId), tenancyId)`
- Replace `new WorkerCredential(token, identity.actorId(), caseId, tenancyId, ...)` with `new WorkerCredential(token, identity.actorId(), new ResourceId(AclResourceType.CASE, caseId.toString()), tenancyId, ...)`

**`revokeForWorker` method:**
- Add `var resourceId = new ResourceId(AclResourceType.CASE, caseId.toString());` at method start
- Replace `credentialStore.findActiveByActorAndCase(actorId, caseId)` with `credentialStore.findActiveByActorAndResource(actorId, resourceId)`
- Use `resourceId.toString()` for the ACL entry request resource ID string

**`revokeForCase` method:**
- Add `var resourceId = new ResourceId(AclResourceType.CASE, caseId.toString());` at method start
- Replace `credentialStore.revokeByCase(caseId)` with `credentialStore.revokeByResource(resourceId)`

- [ ] **Step 4: Update CaseContextChangedEventHandler**

Two changes:

Line ~573: Replace `java.util.List.of(io.casehub.platform.api.acl.WorkerAction.READ_CONTEXT)` with `java.util.List.of(io.casehub.api.acl.EngineWorkerActions.READ_CONTEXT)`

Line ~894: Same replacement.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -f /Users/mdproctor/claude/casehub/slots/117/engine/pom.xml test -pl runtime -am -Dtest=WorkerGrantOrchestratorTest --batch-mode`
Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/117/engine add \
  runtime/src/main/java/io/casehub/engine/internal/acl/WorkerGrantOrchestrator.java \
  runtime/src/main/java/io/casehub/engine/internal/engine/handler/CaseContextChangedEventHandler.java \
  runtime/src/test/java/io/casehub/engine/internal/acl/WorkerGrantOrchestratorTest.java
git -C /Users/mdproctor/claude/casehub/slots/117/engine commit -m "feat(#902): migrate WorkerGrantOrchestrator to ResourceId and WorkerAuthorizationContext"
```

---

### Task 3: CaseDefinitionYamlMapper — parse permissionIntent

Fix the pre-existing gap where the YAML mapper never converts
`permissionIntent` strings to `WorkerAction` records.

**Files:**
- Modify: `api/src/main/java/io/casehub/api/model/converter/CaseDefinitionYamlMapper.java` (in `convertBinding`, after line ~1019)
- Test: `api/src/test/java/io/casehub/api/model/converter/CaseDefinitionYamlMapperTest.java`

**Interfaces:**
- Consumes: `EngineWorkerActions.fromKebabCase(String)` (Task 1)
- Produces: `Binding.getPermissionIntent()` now returns non-null `List<WorkerAction>` when YAML specifies it

- [ ] **Step 1: Write the failing test**

Add a test to `CaseDefinitionYamlMapperTest` that verifies permissionIntent parsing. The test YAML needs a binding with `permissionIntent: [read-context, signal-case]`.

```java
@Test
void convertBinding_permissionIntent_parsesKebabCaseActions() {
    String yaml = """
        namespace: ns
        name: test
        version: v1
        capabilities:
          - name: cap1
            type: external
            endpoint: http://localhost
        stages:
          - name: stage1
            bindings:
              - name: b1
                capability: cap1
                on:
                  contextChange:
                    filter: ".ready"
                permissionIntent:
                  - read-context
                  - signal-case
        """;
    var definition = CaseDefinitionYamlMapper.fromYaml(yaml);
    var binding = definition.getStages().get(0).getBindings().get(0);

    assertThat(binding.getPermissionIntent())
        .isNotNull()
        .containsExactly(
            EngineWorkerActions.READ_CONTEXT,
            EngineWorkerActions.SIGNAL_CASE);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -f /Users/mdproctor/claude/casehub/slots/117/engine/pom.xml test -pl api -Dtest=CaseDefinitionYamlMapperTest#convertBinding_permissionIntent_parsesKebabCaseActions --batch-mode`
Expected: FAIL — `getPermissionIntent()` returns null.

- [ ] **Step 3: Add permissionIntent conversion to CaseDefinitionYamlMapper**

In `convertBinding()`, after the `applyExchangeFields(schemaBinding, builder);` line (around line 1023), add:

```java
if (schemaBinding.getPermissionIntent() != null
    && !schemaBinding.getPermissionIntent().isEmpty()) {
    builder.permissionIntent(
        schemaBinding.getPermissionIntent().stream()
            .map(io.casehub.api.acl.EngineWorkerActions::fromKebabCase)
            .toList());
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -f /Users/mdproctor/claude/casehub/slots/117/engine/pom.xml test -pl api -Dtest=CaseDefinitionYamlMapperTest#convertBinding_permissionIntent_parsesKebabCaseActions --batch-mode`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/117/engine add \
  api/src/main/java/io/casehub/api/model/converter/CaseDefinitionYamlMapper.java \
  api/src/test/java/io/casehub/api/model/converter/CaseDefinitionYamlMapperTest.java
git -C /Users/mdproctor/claude/casehub/slots/117/engine commit -m "fix(#902): parse permissionIntent from YAML — previously silently ignored"
```

---

### Task 4: Delete engine WorkerCredentialFilter + add CaseScopeExtractor

Replace engine's local filter with platform's `acl-worker` module.
Create `CaseScopeExtractor` to provide engine-specific URL scope extraction.

**Files:**
- Delete: `rest/src/main/java/io/casehub/engine/rest/filter/WorkerCredentialFilter.java` (use `ide_refactor_safe_delete`)
- Delete: `rest/src/test/java/io/casehub/engine/rest/filter/WorkerCredentialFilterTest.java` (use `ide_refactor_safe_delete`)
- Modify: `rest/pom.xml` — add `casehub-platform-acl-worker` dependency
- Create: `rest/src/main/java/io/casehub/engine/rest/filter/CaseScopeExtractor.java`
- Test: `rest/src/test/java/io/casehub/engine/rest/filter/CaseScopeExtractorTest.java`

**Interfaces:**
- Consumes: `io.casehub.platform.acl.worker.WorkerScopeExtractor` (SPI from acl-worker), `ResourceId`, `AclResourceType`
- Produces: `CaseScopeExtractor` — CDI bean auto-discovered, displaces `FailClosedWorkerScopeExtractor`

- [ ] **Step 1: Add acl-worker dependency to engine-rest pom.xml**

In `rest/pom.xml`, add after the `casehub-engine-common` dependency (line ~30):

```xml
    <dependency>
      <groupId>io.casehub</groupId>
      <artifactId>casehub-platform-acl-worker</artifactId>
    </dependency>
```

- [ ] **Step 2: Write the failing test for CaseScopeExtractor**

```java
package io.casehub.engine.rest.filter;

import static org.assertj.core.api.Assertions.assertThat;

import io.casehub.platform.api.acl.AclResourceType;
import io.casehub.platform.api.acl.ResourceId;
import java.util.Optional;
import java.util.UUID;
import org.junit.jupiter.api.Test;

class CaseScopeExtractorTest {

    private final CaseScopeExtractor extractor = new CaseScopeExtractor();

    @Test
    void extractsResourceId_fromCasePath() {
        UUID caseId = UUID.randomUUID();
        var ctx = new StubRequestContext(null, "cases/" + caseId + "/context");

        Optional<ResourceId> result = extractor.extractResourceId(ctx);

        assertThat(result).isPresent();
        assertThat(result.get().type()).isEqualTo(AclResourceType.CASE);
        assertThat(result.get().id()).isEqualTo(caseId.toString());
    }

    @Test
    void returnsEmpty_whenNoCaseIdInPath() {
        var ctx = new StubRequestContext(null, "health");

        Optional<ResourceId> result = extractor.extractResourceId(ctx);

        assertThat(result).isEmpty();
    }

    @Test
    void extractsResourceId_fromNestedCasePath() {
        UUID caseId = UUID.randomUUID();
        var ctx = new StubRequestContext(null, "api/v1/cases/" + caseId + "/events");

        Optional<ResourceId> result = extractor.extractResourceId(ctx);

        assertThat(result).isPresent();
        assertThat(result.get().id()).isEqualTo(caseId.toString());
    }
}
```

Note: `StubRequestContext` is the same test helper class from the deleted
`WorkerCredentialFilterTest`. Copy the `StubRequestContext` and `StubUriInfo`
inner classes into `CaseScopeExtractorTest`.

- [ ] **Step 3: Run test to verify it fails**

Run: `mvn -f /Users/mdproctor/claude/casehub/slots/117/engine/pom.xml test -pl rest -am -Dtest=CaseScopeExtractorTest -DfailIfNoTests=false --batch-mode`
Expected: Compilation failure — `CaseScopeExtractor` does not exist.

- [ ] **Step 4: Implement CaseScopeExtractor**

Create `rest/src/main/java/io/casehub/engine/rest/filter/CaseScopeExtractor.java`:

```java
package io.casehub.engine.rest.filter;

import io.casehub.platform.acl.worker.WorkerScopeExtractor;
import io.casehub.platform.api.acl.AclResourceType;
import io.casehub.platform.api.acl.ResourceId;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.ws.rs.container.ContainerRequestContext;
import java.util.Optional;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

@ApplicationScoped
public class CaseScopeExtractor implements WorkerScopeExtractor {

    private static final Pattern CASE_ID_PATTERN =
        Pattern.compile("cases/([0-9a-f-]{36})");

    @Override
    public Optional<ResourceId> extractResourceId(ContainerRequestContext ctx) {
        Matcher matcher = CASE_ID_PATTERN.matcher(ctx.getUriInfo().getPath());
        if (matcher.find()) {
            return Optional.of(
                new ResourceId(AclResourceType.CASE, matcher.group(1)));
        }
        return Optional.empty();
    }
}
```

- [ ] **Step 5: Delete engine's WorkerCredentialFilter and its test**

Use `ide_refactor_safe_delete` on both files:
- `rest/src/main/java/io/casehub/engine/rest/filter/WorkerCredentialFilter.java`
- `rest/src/test/java/io/casehub/engine/rest/filter/WorkerCredentialFilterTest.java`

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn -f /Users/mdproctor/claude/casehub/slots/117/engine/pom.xml test -pl rest -am -Dtest=CaseScopeExtractorTest --batch-mode`
Expected: All 3 tests PASS.

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/117/engine add \
  rest/pom.xml \
  rest/src/main/java/io/casehub/engine/rest/filter/CaseScopeExtractor.java \
  rest/src/test/java/io/casehub/engine/rest/filter/CaseScopeExtractorTest.java
git -C /Users/mdproctor/claude/casehub/slots/117/engine rm \
  rest/src/main/java/io/casehub/engine/rest/filter/WorkerCredentialFilter.java \
  rest/src/test/java/io/casehub/engine/rest/filter/WorkerCredentialFilterTest.java
git -C /Users/mdproctor/claude/casehub/slots/117/engine commit -m "feat(#902): replace engine WorkerCredentialFilter with platform acl-worker + CaseScopeExtractor"
```

---

### Task 5: Integration tests + BindingPermissionIntentTest + full build

Update the remaining tests that reference old WorkerAction enum constants
and old WorkerCredential constructors. Verify the full build passes.

**Files:**
- Modify: `runtime/src/test/java/io/casehub/engine/WorkerRightsIntegrationTest.java`
- Modify: `api/src/test/java/io/casehub/api/model/BindingPermissionIntentTest.java`

**Interfaces:**
- Consumes: `EngineWorkerActions` (Task 1), updated `WorkerGrantOrchestrator` (Task 2)
- Produces: Green build

- [ ] **Step 1: Update WorkerRightsIntegrationTest**

Key changes:
- Import `EngineWorkerActions` instead of `WorkerAction`
- All `WorkerAction.X` → `EngineWorkerActions.X`
- `credential.caseId()` → `credential.resourceId()`; update assertion to compare against `new ResourceId(AclResourceType.CASE, caseId.toString())`
- `mem.revokeByCase(UUID.fromString("00000000-..."))` → `mem.revokeByResource(new ResourceId(AclResourceType.CASE, "00000000-0000-0000-0000-000000000000"))`

- [ ] **Step 2: Update BindingPermissionIntentTest**

Key changes:
- Import `EngineWorkerActions` instead of `WorkerAction`
- `WorkerAction.READ_CONTEXT` → `EngineWorkerActions.READ_CONTEXT`
- `WorkerAction.SIGNAL_CASE` → `EngineWorkerActions.SIGNAL_CASE`

- [ ] **Step 3: Run full build**

Run: `mvn -f /Users/mdproctor/claude/casehub/slots/117/engine/pom.xml --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and all tests pass.

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/117/engine add \
  runtime/src/test/java/io/casehub/engine/WorkerRightsIntegrationTest.java \
  api/src/test/java/io/casehub/api/model/BindingPermissionIntentTest.java
git -C /Users/mdproctor/claude/casehub/slots/117/engine commit -m "feat(#902): update integration and binding tests for generalized worker rights types"
```

- [ ] **Step 5: Also commit the spec and decisions**

```bash
git -C /Users/mdproctor/claude/casehub/slots/117/engine add \
  docs/specs/issue-902-worker-rights-followup/decisions.md \
  docs/specs/issue-902-worker-rights-followup/2026-08-12-engine-worker-rights-migration-design.md
git -C /Users/mdproctor/claude/casehub/slots/117/engine commit -m "docs(#902): engine worker rights migration spec and decisions"
```
