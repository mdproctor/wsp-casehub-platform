# Engine Spring Completeness — Design Spec

**Epic:** casehubio/engine#1206
**Branch:** issue-1206-spring-completeness
**Date:** 2026-10-03

## Overview

Close all remaining Spring deployment gaps in the engine repo. The engine is the largest remaining gap in the Spring story. This epic addresses: Quarkus imports leaked into core modules, 11 CDI modules without framework-neutral counterparts, missing Spring generation for REST/MCP/persistence, and the @McpDomain SPI migration prerequisite.

Work order: #1207 → #1208 (excluding rest/) → #1209 → #1210 → #1211 → #1095 → #1199 (includes rest-core extraction)

Note: #1210 and #1211 are independent of #1208 and could run in parallel, but the .plan queue executes serially within a session. The ordering above is the recommended serial sequence.

## Issue #1207 — Remove Quarkus imports from core modules

### Problem

~77 files across 3 -core modules import Quarkus/CDI types that prevent Spring compilation:

| Module | Files | Import patterns |
|--------|-------|----------------|
| runtime-core | ~69 | `@ApplicationScoped` (69), `@DefaultBean` (9), `@Unremovable` (4), `StartupEvent`/`@Observes` (3), `Event<T>`/`@ObservesAsync` (1), `Instance<T>` (multiple) |
| common-core | 5 | `@ApplicationScoped` |
| engine-support-core | 3 | `Arc.container()` (2 files), `@ApplicationScoped`, `Event<T>`, `@ObservesAsync` |

This scope intentionally expands beyond issue #1207's original description (18 Quarkus-specific annotations) to include ALL framework-coupled imports in -core modules. Issue #1207 should be updated to reflect the actual scope. runtime-core is already a -core module, so its CDI cleanup falls under #1207, not #1208.

### Fix by pattern

| Pattern | Replacement | Where wiring goes |
|---------|------------|-------------------|
| `@ApplicationScoped` | Remove — POJO with constructor injection | Quarkus module `@Produces @ApplicationScoped`, Spring `@Bean` |
| `@DefaultBean` | Remove | Quarkus module `@Produces @DefaultBean`, Spring `@ConditionalOnMissingBean` |
| `@Unremovable` | Remove (no Spring equivalent needed) | N/A |
| `StartupEvent` / `@Observes` | `@PostConstruct` or init callback interface | N/A (PostConstruct is jakarta.annotation, not CDI) |
| `Arc.container()` | Static holder populated at startup | Core class defines static `init(dep)` method; framework-specific bootstrap bean calls it. Constructor injection is infeasible here — `CasehubFlow` is a static utility class, `CasehubCallableTaskBuilder` is loaded via ServiceLoader (requires no-arg constructor). |
| `@VirtualThreads ExecutorService` | Plain `ExecutorService` constructor param | Core POJO accepts `ExecutorService`; Quarkus qualifies with `@VirtualThreads`; Spring provides `Executors.newVirtualThreadPerTaskExecutor()` |
| `Event<T>` | `Consumer<T>` constructor param | Quarkus: CDI `Event<T>` bridge. Spring: `ApplicationEventPublisher` bridge |
| `@ObservesAsync` | `Consumer<T>` callback | Same as Event<T> — consumer registered by framework module |
| `Instance<T>` | `List<T>` constructor param | Quarkus: collected from `Instance<T>`. Spring: collected from `ObjectProvider<T>` |

### Impact on existing Spring modules — MUST update with #1207

runtime-spring's `RuntimeManualConfig` (~770 lines) contains `notResolvable()` stubs that return fake `Instance<T>` implementations. When #1207 changes constructors from `Instance<T>` to `List<T>`, RuntimeManualConfig will fail to compile. Therefore, RuntimeManualConfig MUST be updated as part of #1207 (changing `notResolvable()` calls to `List.of()` or proper bean lists), not deferred to #1211.

## Issue #1208 — Extract 10 -core modules (rest/ deferred to #1199)

### Modules to extract

rest/ is excluded — it depends on #1095 (SPI interfaces) and is handled as part of #1199.

