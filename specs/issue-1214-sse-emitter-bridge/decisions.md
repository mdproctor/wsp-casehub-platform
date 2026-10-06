# Decisions — issue-1214-sse-emitter-bridge

## D1: Stream return type in SPI interfaces

**Choice:** `Flow.Publisher<T>` (pure Java)
**Alternatives:**
- `Multi<T>` (SmallRye Mutiny) — keeps SPI unchanged but couples api module to Quarkus runtime
- `Flux<T>` (Project Reactor) — couples SPI to Spring instead of Quarkus
**Rationale:** Flow.Publisher is the JDK standard reactive type. Both Mutiny Multi and Reactor Flux adapt to/from it. The rest-spring-generator already has a Flow.Publisher→SseEmitter bridge. Removes Quarkus coupling from the api module.
**Trade-offs:** Requires updating all SPI callers — Quarkus implementations wrap Multi via `multi.convert().toPublisher()`, Spring implementations wrap their own mechanism.
**Sources:** EngineCaseApi.java, EnginePlanApi.java, RestControllerWriter.java (rest-spring-generator Flow.Publisher bridge), SpringDomainRestControllerWriter.java (graphql-spring-generator Multi bridge)
**Exploration:** quick
**Status:** captured

## D2: Spring broadcaster location

**Choice:** `runtime-spring/` module
**Alternatives:**
- `rest-core/` (new module) — cleaner separation but more churn for a straightforward bridging task
- Inline in SPI impl — mixes event listening and subscriber management concerns
**Rationale:** Matches the existing adapter pattern in runtime-spring/ (21 event adapter classes already). Hand-written @EventListener beans that maintain subscriber registries.
**Trade-offs:** Broadcaster logic is duplicated between Quarkus (rest/) and Spring (runtime-spring/) — acceptable because the framework wiring is fundamentally different.
**Sources:** CaseContextChangedSpringAdapter.java, RuntimeManualConfig.java
**Exploration:** quick
**Status:** captured

## D3: EvolutionStreamBroadcaster scope

**Choice:** Include proactively
**Alternatives:**
- Defer — only bridge the 2 broadcasters with active SPI consumers
**Rationale:** Same pattern as the other two. Low marginal effort. Ready when EvolutionApi SPI is created for the command centre conductor (#1132).
**Trade-offs:** No active consumer yet — the Spring broadcaster will sit unused until the EvolutionApi SPI exists.
**Sources:** git log 3e5f34336, GitHub issue casehubio/engine#1132
**Exploration:** quick
**Depends on:** D2
**Status:** captured
