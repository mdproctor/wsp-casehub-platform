# REST Test Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/work#403 — Rest module tests broken after APT migration
**Issue group:** #403, #409, #410

**Goal:** Fix all 289 failing tests in the work repo's rest module by
updating endpoint paths, HTTP verbs, and response assertions to match
the new APT-generated REST resources.

**Architecture:** Direct inline updates to each test file. No abstraction
layer — tests show the exact HTTP call. A shared `WorkItemTestFixture`
utility class provides the common `createWorkItem()` fixture used by
~25 test files.

**Tech Stack:** Quarkus 3.32, RESTEasy Reactive, RestAssured, JUnit 5,
H2 in-memory database.

## Global Constraints

- All paths now start with `/api/work/<domain>/`
- All mutations use POST (not PUT or DELETE)
- Path params come AFTER the operation name: `/claim/{id}` not `/{id}/claim`
- Lifecycle operations with complex args take a JSON body (record types)
- `candidateGroup` query param renamed to `candidateGroups` in inbox/summary
- No Location header on create (old: `Response.created(uri)`, new: `Response.status(201)`)
- Error responses return bare HTTP status (404/409) with no body — old `{"error":"..."}` assertions must be removed
- `listAll` returns paginated `WorkItemPage` envelope (`{items, totalCount, hasMore}`) not a raw JSON array
- inbox response nesting: `item.field` → `workItem.field` (`WorkItemRootView` record field name)

---

## Batch 1: Foundation — shared fixture + smoke test

### Task 1: Create WorkItemTestFixture and validate create endpoint

**Files:**
- Create: `rest/src/test/java/io/casehub/work/rest/test/WorkItemTestFixture.java`
- Modify: `rest/pom.xml` (remove `maven.test.skip`)

**Interfaces:**
- Produces: `WorkItemTestFixture.createWorkItem()` → returns `String` id,
  `WorkItemTestFixture.createWorkItem(String body)` → returns `String` id,
  `WorkItemTestFixture.createWorkItemResponse()` → returns `ValidatableResponse`

- [ ] **Step 1: Remove test skip from pom.xml**

In `rest/pom.xml`, remove lines 18-21:
```xml
  <properties>
    <!-- Tests broken after #400 APT migration — tracked by #403 -->
    <maven.test.skip>true</maven.test.skip>
  </properties>
```

- [ ] **Step 2: Write WorkItemTestFixture**

```java
package io.casehub.work.rest.test;

import static io.restassured.RestAssured.given;
import io.restassured.http.ContentType;
import io.restassured.response.ValidatableResponse;

public final class WorkItemTestFixture {

    private static final String CREATE_PATH = "/api/work/items/create";

    private static final String DEFAULT_BODY = """
            {
                "title": "Test item",
                "description": "Do something",
                "priority": "MEDIUM",
                "createdBy": "system"
            }
            """;

    private WorkItemTestFixture() {}

    public static String createWorkItem() {
        return createWorkItem(DEFAULT_BODY);
    }

    public static String createWorkItem(String body) {
        return createWorkItemResponse(body)
                .statusCode(201)
                .extract().path("id");
    }

    public static ValidatableResponse createWorkItemResponse() {
        return createWorkItemResponse(DEFAULT_BODY);
    }

    public static ValidatableResponse createWorkItemResponse(String body) {
        return given()
                .contentType(ContentType.JSON)
                .body(body)
                .when().post(CREATE_PATH)
                .then();
    }
}
```

- [ ] **Step 3: Run compile to validate fixture compiles**

Run: `/opt/homebrew/bin/mvn -f /Users/mdproctor/claude/casehub/slots/198/work/rest/pom.xml test-compile --batch-mode -q`
Expected: BUILD SUCCESS

- [ ] **Step 4: Write a smoke test to validate create endpoint deserialization**

Create `rest/src/test/java/io/casehub/work/rest/CreateEndpointSmokeTest.java`:

