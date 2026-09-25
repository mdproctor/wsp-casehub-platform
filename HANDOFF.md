# HANDOFF — Slot 198

## Last Session

Completed blocks#297 — Spring coverage expansion for casehub-blocks. Added 20 missing bean definitions to BlocksAutoConfiguration (11 config defaults, EventStreamBus, SubjectResolver, InteractionMapper, NormFilter, ModelPreferenceSignalProvider, 3 prompt optimisation defaults). Fixed NoOpNarrativeStore bean ordering bug — moved after CbrNarrativeStore with @ConditionalOnMissingBean(NarrativeStore.class) so the no-op only creates when no real store exists. Created spring-integration-test module (7 tests, all green). Updated consumer guide with Spring Boot section.

Advanced queue to workers#24. Ran full CDI audit of workers repo (40 beans across 8 modules). Audit revealed workers#24 is M/Med, not S/Low — deep Vert.x coupling makes this fundamentally different from the other repos in the campaign.

## Slot State

Seven repos complete. One repo in progress, one repo remaining.

| Repo | Spring Status | Branch |
|------|--------------|--------|
| platform | Complete | — |
| engine | Complete | — |
| work | Complete | — |
| qhorus | Complete | — |
| neocortex | Complete | — |
| ledger | Complete | — |
| casehub-worker | Complete | `issue-16-spring-boot-deployment` (not yet merged) |
| blocks | **Complete** | `issue-297-spring-coverage-expansion` (not yet merged) |
| **workers** | Not started | — |

## What's Next: workers#24 — Investigation Required

workers#24 (Spring Boot deployment) needs a brainstorm before implementation. The audit surfaced 13 Quarkus/Vert.x-specific patterns that don't have trivial Spring equivalents. This section explains what needs investigating and why.

### Why workers is different from the other repos

Every other repo in the campaign (platform, engine, work, qhorus, neocortex, ledger, casehub-worker, blocks) followed the same pattern: extract CDI-free POJOs into a `-core` module, then write a Spring `@AutoConfiguration` that wires them. This worked because those repos used CDI primarily for dependency injection — the business logic was already framework-neutral.

Workers is different. It uses **Vert.x EventBus as an architectural pattern** — the fault pipeline, completion notifications, and retry dispatch all route through `eventBus.publish()` and `@ConsumeEvent`. This isn't just DI; it's an event-driven architecture baked into the wiring.

### The 5 design questions that need answers

**1. How to replace Vert.x EventBus fault routing?**

Workers-common has `WorkerFaultPublisher` and `WorkerRetrySupport` that use `eventBus.publish(faultAddress, event)` to route faults to per-worker-type fault handlers. Each worker module has a `*FaultEventHandler` with `@ConsumeEvent(address, blocking=true)`. In Spring, the options are:
- `ApplicationEventPublisher` + `@EventListener` — but lacks address-based routing (all listeners see all events)
- Direct method calls via a `Map<String, Consumer>` registry — simpler but loses the decoupled architecture
- Spring Integration channels — overkill for internal routing

The fault address routing is central: `CAMEL_WORKER_FAULT`, `HTTP_WORKER_FAULT`, etc. Each worker type has its own address to prevent cross-talk. The Spring translation needs to preserve this isolation.

**2. How to replace Vert.x WebClient?**

Four execution managers (HTTP, GitHub Actions, MCP, Scenario) use Vert.x `WebClient` for reactive HTTP dispatch. Options:
- Spring `WebClient` (reactive, from WebFlux) — close equivalent but adds a WebFlux dependency
- Spring `RestClient` (blocking) — simpler, but workers use reactive patterns (`Uni`, `emitOn`)
- `java.net.http.HttpClient` (JDK) — zero-dep, but manual async handling

The choice affects whether workers-core needs Mutiny or can be fully framework-neutral.

**3. How to translate @WorkerBackend CDI qualifier?**

All `WorkerExecutionManager` implementations are annotated `@WorkerBackend @Priority(10)`. The engine's `CompositeWorkerExecutionManager` discovers them via `Instance<WorkerExecutionManager>` filtered by this qualifier. In Spring:
- `@Qualifier("workerBackend")` on each bean + `List<WorkerExecutionManager>` injection
- Custom `@ConditionalOnClass` per worker type
- `ObjectProvider<WorkerExecutionManager>` with naming convention

This affects engine-spring too — `CompositeWorkerExecutionManager` needs to discover Spring-provided backends.

**4. How to handle @ConsumeEvent(blocking=true)?**

The 7 fault event handlers each consume from a specific Vert.x event bus address. The `blocking=true` flag runs them on the worker pool, not the event loop. In Spring:
- `@EventListener` on typed events (one event class per worker type)
- `@Async @EventListener` for non-blocking (but fault handlers ARE blocking intentionally — they do retries)

The event type hierarchy needs designing: currently it's address-based (string), Spring would use typed events.

**5. What scope is realistic for a single session?**

40 beans across 8 modules. Two approaches:
- **All at once** — one `-core` module per worker type, one consolidated `workers-spring` auto-config. Large but complete.
- **workers-common first** — extract the shared infrastructure (fault pipeline, completion registry, lifecycle orchestrator), then individual worker types in subsequent sessions.

workers-common is the foundation — all other modules depend on it. Starting there gives the most leverage.

### Audit data (for reference)

| Module | Beans | @ConsumeEvent | EventBus | @ConfigProperty | @WorkerBackend |
|--------|-------|---------------|----------|-----------------|----------------|
| workers-common | 9 | 0 | 2 (publish) | 0 | 0 |
| workers-http | 4 | 1 | 0 | 2 | 1 |
| workers-camel | 5 | 1 | 0 | 1 | 1 |
| workers-github-actions | 4 | 1 | 0 | 3 | 1 |
| workers-mcp | 5 | 1 | 0 | 1+ | 1 |
| workers-script | 4 | 1 | 0 | 2 | 1 |
| workers-k8s | 5 | 1 | 0 | 3+ | 1 |
| workers-scenario | 4 | 1 | 0 | 2 | 1 |

### Known issues from this session

- casehub-worker branch `issue-16-spring-boot-deployment` still needs work-end (merge, squash, push)
- blocks branch `issue-297-spring-coverage-expansion` needs work-end (merge, squash, push)
- blocks `NarrativePipeline` takes `CbrNarrativeStore` (concrete type) — prevents co-deployment with social-spring-jpa until constructor is widened to `NarrativeStore` interface
- blocks `SocialCognitionDefaultBeans` in blocks-core still has CDI annotations — cleanup needed
- blocks-core has pre-existing compilation errors (missing `CognitiveEmotion` from neocortex cognitive-index — installed manually this session but not committed)
- platform#430 still open (spring-generator @DefaultBean interface instantiation bug)
