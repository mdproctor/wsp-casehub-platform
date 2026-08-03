# Case Definition Authorization → ACL Grants Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #219 — feat: wire Case Definition authorization YAML to ACL grants
**Issue group:** #219 (single issue; part of epic #210 — ACL completion)

**Goal:** When a case is started, the engine reads `authorization` from the CaseDefinition and creates ACL grants for each declared action×group combination, plus an automatic ADMIN grant for the case creator.

**Architecture:** The `CaseDefinition` model gains an `authorization` field (`Map<AclAction, List<String>>`). The YAML schema adds an `Authorization` type. `CaseDefinitionYamlMapper` parses the YAML block. `CaseHubReactor.startCaseInternal()` injects `AccessControlProvider` and calls `grantBatch()` after `buildInstance()` but before `onCaseStarted()` — ensuring ACL is in place before any bindings fire.

**Tech Stack:** Java 21, Quarkus, casehub-platform-api ACL SPI, casehub-engine-api model, jsonschema2pojo, Jackson

## Global Constraints

- All changes are in the engine repo (`/Users/mdproctor/claude/casehub/engine`)
- `platform-api` is already a transitive compile dependency of engine/runtime (via `casehub-platform`)
- No new platform changes needed — the ACL SPI is ready
- `AccessControlProvider` is a blocking SPI — all methods return directly (no `CompletionStage`)
- `AclEntryRequest` is `record(actorId, resourceId, action, expiresAt)` — input type for batch operations
- `AclResourceType.CASE = "case"` — resource IDs use format `case:<caseId>`
- IntelliJ MCP workspace is open at `/Users/mdproctor/claude/casehub/engine` with project_path `/Users/mdproctor/claude/casehub/engine`

---

### Task 1: CaseDefinition model — add authorization field

**Files:**
- Modify: `api/src/main/java/io/casehub/api/model/CaseDefinition.java`
- Test: `runtime/src/test/java/io/casehub/engine/model/ModelBuilderTest.java`

**Interfaces:**
- Consumes: `io.casehub.platform.api.acl.AclAction` (enum: READ, WRITE, ADMIN, CLAIM)
- Produces: `CaseDefinition.getAuthorization(): Map<AclAction, List<String>>`, `CaseDefinition.setAuthorization(Map<AclAction, List<String>>)`, `CaseDefinition.Builder.authorization(AclAction, List<String>)`, `CaseDefinition.Builder.authorization(Map<AclAction, List<String>>)`

- [ ] **Step 1: Write failing test in ModelBuilderTest**

Add a test in the `CaseDefinitionBuilderTests` nested class:

```java
@Test
@DisplayName("authorization builder sets action-to-groups map")
void authorization_setsMap() {
    var def = CaseDefinition.builder()
        .namespace("ns").name("auth-test").version("1.0")
        .authorization(AclAction.READ, List.of("auditor", "manager"))
        .authorization(AclAction.ADMIN, List.of("supervisor"))
        .build();

    assertNotNull(def.getAuthorization());
    assertEquals(2, def.getAuthorization().size());
    assertEquals(List.of("auditor", "manager"), def.getAuthorization().get(AclAction.READ));
    assertEquals(List.of("supervisor"), def.getAuthorization().get(AclAction.ADMIN));
}

@Test
@DisplayName("authorization defaults to null when not set")
void authorization_defaultsNull() {
    var def = CaseDefinition.builder()
        .namespace("ns").name("no-auth").version("1.0")
        .build();

    assertNull(def.getAuthorization());
}
```

Import: `io.casehub.platform.api.acl.AclAction`

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl runtime -Dtest="ModelBuilderTest$CaseDefinitionBuilderTests#authorization_setsMap" -f /Users/mdproctor/claude/casehub/engine/pom.xml --batch-mode -q`
Expected: compilation failure — `authorization()` method and `getAuthorization()` do not exist

- [ ] **Step 3: Implement — add field, getter, setter, builder methods to CaseDefinition**

On `CaseDefinition` class, add field after `cognitiveDemands` (line 74):

```java
private Map<AclAction, List<String>> authorization;
```

Add getter/setter after `setCognitiveDemands`:

```java
public Map<AclAction, List<String>> getAuthorization() {
    return authorization;
}