```java
package io.casehub.work.rest;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.notNullValue;

import io.quarkus.test.TestTransaction;
import io.quarkus.test.junit.QuarkusTest;
import io.restassured.http.ContentType;
import org.junit.jupiter.api.Test;

@QuarkusTest
@TestTransaction
class CreateEndpointSmokeTest {

    @Test
    void createWorkItem_returns201WithId() {
        given()
            .contentType(ContentType.JSON)
            .body("""
                {
                    "title": "Smoke test item",
                    "description": "Validates APT endpoint works",
                    "priority": "MEDIUM",
                    "createdBy": "system"
                }
                """)
            .when().post("/api/work/items/create")
            .then()
            .statusCode(201)
            .body("id", notNullValue());
    }
}
```

- [ ] **Step 5: Run smoke test**

Run: `/opt/homebrew/bin/mvn -f /Users/mdproctor/claude/casehub/slots/198/work/rest/pom.xml test --batch-mode -Dtest=CreateEndpointSmokeTest -Dsurefire.useFile=false`
Expected: PASS — confirms Jackson can deserialize `WorkItemCreateRequest`

If this fails with a deserialization error, **STOP**. The blocker B1 from
the spec is real. Fix by adding `@JsonCreator` to `WorkItemCreateRequest`
or a Jackson mixin before proceeding.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/work add rest/pom.xml rest/src/test/java/io/casehub/work/rest/test/WorkItemTestFixture.java rest/src/test/java/io/casehub/work/rest/CreateEndpointSmokeTest.java
git -C /Users/mdproctor/claude/casehub/slots/198/work commit -m "feat(#403): add WorkItemTestFixture and validate create endpoint

Remove maven.test.skip, add shared test fixture for createWorkItem(),
add smoke test proving APT-generated create endpoint deserializes
WorkItemCreateRequest correctly.

Refs casehubio/work#403

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: Core CRUD and lifecycle — WorkItemResourceTest

### Task 2: Migrate WorkItemResourceTest

This is the largest test file (~41 tests). All paths, verbs, and
assertions need updating.

**Files:**
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemResourceTest.java`

**Interfaces:**
- Consumes: `WorkItemTestFixture.createWorkItem()`

**Mapping reference:**

| Old | New |
|-----|-----|
| `POST /workitems` (body) | `POST /api/work/items/create` (body) |
| `GET /workitems` | `GET /api/work/items/list-all` |
| `GET /workitems/{id}` | `GET /api/work/items/get-by-id/{id}` |
| `GET /workitems/inbox` | `GET /api/work/items/inbox` |
| `GET /workitems/inbox/summary` | `GET /api/work/items/inbox-summary` |
| `PUT /workitems/{id}/claim?claimant=` | `POST /api/work/lifecycle/claim/{id}?claimant=` |
| `PUT /workitems/{id}/start?actor=` | `POST /api/work/lifecycle/start/{id}?actor=` |
| `PUT /workitems/{id}/complete?actor=` | `POST /api/work/lifecycle/complete/{id}?actor=` (+ body `{}`) |
| `PUT /workitems/{id}/cancel?actor=` | `POST /api/work/lifecycle/cancel/{id}?actor=` (+ body `{}`) |
| `PUT /workitems/{id}/reject?actor=` | `POST /api/work/lifecycle/reject/{id}?actor=` (+ body `{}`) |
| `PUT /workitems/{id}/delegate?actor=&targetAssignee=` | `POST /api/work/lifecycle/delegate/{id}?actor=` (+ body `{"to":"..."}`) |
| `PUT /workitems/{id}/release?actor=` | `POST /api/work/lifecycle/release/{id}?actor=` |
| `PUT /workitems/{id}/suspend?actor=` | `POST /api/work/lifecycle/suspend/{id}?actor=` (+ body `{}`) |
| `PUT /workitems/{id}/resume?actor=` | `POST /api/work/lifecycle/resume/{id}?actor=` |

**Key assertion changes:**
- Remove `Location` header assertions on create
- `$[0].id` → `items[0].id` for list-all (paginated envelope)
- `item.id` → `workItem.id` for inbox responses
- Remove `.body("error", ...)` assertions on error responses
- `candidateGroup` → `candidateGroups` in query params

- [ ] **Step 1: Read the full WorkItemResourceTest**

Read the entire file to understand every test method.

- [ ] **Step 2: Replace private createWorkItem() with fixture call**

Replace the private `createWorkItem()` helper:
```java
// Before:
private String createWorkItem() {
    return given()...post("/workitems")...
}

