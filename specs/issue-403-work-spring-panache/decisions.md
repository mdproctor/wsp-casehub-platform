## D1: Migration strategy

**Choice:** Direct inline update — change paths, verbs, and assertions directly in each test file. Shared `createWorkItem()` fixture extracted to a test utility class.
**Alternatives:**
- Path constants + helper class — centralises paths but hides what's being tested
- Test base class — maximum reuse but deep inheritance anti-pattern for tests
**Rationale:** Integration tests should be transparent — the exact HTTP method, path, and body should be visible in each test. Only the common fixture (createWorkItem) is shared.
**Trade-offs:** More total lines changed, but changes are mechanical and each test remains self-documenting.
**Sources:** WorkItemResourceTest.java (existing test pattern), generated REST resources in rest/target/generated-sources/
**Exploration:** quick
**Status:** captured

## D2: API direction

**Choice:** Update tests to match the generated API as-is. The generated API is the new contract.
**Alternatives:**
- Fix generator to produce RESTful paths first — larger scope, separate concern
- Both — better API but larger scope
**Rationale:** Generator improvements are a separate issue. Tests should exercise the actual API surface.
**Trade-offs:** Tests exercise operation-name-based paths (POST /api/work/lifecycle/claim/{id}) rather than conventional REST (PUT /workitems/{id}/claim). If generator changes later, tests change again — but that's the point of integration tests.
**Sources:** graphql-generator APT in platform repo, WorkItemApi SPI
**Exploration:** quick
**Status:** captured

## D3: Assertion style

**Choice:** Generic JSON assertions via RestAssured jsonPath(). No coupling to specific response types.
**Alternatives:**
- Import SPI view types — stronger type safety but couples tests to SPI evolution
- Mix — generic for simple, typed for complex
**Rationale:** Standard RestAssured integration test pattern. Tests survive DTO evolution without recompilation.
**Trade-offs:** Lose compile-time checking of response field names — typos in jsonPath strings fail at runtime, not compile time.
**Sources:** Existing test patterns in WorkItemResourceTest.java
**Exploration:** quick
**Status:** captured