| Module | Beans to extract | Extraction difficulty |
|--------|-----------------|----------------------|
| a2a | `A2ABeans` (6 @Produces), `A2AClientRegistryAdapter` | Easy — quarkus/ subpackage already separates |
| actor-state | `ActorStateBeans` (7 @Produces) | Easy — quarkus/ subpackage |
| engine-ai | `EngineAiBeans` (4 @Produces) | Easy — quarkus/ subpackage |
| flow | `FlowBeans` (7 @Produces) | Easy — quarkus/ subpackage |
| mcp | `McpBeans` (6 @Produces), `McpClientRegistryAdapter` | Easy — quarkus/ subpackage |
| queue | `QueueBeans` (5 @Produces), 3 adapters | Easy — quarkus/ subpackage |
| work-cloudevent | `WorkCloudEventBeans` (6 @Produces), 2 adapters | Easy — quarkus/ subpackage |
| work-adapter | 10 @ApplicationScoped classes directly on logic | Medium — needs refactoring to separate CDI from logic |
| eidos-routing | `EngineAwareAgentSelector` with @ApplicationScoped | Easy — 1 class |
| yaml-cbr | `StepExecutionCbrBridge`, `StepFileCallableDispatcher` | Easy — 2 classes |

### Extraction pattern

For modules with quarkus/ subpackage already:
1. Create `<module>-core` Maven module
2. Move all non-quarkus/ classes to -core
3. -core has zero CDI, zero Quarkus imports
4. Quarkus module retains beans/adapters, depends on -core

For modules without quarkus/ separation (work-adapter, eidos-routing, yaml-cbr):
1. Create `<module>-core` Maven module
2. Extract logic classes, remove `@ApplicationScoped`
3. Add constructor injection for all dependencies
4. Create CDI wiring class in the Quarkus module

### Spring auto-config generation

After extraction, each -core module is a candidate for `spring-generator`. For modules with few beans, consider consolidating into `engine-support-spring` rather than creating per-module -spring modules.

## Issue #1209 — Engine MCP Spring module

### Problem

The engine's `mcp/` module uses Quarkus-specific MCP wiring (quarkus-arc). No @Tool annotations exist — the engine uses the platform's @McpDomain system exclusively.

### Solution

After #1208 extracts mcp-core, the `spring-generator` should be able to generate the Spring auto-config. If the mcp module's `McpBeans` wiring is simple enough, the generated Spring module just needs to produce the same POJOs as beans.

The platform's `mcp-spring` module already provides `SpringModelScanner`, `CaseHubToolCallbackProvider`, and `SpringMcpResourceRegistryBridge`. The engine's mcp-spring module bridges engine-specific MCP tools into this infrastructure.

The engine's @McpDomain classes register through platform's `SpringModelScanner` automatically — no engine-specific MCP Spring code is needed beyond ensuring the -core beans are wired as Spring @Bean definitions. Verify by checking that `casehub_model` and `casehub_action` tools include engine domains in the spring-integration-test.

## Issue #1210 — persistence-spring-jpa generation candidate

### Current state

12 hand-written classes:
- `PersistenceAutoConfiguration` — @AutoConfiguration with all repository beans, RLS policy
- 10 repository implementations (Spring Data JPA)
- 1 mapper utility

### Assessment

This module shares entities via `persistence-jpa-common` and implements SPIs defined in `api/`. The repository implementations use Spring Data JPA patterns (JpaRepository, custom queries) that are NOT mechanically derivable from the Quarkus `persistence-hibernate` module.

**Recommendation:** Keep hand-written. The Spring Data JPA patterns (derived queries, custom JPQL, entity scan configuration, RLS policy setup) are Spring-specific and can't be generated from the Quarkus counterpart. The existing code is correct and maintained. The verify goal of spring-generator can detect drift without replacing it.

## Issue #1211 — runtime-spring partial generation candidate

### Current state

25 files, mixed:
- **Generated** via `spring-generator` (scans runtime/) + `graphql-spring-generator` (scans api/)
- **Hand-written:**
  - `RuntimeManualConfig` (~770 lines) — massive bean registration for event handlers, orchestrators, routing evaluators
  - `SpringEventDispatcher` — ApplicationEventPublisher bridge for EventDispatcher SPI
  - 21 `*SpringAdapter` classes — event adapters bridging Spring ApplicationEvent to engine event handlers

### Assessment

After #1207 cleans runtime-core's CDI leaks:
- `RuntimeManualConfig`'s `notResolvable()` stubs become unnecessary (Instance<T> → List<T>)
- The generated portion should expand as more runtime beans become generatable
- The 21 event adapters remain hand-written (Spring event listener patterns are Spring-specific)

**Recommendation:** After #1207, re-run spring-generator verify to identify newly generatable beans. Shrink RuntimeManualConfig by moving generatable beans to the generated output. The event adapters stay hand-written.

## Issue #1095 — @McpDomain SPI migration

### Current state

@McpDomain annotations are on 6 concrete classes in `rest/`:
- `DefaultEngineCaseApi` → `engine/cases`
- `DefaultEngineCaseControlApi` → `engine/control`
- `DefaultEngineCaseDefinitionApi` → `engine/definitions`
- `DefaultEngineEventLogApi` → `engine/events`
- `DefaultEnginePlanApi` → `engine/plan`
- `EvolutionMcpAdapter` → `engine/evolution`