// After:
import io.casehub.work.rest.test.WorkItemTestFixture;
// Then replace all createWorkItem() calls with WorkItemTestFixture.createWorkItem()
```

Also remove the import of deleted `CreateWorkItemRequest` if present.

- [ ] **Step 3: Update all endpoint paths and verbs**

Apply the mapping table above to every `given()...when()` chain:
- `.post("/workitems")` → `.post("/api/work/items/create")`
- `.get("/workitems")` → `.get("/api/work/items/list-all")`
- `.get("/workitems/" + id)` → `.get("/api/work/items/get-by-id/" + id)`
- `.get("/workitems/inbox")` → `.get("/api/work/items/inbox")`
- `.put("/workitems/" + id + "/claim?claimant=X")` → `.post("/api/work/lifecycle/claim/" + id + "?claimant=X")`
- etc. for all lifecycle verbs

For lifecycle ops that now take a body (cancel, complete, reject,
delegate, suspend, escalate, extend, fault, obsolete, compensate,
update-deadline): add `.contentType(ContentType.JSON).body("{}")` before
`.when().post(...)`. For delegate, body is `{"to":"<targetAssignee>"}`.
For complete with outcome: body is `{"outcome":"<value>","resolution":"<value>"}`.

- [ ] **Step 4: Update response assertions**

- Remove `Location` header assertions
- `candidateGroup` → `candidateGroups`
- Remove `.body("error", ...)` on 404/409 checks
- For inbox: `item.id` → `workItem.id`, `item.status` → `workItem.status`
- For list-all: wrap array assertions with `items.` prefix
  (e.g., `hasSize(2)` on root → `body("items", hasSize(2))`)

- [ ] **Step 5: Run WorkItemResourceTest**

Run: `/opt/homebrew/bin/mvn -f /Users/mdproctor/claude/casehub/slots/198/work/rest/pom.xml test --batch-mode -Dtest=WorkItemResourceTest -Dsurefire.useFile=false`
Expected: All 41 tests PASS

Fix any remaining failures iteratively — each fix should be guided by
reading the actual error message.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/work add rest/src/test/java/io/casehub/work/rest/WorkItemResourceTest.java
git -C /Users/mdproctor/claude/casehub/slots/198/work commit -m "feat(#403): migrate WorkItemResourceTest to generated API paths

Update all 41 tests: /workitems → /api/work/items, lifecycle verbs
PUT → POST via /api/work/lifecycle, paginated list-all, inbox nesting,
remove deleted DTO imports.

Refs casehubio/work#403

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 3: Lifecycle and relation tests

### Task 3: Migrate lifecycle test files

**Files:**
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemDelegationTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemExtendTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemOptimisticLockTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemCapabilityIT.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkerSelectionStrategyIT.java`

**Interfaces:**
- Consumes: `WorkItemTestFixture.createWorkItem()`

Same patterns as Task 2: replace paths, PUT→POST, add bodies where needed.

**Delegation-specific changes:**
- Old: `PUT /workitems/{id}/delegate?actor=A&targetAssignee=B`
- New: `POST /api/work/lifecycle/delegate/{id}?actor=A` with body `{"to":"B"}`
  (the `targetAssignee` query param moved to `DelegateRequest.to`)

- [ ] **Step 1: Read and update all 5 files**

Apply the same path/verb mapping from Task 2. Replace createWorkItem()
with fixture. Fix delegate body binding. Fix extend body binding
(`ExtendRequest` with `newDeadline`).

- [ ] **Step 2: Run all 5 test classes**