public void setAuthorization(Map<AclAction, List<String>> authorization) {
    this.authorization = authorization;
}
```

On `CaseDefinition.Builder`, add field after `cognitiveDemands`:

```java
private Map<AclAction, List<String>> authorization;
```

Add builder methods:

```java
public Builder authorization(AclAction action, List<String> groups) {
    if (this.authorization == null) {
        this.authorization = new java.util.EnumMap<>(AclAction.class);
    }
    this.authorization.put(action, List.copyOf(groups));
    return this;
}

public Builder authorization(Map<AclAction, List<String>> authorization) {
    this.authorization = authorization != null ? new java.util.EnumMap<>(authorization) : null;
    return this;
}
```

In `build()` method, after cognitiveDemands wiring, add:

```java
if (authorization != null && !authorization.isEmpty()) {
    def.setAuthorization(Map.copyOf(authorization));
}
```

Import: `io.casehub.platform.api.acl.AclAction`

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn test -pl runtime -Dtest="ModelBuilderTest" -f /Users/mdproctor/claude/casehub/engine/pom.xml --batch-mode -q`
Expected: all ModelBuilderTest tests PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/engine add api/src/main/java/io/casehub/api/model/CaseDefinition.java runtime/src/test/java/io/casehub/engine/model/ModelBuilderTest.java
git -C /Users/mdproctor/claude/casehub/engine commit -m "feat(#219): add authorization field to CaseDefinition model"
```

---

### Task 2: CaseDefinition.yaml schema — add Authorization type

**Files:**
- Modify: `schema/src/main/resources/schema/CaseDefinition.yaml`

**Interfaces:**
- Consumes: nothing
- Produces: YAML schema property `authorization` on `CaseDefinitionSpec`, `Authorization` type in `$defs`

- [ ] **Step 1: Add `authorization` property to CaseDefinitionSpec**

In `CaseDefinitionSpec.properties` (after the `_forceGoogleAi` entry, around line 307), add:

```yaml
      authorization:
        $ref: "#/$defs/Authorization"
        description: >
          ACL grants created when a case instance of this type is started.
          Maps AclAction to groups. Absent = no ACL enforcement (NoOp default).
```

- [ ] **Step 2: Add Authorization type to $defs**

Add before the end of the `$defs` section (after the last model type definition):

```yaml
  Authorization:
    type: object
    description: >
      Declares which groups are granted each ACL action when a case
      of this type is created. Groups are IdP-agnostic — resolved
      via CurrentPrincipal.roles(). All fields are optional.
    unevaluatedProperties: false
    properties:
      read:
        type: array
        items: { type: string }
        description: "Groups granted READ — query case, view plan items, event log, work items"
      write:
        type: array
        items: { type: string }
        description: "Groups granted WRITE — signal, update context, assign work items"
      admin:
        type: array
        items: { type: string }
        description: "Groups granted ADMIN — start, close, suspend, resume, dispatch"
      claim:
        type: array
        items: { type: string }
        description: "Groups granted CLAIM — claim work items for execution"
```

- [ ] **Step 3: Rebuild schema module to verify JSON schema compiles**

Run: `mvn compile -pl schema -f /Users/mdproctor/claude/casehub/engine/pom.xml --batch-mode -q`
Expected: BUILD SUCCESS, generated `Authorization.java` in `target/generated-sources/`

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/engine add schema/src/main/resources/schema/CaseDefinition.yaml
git -C /Users/mdproctor/claude/casehub/engine commit -m "feat(#219): add Authorization type to CaseDefinition JSON schema"
```

---

### Task 3: CaseDefinitionYamlMapper — parse authorization from YAML

