# Dual-Framework Core Extraction — Design Spec

**Issue:** casehubio/platform#276 (child of casehubio/parent#469)
**Branch:** issue-469-dual-framework-core-extraction
**Date:** 2026-09-07
**Status:** Approved

## Goal

Extract framework-neutral cores from all CDI-coupled platform modules so that
casehub infrastructure can run on both Quarkus and Spring Boot. Existing Quarkus
consumers see zero breakage — all current artifact names preserved.

## Architecture

Every CDI-coupled module splits into three Maven artifacts:

```
module-core/     <- pure Java: POJOs, constructor injection, zero annotations
module/          <- existing artifact name: CDI producers, observers, @Scheduled
module-spring/   <- new: Spring Boot auto-configuration, @EventListener, @Scheduled
```

The core module contains all business logic. Framework modules are thin wiring
that creates beans, observes events, and delegates to core POJOs. The existing
Quarkus module depends on the new core module — consumers continue to depend on
the same artifact, which now transitively includes the core.

```
Consumer pom.xml (Quarkus — unchanged):
  <dependency>
    <artifactId>casehub-platform-view</artifactId>   <- same as today
  </dependency>

Consumer pom.xml (Spring — new):
  <dependency>
    <artifactId>casehub-platform-view-core</artifactId>
  </dependency>
  <dependency>
    <artifactId>casehub-platform-view-spring</artifactId>
  </dependency>
```

### Dependency Flow

```
platform-api (pure Java SPIs — unchanged)
       |
module-core (pure Java POJOs — new)
      / \
module    module-spring
(Quarkus)  (Spring Boot)
```

Both framework modules depend on the core. Neither depends on the other.
The core depends only on platform-api and standard Java libraries.

## Module Classification

### Category N — Already Framework-Neutral (no change)

| Module | Reason |
|--------|--------|
| platform-api | Zero-dep pure Java SPIs |
| datasource-alpha | Pure runtime, no CDI |
| graphql | Pure types (scalar, pagination) |
| graphql-generator | APT annotation processor |
| callback-api | Pure Java records and SPIs |
| callback-generator | APT annotation processor |
| agent-api | Pure Java SPIs + Mutiny |
| schema-generator | victools JSON Schema, no runtime coupling |
| yaml-core | Zero deps, J2CL-transpilable |
| yaml-jackson | Jackson mixins only |
| yaml-codegen | Maven plugin, build-time only |
| ts-core | TypeScript module |

### Category A — Core Extraction

Each module gets a new `-core` artifact (pure Java POJOs) and a new `-spring`
artifact (Spring Boot auto-configuration). The existing Quarkus module retains
its artifact name and depends on the core.

**Platform defaults:**

| Module | Core Contents | Quarkus Wiring | Spring Wiring |
|--------|--------------|----------------|---------------|
| platform | NoOp POJOs (NoOpCaseMemoryStore, MockCurrentPrincipal, etc.) | @Produces @DefaultBean for each NoOp | @Bean @ConditionalOnMissingBean for each NoOp |

**Services and orchestration:**