Run: `/opt/homebrew/bin/mvn -f /Users/mdproctor/claude/casehub/slots/198/work/rest/pom.xml test --batch-mode -Dtest=WorkItemDelegationTest,WorkItemExtendTest,WorkItemOptimisticLockTest,WorkItemCapabilityIT,WorkerSelectionStrategyIT -Dsurefire.useFile=false`
Expected: All tests PASS (~38 tests)

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/work add rest/src/test/java/io/casehub/work/rest/WorkItemDelegationTest.java rest/src/test/java/io/casehub/work/rest/WorkItemExtendTest.java rest/src/test/java/io/casehub/work/rest/WorkItemOptimisticLockTest.java rest/src/test/java/io/casehub/work/rest/WorkItemCapabilityIT.java rest/src/test/java/io/casehub/work/rest/WorkerSelectionStrategyIT.java
git -C /Users/mdproctor/claude/casehub/slots/198/work commit -m "feat(#403): migrate lifecycle test files to generated API paths

Refs casehubio/work#403

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4: Migrate relation, note, link, and label tests

**Files:**
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemRelationTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemNoteTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemLinkTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/LabelEndpointTest.java`

**Interfaces:**
- Consumes: `WorkItemTestFixture.createWorkItem()`

**Mapping reference:**

Relations:
- `POST /workitems/{id}/relations` → `POST /api/work/relations/add-relation/{id}`
- `GET /workitems/{id}/relations` → `GET /api/work/relations/list-outgoing/{id}`
- `GET /workitems/{id}/relations/incoming` → `GET /api/work/relations/list-incoming/{id}`
- `DELETE /workitems/{id}/relations/{rid}` → `POST /api/work/relations/delete-relation/{id}/{rid}`
- `GET /workitems/{id}/children` → `GET /api/work/relations/children/{id}`
- `GET /workitems/{id}/parent` → `GET /api/work/relations/parent/{id}`

Notes:
- `POST /workitems/{id}/notes` → `POST /api/work/notes/add-note/{id}`
- `GET /workitems/{id}/notes` → `GET /api/work/notes/list-notes/{id}`
- `PUT /workitems/{id}/notes/{nid}` → `POST /api/work/notes/edit-note/{id}/{nid}`
- `DELETE /workitems/{id}/notes/{nid}` → `POST /api/work/notes/delete-note/{id}/{nid}`

Links:
- `POST /workitems/{id}/links` → `POST /api/work/links/add-link/{id}`
- `GET /workitems/{id}/links` → `GET /api/work/links/list-links/{id}`
- `DELETE /workitems/{id}/links/{lid}` → `POST /api/work/links/delete-link/{id}/{lid}`
- Note: `?type=` filter on list-links is NOT in generated API — remove filter assertions or skip those tests

Labels:
- `POST /workitems/{id}/labels` (body: `{"path":"...","appliedBy":"..."}`) → `POST /api/work/items/add-label/{id}?path=...&appliedBy=...`
- `DELETE /workitems/{id}/labels?path=` → `POST /api/work/items/remove-label/{id}?path=...`
- `GET /vocabulary` → `GET /api/work/vocabulary/list-all`
- `POST /vocabulary` → `POST /api/work/vocabulary/add-definition`

- [ ] **Step 1: Read and update all 4 files**

- [ ] **Step 2: Run all 4 test classes**

Run: `/opt/homebrew/bin/mvn -f /Users/mdproctor/claude/casehub/slots/198/work/rest/pom.xml test --batch-mode -Dtest=WorkItemRelationTest,WorkItemNoteTest,WorkItemLinkTest,LabelEndpointTest -Dsurefire.useFile=false`
Expected: All tests PASS (~64 tests)

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/work add rest/src/test/java/io/casehub/work/rest/WorkItemRelationTest.java rest/src/test/java/io/casehub/work/rest/WorkItemNoteTest.java rest/src/test/java/io/casehub/work/rest/WorkItemLinkTest.java rest/src/test/java/io/casehub/work/rest/LabelEndpointTest.java
git -C /Users/mdproctor/claude/casehub/slots/198/work commit -m "feat(#403): migrate relation/note/link/label tests to generated API paths

Refs casehubio/work#403

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 4: Feature tests — spawn, bulk, clone, inbox, SSE

### Task 5: Migrate feature-specific test files

**Files:**
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemCloneTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemBulkTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/SpawnE2ETest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/SpawnCorrectnessTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/SpawnCallerRefTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/SpawnCascadeCancelTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/SpawnIdempotencyTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/SummaryTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/InboxFilterTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemExcludedUsersTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemOutcomeValidationTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemSchemaValidationTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemSSETest.java`

