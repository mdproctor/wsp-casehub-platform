# HANDOFF — Slot 198

## Current Work

**Branch:** `issue-403-work-spring-panache` (platform + work repos)
**Queue:** work#403 → work#409 → work#410

### work#403 — Rest module tests broken after APT migration
- **Status:** 282 of 348 tests pass (was 59 before this session, 289 failing)
- 56 remaining failures need per-test investigation
- `maven.test.skip` removed, tests are running
- **Spec:** `specs/issue-403-work-spring-panache/2026-10-01-rest-test-migration-design.md`
- **Plan:** `plans/2026-10-01-rest-test-migration.md`

### Remaining failure categories (56 tests)
- **16 TemplatePatchTest:** PATCH semantics don't exist in generated API — `POST /update` requires full body, old PATCH sent partial. Needs hand-written PATCH endpoint or SPI change.
- **~20 body/content-type:** Tests hitting lifecycle/spawn/template endpoints without required JSON body (CompleteRequest, CancelRequest etc.)
- **~10 status code mismatches:** Old 204→404 (DELETE→POST path), 400→201 (validation differences), 422→400
- **~10 path/behavioral:** SSE endpoint paths, spawn idempotency, schema validation, audit assertions

### Infrastructure fixes this session (work repo)
- `rest/pom.xml`: removed `maven.test.skip`; added `<proc>none</proc>` for test-compile (prevents duplicate APT generation)
- `rest/src/test/resources/application.properties`: fixed CDI ambiguity (exclude `NoOpGroupMembershipProvider` instead of `MockGroupMembershipProvider`; exclude `io.casehub.platform.rest.generated.**`)
- `api/WorkItemCreateRequest.java`: added `@JsonDeserialize(builder)` + `@JsonPOJOBuilder` (B1 blocker)
- `rest/IllegalArgumentExceptionMapper.java`: new `@Provider` mapping `IllegalArgumentException` → 400

### work#409 — 21 entities still extend PanacheEntityBase
*Unchanged — see git show HEAD~1:HANDOFF.md*

### work#410 — ai and queues missing from rest-spring-generator
*Unchanged — blocked by #403*

## Previous Session (2026-10-01)

Worked work#403 REST test migration:

| What | Result |
|------|--------|
| Root cause investigation | 5 categories: path, verb, structure, response types, response shape |
| Design spec | Written and committed |
| Implementation plan | 8 tasks in 6 batches |
| Tasks 1-5 completed | Fixture, WorkItemResourceTest, lifecycle, relation/note/link/label, feature tests |
| 3 script passes | Bulk path migration, content-type fix, status code fix |
| 4 infrastructure fixes | CDI, Jackson, APT, exception mapper |

## Previous Session (2026-09-30, session 2)

*Unchanged — see git history*
