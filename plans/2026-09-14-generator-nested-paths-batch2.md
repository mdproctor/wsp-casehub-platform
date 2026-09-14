# Generator Nested Paths + Batch 2 Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #296 — generator: nested resource paths + enum param detection for batch 2 endpoints
**Issue group:** #296, #297

**Goal:** Enhance the graphql-generator APT with @RestPath support and simple type detection, then migrate the remaining 5 hand-written REST endpoints to generated @McpDomain approach.

**Architecture:** The generator APT scans Jandex indexes from dependency JARs for @McpDomain interfaces and produces REST + GraphQL source at compile time. New @RestPath annotation enables custom path segments. SPI interfaces live in dependency modules (platform-api, preferences-editor-core) where the APT can discover them via Jandex — NOT in the same module as the APT. Service implementations live in the Quarkus module and carry authorization/validation.

**Tech Stack:** Java 21, Maven, Jandex, annotation processing (javax.annotation.processing), Quarkus, JAX-RS

**Spec deviation — D7 eliminated:** The spec proposes RoundEnvironment scanning (D7) to let SPIs live in the same module as the APT. Investigation revealed batch 1 SPIs (`DeliveryChannelApi`, `DigestApi`) actually live in `platform-api/`, not `notifications/`. The APT finds them via Jandex indexes from dependency JARs. Batch 2 follows this pattern: ACL and notification SPIs → `platform-api/`, preference SPIs → `preferences-editor-core/`. D7 is unnecessary and is dropped from this plan.

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports. Pure Java only.
- All generated REST resources get `@Path("/api/{domain}")`, `@Produces(APPLICATION_JSON)`, `@RunOnVirtualThread`, `@ApplicationScoped`.
- Pre-release — path and verb changes acceptable, no external consumers.
- Every commit references an issue (`Refs #296` or `Refs #297`).

---

## Batch 1: Generator Enhancements (#296)

### Task 1: @RestPath annotation + simple type detection + tests

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/mcp/RestPath.java`
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java`
- Test: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java`

**Interfaces:**
- Produces: `@RestPath` annotation, `isSimpleType(String, IndexView)` method, `OperationInfo.restPathOverride` field

- [ ] **Step 1: Write @RestPath annotation test**

Add test to `GraphQLResolverProcessorTest`:

```java
@Test
void restPathOverride_usesLiteralValue() {
    // When @RestPath("grants") is present, path should be /grants not /grant
    // This test validates the static helper behavior
    assertThat(GraphQLResolverProcessor.resolveRestPath("grants", "grant")).isEqualTo("grants");
}

@Test
void restPathOverride_absent_fallsBackToKebab() {
    assertThat(GraphQLResolverProcessor.resolveRestPath(null, "grantBatch")).isEqualTo("grant-batch");
}