**Files:**
- Modify: `api/src/main/java/io/casehub/api/model/converter/CaseDefinitionYamlMapper.java`
- Test: `api/src/test/java/io/casehub/api/model/converter/CaseDefinitionYamlMapperTest.java`

**Interfaces:**
- Consumes: `CaseDefinition.setAuthorization(Map<AclAction, List<String>>)` (from Task 1), `Authorization` generated class (from Task 2)
- Produces: YAML `spec.authorization` block parsed into `CaseDefinition.authorization` field

- [ ] **Step 1: Write failing YAML mapper test**

Add a test in `CaseDefinitionYamlMapperTest`:

```java
@Test
void authorizationBlockParsedToAclActionMap() {
    String yaml = """
        dsl: "0.1.0"
        namespace: acl-test
        name: auth-case
        version: "1.0.0"
        spec:
          authorization:
            read:  [case-manager, auditor]
            write: [case-manager]
            admin: [supervisor]
            claim: [case-worker]
          capabilities:
            - name: verify
          workers:
            - name: verifier
              capabilityName: verify
              function:
                function: "(input, scope) -> WorkerResult.of(Map.of())"
          bindings:
            - name: verify-binding
              target:
                capabilityName: verify
              trigger:
                contextChange:
                  when: ".status == \\"pending\\""
        """;

    CaseDefinition def = CaseDefinitionYamlMapper.load(
        new java.io.ByteArrayInputStream(yaml.getBytes(java.nio.charset.StandardCharsets.UTF_8)));

    assertNotNull(def.getAuthorization());
    assertEquals(4, def.getAuthorization().size());
    assertEquals(List.of("case-manager", "auditor"), def.getAuthorization().get(AclAction.READ));
    assertEquals(List.of("case-manager"), def.getAuthorization().get(AclAction.WRITE));
    assertEquals(List.of("supervisor"), def.getAuthorization().get(AclAction.ADMIN));
    assertEquals(List.of("case-worker"), def.getAuthorization().get(AclAction.CLAIM));
}

@Test
void absentAuthorizationLeavesFieldNull() {
    String yaml = """
        dsl: "0.1.0"
        namespace: acl-test
        name: no-auth-case
        version: "1.0.0"
        spec:
          capabilities:
            - name: verify
          workers:
            - name: verifier
              capabilityName: verify
              function:
                function: "(input, scope) -> WorkerResult.of(Map.of())"
          bindings:
            - name: verify-binding
              target:
                capabilityName: verify
              trigger:
                contextChange:
                  when: ".status == \\"pending\\""
        """;

    CaseDefinition def = CaseDefinitionYamlMapper.load(
        new java.io.ByteArrayInputStream(yaml.getBytes(java.nio.charset.StandardCharsets.UTF_8)));

    assertNull(def.getAuthorization());
}
```

