# Design: REST Module Test Migration (#403)

## Problem

Commit e05ae639 (#400) deleted the hand-written `WorkItemResource` (823 lines),
`WorkItemRelationResource` (219 lines), 11 REST DTOs, and `WorkItemMapper` —
replacing them with 14 APT-generated REST resources from `@McpDomain` SPI
interfaces. The test suite was not updated. 289 of 348 tests fail; tests are
currently skipped via `<maven.test.skip>true</maven.test.skip>`.

## Root Cause

Five categories of breakage:

1. **Path changes**: `/workitems` → `/api/work/items`, lifecycle operations moved
   to `/api/work/lifecycle`, relations to `/api/work/relations`, etc.
2. **Verb changes**: PUT (state transitions) → POST, DELETE → POST
3. **Path structure**: `/{id}/claim` → `/claim/{id}` (id moves after operation name)
4. **Response types**: Deleted DTOs → SPI view types (different field names in some cases)
5. **Response shape**: Raw `List<WorkItemResponse>` → `WorkItemPage` paginated envelope

## Decisions

- **D1**: Direct inline update — change paths/verbs/assertions in each test file.
  Shared `createWorkItem()` fixture extracted to a test utility class.
- **D2**: Tests match the generated API as-is. Generator improvements are separate.
- **D3**: Generic JSON assertions via RestAssured jsonPath(). No coupling to SPI types.

## Endpoint Mapping

### WorkItemsResource (`/api/work/items`)

| Old path | Old verb | New path | New verb | Params |
|----------|----------|----------|----------|--------|
| `POST /workitems` | POST | `POST /api/work/items/create` | POST | body: JSON |
| `GET /workitems` | GET | `GET /api/work/items/list-all` | GET | `?status=&priority=&label=&outcome=&offset=&limit=` |
| `GET /workitems/{id}` | GET | `GET /api/work/items/get-by-id/{id}` | GET | |
| `GET /workitems/inbox` | GET | `GET /api/work/items/inbox` | GET | `?assignee=&candidateGroups=&candidateUser=&status=&priority=&type=&followUp=&outcome=` |
| `GET /workitems/inbox/summary` | GET | `GET /api/work/items/inbox-summary` | GET | same filters |
| `POST /workitems/{id}/labels` | POST | `POST /api/work/items/add-label/{id}` | POST | `?path=&appliedBy=` |
| `DELETE /workitems/{id}/labels` | DELETE | `POST /api/work/items/remove-label/{id}` | POST | `?path=` |
| `POST /workitems/{id}/clone` | POST | `POST /api/work/items/clone/{id}` | POST | `?title=&createdBy=` |
| `GET /workitems/events` | GET | `GET /api/work/items/stream-events` | GET | SSE |
| `GET /workitems/{id}/events` | GET | `GET /api/work/items/stream-work-item-events/{id}` | GET | SSE |

### WorkLifecycleResource (`/api/work/lifecycle`)

All lifecycle operations: old `PUT /workitems/{id}/<op>` → new `POST /api/work/lifecycle/<op>/{id}`

| Operation | Query params |
|-----------|-------------|
| claim | `?claimant=` |
| start | `?actor=` |
| complete | `?actor=&outcome=&resolution=` |
| cancel | `?actor=&reason=` |
| reject | `?actor=&reason=` |
| delegate | `?actor=&targetAssignee=&reason=` |
| release | `?actor=` |
| suspend | `?actor=&reason=` |
| resume | `?actor=` |
| extend | `?newDeadline=&actor=` |
| escalate | `?actor=&reason=` |
| fault | `?actor=&reason=` |
| obsolete | `?actor=&reason=` |
| compensate | complex — needs body |
| update-deadline | `?newDeadline=&actor=` |
| accept-delegation | `?actor=` |
| decline-delegation | `?actor=&reason=` |

### WorkRelationsResource (`/api/work/relations`)

| Old path | New path | New verb |
|----------|----------|----------|
| `POST /workitems/{id}/relations` | `POST /api/work/relations/add-relation/{id}` | POST |
| `GET /workitems/{id}/relations` | `GET /api/work/relations/list-outgoing/{id}` | GET |
| `GET /workitems/{id}/relations/incoming` | `GET /api/work/relations/list-incoming/{id}` | GET |
| `DELETE /workitems/{id}/relations/{relId}` | `POST /api/work/relations/delete-relation/{id}/{relId}` | POST |
| `GET /workitems/{id}/children` | `GET /api/work/relations/children/{id}` | GET |
| `GET /workitems/{id}/parent` | `GET /api/work/relations/parent/{id}` | GET |

### WorkNotesResource (`/api/work/notes`)

| Old path | New path | New verb |
|----------|----------|----------|
| `POST /workitems/{id}/notes` | `POST /api/work/notes/add-note/{id}` | POST |
| `GET /workitems/{id}/notes` | `GET /api/work/notes/list-notes/{id}` | GET |
| `PUT /workitems/{id}/notes/{noteId}` | `POST /api/work/notes/edit-note/{id}/{noteId}` | POST |
| `DELETE /workitems/{id}/notes/{noteId}` | `POST /api/work/notes/delete-note/{id}/{noteId}` | POST |

### WorkLinksResource (`/api/work/links`)

| Old path | New path | New verb |
|----------|----------|----------|
| `POST /workitems/{id}/links` | `POST /api/work/links/add-link/{id}` | POST |
| `GET /workitems/{id}/links` | `GET /api/work/links/list-links/{id}` | GET |
| `DELETE /workitems/{id}/links/{linkId}` | `POST /api/work/links/delete-link/{id}/{linkId}` | POST |

### Other Resources

| Domain | Base path | Key operations |
|--------|-----------|---------------|
| WorkSpawnResource | `/api/work/spawn` | spawn, cancel-group, list-spawn-groups |
| WorkSpawnGroupsResource | `/api/work/spawn-groups` | get-group |
| WorkBulkResource | `/api/work/bulk` | bulk |
| WorkAuditResource | `/api/work/audit` | query |
| WorkTemplatesResource | `/api/work/templates` | create, get-by-id, list-all, update, delete, instantiate |
| WorkSchedulesResource | `/api/work/schedules` | create, get, list, delete, set-active |
| WorkVocabularyResource | `/api/work/vocabulary` | add-definition, list-all |
| WorkLabelRulesResource | `/api/work/label-rules` | create, list, update, delete, evaluate |
| WorkInstancesResource | `/api/work/instances` | get-instances |

## Response Shape Changes

### list-all: paginated envelope

Old: `List<WorkItemResponse>` (raw JSON array)
New: `WorkItemPage` record with `X-Total-Count` header

```json
{"items": [...], "totalCount": N, "hasMore": false}
```

Tests that assert on `$[0].id` need to change to `items[0].id`.

### get-by-id: view type

Old: `WorkItemWithAuditResponse` with nested `WorkItemResponse`
New: `WorkItemWithAuditView` — flat record, same fields as `WorkItemView` plus `auditTrail`

Key field name changes to verify: the SPI view uses `assigneeId` (same as old
`WorkItemResponse`), `types` (List), `labels` (List of `WorkItemLabelView`).

### inbox: root view

Old: `List<WorkItemRootResponse>` with nested `WorkItemResponse item`
New: `List<WorkItemRootView>` — the SPI type has `workItem()` accessor, but Jackson
serializes the record field name, so the JSON key is `workItem` (not `item`).

Tests asserting `item.id` need to change to `workItem.id`.

### Lifecycle operations

Old: returned `WorkItemResponse`
New: returns `WorkItemView` — same shape, JSON field names match.

### create: no Location header

Old: `Response.created(location).entity(...)` → 201 + `Location: /workitems/{id}`
New: `Response.status(201).entity(...)` → 201, no Location header

Tests asserting `Location` header will fail. Remove those assertions.

## Blockers and Edge Cases

### B1: WorkItemCreateRequest Deserialization

`WorkItemCreateRequest` has only a private builder constructor and no `@JsonCreator`.
Jackson may not be able to deserialize JSON bodies into it. This affects only
`POST /api/work/items/create`.

If deserialization fails at runtime, the fix is to add `@JsonCreator` annotations
or a Jackson mixin in the rest module. Validate first by running a single create test.

### B2: PATCH Not Generated

`WorkItemTemplatePatchTest` (22 tests) uses `PATCH /workitem-templates/{id}` with
`application/merge-patch+json`. The generated `WorkTemplatesResource` only has
`POST /update/{id}`. Either the 22 PATCH tests get rewritten to use POST update,
or a hand-written PATCH endpoint stays alongside the generated ones.

### B3: Link Type Filter Missing

`WorkItemLinkTest` tests `?type=design-spec` filter on listLinks. Generated
`WorkLinksResource` has no query param on `list-links`. The filter capability
is lost in the SPI — tests must be updated or the SPI enhanced.

### B4: Audit Response Envelope Changed

Old: `{entries, page, size, total}` with pagination params `page` and `size`.
New: `AuditQueryResult` with `X-Total-Count` header and params `pageIndex`, `pageSize`.

### B5: Label Add/Remove Parameter Binding Changed

Old: POST body `{"path":"...", "appliedBy":"..."}` for add, DELETE with path param for remove.
New: `?path=...&appliedBy=...` query params for add, POST with `?path=...` for remove.

### B6: Error Response Format Changed

Old hand-written resource returned `{"error":"..."}` with custom messages.
Generated resource returns bare HTTP 404/409 with no body. Tests checking
`.body("error", notNullValue())` will fail — remove those assertions.

### B7: inbox response nesting

Old: `item.id` (field name `item` in `WorkItemRootResponse`)
New: `workItem.id` (field name `workItem` in `WorkItemRootView`)

## Migration Plan

### Batch 1: Shared test fixture

Create `WorkItemTestFixture` utility class with a `createWorkItem()` method that
POSTs to `/api/work/items/create` with a standard body. Many tests share this
pattern — centralising it means the path is defined once.

### Batch 2: Core CRUD tests (WorkItemResourceTest)

The main test file (~50 test methods). Update all paths, verbs, and assertions.
Validates the core API surface.

### Batch 3: Lifecycle tests

Files: WorkItemDelegationTest, WorkItemExtendTest, WorkItemOptimisticLockTest,
WorkItemCapabilityIT, WorkerSelectionStrategyIT, MultiTenancyIT.
All use lifecycle verbs (claim/start/complete/etc.) — mechanical PUT→POST + path.

### Batch 4: Relation/note/link/label tests

Files: WorkItemRelationTest, WorkItemNoteTest, WorkItemLinkTest, LabelEndpointTest.
Path changes + verb changes for DELETE→POST.

### Batch 5: Feature-specific tests

Files: WorkItemCloneTest, WorkItemBulkTest, SpawnE2ETest, SpawnCorrectnessTest,
SpawnCallerRefTest, SpawnCascadeCancelTest, SpawnIdempotencyTest, SummaryTest,
InboxFilterTest, WorkItemExcludedUsersTest, WorkItemOutcomeValidationTest,
WorkItemSchemaValidationTest, WorkItemSSETest.

### Batch 6: Template and schedule tests

Files: WorkItemTemplateTest, WorkItemTemplatePatchTest, WorkItemTemplateSchemaTest,
WorkItemTemplateOutcomeTest, WorkItemScheduleTest, WorkItemScheduleClusterTest.
Different base paths (`/workitem-templates` → `/api/work/templates`).

### Batch 7: Audit, filter, and remaining tests

Files: AuditResourceTest, AuditQueryTest, DynamicFilterRegistryTest,
PermanentFilterRegistryTest, BusinessHoursIntegrationTest, MetricsEndpointTest,
OpenApiTest, AsyncApiTest, WorkItemSpawnResourceTest.

### Batch 8: Remove test skip + validate

Remove `<maven.test.skip>true</maven.test.skip>` from rest/pom.xml.
Run full test suite. Fix any remaining failures.

## Files Expected to Pass Without Changes

- **AuditQueryTest** — pure unit test, no REST paths
- **AsyncApiTest** — tests `/q/asyncapi`, platform endpoint
- **WorkItemInstancesResourceTest** — hand-written resource still exists

## Out of Scope

- Generator improvements (RESTful paths, proper HTTP verbs) — separate issue
- `WorkItemCreateRequest` builder → Jackson deserialization support — fix if blocking,
  but scope is limited to enabling test passage
- Response type field name changes beyond what's needed for test assertions

## References

- `e05ae639` — commit that deleted hand-written endpoints
- `rest/pom.xml:20` — maven.test.skip property
- `WorkItemApi` SPI — `/Users/mdproctor/claude/casehub/slots/198/work/api/src/main/java/io/casehub/work/api/spi/WorkItemApi.java`
- Generated resources — `rest/target/generated-sources/annotations/io/casehub/work/rest/spi/`
- `WorkItemView` — `/Users/mdproctor/claude/casehub/slots/198/work/api/src/main/java/io/casehub/work/api/view/WorkItemView.java`
- `WorkItemCreateRequest` — `/Users/mdproctor/claude/casehub/slots/198/work/api/src/main/java/io/casehub/work/api/WorkItemCreateRequest.java`