The `graphql-generator` APT is already wired in rest/ (REST generation, GraphQL disabled) and graphql/ (GraphQL generation, REST disabled).

### Migration

1. Define SPI interfaces in `api/` module:
   ```java
   @McpDomain(value = "engine/cases", app = "engine", summary = "...")
   @Path("/api/engine/cases")
   public interface EngineCaseApi { ... }
   ```

2. Move annotations from concrete classes to SPI interfaces. Annotation mapping (per #1095 — `@PlatformQuery`/`@PlatformMutation` are deprecated):

   | Current (concrete class) | Target (SPI interface) |
   |-------------------------|----------------------|
   | `@PlatformQuery` | `@GET` (jakarta.ws.rs) |
   | `@PlatformMutation` | `@POST` / `@PUT` / `@DELETE` (per HTTP semantics) |
   | `@PlatformStream` | Excluded from SPI — stays on concrete class (SSE is framework-specific) |
   | `@PathParam` (platform) | `@PathParam` (jakarta.ws.rs) |
   | `@Description` | `@Description` (unchanged) |

3. Concrete classes implement the SPI, losing their own annotations:
   ```java
   @ApplicationScoped
   public class DefaultEngineCaseApi implements EngineCaseApi { ... }
   ```

4. graphql-generator APT produces REST resources and GraphQL resolvers from SPIs

5. SSE/streaming endpoints (`@PlatformStream` / `Multi<T>` returns) stay on concrete classes — excluded from SPI interfaces. Stub implementations (`Multi.createFrom().empty()` in `caseLifecycle` and `caseContextChange`) should be removed rather than migrated.

6. `EvolutionMcpAdapter` is a trivial case — it already delegates to `EngineEvolutionApi` (in api/). Migration: move `@McpDomain("engine/evolution")` to the existing `EngineEvolutionApi` interface and delete the adapter class entirely.

### Pre-migration cleanup (from #1095)

- Type any `Map<String,Object>` returns as proper DTOs
- Extract business logic from resources to service layer where mixed

## Issue #1199 — rest-spring module

### Depends on

- #1095 (SPI interfaces must exist for generation)

### Solution

1. Extract `rest-core` with framework-neutral service POJOs (deferred from #1208 because rest/ depends on #1095 SPI interfaces)
2. Wire `rest-spring-generator` to scan SPI interfaces and generate Spring MVC @RestController classes
3. Wire `graphql-spring-generator` to generate Spring GraphQL @Controller classes
4. Hand-write:
   - @ControllerAdvice equivalents for 5 exception mappers
   - SseEmitter bridge for 3 SSE broadcasters (Multi<T> → SseEmitter)
   - `SpringWorkerScopeExtractor` implementation for CaseScopeExtractor (platform provides this SPI in `io.casehub.platform.acl.worker.spring` with `FailClosedSpringWorkerScopeExtractor` default — do NOT implement as a generic Filter/HandlerInterceptor)

### New module: engine-rest-spring

```
engine-rest-spring/
  src/main/java/
    io/casehub/engine/rest/spring/
      generated/          # rest-spring-generator output
      ExceptionHandlers.java  # hand-written @ControllerAdvice
      SseBridges.java         # hand-written SseEmitter adapters
      CaseScopeExtractor.java  # hand-written SpringWorkerScopeExtractor impl
```

## Testing strategy

Each issue has its own verification:

| Issue | Verification |
|-------|-------------|
| #1207 | Zero Quarkus/CDI imports in -core modules (`grep` enforcer or IDE search) |
| #1208 | Each -core module compiles independently with no CDI deps. spring-integration-test passes |
| #1209 | MCP tools visible in Spring Boot application context |
| #1210 | spring-generator verify goal confirms no drift (or hand-written acknowledged) |
| #1211 | RuntimeManualConfig shrunk, spring-generator verify shows expanded coverage |
| #1095 | SPI interfaces in api/, generated REST/GraphQL pass existing tests |
| #1199 | Spring REST controllers serve same endpoints, SSE works, exception mapping correct |

Cross-cutting: `spring-integration-test` must pass after each issue.

## References

- Platform Core Module Architecture table (CLAUDE.md)
- Platform spring-generator, rest-spring-generator, graphql-spring-generator, mcp-spring-generator documentation
- casehubio/engine#1095 body (annotation model, pre-migration cleanup)
- casehubio/engine#1199 body (REST gap analysis)
- casehubio/engine#1207 body (fix patterns by annotation type)
- casehubio/engine#1208 body (module prioritisation)
- Engine module survey (IDE search results, file reads)