Import: `io.casehub.platform.api.acl.AclAction`

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl api -Dtest="CaseDefinitionYamlMapperTest#authorizationBlockParsedToAclActionMap" -f /Users/mdproctor/claude/casehub/engine/pom.xml --batch-mode -q`
Expected: FAIL — authorization not parsed

- [ ] **Step 3: Implement — add authorization parsing in convertToApiModel()**

In `CaseDefinitionYamlMapper.convertToApiModel()`, after the `routingSignalWeights` block (around line 696) and before `return def;`, add:

```java
// authorization — spec-level action-to-groups map for ACL grants at case start
final JsonNode authNode = specNode != null ? specNode.get("authorization") : null;
if (authNode != null && authNode.isObject()) {
    var authMap = new java.util.EnumMap<AclAction, List<String>>(AclAction.class);
    authNode.fields().forEachRemaining(e -> {
        AclAction action;
        try {
            action = AclAction.valueOf(e.getKey().toUpperCase(java.util.Locale.ROOT));
        } catch (IllegalArgumentException ex) {
            throw new IllegalArgumentException(
                "Unknown authorization action: '" + e.getKey()
                    + "'. Valid values: " + java.util.Arrays.toString(AclAction.values()));
        }
        if (e.getValue().isArray()) {
            var groups = new java.util.ArrayList<String>();
            e.getValue().forEach(g -> groups.add(g.asText()));
            authMap.put(action, List.copyOf(groups));
        }
    });
    if (!authMap.isEmpty()) {
        def.setAuthorization(Map.copyOf(authMap));
    }
}
```

Import: `io.casehub.platform.api.acl.AclAction`

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn test -pl api -Dtest="CaseDefinitionYamlMapperTest" -f /Users/mdproctor/claude/casehub/engine/pom.xml --batch-mode -q`
Expected: all CaseDefinitionYamlMapperTest tests PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/engine add api/src/main/java/io/casehub/api/model/converter/CaseDefinitionYamlMapper.java api/src/test/java/io/casehub/api/model/converter/CaseDefinitionYamlMapperTest.java
git -C /Users/mdproctor/claude/casehub/engine commit -m "feat(#219): parse authorization YAML block in CaseDefinitionYamlMapper"
```

---

### Task 4: CaseHubReactor — wire ACL grants at case start

**Files:**
- Modify: `runtime/src/main/java/io/casehub/engine/internal/engine/CaseHubReactor.java`
- Modify: `runtime/pom.xml` (add acl-inmem test dependency)
- Modify: `runtime/src/test/resources/application.properties` (add index-dependency for acl-inmem)
- Test: `runtime/src/test/java/io/casehub/engine/AuthorizationGrantIntegrationTest.java`

**Interfaces:**
- Consumes: `CaseDefinition.getAuthorization()` (from Task 1), `AccessControlProvider.grantBatch(Collection<AclEntryRequest>)`, `AclEntryRequest(actorId, resourceId, action, expiresAt)`, `AclResourceType.CASE` = `"case"`, `CurrentPrincipal.actorId()`
- Produces: ACL grants created when a case with `authorization` block is started

- [ ] **Step 1: Add acl-inmem test dependency to runtime/pom.xml**

Add to `runtime/pom.xml` test dependencies section:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-acl-inmem</artifactId>
    <scope>test</scope>
</dependency>
```

The version is managed by the parent POM. `InMemoryAccessControlProvider` is `@Alternative @Priority(10)` — it automatically displaces the `NoOpAccessControlProvider @DefaultBean` from `casehub-platform`.

- [ ] **Step 2: Add index-dependency for acl-inmem in application.properties**

Add to `runtime/src/test/resources/application.properties`:

```properties
# acl-inmem provides InMemoryAccessControlProvider (@Alternative @Priority(10))
# for ACL grant verification in integration tests.
quarkus.index-dependency.acl-inmem.group-id=io.casehub
quarkus.index-dependency.acl-inmem.artifact-id=casehub-platform-acl-inmem
```

- [ ] **Step 3: Write failing integration test**

Create `runtime/src/test/java/io/casehub/engine/AuthorizationGrantIntegrationTest.java`:

