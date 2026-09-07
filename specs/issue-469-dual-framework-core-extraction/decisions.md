# Decisions — Dual-Framework Core Extraction

## D1: Extraction scope

**Choice:** Full platform extraction — all modules with CDI coupling whose business logic is separable from framework entry points. Already framework-neutral modules (platform-api, yaml-core, ts-core, yaml-jackson, agent-api, datasource-alpha) retain their current structure. "C"-classified modules (see D3) receive framework-specific implementations sharing utility logic, not core extraction.
**Alternatives:**
- Pattern + platform-view only — proves the pattern but doesn't address the root (@DefaultBean coupling in platform/)
- Pattern + platform-view + platform/ defaults — middle ground, proves the hardest pattern but leaves other modules untouched
- Threshold-based extraction (only modules with ≥ N CDI-coupled beans) — risks inconsistent codebase; the threshold is arbitrary
**Classification criteria:** A module qualifies for core extraction ("A" category) when it has ≥1 CDI-coupled bean whose business logic is separable from its CDI entry points (observers, scheduled methods, producers). Already-neutral modules (zero CDI, zero JPA) need no extraction — they are already cores. Persistence modules (-jpa, -mongodb) remain Tier 3 — their entities and wiring are inherently framework-specific. In-memory modules (-inmem) are thin CDI wiring and do not warrant separate core extraction. CDI @Decorator modules qualify for A classification when the decorator pattern (delegate wrapping) is expressible via constructor injection — the business logic (e.g. rate limiting, gating) is separable from the CDI decorator mechanism.
**Rationale:** Pre-release platform where breaking changes cost nothing. Finding the roots means addressing the full coupling surface, not just one leaf module. The pattern must be proven comprehensively — partial extraction creates an inconsistent codebase where some modules are framework-neutral and others aren't.
**Trade-offs:** Scale increases from M to XL. Mechanical work is high but each module follows the same extraction pattern.
**Sources:** casehubio/parent#469 (epic), casehubio/platform#276 (issue), contributor-guide.md (three-layer model)
**Exploration:** quick
**Status:** revised — reconciled D1 scope with D3's A/C classification; added classification criteria; excluded already-neutral and persistence modules; added @Decorator classification rule

## D2: Module structure

**Choice:** Core extraction with preserved Quarkus names — each extracted module becomes: module-core/ (pure Java POJOs, constructor injection, no CDI or Spring annotations), module/ (existing artifact name retained — CDI producers, event observers, @Scheduled wrappers, depends on module-core), module-spring/ (auto-config, @EventListener, @Scheduled wrappers, depends on module-core)
**Alternatives:**
- Rename existing to module/ (core) and add module-quarkus/ + module-spring/ — clean symmetry but every Quarkus consumer must update dependency declarations
- Keep existing names, add -spring only — zero Quarkus consumer breakage but duplicates logic across framework modules
**Rationale:** @DefaultBean in a module without quarkus-arc is silently ignored (GE-20260615-c234fc). Framework wiring MUST live in separate modules. POJO core with thin wiring gives maximum code sharing — logic lives once, wiring is trivial boilerplate. Preserving existing artifact names for Quarkus modules means zero consumer disruption — each consumer continues to depend on the same artifact, which now transitively pulls in the core. The -core suffix convention is universally understood and accurately names the new module.
**NoOp placement:** NoOp implementations (NoOpAccessControlProvider, NoOpNotificationStore, etc.) are plain POJOs in the core module — their logic (returning empty lists, no-op method bodies) has no framework dependency. Framework wiring modules produce them: Quarkus via @Produces @DefaultBean, Spring via @Bean @ConditionalOnMissingBean. NoOp logic is written once, wired once per framework.
**JPA entities:** JPA @Entity classes remain in existing -jpa persistence modules (Tier 3). "No CDI or Spring annotations" applies to the core; JPA entities are not extracted into cores.
**Trade-offs:** Module count increases (~1.5x for extracted modules: new -core + new -spring). Quarkus consumers require no pom.xml changes. Asymmetry in naming (-core vs no suffix for Quarkus) reflects the asymmetry in the migration: Quarkus is the existing framework, Spring is the new addition.
**Sources:** GE-20260615-c234fc, GE-20260522-adb5cd, GE-20260604-81a6a6, PP-20260514-engine-spi-noops-defaultbean
**Exploration:** quick
**Depends on:** D1 (extraction scope)
**Status:** revised — naming changed from module/module-quarkus/module-spring to module-core/module/module-spring; NoOp placement clarified; JPA entity placement clarified

