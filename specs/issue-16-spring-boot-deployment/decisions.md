# Decisions — casehub-worker#16 Spring Boot Deployment

## D1: Spring integration test module

**Choice:** Yes — create a `spring-integration-test` module
**Alternatives:**
- Skip integration test — unit tests on auto-config suffice for this small codebase
**Rationale:** Matches the campaign pattern from platform and ledger. Verifies Spring composition end-to-end (H2 + Hibernate DDL, auto-config composes correctly). Small overhead for a small module.
**Trade-offs:** One more module to maintain in an already small repo
**Sources:** platform/spring-integration-test, ledger spring-integration-test pattern
**Exploration:** quick
**Status:** captured

## D2: Mock location for Spring tests

**Choice:** In `runtime-core` — `MockWorkerExecutorCore` alongside the core interface
**Alternatives:**
- In `testing/` — keeps all test fixtures together but means testing/ depends on runtime-core
- New `spring-testing/` — separate module, more modules for a small codebase
**Rationale:** MockWorkerExecutorCore in runtime-core is usable by both Spring and Quarkus tests. Existing MockWorkerExecutor in testing/ wraps it for Uni. Minimises module count.
**Trade-offs:** runtime-core ships a test fixture as a main source (consumers can use it for testing). Precedent: platform-api ships NoOp* implementations similarly.
**Sources:** platform-core pattern, platform-api NoOp* pattern
**Exploration:** quick
**Status:** captured