```java
package io.casehub.engine;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;

import io.casehub.api.engine.CaseHub;
import io.casehub.api.engine.CaseHubRuntime;
import io.casehub.api.model.Binding;
import io.casehub.api.model.CaseDefinition;
import io.casehub.api.model.CaseStatus;
import io.casehub.api.model.ContextChangeTrigger;
import io.casehub.engine.common.spi.cache.CaseInstanceCache;
import io.casehub.platform.api.acl.AccessControlProvider;
import io.casehub.platform.api.acl.AclAction;
import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.worker.api.Capability;
import io.casehub.worker.api.Worker;
import io.casehub.worker.api.WorkerResult;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;

@QuarkusTest
class AuthorizationGrantIntegrationTest {

    @Inject AuthorizationCaseHubBean caseHubBean;
    @Inject CaseHubRuntime runtime;
    @Inject AccessControlProvider accessControl;
    @Inject CurrentPrincipal currentPrincipal;
    @Inject CaseInstanceCache caseInstanceCache;

    @Test
    void authorizationGrantsCreatedOnCaseStart() {
        UUID caseId = caseHubBean.startCase(Map.of("status", "pending"));

        // Verify group-based grants from the authorization block
        assertThat(accessControl.canAccess("group:case-manager", "case:" + caseId, AclAction.READ))
            .as("case-manager group should have READ grant")
            .isTrue();
        assertThat(accessControl.canAccess("group:auditor", "case:" + caseId, AclAction.READ))
            .as("auditor group should have READ grant")
            .isTrue();
        assertThat(accessControl.canAccess("group:case-manager", "case:" + caseId, AclAction.WRITE))
            .as("case-manager group should have WRITE grant")
            .isTrue();
        assertThat(accessControl.canAccess("group:supervisor", "case:" + caseId, AclAction.ADMIN))
            .as("supervisor group should have ADMIN grant")
            .isTrue();
        assertThat(accessControl.canAccess("group:case-worker", "case:" + caseId, AclAction.CLAIM))
            .as("case-worker group should have CLAIM grant")
            .isTrue();

        // Verify case creator receives automatic ADMIN grant
        assertThat(accessControl.canAccess(currentPrincipal.actorId(), "case:" + caseId, AclAction.ADMIN))
            .as("case creator should have automatic ADMIN grant")
            .isTrue();
    }

    @Test
    void noGrantsCreatedWhenAuthorizationAbsent() {
        UUID caseId = noAuthCaseHubBean.startCase(Map.of("status", "pending"));

        // With NoOp/InMemory and no grants, canAccess should return false for specific actors
        assertThat(accessControl.canAccess("group:anyone", "case:" + caseId, AclAction.READ))
            .as("no grants should exist when authorization is absent")
            .isFalse();
    }

    @Inject NoAuthCaseHubBean noAuthCaseHubBean;

    @ApplicationScoped
    static class AuthorizationCaseHubBean extends CaseHub {
        @Override
        protected CaseDefinition buildDefinition() {
            return CaseDefinition.builder()
                .namespace("acl-test").name("auth-case").version("1.0")
                .authorization(AclAction.READ, List.of("case-manager", "auditor"))
                .authorization(AclAction.WRITE, List.of("case-manager"))
                .authorization(AclAction.ADMIN, List.of("supervisor"))
                .authorization(AclAction.CLAIM, List.of("case-worker"))
                .build();
        }
    }

    @ApplicationScoped
    static class NoAuthCaseHubBean extends CaseHub {
        @Override
        protected CaseDefinition buildDefinition() {
            return CaseDefinition.builder()
                .namespace("acl-test").name("no-auth-case").version("1.0")
                .build();
        }
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `mvn test -pl runtime -Dtest="AuthorizationGrantIntegrationTest#authorizationGrantsCreatedOnCaseStart" -f /Users/mdproctor/claude/casehub/engine/pom.xml --batch-mode -q`
Expected: FAIL — grants not created (canAccess returns false)

- [ ] **Step 5: Implement grant wiring in CaseHubReactor.startCaseInternal()**

In `CaseHubReactor`, add field:

```java
@Inject AccessControlProvider accessControlProvider;
```

Imports:
```java
import io.casehub.platform.api.acl.AccessControlProvider;
import io.casehub.platform.api.acl.AclAction;
import io.casehub.platform.api.acl.AclEntryRequest;
import io.casehub.platform.api.acl.AclResourceType;
```

In `startCaseInternal()`, after `buildInstance()` returns and before `caseStartedHandler.onCaseStarted()`, add:

```java
// Wire ACL grants from the authorization block — before bindings fire
String resourceId = AclResourceType.CASE + ":" + instance.getUuid();
Map<AclAction, List<String>> authorization = definition.getAuthorization();
if (authorization != null && !authorization.isEmpty()) {
    List<AclEntryRequest> requests = new ArrayList<>();
    for (var entry : authorization.entrySet()) {
        AclAction action = entry.getKey();
        for (String group : entry.getValue()) {
            requests.add(new AclEntryRequest("group:" + group, resourceId, action, null));
        }
    }
    // Case creator always receives ADMIN
    requests.add(new AclEntryRequest(currentPrincipal.actorId(), resourceId, AclAction.ADMIN, null));
    accessControlProvider.grantBatch(requests);
} else {
    // No authorization block — still grant creator ADMIN when ACL is installed
    // (NoOp provider ignores this; real providers record it)
}
```

Wait — re-reading the spec: "The initiating principal receives ADMIN grant automatically (case creator is always admin of their case)". This should ALWAYS happen, not just when the authorization block is present. But: if `authorization` is absent, the NoOp default applies and no grants are created at all. Granting creator ADMIN when there's no authorization block would create grants that serve no purpose (no other ACL enforcement is active). Let me re-read...

The spec says: "If `authorization` is absent, no grants are created." And separately: "The initiating principal receives ADMIN grant automatically." The second rule applies only in the context of the authorization block. When authorization is absent, the entire ACL path is inert.

So the creator ADMIN grant should only fire when `authorization` is present:

```java
String resourceId = AclResourceType.CASE + ":" + instance.getUuid();
Map<AclAction, List<String>> authorization = definition.getAuthorization();
if (authorization != null && !authorization.isEmpty()) {
    List<AclEntryRequest> requests = new ArrayList<>();
    for (var entry : authorization.entrySet()) {
        AclAction action = entry.getKey();
        for (String group : entry.getValue()) {
            requests.add(new AclEntryRequest("group:" + group, resourceId, action, null));
        }
    }
    requests.add(new AclEntryRequest(currentPrincipal.actorId(), resourceId, AclAction.ADMIN, null));
    accessControlProvider.grantBatch(requests);
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn test -pl runtime -Dtest="AuthorizationGrantIntegrationTest" -f /Users/mdproctor/claude/casehub/engine/pom.xml --batch-mode -q`
Expected: both tests PASS

- [ ] **Step 7: Run full runtime test suite to verify no regressions**

Run: `mvn test -pl runtime -f /Users/mdproctor/claude/casehub/engine/pom.xml --batch-mode`
Expected: all tests PASS — `InMemoryAccessControlProvider` displaces `NoOpAccessControlProvider` but no existing code calls `canAccess()`, so behavior is unchanged

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/engine add runtime/pom.xml runtime/src/test/resources/application.properties runtime/src/main/java/io/casehub/engine/internal/engine/CaseHubReactor.java runtime/src/test/java/io/casehub/engine/AuthorizationGrantIntegrationTest.java
git -C /Users/mdproctor/claude/casehub/engine commit -m "feat(#219): wire authorization grants in CaseHubReactor at case start"
```

---

### Task 5: CLAUDE.md — document authorization field on CaseDefinition

**Files:**
- Modify: `CLAUDE.md` (engine repo)

**Interfaces:**
- Consumes: nothing
- Produces: documentation of the authorization field

- [ ] **Step 1: Update CLAUDE.md**

In the engine `CLAUDE.md`, after the `CaseDefinition` gains section for `cognitiveDemands`, add:

`CaseDefinition` gains `authorization` (`Map<AclAction, List<String>>`, nullable). Declares which groups receive ACL grants when a case is started. `CaseHubReactor.startCaseInternal()` calls `AccessControlProvider.grantBatch()` before `onCaseStarted()`. Case creator receives automatic ADMIN. If absent, no grants are created (NoOp default). YAML: `authorization:` block under `spec:` with keys `read`, `write`, `admin`, `claim`. Refs platform#219.

- [ ] **Step 2: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/engine add CLAUDE.md
git -C /Users/mdproctor/claude/casehub/engine commit -m "docs(#219): document authorization field on CaseDefinition in CLAUDE.md"
```