**Interfaces:**
- Consumes: `WorkItemTestFixture.createWorkItem()`

**Mapping reference:**

Spawn:
- `POST /workitems/{id}/spawn` → `POST /api/work/spawn/spawn/{id}`
- `GET /workitems/{id}/spawn-groups` → `GET /api/work/spawn/list-spawn-groups/{id}`
- `POST /workitems/{id}/spawn-groups/{gid}/cancel` → `POST /api/work/spawn/cancel-group/{id}/{gid}`
- `GET /spawn-groups/{gid}` → `GET /api/work/spawn-groups/get-group/{gid}`

Bulk:
- `POST /workitems/bulk` → `POST /api/work/bulk/bulk`

Clone:
- `POST /workitems/{id}/clone` → `POST /api/work/items/clone/{id}?title=...&createdBy=...`
  (old: JSON body with title/createdBy; new: query params)

SSE:
- `GET /workitems/events` → `GET /api/work/items/stream-events`
- `GET /workitems/{id}/events` → `GET /api/work/items/stream-work-item-events/{id}`

Summary/inbox:
- `GET /workitems/inbox/summary` → `GET /api/work/items/inbox-summary`
- `candidateGroup` → `candidateGroups`

- [ ] **Step 1: Read and update all 13 files**

Apply path/verb mappings. Replace createWorkItem() with fixture.
For clone: old JSON body `{"title":"...","createdBy":"..."}` becomes
query params `?title=...&createdBy=...`.

- [ ] **Step 2: Run all 13 test classes**

Run: `/opt/homebrew/bin/mvn -f /Users/mdproctor/claude/casehub/slots/198/work/rest/pom.xml test --batch-mode -Dtest=WorkItemCloneTest,WorkItemBulkTest,SpawnE2ETest,SpawnCorrectnessTest,SpawnCallerRefTest,SpawnCascadeCancelTest,SpawnIdempotencyTest,SummaryTest,InboxFilterTest,WorkItemExcludedUsersTest,WorkItemOutcomeValidationTest,WorkItemSchemaValidationTest,WorkItemSSETest -Dsurefire.useFile=false`
Expected: All tests PASS (~85 tests)

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/work add rest/src/test/java/io/casehub/work/rest/WorkItemCloneTest.java rest/src/test/java/io/casehub/work/rest/WorkItemBulkTest.java rest/src/test/java/io/casehub/work/rest/SpawnE2ETest.java rest/src/test/java/io/casehub/work/rest/SpawnCorrectnessTest.java rest/src/test/java/io/casehub/work/rest/SpawnCallerRefTest.java rest/src/test/java/io/casehub/work/rest/SpawnCascadeCancelTest.java rest/src/test/java/io/casehub/work/rest/SpawnIdempotencyTest.java rest/src/test/java/io/casehub/work/rest/SummaryTest.java rest/src/test/java/io/casehub/work/rest/InboxFilterTest.java rest/src/test/java/io/casehub/work/rest/WorkItemExcludedUsersTest.java rest/src/test/java/io/casehub/work/rest/WorkItemOutcomeValidationTest.java rest/src/test/java/io/casehub/work/rest/WorkItemSchemaValidationTest.java rest/src/test/java/io/casehub/work/rest/WorkItemSSETest.java
git -C /Users/mdproctor/claude/casehub/slots/198/work commit -m "feat(#403): migrate feature tests (spawn/bulk/clone/inbox/SSE)

