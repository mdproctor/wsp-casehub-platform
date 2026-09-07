# Decisions — Dual-Framework Core Extraction

## D1: Extraction scope

**Choice:** Full platform extraction — all modules, not just platform-view
**Alternatives:**
- Pattern + platform-view only — proves the pattern but doesn't address the root (@DefaultBean coupling in platform/)
- Pattern + platform-view + platform/ defaults — middle ground, proves the hardest pattern but leaves other modules untouched
**Rationale:** Pre-release platform where breaking changes cost nothing. Finding the roots means addressing the full coupling surface, not just one leaf module. The pattern must be proven comprehensively — partial extraction creates an inconsistent codebase where some modules are framework-neutral and others aren't.
**Trade-offs:** Scale increases from M to XL. Mechanical work is high but each module follows the same extraction pattern.
**Sources:** casehubio/parent#469 (epic), casehubio/platform#276 (issue), contributor-guide.md (three-layer model)
**Exploration:** quick
**Status:** captured

## D2: Module structure

**Choice:** POJO core + thin wiring modules — each module becomes: module/ (pure Java POJOs, constructor injection, no framework annotations), module-quarkus/ (CDI producers, event observers, @Scheduled wrappers), module-spring/ (auto-config, @EventListener, @Scheduled wrappers)
**Alternatives:**
- Rename existing to -quarkus, new -core — git history follows renames but artifact names change for both core and Quarkus
- Keep existing names, add -spring only — zero Quarkus consumer breakage but duplicates logic across framework modules
**Rationale:** @DefaultBean in a module without quarkus-arc is silently ignored (GE-20260615-c234fc). Framework wiring MUST live in separate modules. POJO core with thin wiring gives maximum code sharing — logic lives once, wiring is trivial boilerplate. No Quarkus goodness is lost: the -quarkus module uses full Arc features (@Produces, @DefaultBean, CDI events, @Scheduled), build-time optimization still applies.
**Trade-offs:** Module count increases (~2x for extracted modules). Each consumer needs to change dependency from module to module-quarkus.
**Sources:** GE-20260615-c234fc, GE-20260522-adb5cd, GE-20260604-81a6a6, PP-20260514-engine-spi-noops-defaultbean
**Exploration:** quick
**Status:** captured

## D3: Event handling strategy

**Choice:** A + C — pure I/O cores with typed callback interfaces for extractable modules; framework-specific implementations sharing utility logic for event-heavy modules
**Alternatives:**
- Platform EventBus abstraction in platform-api — leaky abstraction: CDI fire/fireAsync semantic split has no Spring equivalent. The caller controls sync/async in CDI; the observer controls it in Spring. Can't model cleanly.
- Core is pure I/O for ALL modules (no C) — forces extraction of modules whose purpose IS framework integration (notification-dispatch, subscriptions, streams), creating nearly-empty cores
**Rationale:** CDI events and Spring events have fundamentally different sync/async semantics — an abstraction over them would lie about the contract. Modules with separable logic (view, identity, governance, stores) benefit from core extraction. Modules whose purpose is event orchestration (notification-dispatch, subscriptions, streams, mcp) benefit from framework-specific implementations that share pure utility classes.
**Trade-offs:** Two categories of modules with different extraction strategies adds cognitive load. The "C" modules still need dual implementations for the orchestration layer.
**Sources:** GE-20260605-373190, GE-20260531-e1ce47, GE-20260423-daef97, GE-20260517-a6d608, GE-20260515-99cf39
**Exploration:** deep-analysis
**Depends on:** D2 (module structure)
**Status:** captured

## D4: Consumer dependency management

**Choice:** Swap artifact names — consumers change from module to module-quarkus (or module-spring). The -quarkus/-spring module transitively pulls in the core. One dependency declaration per consumer.
**Alternatives:**
- BOM-managed auto-selection — more machinery, zero consumer breakage, but hides the framework dependency graph
- Keep current names for Quarkus, add -spring only — asymmetric naming, zero Quarkus disruption but inconsistent architecture
**Rationale:** Pre-release platform — breaking changes cost nothing. Mechanical find-replace in consumer pom.xml files. Clean, consistent naming. Consumers see explicitly which framework they're using.
**Trade-offs:** Every consumer repo needs pom.xml updates. But these are the same repos that the epic targets (engine, work, qhorus, ledger, eidos, neocortex, blocks, connectors) — they'll be touched anyway.
**Sources:** casehubio/parent#469 (epic child issues)
**Exploration:** quick
**Depends on:** D2 (module structure)
**Status:** captured

## D5: CDI pattern mappings

**Choice:** Direct mechanical mappings for each CDI pattern — no abstraction layers
**Alternatives:**
- Abstract each pattern behind a platform interface — adds unnecessary abstraction for patterns that have well-known framework equivalents
**Rationale:** Each CDI pattern has a well-known Spring equivalent. No abstraction needed — the framework modules use their native patterns at full fidelity.

| CDI Pattern | Core Module | Quarkus Module | Spring Module |
|---|---|---|---|
| @DefaultBean no-op | Plain POJO | @Produces @DefaultBean | @Bean @ConditionalOnMissingBean |
| @ApplicationScoped service | Constructor-injected POJO | @Produces @ApplicationScoped | @Bean |
| @Alternative @Priority(N) | Plain POJO | @Produces @Alternative @Priority(N) | @Bean @ConditionalOnMissingBean + @Primary or @Order |
| @Inject Instance<T> | Constructor param: List<T> or Optional<T> | Resolved from Instance<T> | Resolved from ObjectProvider<T> |
| @Observes / @ObservesAsync | Method called by framework adapter | CDI observer delegates to core | @EventListener delegates to core |
| @Scheduled | Method called by framework adapter | @Scheduled delegates to core | @Scheduled delegates to core |
| @ConfigProperty | Constructor param | @ConfigProperty injected, passed to constructor | @Value or @ConfigurationProperties, passed to constructor |
| PanacheEntityBase | Standard JPA @Entity | Can extend with Panache if desired | Spring Data JPA repository |
| Event.fire() / fireAsync() | Consumer<T> callback | CDI Event<T> provided at construction | ApplicationEventPublisher provided at construction |

**Trade-offs:** None significant. Each mapping is well-established in both ecosystems.
**Sources:** PP-20260518-platform-spi-contract, PP-20260514-engine-spi-noops-defaultbean, alternative-extension-patterns.md
**Exploration:** quick
**Status:** captured