| Module | Core Contents | CDI Entry Points (stay in Quarkus module) |
|--------|--------------|-------------------------------------------|
| platform-view | SubjectViewEvaluator, SubjectViewOrchestrator (constructor-injected POJOs) | @Produces for beans, event observers |
| notification-dispatch | TargetResolver, SuppressionEvaluator, ChannelRouter, DigestFlushScheduler logic, DeliveryTracker, DeliveryRetryProcessor logic, TemplateResolver, EngagementRecorder logic | 2x @ObservesAsync, 2x @Scheduled |
| notifications | NotificationPushService logic | REST endpoints, CDI event observers |
| expression | DefaultExpressionEngineRegistry, MvelExpressionEngine, JQExpressionEngine, MockSecretManager, MockConfigManager | @Produces for engines, @DefaultBean for mocks |
| identity | CompositeDIDResolver, WebDIDResolver, KeyDIDResolver, CompositeActorDIDProvider, JwtVCValidator, ScimAgentLookup, CdiPriorityUtils | @Produces with @DIDMethod qualifiers |
| governance | DefaultPolicyEnforcer (virtual thread executor) | @Produces @ApplicationScoped |
| config | Scope-aware YAML parsing logic | @Startup endpoint loading |
| platform-signing | DssDocumentSigningService, DssDocumentVerificationService, KeyStoreManager, TenantKeyStoreResolver, TrustedListManager, CertificateExpiryMonitor logic | @Scheduled cert monitor, @Produces |
| platform-pdf | OpenHTMLtoPDF PdfGenerator | @Produces @ApplicationScoped |
| preferences-editor | REST logic, InMemoryPreferenceSchemaRegistry | @Produces, REST endpoint wiring |
| callback | CallbackInvoker (HTTP POST + retry), LeaseReaper logic | @Scheduled lease reaper, REST endpoint |
| acl-admin | ACL REST logic | @RunOnVirtualThread REST endpoints |
| acl-worker | WorkerCredentialFilter logic, FailClosedWorkerScopeExtractor | JAX-RS @Provider registration |
| agent-router | RoutingAgentProvider dispatch logic | @Produces with Instance<AgentBackend> |
| agent-gate | Rate limiter + semaphore logic (POJO with delegate param) | CDI @Decorator @Priority(2000) |
| agent-runtime | SubprocessRuntime (Process wrapper) | @Produces @ApplicationScoped |
| agent-claude | ClaudeAgentProvider + ClaudeAgentClient logic | @Produces @Startup |
| agent-openai | OpenAiAgentBackend logic | @Produces @ApplicationScoped |
| agent-gemini | GeminiAgentBackend logic | @Produces @ApplicationScoped |
| agent-codex | CodexAgentBackend logic | @Produces @ApplicationScoped |
| agent-gemini-cli | GeminiCliAgentBackend logic | @Produces @ApplicationScoped |
| agent-langchain4j | ChatModelAgentProvider, AgentProviderChatModel | @Produces @DefaultBean |
| scim | SCIM GroupMembershipProvider (REST client) | @Produces @ApplicationScoped, @CacheResult |
| delivery-channel-inmem | InMemoryDeliveryChannelRegistry | @Produces @ApplicationScoped |

**In-memory stores (annotation-only coupling — lightweight extraction):**

In-memory stores are thin ConcurrentHashMap wrappers with CDI annotations. The
extraction is trivially mechanical: remove annotations, the class becomes a POJO.
These follow the same -core/-spring pattern for consistency, but the -core modules
are single-class JARs. During implementation planning, adjacent in-memory stores
may be grouped into a shared core where it reduces module count without violating
the single-responsibility principle.

| Module | Core Contents |
|--------|--------------|
| platform-view-inmem | InMemorySubjectViewStore, InMemoryCrossTenantSubjectViewStore, InMemoryViewMembershipTracker, InMemorySubjectViewQuerySupport |
| notifications-inmem | InMemoryNotificationStore |
| notification-settings-inmem | InMemoryNotificationPreferenceStore, InMemorySuppressionStore |
| subscriptions-inmem | InMemorySubscriptionStore |
| delivery-tracking-inmem | InMemoryDeliveryAttemptStore |
| digest-inmem | InMemoryDigestBuffer |
| callback-inmem | InMemoryCallbackRegistry |
| acl-inmem | InMemoryAccessControlProvider |
| datasource-inmem | InMemoryDataSourceRegistry |
| endpoints-memory | InMemoryEndpointRegistry |
| memory-inmem | InMemoryCaseMemoryStore |

**JPA/persistence stores:**

JPA @Entity classes and Panache usage remain in the existing persistence modules
(Tier 3). These are NOT extracted into cores — JPA entities are inherently tied
to their persistence framework. The store logic (queries, transactions) stays
in the persistence module.

| Module | Stays As-Is |
|--------|-------------|
| platform-view-jpa | JPA store + PanacheEntityBase entities |
| persistence-jpa | JPA PreferenceProvider |
| persistence-mongodb | MongoDB PreferenceProvider |
| notifications-jpa | JPA NotificationStore + Panache + @Scheduled purge |
| notification-settings-jpa | JPA stores + Panache + @Scheduled purge |
| subscriptions-jpa | JPA SubscriptionStore |
| delivery-tracking-jpa | JPA DeliveryAttemptStore + Panache + @Scheduled purge |
| digest-jpa | JPA DigestBuffer + Panache |
| acl-jpa | JPA AccessControlProvider + Panache + @Scheduled purge |
| memory-jpa | JPA CaseMemoryStore |
| memory-sqlite | SQLite CaseMemoryStore |
| memory-mem0 | Mem0 REST CaseMemoryStore |
| memory-graphiti | Graphiti REST GraphCaseMemoryStore |

For Spring Boot consumers, equivalent Spring Data JPA or JDBC modules will be
needed — these are separate issues in the epic, not part of this extraction.

### Category C — Framework-Specific with Shared Logic

These modules have framework integration as their primary purpose. Each gets
parallel framework implementations that share pure utility classes.