Refs casehubio/work#403

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 5: Template, schedule, and audit tests

### Task 6: Migrate template and schedule tests

**Files:**
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemTemplateTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemTemplatePatchTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemTemplateSchemaTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemTemplateOutcomeTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemScheduleTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemScheduleClusterTest.java`

**Mapping reference:**

Templates:
- `POST /workitem-templates` → `POST /api/work/templates/create`
- `GET /workitem-templates` → `GET /api/work/templates/list-all`
- `GET /workitem-templates/{id}` → `GET /api/work/templates/get-by-id/{id}`
- `PUT /workitem-templates/{id}` → `POST /api/work/templates/update/{id}`
- `DELETE /workitem-templates/{id}` → `POST /api/work/templates/delete/{id}`
- `POST /workitem-templates/{id}/instantiate` → `POST /api/work/templates/instantiate/{id}`

**PATCH handling (B2):** `WorkItemTemplatePatchTest` uses
`PATCH /workitem-templates/{id}` with `application/merge-patch+json`.
No generated equivalent exists. Options:
1. Rewrite tests to use `POST /api/work/templates/update/{id}` (full replace)
2. Skip/disable PATCH tests and file a follow-up issue

Decision: rewrite PATCH tests to use POST update. If the SPI's update
method accepts partial updates, the tests can send partial bodies. If
not, tests must send full template bodies. Check the `WorkItemTemplateApi`
update method signature to decide.

Schedules:
- `POST /workitem-schedules` → `POST /api/work/schedules/create`
- `GET /workitem-schedules` → `GET /api/work/schedules/list`
- `GET /workitem-schedules/{id}` → `GET /api/work/schedules/get/{id}`
- `DELETE /workitem-schedules/{id}` → `POST /api/work/schedules/delete/{id}`
- `PUT /workitem-schedules/{id}/active` → `POST /api/work/schedules/set-active/{id}`

- [ ] **Step 1: Read WorkItemTemplateApi to understand update semantics**

Check if `update()` accepts partial updates or requires full replacement.

- [ ] **Step 2: Update all 6 files**

For PATCH tests: rewrite to use POST update with the appropriate body.
Apply path/verb mappings for templates and schedules.

- [ ] **Step 3: Run all 6 test classes**

Run: `/opt/homebrew/bin/mvn -f /Users/mdproctor/claude/casehub/slots/198/work/rest/pom.xml test --batch-mode -Dtest=WorkItemTemplateTest,WorkItemTemplatePatchTest,WorkItemTemplateSchemaTest,WorkItemTemplateOutcomeTest,WorkItemScheduleTest,WorkItemScheduleClusterTest -Dsurefire.useFile=false`
Expected: All tests PASS (~77 tests)

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/work add rest/src/test/java/io/casehub/work/rest/WorkItemTemplateTest.java rest/src/test/java/io/casehub/work/rest/WorkItemTemplatePatchTest.java rest/src/test/java/io/casehub/work/rest/WorkItemTemplateSchemaTest.java rest/src/test/java/io/casehub/work/rest/WorkItemTemplateOutcomeTest.java rest/src/test/java/io/casehub/work/rest/WorkItemScheduleTest.java rest/src/test/java/io/casehub/work/rest/WorkItemScheduleClusterTest.java
git -C /Users/mdproctor/claude/casehub/slots/198/work commit -m "feat(#403): migrate template and schedule tests

PATCH tests rewritten to POST update. Schedule DELETE → POST.

Refs casehubio/work#403

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 7: Migrate audit, filter, and remaining tests

**Files:**
- Modify: `rest/src/test/java/io/casehub/work/rest/AuditResourceTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/DynamicFilterRegistryTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/PermanentFilterRegistryTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/BusinessHoursIntegrationTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/MetricsEndpointTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/OpenApiTest.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/MultiTenancyIT.java`
- Modify: `rest/src/test/java/io/casehub/work/rest/WorkItemSpawnResourceTest.java`

**Not modified (should pass):**
- `AuditQueryTest` — pure unit test
- `AsyncApiTest` — platform endpoint
- `WorkItemInstancesResourceTest` — hand-written resource still exists

**Mapping reference:**

Audit:
- `GET /audit?page=0&size=20` → `GET /api/work/audit/query?pageIndex=0&pageSize=20`
- Response: check `entries`, `page`, `size`, `totalCount` fields (same names in `AuditQueryResult`)
- `X-Total-Count` header now set on response

Filters (label rules):
- `POST /label-rules` → `POST /api/work/label-rules/create`
- `GET /label-rules` → `GET /api/work/label-rules/list`
- `PUT /label-rules/{id}` → `POST /api/work/label-rules/update/{id}`
- `DELETE /label-rules/{id}` → `POST /api/work/label-rules/delete/{id}`

- [ ] **Step 1: Read and update all 8 files**

- [ ] **Step 2: Run all test classes including the unchanged ones**

Run: `/opt/homebrew/bin/mvn -f /Users/mdproctor/claude/casehub/slots/198/work/rest/pom.xml test --batch-mode -Dtest=AuditResourceTest,AuditQueryTest,DynamicFilterRegistryTest,PermanentFilterRegistryTest,BusinessHoursIntegrationTest,MetricsEndpointTest,OpenApiTest,AsyncApiTest,MultiTenancyIT,WorkItemSpawnResourceTest,WorkItemInstancesResourceTest -Dsurefire.useFile=false`
Expected: All tests PASS

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/work add rest/src/test/java/io/casehub/work/rest/
git -C /Users/mdproctor/claude/casehub/slots/198/work commit -m "feat(#403): migrate audit/filter/remaining tests

Audit pagination params page→pageIndex, size→pageSize.
Label rules DELETE/PUT → POST. Multi-tenancy paths updated.

Refs casehubio/work#403

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 6: Full validation + cleanup

### Task 8: Run full test suite and fix remaining failures

**Files:**
- Possibly modify: any test files with remaining failures
- Delete: `rest/src/test/java/io/casehub/work/rest/CreateEndpointSmokeTest.java`
  (served its purpose in Batch 1)

- [ ] **Step 1: Run the complete test suite**

Run: `/opt/homebrew/bin/mvn -f /Users/mdproctor/claude/casehub/slots/198/work/rest/pom.xml test --batch-mode -Dsurefire.useFile=false`
Expected: All 348 tests PASS (or close — some may have been removed)

- [ ] **Step 2: Fix any remaining failures**

Read each failure message. Most will be one of:
- A path that was missed
- A query param name that changed
- A response field name that changed
- An import of a deleted class

Fix each failure, re-run the specific test, verify pass.

- [ ] **Step 3: Remove the smoke test**

Delete `CreateEndpointSmokeTest.java` — the fixture and other tests
cover create endpoint validation.

- [ ] **Step 4: Final full test run**

Run: `/opt/homebrew/bin/mvn -f /Users/mdproctor/claude/casehub/slots/198/work/rest/pom.xml test --batch-mode -Dsurefire.useFile=false`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/work add rest/
git -C /Users/mdproctor/claude/casehub/slots/198/work commit -m "feat(#403): complete REST test migration — all tests pass

Refs casehubio/work#403

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## References

- [2026-10-01-rest-test-migration-design.md] — design spec
- [WorkItemApi.java] — SPI interface driving WorkItemsResource generation
- [WorkItemLifecycleApi] — SPI for lifecycle operations
- [WorkLifecycleResource.java] — generated lifecycle endpoints
- [WorkItemsResource.java] — generated items endpoints
- [WorkItemView.java] — response view type
- [CompleteRequest.java, CancelRequest.java, DelegateRequest.java] — lifecycle body types
- [AuditQueryResult.java] — audit response envelope
- [WorkItemCreateRequest.java] — create endpoint body type (potential deserialization blocker)
- [casehubio/work#403] — focal issue
- [e05ae639] — commit that broke tests