## D3: Event handling strategy

**Choice:** A + C hybrid — pure I/O cores with typed callback interfaces for extractable modules; framework-specific implementations sharing utility logic for event-heavy orchestration modules (subscriptions, streams, mcp)
**Alternatives:**
- Platform EventBus abstraction in platform-api — unnecessary abstraction: the platform has standardised on fireAsync(), and Consumer<T> callbacks are simpler and more testable than any EventBus
- Core is pure I/O for ALL modules (no C) — forces extraction of modules whose purpose IS framework integration (subscriptions, streams, mcp), creating nearly-empty cores
**Category assignments:**
- **A (core extraction):** view, identity, governance, stores, notification-dispatch, expression, agent-gate, platform/ defaults
- **C (framework-specific with shared utility):** subscriptions (4x @ObservesAsync + 1x @Observes StartupEvent + alpha network CDI integration + CDI event firing), streams-* (connector-specific framework binding), mcp (GraphQL model scanning + CDI startup)
**Rationale:** Consumer<T> callbacks are simpler and more testable than any EventBus abstraction — they require no framework at all. notification-dispatch was reclassified from C to A: its CDI coupling (2 async observers + 2 scheduled jobs) is structurally identical to other A modules, and its business logic (target resolution, suppression evaluation, channel routing, delivery retry, digest flushing) is cleanly separable from the 4 CDI entry points. The previous rationale based on the sync/async semantic gap between CDI and Spring events was overstated — the platform uses fireAsync() uniformly (only 1 synchronous fire() call exists in GraphQLModelScanner across the entire codebase). The stronger argument for callbacks over an EventBus is simplicity.
**Trade-offs:** Two categories of modules with different extraction strategies adds cognitive load. The "C" modules still need dual implementations for the orchestration layer.
**Sources:** GE-20260605-373190, GE-20260531-e1ce47, GE-20260423-daef97, GE-20260517-a6d608, GE-20260515-99cf39
**Exploration:** deep-analysis
**Depends on:** D2 (module structure)
**Status:** revised — notification-dispatch reclassified from C to A; agent-gate added to A list; subscriptions observer count corrected to 4x @ObservesAsync + 1x @Observes StartupEvent; rationale corrected from sync/async gap to simplicity

## D4: Consumer dependency management

**Choice:** Zero-change for Quarkus consumers — existing artifact names are preserved (see D2), so Quarkus consumers continue to depend on the same artifacts, which now transitively include the core. Spring consumers explicitly depend on module-core + module-spring.
**Alternatives:**
- BOM-managed auto-selection — adds machinery unnecessary for Quarkus (zero change already); potentially useful for Spring dependency management
- Swap artifact names (original D4) — consumers change from module to module-quarkus; unnecessary with preserved naming
**Rationale:** The revised naming in D2 eliminates the need for Quarkus consumer pom.xml updates entirely. Spring is a new addition to the platform — there are no existing Spring consumers to break. Spring consumers add explicit dependencies, making their framework choice visible in the pom.xml.
**Trade-offs:** Asymmetric — Quarkus consumers get zero-change, Spring consumers are explicit. This reflects the reality that Quarkus is the established framework and Spring is being added.
**Sources:** casehubio/parent#469 (epic child issues)
**Exploration:** quick
**Depends on:** D2 (module structure)
**Status:** revised — simplified from artifact-name swap to zero-change for Quarkus, following D2's naming revision

