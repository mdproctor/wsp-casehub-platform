# HANDOFF — Slot 198

## Status

**Branch:** issue-1214-sse-emitter-bridge (both platform and engine repos)
**Active issue:** engine#1214 — SSE broadcasters SseEmitter bridge
**State:** 3 of 6 tasks complete (Batch 1 + Batch 2 done)

## Queue

1. casehubio/engine#1214 — SSE broadcasters SseEmitter bridge (M/Med) ← active

## Resume Point

Batches 1–2 complete. Batches 3–4 remain:

### Batch 3: Spring broadcasters (engine runtime-spring/)
- **Task 4:** `CaseStreamSpringBroadcaster` — @EventListener + SubmissionPublisher registry
- **Task 5:** `ExecutionStateSpringBroadcaster` — same pattern, plus composition logic (mirrors `ExecutionStateBroadcaster` in rest/)

### Batch 4: Regenerate and verify
- **Task 6:** Rebuild platform install, regenerate engine Spring controllers, full compile + test

### What's done

**Platform repo** (branch: issue-1214-sse-emitter-bridge):
- `graphql-spring-generator/SpringDomainRestControllerWriter.buildStreamMethod()` — replaced Mutiny `.subscribe().with()` with `Flow.Subscriber` bridge, `SseEmitter(0L)`, `onTimeout`/`onCompletion` callbacks
- `rest-spring-generator/RestControllerWriter` — added `onTimeout`/`onCompletion` lifecycle callbacks
- `graphql-generator/GraphQLResolverProcessor` — wraps `Flow.Publisher<T>` in `Multi.createFrom().publisher()` for generated Quarkus resources; fixed nested class type handling (`Flow$Publisher` → `Flow.Publisher`) in `typeToJava`/`addTypeImport`

**Engine repo** (branch: issue-1214-sse-emitter-bridge):
- `api/EngineCaseApi` — `caseStream()` returns `Flow.Publisher<CaseStreamEventView>`. Deleted `caseLifecycle()` and `caseContextChange()` stubs
- `api/EnginePlanApi` — `executionStateStream()` returns `Flow.Publisher<JsonNode>`
- `api/pom.xml` — removed `io.smallrye.reactive:mutiny` dependency
- `rest/DefaultEngineCaseApi` — return type widened, stubs deleted
- `rest/DefaultEnginePlanApi` — return type widened

### Known issue

Pre-existing CDI failure: `EngineEvolutionApi` unsatisfied dependency blocks `@QuarkusTest` in rest module. Not caused by our changes — same failure on main. Investigate separately.

### Key files for remaining work

- Plan: `wsp-casehub-platform/plans/2026-10-06-sse-emitter-bridge.md` — Tasks 4-6
- Spec: `wsp-casehub-platform/specs/issue-1214-sse-emitter-bridge/2026-10-06-sse-emitter-bridge-design.md`
- Quarkus broadcasters to mirror: `engine/rest/src/main/java/io/casehub/engine/rest/CaseStreamBroadcaster.java`, `ExecutionStateBroadcaster.java`
- Spring target: `engine/runtime-spring/src/main/java/io/casehub/engine/runtime/spring/broadcast/` (create)

## Prior Work (landed)

Branch `issue-516-spring-remaining` closed — platform#516 was already on main.