| Module | Why C | Shared Logic | Framework-Specific |
|--------|-------|-------------|-------------------|
| subscriptions | 4x @ObservesAsync + alpha network CDI integration + CDI event firing | Filter compilation, event type matching | CDI event orchestration / Spring event orchestration |
| streams-kafka | Reactive Messaging @Incoming | CloudEvent building from descriptors | Kafka channel binding |
| streams-amqp | AMQP channel ingestion | Message processing | AMQP binding |
| streams-webhook | JAX-RS + CloudEvents HTTP binding | CloudEvent parsing | Web framework binding |
| streams-poll | @Scheduled HTTP GET poller | HTTP polling logic | Scheduler binding |
| streams-camel | Camel route builder + @Observes | Route configuration | Camel lifecycle |
| mcp | CDI BeanManager scanning + @Observes ModelScanComplete | Domain content formatting, schema building | CDI bean discovery / Spring bean scanning |
| oidc | Quarkus SecurityIdentity | None — inherently Quarkus | Spring Security equivalent |
| credentials-quarkus | Quarkus CredentialsProvider bridge | None — inherently Quarkus | Spring Vault / AWS Secrets Manager |
| testing | @Alternative @Priority(200) fixtures | None — test framework by nature | spring-testing module |
| graphql-client | SmallRye @GraphQLClientApi | DTO types (already in graphql/) | Spring GraphQL client |
| callback-client | @Startup CDI discovery + @Readiness | SPI scanning logic | Spring Boot lifecycle |

## Event Handling

Core modules are pure I/O. They do not fire or observe framework events.

### Event Emission

Core modules accept typed callback interfaces:

```java
// In module-core — typed publisher interface
public interface ViewEvents {
    void viewEvaluated(SubjectViewEvent event);
}

// Core POJO uses the callback
public class SubjectViewOrchestrator {
    private final ViewEvents events;

    public SubjectViewOrchestrator(..., ViewEvents events) {
        this.events = events;
    }

    public void evaluate(SubjectViewSpec spec) {
        // business logic
        events.viewEvaluated(new SubjectViewEvent(...));
    }
}
```

Framework modules implement the callback:

```java
// Quarkus module
@ApplicationScoped
public class CdiViewEvents implements ViewEvents {
    @Inject Event<SubjectViewEvent> viewEvent;

    @Override
    public void viewEvaluated(SubjectViewEvent event) {
        viewEvent.fireAsync(event);
    }
}

// Spring module
@Component
public class SpringViewEvents implements ViewEvents {
    private final ApplicationEventPublisher publisher;

    @Override
    public void viewEvaluated(SubjectViewEvent event) {
        publisher.publishEvent(event);
    }
}
```

### Event Observation

Framework modules have observer/listener methods that delegate to core:

```java
// Quarkus module
@ApplicationScoped
public class CdiSubscriptionObserver {
    @Inject NotificationDispatcher dispatcher;

    void onMatch(@ObservesAsync SubscriptionMatched event) {
        dispatcher.dispatch(event);
    }
}

// Spring module
@Component
public class SpringSubscriptionListener {
    private final NotificationDispatcher dispatcher;

    @EventListener
    public void onMatch(SubscriptionMatched event) {
        dispatcher.dispatch(event);
    }
}
```

### Event Types

Event record types (SubjectViewEvent, SubscriptionMatched, DataSourceRegistered,
etc.) remain in platform-api unchanged. They are pure Java records with no
framework dependency.

## CDI Pattern Mapping

| CDI Pattern | Core Module | Quarkus Module | Spring Module |
|---|---|---|---|
| @DefaultBean no-op | POJO in core | @Produces @DefaultBean | @Bean @ConditionalOnMissingBean |
| @ApplicationScoped | Constructor-injected POJO | @Produces @ApplicationScoped | @Bean via @AutoConfiguration |
| @Alternative @Priority(N) | POJO | @Produces @Alternative @Priority(N) | @AutoConfiguration + @ConditionalOnClass + @Primary |
| @Decorator @Priority(N) | POJO with delegate constructor param | @Decorator @Delegate @Any | @Bean @Primary wrapping delegate |
| @Inject Instance\<T\> | Constructor param: List\<T\> or Optional\<T\> | Collected from Instance\<T\> | Collected from ObjectProvider\<T\> |
| @Observes / @ObservesAsync | Method called by framework adapter | CDI observer delegates to core | @EventListener delegates to core |
| @Scheduled | Method called by framework adapter | @Scheduled delegates to core | @Scheduled delegates to core |
| @ConfigProperty | Constructor param | @ConfigProperty injected, passed to ctor | @Value / @ConfigurationProperties, passed to ctor |
| PanacheEntityBase | Stays in -jpa module | PanacheEntityBase | Spring Data JPA |
| Event.fire() / fireAsync() | Consumer\<T\> callback | CDI Event\<T\> at construction | ApplicationEventPublisher at construction |