## D5: CDI pattern mappings

**Choice:** Direct mechanical mappings for each CDI pattern — no abstraction layers
**Alternatives:**
- Abstract each pattern behind a platform interface — adds unnecessary abstraction for patterns that have well-known framework equivalents
**Rationale:** Each CDI pattern has a well-known Spring equivalent. No abstraction needed — the framework modules use their native patterns at full fidelity.

| CDI Pattern | Core Module | Quarkus Module | Spring Module |
|---|---|---|---|
| @DefaultBean no-op | Plain POJO (in core) | @Produces @DefaultBean | @Bean @ConditionalOnMissingBean |
| @ApplicationScoped service | Constructor-injected POJO | @Produces @ApplicationScoped | @Bean via @AutoConfiguration |
| @Alternative @Priority(N) | Plain POJO | @Produces @Alternative @Priority(N) | @AutoConfiguration + @ConditionalOnClass for activation; @Primary for preference (see detail below) |
| @Decorator @Priority(N) | POJO with delegate constructor param | @Decorator @Delegate @Any | @Bean @Primary wrapping the delegate (see detail below) |
| @Inject Instance<T> | Constructor param: List<T> or Optional<T> | Collected from Instance<T> | Collected from ObjectProvider<T> |
| @Observes / @ObservesAsync | Method called by framework adapter | CDI observer delegates to core | @EventListener delegates to core |
| @Scheduled | Method called by framework adapter | @Scheduled delegates to core | @Scheduled delegates to core |
| @ConfigProperty | Constructor param | @ConfigProperty injected, passed to constructor | @Value or @ConfigurationProperties, passed to constructor |
| PanacheEntityBase (in -jpa modules) | Stays in persistence module as standard JPA @Entity | Can extend with PanacheEntityBase | Spring Data JPA repository |
| Event.fire() / fireAsync() | Consumer<T> callback | CDI Event<T> provided at construction | ApplicationEventPublisher provided at construction |

**@Alternative @Priority mapping — Spring activation principle:** Spring -spring modules use Spring Boot auto-configuration for classpath-activated bean registration — analogous to CDI's classpath scanning. Each -spring module ships an @AutoConfiguration class registered via META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports. The CDI three-tier priority ladder maps as follows:

| CDI Tier | CDI Mechanism | Spring Mechanism |
|---|---|---|
| @DefaultBean (fallback) | Yields to any bean | @Bean @ConditionalOnMissingBean in base auto-config |
| @ApplicationScoped (production default) | Classpath-presence activation | @AutoConfiguration + @ConditionalOnClass in module auto-config |
| @Alternative @Priority(1..N) (opt-in override) | Classpath-presence + numeric priority | @AutoConfiguration ordering via @AutoConfigureBefore/@AutoConfigureAfter + @Primary |
| @Alternative @Priority(200) (test override) | Test classpath + highest priority | @TestConfiguration with explicit @Bean overrides |

**@Decorator mapping detail:** CDI's @Decorator provides automatic delegate binding via @Delegate @Inject. The core POJO expresses the same pattern via constructor injection: takes a delegate instance, wraps it. The Quarkus module uses @Decorator for automatic delegate binding. The Spring module uses @Bean @Primary that takes the original bean as a constructor parameter and wraps it — or Spring AOP @Around advice for cross-cutting concerns. Example: GatedAgentProvider's core is a POJO wrapping an AgentProvider delegate with admission strategies; CDI's @Decorator provides the delegate automatically; Spring provides it via @Bean method parameter injection.
**Trade-offs:** The @Alternative @Priority mapping is the most complex — @AutoConfiguration ordering is less granular than CDI's numeric priorities. The @Decorator mapping requires one @Bean method per decorator in Spring vs automatic binding in CDI.
**Sources:** PP-20260518-platform-spi-contract, PP-20260514-engine-spi-noops-defaultbean, alternative-extension-patterns.md
**Exploration:** quick
**Status:** revised — @Alternative @Priority mapping corrected with Spring auto-configuration activation principle; @Decorator mapping row added; PanacheEntityBase row clarified to show entities stay in persistence modules