@Test
void restPathOverride_nestedSegments() {
    assertThat(GraphQLResolverProcessor.resolveRestPath("grants/batch", "grantBatch")).isEqualTo("grants/batch");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl graphql-generator`
Expected: FAIL — `resolveRestPath` method does not exist

- [ ] **Step 3: Create @RestPath annotation**

Create `platform-api/src/main/java/io/casehub/platform/api/mcp/RestPath.java`:

```java
package io.casehub.platform.api.mcp;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface RestPath {
    String value();
}
```

- [ ] **Step 4: Add resolveRestPath helper + @RestPath support to generator**

In `GraphQLResolverProcessor.java`:

Add DotName constant (after line 45):
```java
private static final DotName REST_PATH_ANN = DotName.createSimple("io.casehub.platform.api.mcp.RestPath");
```

Add `restPathOverride` field to `OperationInfo` (replace existing constructor):
```java
static class OperationInfo {
    final MethodInfo method;
    final ClassInfo declaringClass;
    final OperationType type;
    final String description;
    final String restMethodOverride;
    final String restPathOverride;
    OperationInfo(MethodInfo method, ClassInfo declaringClass, OperationType type, String description, String restMethodOverride, String restPathOverride) {
        this.method = method;
        this.declaringClass = declaringClass;
        this.type = type;
        this.description = description;
        this.restMethodOverride = restMethodOverride;
        this.restPathOverride = restPathOverride;
    }
}
```

In `scanAnnotatedInterfaces()`, read `@RestPath` and pass to `OperationInfo` (replace lines 181-186):
```java
String restMethodOverride = null;
AnnotationInstance restMethodAnn = method.annotation(REST_METHOD_ANN);
if (restMethodAnn != null && restMethodAnn.value() != null) {
    restMethodOverride = restMethodAnn.value().asEnum();
}
String restPathOverride = null;
AnnotationInstance restPathAnn = method.annotation(REST_PATH_ANN);
if (restPathAnn != null && restPathAnn.value() != null) {
    restPathOverride = restPathAnn.value().asString();
}
ops.operations.add(new OperationInfo(method, classInfo, opType, desc, restMethodOverride, restPathOverride));
```

Add static helper:
```java
static String resolveRestPath(String restPathOverride, String methodName) {
    if (restPathOverride != null) {
        return restPathOverride;
    }
    return toKebabCase(methodName);
}
```

In `generateRestMethod()`, replace line 406:
```java
pathSuffix.append("/").append(toKebabCase(method.name()));
```
with:
```java
pathSuffix.append("/").append(resolveRestPath(op.restPathOverride, method.name()));
```

- [ ] **Step 5: Run tests to verify @RestPath tests pass**

Run: `mvn --batch-mode test -pl graphql-generator`
Expected: PASS — all 3 new tests + existing tests pass

- [ ] **Step 6: Write simple type detection tests**

Add to `GraphQLResolverProcessorTest`:

```java
@Test
void isSimpleType_enumViaJandex() throws IOException {
    var indexer = new org.jboss.jandex.Indexer();
    indexer.indexClass(io.casehub.platform.api.acl.AclAction.class);
    var index = indexer.complete();
    assertThat(GraphQLResolverProcessor.isSimpleType("io.casehub.platform.api.acl.AclAction", index)).isTrue();
}

@Test
void isSimpleType_fromStringViaJandex() throws IOException {
    var indexer = new org.jboss.jandex.Indexer();
    indexer.indexClass(io.casehub.platform.api.acl.ResourceId.class);
    var index = indexer.complete();
    assertThat(GraphQLResolverProcessor.isSimpleType("io.casehub.platform.api.acl.ResourceId", index)).isTrue();
}

@Test
void isSimpleType_complexTypeWithJandex() throws IOException {
    var indexer = new org.jboss.jandex.Indexer();
    indexer.indexClass(io.casehub.platform.api.callback.CallbackRegistrationRequest.class);
    var index = indexer.complete();
    assertThat(GraphQLResolverProcessor.isSimpleType("io.casehub.platform.api.callback.CallbackRegistrationRequest", index)).isFalse();
}

@Test
void isSimpleType_staticFallback_stillWorks() {
    assertThat(GraphQLResolverProcessor.isSimpleType("java.lang.String", null)).isTrue();
    assertThat(GraphQLResolverProcessor.isSimpleType("java.time.Instant", null)).isTrue();
}
```

- [ ] **Step 7: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl graphql-generator`
Expected: FAIL — `isSimpleType` method signature mismatch (no `IndexView` overload)

- [ ] **Step 8: Implement simple type detection**

In `GraphQLResolverProcessor.java`, replace the existing `isSimpleType` method (lines 610-614) with:

```java
static boolean isSimpleType(String fqcn) {
    return isSimpleType(fqcn, null);
}

static boolean isSimpleType(String fqcn, IndexView index) {
    if (SIMPLE_TYPES.contains(fqcn)) return true;
    if (fqcn.startsWith("java.time.")) return true;
    if (index != null) {
        ClassInfo ci = index.getClassByName(fqcn);
        if (ci != null) {
            if (ci.isEnum()) return true;
            if (hasStaticStringMethod(ci, "fromString")) return true;
            if (!ci.isEnum() && hasStaticStringMethod(ci, "valueOf")) return true;
        }
    }
    return false;
}

private static boolean hasStaticStringMethod(ClassInfo ci, String methodName) {
    DotName stringType = DotName.createSimple("java.lang.String");
    for (MethodInfo m : ci.methods()) {
        if (m.name().equals(methodName)
                && java.lang.reflect.Modifier.isStatic(m.flags())
                && m.parameterTypes().size() == 1
                && m.parameterTypes().get(0).name().equals(stringType)) {
            return true;
        }
    }
    return false;
}
```

Thread `IndexView` through the call chain. Store `index` as a field set in `process()`:

Add field:
```java
private IndexView jandexIndex;
```

In `process()`, after `loadCombinedIndex()`:
```java
this.jandexIndex = index;
```

In `generateRestMethod()` line 386, change:
```java
&& !isSimpleType(method.parameterTypes().get(i).name().toString()))
```
to:
```java
&& !isSimpleType(method.parameterTypes().get(i).name().toString(), jandexIndex))
```

- [ ] **Step 9: Run tests to verify all pass**

Run: `mvn --batch-mode test -pl graphql-generator`
Expected: PASS — all new + existing tests pass

- [ ] **Step 10: Build full project to verify no regressions**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile, all tests pass

- [ ] **Step 11: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/mcp/RestPath.java graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java
git commit -m "$(cat <<'EOF'
feat(#296): @RestPath annotation + simple type detection via Jandex

Add @RestPath annotation to platform-api for custom REST path segments
on SPI methods, enabling nested paths like /grants/batch.

Enhance isSimpleType() to detect enums, fromString(String), and
valueOf(String) types via Jandex IndexView for correct @QueryParam
classification.

Refs #296

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Batch 2: ACL Migration (#297)

### Task 2: AclApi SPI + AclService + migrate tests

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/acl/AclApi.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/acl/AccessCheckResponse.java` (move from acl-admin)
- Create: `acl-admin/src/main/java/io/casehub/platform/acl/admin/AclService.java`
- Modify: `acl-admin/pom.xml` — add graphql-generator APT config
- Modify: `acl-admin/src/test/java/io/casehub/platform/acl/admin/AclResourceTest.java` — update paths + verbs
- Delete: `acl-admin/src/main/java/io/casehub/platform/acl/admin/AclResource.java` (use `ide_refactor_safe_delete`)
- Delete: `acl-admin/src/main/java/io/casehub/platform/acl/admin/AclEntryInput.java` (use `ide_refactor_safe_delete`)
- Delete: `acl-admin/src/main/java/io/casehub/platform/acl/admin/ParentInput.java` (use `ide_refactor_safe_delete`)

**Interfaces:**
- Consumes: `@RestPath`, `@RestMethod`, `@PathParam` from platform-api; `isSimpleType` with IndexView from Task 1
- Produces: `AclApi` SPI (`@McpDomain("acl")`), `AclService` implementation

- [ ] **Step 1: Move AccessCheckResponse to platform-api**

Use `ide_move_file` to move `acl-admin/src/main/java/io/casehub/platform/acl/admin/AccessCheckResponse.java` → `platform-api/src/main/java/io/casehub/platform/api/acl/AccessCheckResponse.java`.

Update the package declaration to `io.casehub.platform.api.acl`.

- [ ] **Step 2: Create AclApi SPI in platform-api**

Create `platform-api/src/main/java/io/casehub/platform/api/acl/AclApi.java`:

```java
package io.casehub.platform.api.acl;

import io.casehub.platform.api.mcp.HttpMethod;
import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PathParam;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.platform.api.mcp.RestMethod;
import io.casehub.platform.api.mcp.RestPath;

import java.util.List;

@McpDomain("acl")
public interface AclApi {

    @PlatformMutation("Grant access to a resource")
    @RestPath("grants")
    void grant(AclEntryRequest input);

    @PlatformMutation("Grant access in batch")
    @RestPath("grants/batch")
    void grantBatch(List<AclEntryRequest> inputs);

    @PlatformMutation("Revoke a grant")
    @RestMethod(HttpMethod.DELETE)
    @RestPath("grants")
    void revoke(String actorId, ResourceId resourceId, AclAction action);

    @PlatformMutation("Revoke grants in batch")
    @RestPath("grants/revoke-batch")
    void revokeBatch(List<AclEntryRequest> inputs);

    @PlatformMutation("Revoke all grants for an actor on a resource")
    @RestMethod(HttpMethod.DELETE)
    @RestPath("grants/all")
    void revokeAll(String actorId, ResourceId resourceId);

    @PlatformMutation("Add a deny entry")
    @RestPath("denies")
    void deny(AclEntryRequest input);

    @PlatformMutation("Add deny entries in batch")
    @RestPath("denies/batch")
    void denyBatch(List<AclEntryRequest> inputs);

    @PlatformMutation("Remove a deny entry")
    @RestMethod(HttpMethod.DELETE)
    @RestPath("denies")
    void removeDeny(String actorId, ResourceId resourceId, AclAction action);

    @PlatformMutation("Remove deny entries in batch")
    @RestPath("denies/revoke-batch")
    void removeDenyBatch(List<AclEntryRequest> inputs);

    @PlatformMutation("Register a parent resource relationship")
    @RestPath("parents")
    void registerParent(ResourceId childResourceId, ResourceId parentResourceId);

    @PlatformQuery("Check if an actor has access to a resource")
    @RestPath("check")
    AccessCheckResponse check(String actorId, ResourceId resourceId, AclAction action);

    @PlatformQuery("List accessible resources for an actor")
    @RestPath("accessible")
    AclPage accessible(String actorId, String resourceType, AclAction action, String cursor, Integer limit);
}
```

- [ ] **Step 3: Create AclService implementation**

Create `acl-admin/src/main/java/io/casehub/platform/acl/admin/AclService.java`:

```java
package io.casehub.platform.acl.admin;

import io.casehub.platform.api.acl.AccessCheckResponse;
import io.casehub.platform.api.acl.AccessControlProvider;
import io.casehub.platform.api.acl.AclAction;
import io.casehub.platform.api.acl.AclApi;
import io.casehub.platform.api.acl.AclEntryRequest;
import io.casehub.platform.api.acl.AclPage;
import io.casehub.platform.api.acl.AclQuery;
import io.casehub.platform.api.acl.ResourceId;
import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.identity.PlatformRoles;
import jakarta.annotation.security.RolesAllowed;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.BadRequestException;
import jakarta.ws.rs.ForbiddenException;

import java.util.List;

@ApplicationScoped
public class AclService implements AclApi {

    private final AccessControlProvider acl;
    private final CurrentPrincipal principal;

    @Inject
    public AclService(AccessControlProvider acl, CurrentPrincipal principal) {
        this.acl = acl;
        this.principal = principal;
    }

    @Override
    @RolesAllowed(PlatformRoles.ADMIN)
    public void grant(AclEntryRequest input) {
        acl.grant(input.actorId(), input.resourceId(), input.action(), input.expiresAt());
    }

    @Override
    @RolesAllowed(PlatformRoles.ADMIN)
    public void grantBatch(List<AclEntryRequest> inputs) {
        acl.grantBatch(inputs);
    }

    @Override
    @RolesAllowed(PlatformRoles.ADMIN)
    public void revoke(String actorId, ResourceId resourceId, AclAction action) {
        requireNonNull(actorId, resourceId, action);
        acl.revoke(actorId, resourceId, action);
    }

    @Override
    @RolesAllowed(PlatformRoles.ADMIN)
    public void revokeBatch(List<AclEntryRequest> inputs) {
        acl.revokeBatch(inputs);
    }

    @Override
    @RolesAllowed(PlatformRoles.ADMIN)
    public void revokeAll(String actorId, ResourceId resourceId) {
        requireNonNull(actorId, resourceId);
        acl.revokeAll(actorId, resourceId);
    }

    @Override
    @RolesAllowed(PlatformRoles.ADMIN)
    public void deny(AclEntryRequest input) {
        acl.deny(input.actorId(), input.resourceId(), input.action(), input.expiresAt());
    }

    @Override
    @RolesAllowed(PlatformRoles.ADMIN)
    public void denyBatch(List<AclEntryRequest> inputs) {
        acl.denyBatch(inputs);
    }

    @Override
    @RolesAllowed(PlatformRoles.ADMIN)
    public void removeDeny(String actorId, ResourceId resourceId, AclAction action) {
        requireNonNull(actorId, resourceId, action);
        acl.removeDeny(actorId, resourceId, action);
    }

    @Override
    @RolesAllowed(PlatformRoles.ADMIN)
    public void removeDenyBatch(List<AclEntryRequest> inputs) {
        acl.removeDenyBatch(inputs);
    }

    @Override
    @RolesAllowed(PlatformRoles.ADMIN)
    public void registerParent(ResourceId childResourceId, ResourceId parentResourceId) {
        acl.registerParent(childResourceId, parentResourceId);
    }

    @Override
    public AccessCheckResponse check(String actorId, ResourceId resourceId, AclAction action) {
        requireNonNull(actorId, resourceId, action);
        requireAdminOrSelf(actorId);
        return new AccessCheckResponse(acl.canAccess(actorId, resourceId, action));
    }

    @Override
    public AclPage accessible(String actorId, String resourceType, AclAction action, String cursor, Integer limit) {
        requireNonNull(actorId, resourceType, action);
        requireAdminOrSelf(actorId);
        return acl.accessibleResources(new AclQuery(actorId, resourceType, action, cursor, limit != null ? limit : 100));
    }

    private void requireAdminOrSelf(String actorId) {
        if (!principal.groups().contains(PlatformRoles.ADMIN) && !principal.actorId().equals(actorId)) {
            throw new ForbiddenException("Access denied");
        }
    }

    private static void requireNonNull(Object... args) {
        for (Object arg : args) {
            if (arg == null) throw new BadRequestException("Required parameter is null");
        }
    }
}
```

- [ ] **Step 4: Add graphql-generator APT config to acl-admin/pom.xml**

Add to the `maven-compiler-plugin` configuration in `acl-admin/pom.xml`:

```xml
<configuration>
    <annotationProcessorPaths>
        <path>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-graphql-generator</artifactId>
            <version>${project.version}</version>
        </path>
        <path>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </path>
    </annotationProcessorPaths>
    <compilerArgs>
        <arg>-AgenerateGraphQL=false</arg>
        <arg>-AdomainFilter=acl</arg>
    </compilerArgs>
</configuration>
```

- [ ] **Step 5: Update AclResourceTest paths and verbs**

Update `acl-admin/src/test/java/io/casehub/platform/acl/admin/AclResourceTest.java`:

Path changes:
- `/acl/grants` → `/api/acl/grants`
- `/acl/grants/batch` → `/api/acl/grants/batch` (POST grant batch stays POST)
- `/acl/grants/all` → `/api/acl/grants/all`
- `/acl/denies` → `/api/acl/denies`
- `/acl/denies/batch` → `/api/acl/denies/batch`
- `/acl/parents` → `/api/acl/parents`
- `/acl/check` → `/api/acl/check`
- `/acl/accessible` → `/api/acl/accessible`

Verb changes:
- `revokeBatch`: `.when().delete(...)` → `.when().post("/api/acl/grants/revoke-batch")`
- `removeDenyBatch`: `.when().delete(...)` → `.when().post("/api/acl/denies/revoke-batch")`

Request body changes:
- `grant`/`deny` bodies: change from `AclEntryInput` fields (`actorId`, `resourceId`, `action`) to `AclEntryRequest` fields (same names)
- `registerParent` body: change from `ParentInput` (`childResourceId`, `parentResourceId`) to individual query params or adjust the SPI

- [ ] **Step 6: Delete old files**

Use `ide_refactor_safe_delete` on:
- `acl-admin/src/main/java/io/casehub/platform/acl/admin/AclResource.java`
- `acl-admin/src/main/java/io/casehub/platform/acl/admin/AclEntryInput.java`
- `acl-admin/src/main/java/io/casehub/platform/acl/admin/ParentInput.java`

Delete the old `AccessCheckResponse.java` from `acl-admin/` (already moved to platform-api).

- [ ] **Step 7: Build and test**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — generated `GeneratedAclResource` replaces hand-written `AclResource`, all tests pass on new paths

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(#297): migrate AclResource to generated @McpDomain approach

Create AclApi SPI in platform-api with @RestPath nested paths.
AclService carries @RolesAllowed on mutations and imperative
admin-or-self guard on queries. Use AclEntryRequest directly
(drop AclEntryInput/ParentInput DTOs). Batch deletes changed
from DELETE to POST (non-standard HTTP body on DELETE).

Closes #296
Refs #297

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Batch 3: Preferences Migration (#297)

### Task 3: PreferenceApi + PreferenceSchemaApi + services + migrate tests

**Files:**
- Create: `preferences-editor-core/src/main/java/io/casehub/platform/preferences/editor/PreferenceApi.java`
- Create: `preferences-editor-core/src/main/java/io/casehub/platform/preferences/editor/PreferenceSchemaApi.java`
- Create: `preferences-editor/src/main/java/io/casehub/platform/preferences/editor/quarkus/PreferenceService.java`
- Create: `preferences-editor/src/main/java/io/casehub/platform/preferences/editor/quarkus/PreferenceSchemaService.java`
- Modify: `preferences-editor/src/main/java/io/casehub/platform/preferences/editor/PreferenceSchemaResource.java` — add @McpDomain
- Modify: `preferences-editor/pom.xml` — add graphql-generator APT config
- Delete: `preferences-editor/src/main/java/io/casehub/platform/preferences/editor/PreferenceResource.java` (use `ide_refactor_safe_delete`)
- Test: update existing tests for new paths

**Interfaces:**
- Consumes: `@RestPath`, `@RestMethod`, `@PathParam` from platform-api; PreferenceInput, PreferenceValidator, ResolvedPreferencesResponse from preferences-editor-core
- Produces: `PreferenceApi` SPI, `PreferenceSchemaApi` SPI, `PreferenceService`, `PreferenceSchemaService`

- [ ] **Step 1: Create PreferenceApi SPI in preferences-editor-core**

Create `preferences-editor-core/src/main/java/io/casehub/platform/preferences/editor/PreferenceApi.java`:

```java
package io.casehub.platform.preferences.editor;

import io.casehub.platform.api.mcp.HttpMethod;
import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.platform.api.mcp.RestMethod;
import io.casehub.platform.api.mcp.RestPath;
import io.casehub.platform.api.preferences.PreferenceRecord;

import java.util.List;

@McpDomain("preferences")
public interface PreferenceApi {

    @PlatformMutation("Set a preference value")
    @RestMethod(HttpMethod.PUT)
    void set(String scope, PreferenceInput input);

    @PlatformMutation("Delete a single preference")
    @RestMethod(HttpMethod.DELETE)
    @RestPath("delete")
    void delete(String scope, String namespace, String name, String subKey);

    @PlatformMutation("Delete all preferences in a namespace")
    @RestMethod(HttpMethod.DELETE)
    @RestPath("delete-namespace")
    void deleteNamespace(String scope, String namespace);

    @PlatformQuery("List raw preference records")
    List<PreferenceRecord> list(String scope);

    @PlatformQuery("Get resolved preferences for a scope")
    ResolvedPreferencesResponse resolved(String scope);
}
```

- [ ] **Step 2: Create PreferenceSchemaApi SPI**

Create `preferences-editor-core/src/main/java/io/casehub/platform/preferences/editor/PreferenceSchemaApi.java`:

```java
package io.casehub.platform.preferences.editor;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.platform.api.preferences.PreferenceSchemaDescriptor;

import java.util.List;

@McpDomain("preference-schemas")
public interface PreferenceSchemaApi {

    @PlatformQuery("List preference schema descriptors")
    List<PreferenceSchemaDescriptor> schema(String namespace);
}
```

- [ ] **Step 3: Create PreferenceService**

Create `preferences-editor/src/main/java/io/casehub/platform/preferences/editor/quarkus/PreferenceService.java`:

```java
package io.casehub.platform.preferences.editor.quarkus;

import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.preferences.PreferenceProvider;
import io.casehub.platform.api.preferences.PreferenceQuery;
import io.casehub.platform.api.preferences.PreferenceRecord;
import io.casehub.platform.api.preferences.PreferenceSchemaDescriptor;
import io.casehub.platform.api.preferences.PreferenceSchemaRegistry;
import io.casehub.platform.api.preferences.PreferenceStore;
import io.casehub.platform.api.preferences.Preferences;
import io.casehub.platform.api.preferences.SettingsScope;
import io.casehub.platform.preferences.editor.PreferenceApi;
import io.casehub.platform.preferences.editor.PreferenceInput;
import io.casehub.platform.preferences.editor.PreferenceValidator;
import io.casehub.platform.preferences.editor.ResolvedPreferencesResponse;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.BadRequestException;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

@ApplicationScoped
public class PreferenceService implements PreferenceApi {

    private final PreferenceStore store;
    private final PreferenceProvider provider;
    private final PreferenceSchemaRegistry schemaRegistry;
    private final PreferenceValidator validator;
    private final CurrentPrincipal principal;

    @Inject
    public PreferenceService(PreferenceStore store, PreferenceProvider provider,
                             PreferenceSchemaRegistry schemaRegistry, PreferenceValidator validator,
                             CurrentPrincipal principal) {
        this.store = store;
        this.provider = provider;
        this.schemaRegistry = schemaRegistry;
        this.validator = validator;
        this.principal = principal;
    }

    @Override
    public void set(String scope, PreferenceInput input) {
        Path scopePath = parseScopePath(scope);
        String qualifiedName = input.namespace() + "." + input.name();
        Optional<PreferenceSchemaDescriptor> descriptor = schemaRegistry.resolve(qualifiedName);
        if (descriptor.isPresent()) {
            List<String> violations = validator.validate(descriptor.get(), input.value());
            if (!violations.isEmpty()) {
                throw new BadRequestException("Validation failed: " + String.join(", ", violations));
            }
        }
        store.set(principal.tenancyId(), scopePath, input.namespace(), input.name(), input.subKey(), input.value());
    }

    @Override
    public void delete(String scope, String namespace, String name, String subKey) {
        if (name == null || name.isBlank()) throw new BadRequestException("name is required for single-delete");
        if (namespace == null || namespace.isBlank()) throw new BadRequestException("namespace is required for single-delete");
        Path scopePath = parseScopePath(scope);
        store.delete(principal.tenancyId(), scopePath, namespace, name, subKey != null ? subKey : "");
    }

    @Override
    public void deleteNamespace(String scope, String namespace) {
        if (namespace == null || namespace.isBlank()) throw new BadRequestException("namespace is required");
        Path scopePath = parseScopePath(scope);
        store.deleteAll(principal.tenancyId(), scopePath, namespace);
    }

    @Override
    public List<PreferenceRecord> list(String scope) {
        Path scopePath = (scope == null || scope.isBlank()) ? null : parseScopePath(scope);
        return store.list(new PreferenceQuery(principal.tenancyId(), scopePath, null));
    }

    @Override
    public ResolvedPreferencesResponse resolved(String scope) {
        Path scopePath = parseScopePath(scope);
        Preferences resolved = provider.resolve(SettingsScope.of(principal.tenancyId(), scopePath));
        Map<String, String> values = new HashMap<>();
        resolved.asMap().forEach((k, v) -> values.put(k, String.valueOf(v)));
        return new ResolvedPreferencesResponse(scope != null ? scope : "", values);
    }

    private static Path parseScopePath(String scopeParam) {
        if (scopeParam == null || scopeParam.isBlank()) return Path.root();
        return Path.of(scopeParam.split("/"));
    }
}
```

- [ ] **Step 4: Create PreferenceSchemaService**

Create `preferences-editor/src/main/java/io/casehub/platform/preferences/editor/quarkus/PreferenceSchemaService.java`:

```java
package io.casehub.platform.preferences.editor.quarkus;

import io.casehub.platform.api.preferences.PreferenceSchemaDescriptor;
import io.casehub.platform.api.preferences.PreferenceSchemaRegistry;
import io.casehub.platform.preferences.editor.PreferenceSchemaApi;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.util.Comparator;
import java.util.List;

@ApplicationScoped
public class PreferenceSchemaService implements PreferenceSchemaApi {

    private final PreferenceSchemaRegistry registry;

    @Inject
    public PreferenceSchemaService(PreferenceSchemaRegistry registry) {
        this.registry = registry;
    }

    @Override
    public List<PreferenceSchemaDescriptor> schema(String namespace) {
        return registry.discover().stream()
                .filter(d -> namespace == null || namespace.isBlank() || d.namespace().equals(namespace))
                .sorted(Comparator.comparing(PreferenceSchemaDescriptor::qualifiedName))
                .toList();
    }
}
```

- [ ] **Step 5: Add @McpDomain to PreferenceSchemaResource for skip detection**

Add `@McpDomain("preference-schemas")` to the existing `PreferenceSchemaResource` class declaration. Add the import `io.casehub.platform.api.mcp.McpDomain`.

- [ ] **Step 6: Add graphql-generator APT config to preferences-editor/pom.xml**

```xml
<configuration>
    <annotationProcessorPaths>
        <path>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-graphql-generator</artifactId>
            <version>${project.version}</version>
        </path>
        <path>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-preferences-editor-core</artifactId>
            <version>${project.version}</version>
        </path>
    </annotationProcessorPaths>
    <compilerArgs>
        <arg>-AgenerateGraphQL=false</arg>
        <arg>-AdomainFilter=preferences,preference-schemas</arg>
    </compilerArgs>
</configuration>
```

- [ ] **Step 7: Delete PreferenceResource.java**

Use `ide_refactor_safe_delete` on `preferences-editor/src/main/java/io/casehub/platform/preferences/editor/PreferenceResource.java`.

- [ ] **Step 8: Update tests for new paths**

Update tests to use new paths:
- `/preferences` PUT → `/api/preferences/set` PUT
- `/preferences` DELETE → `/api/preferences/delete` DELETE
- `/preferences/by-namespace` DELETE → `/api/preferences/delete-namespace` DELETE
- `/preferences` GET → `/api/preferences/list` GET
- `/preferences/resolved` GET → `/api/preferences/resolved` GET
- `/preferences/schema` GET → stays at `/preferences/schema` (hand-written, unchanged)

- [ ] **Step 9: Build and test**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(#297): migrate PreferenceResource to generated @McpDomain approach

Create PreferenceApi and PreferenceSchemaApi SPIs in
preferences-editor-core. PreferenceService handles validation
and scope parsing. PreferenceSchemaResource stays hand-written
for ETag support, annotated with @McpDomain for skip detection.

Refs #297

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Batch 4: Notifications Migration (#297)

### Task 4: NotificationApi + NotificationSuppressionApi + services + migrate tests

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/notification/NotificationApi.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/NotificationSuppressionApi.java`
- Create: `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationService.java`
- Create: `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationSuppressionService.java`
- Modify: `notifications/pom.xml` — update domainFilter
- Modify: `notifications/src/test/java/io/casehub/platform/notification/rest/NotificationResourceTest.java` — update paths
- Modify: `notifications/src/test/java/io/casehub/platform/notification/rest/SuppressionResourceTest.java` — update paths
- Delete: `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationResource.java` (use `ide_refactor_safe_delete`)
- Delete: `notifications/src/main/java/io/casehub/platform/notification/rest/SuppressionResource.java` (use `ide_refactor_safe_delete`)

**Interfaces:**
- Consumes: `@RestPath`, `@RestMethod`, `@PathParam` from platform-api; NotificationStore, SuppressionStore, CurrentPrincipal
- Produces: `NotificationApi` SPI, `NotificationSuppressionApi` SPI, services

- [ ] **Step 1: Create NotificationApi SPI in platform-api**

Create `platform-api/src/main/java/io/casehub/platform/api/notification/NotificationApi.java`:

```java
package io.casehub.platform.api.notification;

import io.casehub.platform.api.mcp.HttpMethod;
import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PathParam;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.platform.api.mcp.RestMethod;
import io.casehub.platform.api.mcp.RestPath;

import java.util.Map;
import java.util.Optional;

@McpDomain("notifications")
public interface NotificationApi {

    @PlatformQuery("List notifications for the current user")
    NotificationPage list(NotificationStatus status, String category, String cursor, Integer limit);

    @PlatformQuery("Get unread notification count")
    @RestPath("unread-count")
    Map<String, Long> unreadCount();

    @PlatformMutation("Mark a notification as read")
    @RestMethod(HttpMethod.PATCH)
    @RestPath("read")
    Optional<Notification> markRead(@PathParam String id);

    @PlatformMutation("Dismiss a notification")
    @RestMethod(HttpMethod.PATCH)
    @RestPath("dismiss")
    Optional<Notification> dismiss(@PathParam String id);

    @PlatformMutation("Mark all notifications as read")
    @RestPath("mark-all-read")
    Map<String, Integer> markAllRead();
}
```

- [ ] **Step 2: Create NotificationSuppressionApi SPI in platform-api**

Create `platform-api/src/main/java/io/casehub/platform/api/notification/settings/NotificationSuppressionApi.java`:

```java
package io.casehub.platform.api.notification.settings;

import io.casehub.platform.api.mcp.HttpMethod;
import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PathParam;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.platform.api.mcp.RestMethod;
import io.casehub.platform.api.mcp.RestPath;

import java.util.List;
import java.util.Optional;

@McpDomain("notification-suppression")
public interface NotificationSuppressionApi {

    @PlatformMutation("Add a mute rule")
    @RestPath("mute")
    MuteRule addMute(MuteRuleInput input);

    @PlatformQuery("List active mute rules")
    @RestPath("mute")
    List<MuteRule> listMutes();

    @PlatformMutation("Remove a mute rule")
    @RestMethod(HttpMethod.DELETE)
    @RestPath("mute")
    void removeMute(@PathParam String id);

    @PlatformMutation("Activate snooze")
    @RestPath("snooze")
    Snooze activateSnooze(SnoozeInput input);

    @PlatformQuery("Get active snooze")
    @RestPath("snooze")
    Optional<Snooze> getSnooze();

    @PlatformMutation("Cancel snooze")
    @RestMethod(HttpMethod.DELETE)
    @RestPath("snooze")
    void cancelSnooze();
}
```

- [ ] **Step 3: Create NotificationService**

Create `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationService.java`:

```java
package io.casehub.platform.notification.rest;

import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.notification.Notification;
import io.casehub.platform.api.notification.NotificationApi;
import io.casehub.platform.api.notification.NotificationPage;
import io.casehub.platform.api.notification.NotificationQuery;
import io.casehub.platform.api.notification.NotificationStatus;
import io.casehub.platform.api.notification.NotificationStore;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.util.Map;
import java.util.Optional;

@ApplicationScoped
public class NotificationService implements NotificationApi {

    private final NotificationStore store;
    private final CurrentPrincipal principal;

    @Inject
    public NotificationService(NotificationStore store, CurrentPrincipal principal) {
        this.store = store;
        this.principal = principal;
    }

    @Override
    public NotificationPage list(NotificationStatus status, String category, String cursor, Integer limit) {
        return store.find(new NotificationQuery(
                principal.actorId(), principal.tenancyId(),
                status, category, cursor, limit != null ? limit : 25));
    }

    @Override
    public Map<String, Long> unreadCount() {
        return Map.of("count", store.unreadCount(principal.actorId(), principal.tenancyId()));
    }

    @Override
    public Optional<Notification> markRead(String id) {
        return store.markRead(id, principal.actorId(), principal.tenancyId());
    }

    @Override
    public Optional<Notification> dismiss(String id) {
        return store.dismiss(id, principal.actorId(), principal.tenancyId());
    }

    @Override
    public Map<String, Integer> markAllRead() {
        return Map.of("count", store.markAllRead(principal.actorId(), principal.tenancyId()));
    }
}
```

- [ ] **Step 4: Create NotificationSuppressionService**

Create `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationSuppressionService.java`:

```java
package io.casehub.platform.notification.rest;

import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.notification.settings.MuteRule;
import io.casehub.platform.api.notification.settings.MuteRuleInput;
import io.casehub.platform.api.notification.settings.NotificationSuppressionApi;
import io.casehub.platform.api.notification.settings.Snooze;
import io.casehub.platform.api.notification.settings.SnoozeInput;
import io.casehub.platform.api.notification.settings.SuppressionStore;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.NotFoundException;

import java.util.List;
import java.util.Optional;

@ApplicationScoped
public class NotificationSuppressionService implements NotificationSuppressionApi {

    private final SuppressionStore store;
    private final CurrentPrincipal principal;

    @Inject
    public NotificationSuppressionService(SuppressionStore store, CurrentPrincipal principal) {
        this.store = store;
        this.principal = principal;
    }

    @Override
    public MuteRule addMute(MuteRuleInput input) {
        var sanitizedInput = new MuteRuleInput(
            principal.actorId(), principal.tenancyId(),
            input.scope(), input.scopeId(), input.entityType(), input.expiresAt());
        return store.addMute(sanitizedInput);
    }

    @Override
    public List<MuteRule> listMutes() {
        return store.activeMutes(principal.actorId(), principal.tenancyId());
    }

    @Override
    public void removeMute(String id) {
        boolean removed = store.removeMute(id, principal.actorId(), principal.tenancyId());
        if (!removed) throw new NotFoundException("Mute rule not found");
    }

    @Override
    public Snooze activateSnooze(SnoozeInput input) {
        var sanitizedInput = new SnoozeInput(principal.actorId(), principal.tenancyId(), input.until());
        return store.activateSnooze(sanitizedInput);
    }

    @Override
    public Optional<Snooze> getSnooze() {
        return store.activeSnooze(principal.actorId(), principal.tenancyId());
    }

    @Override
    public void cancelSnooze() {
        boolean cancelled = store.cancelSnooze(principal.actorId(), principal.tenancyId());
        if (!cancelled) throw new NotFoundException("No active snooze");
    }
}
```

- [ ] **Step 5: Update notifications/pom.xml domainFilter**

Change the domainFilter compiler arg from:
```xml
<arg>-AdomainFilter=delivery-channels,digest,notification-preferences</arg>
```
to:
```xml
<arg>-AdomainFilter=delivery-channels,digest,notification-preferences,notifications,notification-suppression</arg>
```

- [ ] **Step 6: Delete old resource classes**

Use `ide_refactor_safe_delete` on:
- `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationResource.java`
- `notifications/src/main/java/io/casehub/platform/notification/rest/SuppressionResource.java`

- [ ] **Step 7: Update tests for new paths**

In `NotificationResourceTest.java`:
- `/notifications` GET → `/api/notifications/list` GET
- `/notifications/unread-count` GET → `/api/notifications/unread-count` GET
- `/notifications/{id}/read` PATCH → `/api/notifications/read/{id}` PATCH
- `/notifications/{id}/dismiss` PATCH → `/api/notifications/dismiss/{id}` PATCH
- `/notifications/mark-all-read` POST → `/api/notifications/mark-all-read` POST

In `SuppressionResourceTest.java`:
- `/notifications/mute` POST → `/api/notification-suppression/mute` POST
- `/notifications/mute` GET → `/api/notification-suppression/mute` GET
- `/notifications/mute/{id}` DELETE → `/api/notification-suppression/mute/{id}` DELETE
- `/notifications/snooze` POST → `/api/notification-suppression/snooze` POST
- `/notifications/snooze` GET → `/api/notification-suppression/snooze` GET
- `/notifications/snooze` DELETE → `/api/notification-suppression/snooze` DELETE

Status code changes:
- `addMute` / `activateSnooze`: 201 → 200
- `removeMute` / `cancelSnooze`: boolean-based 204/404 → NotFoundException-based 204/404 (same external behavior for 404, but 204→200 for success since generator wraps void in `Response.noContent()`)

- [ ] **Step 8: Build and test**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all generated endpoints replace hand-written resources

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(#297): migrate notification + suppression endpoints to generated @McpDomain

Create NotificationApi and NotificationSuppressionApi SPIs in
platform-api. Separate domains for clean MCP discovery.
NotificationSuppressionService sanitizes input from CurrentPrincipal
and throws NotFoundException for missing resources.

Closes #297

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## References

- [2026-09-14-generator-nested-paths-enum-design.md] — design spec this plan implements
- [GraphQLResolverProcessor.java:366-452] — generateRestMethod (path generation, body detection)
- [GraphQLResolverProcessor.java:603-614] — isSimpleType (current static check)
- [GraphQLResolverProcessor.java:161-194] — scanAnnotatedInterfaces (Jandex SPI discovery)
- [AclResource.java:28-180] — 12 hand-written ACL endpoints
- [PreferenceResource.java:28-96] — 5 hand-written preference endpoints
- [PreferenceSchemaResource.java:20-38] — ETag conditional GET (stays hand-written)
- [NotificationResource.java:24-79] — 5 hand-written notification endpoints
- [SuppressionResource.java:28-146] — 6 hand-written suppression endpoints
- [DeliveryChannelApi.java] — batch 1 reference SPI (platform-api placement pattern)
- [DeliveryChannelService.java] — batch 1 reference service impl
- [CallbackApi.java] — batch 1 reference SPI (callback-api placement)
- [callback/pom.xml] — APT config reference (annotationProcessorPaths + domainFilter)
- [notifications/pom.xml] — APT config reference (platform-api in processor paths)
- [GE-20260612-4f9a47] — JAX-RS on SPI interface causes Quarkus registration conflict
- [GitHub #296] — generator enhancements issue
- [GitHub #297] — batch 2 migration issue