### Spring Auto-Configuration

Each `-spring` module ships an `@AutoConfiguration` class registered via
`META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`.
This provides classpath-activated bean registration — the Spring equivalent of
CDI's Jandex-based bean discovery.

The CDI priority ladder maps to Spring as:

| CDI Tier | Spring Mechanism |
|---|---|
| @DefaultBean (fallback) | @Bean @ConditionalOnMissingBean |
| @ApplicationScoped (default) | @AutoConfiguration + @ConditionalOnClass |
| @Alternative @Priority (override) | @AutoConfigureBefore/After + @Primary |
| @Alternative @Priority(200) (test) | @TestConfiguration with @Bean overrides |

## Testing Strategy

Three tiers aligned with module structure:

| Tier | Framework | What's Tested |
|---|---|---|
| Core modules | Pure JUnit 5 | Business logic. Construct POJOs directly. Mocks for SPI deps. |
| Quarkus wiring | @QuarkusTest | Bean production, CDI events, @Scheduled. Existing testing/ module. |
| Spring wiring | @SpringBootTest | Bean creation, @EventListener, @Scheduled. New spring-testing module. |

Core tests are fast (no container). Contract tests run against core implementations
directly — both framework variants satisfy the same contract by delegating to the
same core.

## Spring Boot Integration

**Version:** Spring Boot 3.x (Jakarta namespace compatible with Quarkus 3.x)

**BOM:** casehub-parent imports `spring-boot-dependencies` as a managed BOM in
`<dependencyManagement>`. Consistent versions across all -spring modules.

**Test:** `spring-boot-starter-test` is test-scoped in each -spring module.
New `spring-testing` module provides platform-specific test fixtures
(@TestConfiguration overrides for NoOp POJOs).

## Extraction Pattern (Step-by-Step)

For each Category A module:

1. **Create `module-core/` Maven module** with no framework dependencies
2. **Move business logic classes** from existing module to core
3. **Convert to constructor injection** — remove @Inject field injection, add constructor params
4. **Remove all CDI annotations** (@ApplicationScoped, @DefaultBean, @Alternative, etc.)
5. **Replace Event\<T\> with Consumer\<T\>** callback interfaces
6. **Update existing module** to depend on core, add @Produces methods for each bean
7. **Create `module-spring/`** with @AutoConfiguration producing the same beans
8. **Move tests** — pure logic tests to core, framework-specific tests stay
9. **Verify** — `mvn install` passes, existing Quarkus tests green

## Scope and Constraints

- **platform-api stays unchanged** — zero-dep pure Java, already framework-neutral
- **JPA entities stay in persistence modules** — not extracted into cores
- **No Quarkus goodness lost** — framework modules use full Arc features
- **Spring Data JPA modules are out of scope** — separate issues in the epic
- **Breaking changes acceptable** — pre-release platform
- **Consumer repos updated in later batches** — engine, work, qhorus, etc.

## References

- [BootUI QUARKUS-SUPPORT.md](https://github.com/jdubois/boot-ui/blob/main/docs/QUARKUS-SUPPORT.md) — real-world dual-framework architecture
- [Hexagonal Architecture Java](https://github.com/SvenWoltmann/hexagonal-architecture-java) — pure core + framework adapter branches
- casehubio/parent#469 — epic: dual-framework support
- casehubio/platform#276 — platform extraction issue
- GE-20260615-c234fc — @DefaultBean silently ignored without quarkus-arc
- GE-20260522-adb5cd — moving beans to library JARs breaks CDI discovery
- GE-20260604-81a6a6 — @DefaultBean @Unremovable for cross-module injection
- GE-20260627-51e402 — @Alternative suppresses ALL @DefaultBean beans
- GE-20260513-4f26a7 — @DefaultBean + @ApplicationScoped displacement pattern
- GE-20260605-373190 — @ObservesAsync + @RequestScoped incompatibility
- GE-20260531-e1ce47 — CDI @Observes vs @ObservesAsync separate channels
- GE-20260423-daef97 — fire() vs fireAsync() delivery split
- PP-20260522-platform-api-scope — platform-api scope rules
- PP-20260514-engine-spi-noops-defaultbean — @DefaultBean pattern
- PP-20260518-platform-spi-contract — SPI implementation contract
- PP-20260619-409a36 — Instance<T> for optional SPIs
- PP-20260812-2dab38 — orm.xml tier separation
- alternative-extension-patterns.md — @Alternative extension patterns
- platform-module-progression.md — module adoption progression
- contributor-guide.md — three-layer model