## D6: Testing strategy

**Choice:** Three-tier testing aligned with module structure — core modules tested with pure JUnit 5, framework wiring modules tested with their native test frameworks
**Alternatives:**
- Shared abstract test suite with framework-specific runners — higher coupling between test modules; test infrastructure becomes a third axis of complexity
- Test only at the integration level (always @QuarkusTest / @SpringBootTest) — loses the benefit of fast, container-free unit tests for business logic
**Rationale:** The whole point of core extraction is that business logic becomes framework-free. Testing should reflect this: core modules are plain Java, tested with plain JUnit. Constructor-injected POJOs need no DI container — instantiate directly, pass mocks or test doubles.
**Testing plan:**
- **Core modules:** Pure JUnit 5. Construct POJOs directly. Use test doubles (hand-written or Mockito) for SPI dependencies. No DI container. Fast.
- **Quarkus wiring modules:** @QuarkusTest with core on classpath. Existing test infrastructure (testing/ module with @Alternative @Priority(200) fixtures) works unchanged.
- **Spring wiring modules:** @SpringBootTest with core on classpath. A new spring-testing module provides equivalent fixtures (@TestConfiguration overrides).
- **Contract tests:** Existing contract tests test the SPI interface, not the wiring. They run against core implementations directly — no framework needed. Both framework variants satisfy the same contract by delegating to the same core.
- **CI:** Both Quarkus and Spring test suites run in CI. Spring modules added to the Maven reactor.
**Trade-offs:** Spring wiring modules need a parallel test infrastructure (spring-testing module). This is one-time setup — the fixtures are thin wiring around the same NoOp POJOs already in the core.
**Sources:** PP-20260512-module-tiers (testing guidance), existing testing/ module pattern
**Exploration:** implicit decision surfaced by reviewer
**Depends on:** D7 (Spring framework choice)
**Status:** captured

## D7: Spring framework choice

**Choice:** Spring Boot 3.x — auto-configuration for classpath-activated bean registration, opinionated dependency management, Jakarta EE namespace compatibility with Quarkus 3.x
**Alternatives:**
- Plain Spring Framework (no Boot) — requires explicit @Import on every consumer; no auto-configuration; loses the CDI-analogous classpath activation model. More configuration friction, no architectural benefit.
- Spring Boot 2.x — javax namespace, incompatible with Quarkus 3.x's Jakarta migration. Not viable.
**Rationale:** Spring Boot auto-configuration is the Spring-side equivalent of CDI's classpath-scanning bean discovery. Each -spring module ships an @AutoConfiguration class that registers beans when the module is on the classpath — the same "drop the jar on the classpath and it activates" model that CDI provides. Spring Boot 3.x uses the Jakarta namespace (jakarta.inject, jakarta.persistence), ensuring the core module's Jakarta annotations are compatible with both Quarkus and Spring consumers. Plain Spring Framework would require every consumer to explicitly @Import every module's configuration — the same friction as manual CDI bean.xml registration.
**BOM integration:** casehub-parent BOM imports spring-boot-dependencies as a managed BOM (<scope>import</scope> in <dependencyManagement>). This ensures consistent Spring Boot versions across all -spring modules without requiring each module to specify versions. The Spring Boot version is managed in one place (casehub-parent).
**Test dependency:** spring-boot-starter-test is test-scoped in each -spring module's pom.xml. The spring-testing module aggregates platform-specific test fixtures (@TestConfiguration overrides for NoOp POJOs) but does not re-export the test framework itself.
**Trade-offs:** Spring Boot brings opinionated auto-configuration that may conflict with Quarkus in mixed-classpath scenarios — but this is prevented by the module separation (a consumer uses either -quarkus or -spring modules, never both).
**Sources:** D5 (CDI pattern mappings), D6 (testing strategy)
**Exploration:** implicit decision surfaced by reviewer
**Status:** captured
