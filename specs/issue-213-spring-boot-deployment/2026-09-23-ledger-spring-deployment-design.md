# Ledger Spring Boot Deployment — Design Spec

**Issue:** casehubio/ledger#213
**Branch:** issue-213-spring-boot-deployment
**Date:** 2026-09-23

## Goal

Complete Spring Boot deployment for casehub-ledger: aggressive core extraction of all runtime services to framework-neutral POJOs, Spring auto-configuration module, Spring Data JPA module with shared entities, signing backend Spring modules, generator wiring, and integration test. Follow the three-layer model established by platform#384: -core (POJO) / Quarkus (CDI) / -spring (auto-config).

## Prerequisites (complete)

- **Core extraction (parent#469):** ledger-core exists with 55+ POJOs (trust computation, merkle, signing, privacy, compliance, enrichment, federation, model types)
- **Panache purge:** Complete — all entities are plain @Entity, all repositories use EntityManager + JPQL
- **Spring generators (parent#474):** spring-generator, rest-spring-generator, graphql-spring-generator, mcp-spring-generator — all built, tested, merged to platform main
- **@McpDomain endpoints:** REST module uses Pattern 2 (@McpDomain on concrete classes with @PlatformQuery/@PlatformMutation)

## Current State

| Module | Core extracted | Panache-free | Spring module | Generator wired | Status |
|--------|:---:|:---:|:---:|:---:|---|
| api | N/A (pure SPI) | N/A | N/A | N/A | Needs repository SPI additions (7 interfaces from runtime) |
| ledger-core | ✅ | N/A | N/A | N/A | Needs expansion (services, config records) |
| runtime | Partial | ✅ | ❌ | ❌ | Needs aggressive extraction → ledger-spring |
| rest | ❌ | N/A | ❌ | ❌ | Needs core extraction → spring-generator + graphql-spring-generator + rest-spring-generator |
| graphql | ❌ | N/A | ❌ | ❌ | Needs core extraction → graphql-spring-generator |
| persistence-memory | ❌ | N/A | ❌ | ❌ | Needs core extraction → spring-generator |
| signing/* | ✅ (core exists) | N/A | ❌ | ❌ | 4 Spring modules needed |
| annotations | N/A | N/A | ❌ | ❌ | Quarkus CDI annotations; Spring AOP equivalents needed in ledger-spring |
| testing | N/A | N/A | ❌ | ❌ | Test utilities; Spring test support via ledger-spring-integration-test |
| deployment | N/A | N/A | N/A | N/A | Quarkus build-time processors; no Spring equivalent needed |
| consumer-compat-test | N/A | N/A | N/A | N/A | Consumer compatibility gate; no changes needed |

## Architecture

### New Module Inventory

| Module | Artifact | Purpose |
|--------|----------|---------|
| `ledger-jpa-common` | `casehub-ledger-jpa-common` | Shared entity classes, Flyway SQL, JPA helpers extracted from runtime |
| `ledger-spring` | `casehub-ledger-spring` | Spring auto-config (spring-generator + graphql-spring-generator) |
| `ledger-spring-jpa` | `casehub-ledger-spring-jpa` | Spring Data JPA repositories (depends on jpa-common) |
| `ledger-signing-spring` | `casehub-ledger-signing-spring` | Consolidated Spring auto-config for all signing backends |
| `ledger-spring-integration-test` | `casehub-ledger-spring-integration-test` | @SpringBootTest composition gate |

### Three-Layer Model

```
api/                    Pure Java SPIs + repository SPI interfaces (expanded: 7 interfaces from runtime)
ledger-core/            Framework-neutral POJOs (expanded: services, config records)
runtime/                Quarkus CDI thin shells (slimmed: delegates to core)
ledger-spring/          Spring auto-config (generated + hand-written)
ledger-jpa-common/      Shared entity classes + Flyway migrations + LedgerSequenceAllocator
ledger-spring-jpa/      Spring Data JPA repos
```

### Dependency Graph

```
                      api
                    ↗     ↖
           ledger-core    ledger-jpa-common
            ↗      ↖         ↗         ↖
  ledger-spring    runtime              ledger-spring-jpa
                    ↗
           ledger-jpa-common
```

Read as: arrow points from dependent to dependency. Key relationships:
- `ledger-jpa-common → api` (entities reference api types: `LedgerEntry`, `ActorType`, `ScoreType`)
- `ledger-core → api` (core POJOs reference api SPIs)
- `runtime → ledger-core, ledger-jpa-common, api` (CDI shells delegate to core, use entities)
- `ledger-spring → ledger-core, api` (auto-config wraps core POJOs)
- `ledger-spring-jpa → ledger-jpa-common, api` (Spring Data repos use entities, implement api SPIs)

**Prerequisite:** 7 repository SPI interfaces currently in `runtime.repository` must move to `api.spi` before Step 5 (see Step 0). `ledger-spring-jpa` reaches them via transitive dependency on `api` through `ledger-jpa-common`.

## Execution Plan (Bottom-Up)

### Step 0: Repository SPI relocation → api

Move 7 repository SPI interfaces from `runtime/repository/` to `api/spi/`. Currently only `LedgerEntryRepository` is in `api.spi`; the other 7 are stranded in `runtime.repository`, making them unreachable from `ledger-spring-jpa`.

**Interfaces to move:**

| Interface | Current package | Notes |
|-----------|----------------|-------|
| `CrossTenantLedgerEntryRepository` | `runtime.repository` | References `LedgerAttestation` — use `api.model.LedgerAttestation` |
| `ActorTrustScoreRepository` | `runtime.repository` | References `ActorTrustScore` entity — create `api.model.ActorTrustScore` base POJO |
| `ActorIdentityBindingRepository` | `runtime.repository` | References `ActorIdentityBindingEntry` entity |
| `ErasureReceiptRepository` | `runtime.repository` | References `ErasureReceiptLedgerEntry` (extends `LedgerEntry`) |
| `KeyRotationRepository` | `runtime.repository` | References `KeyRotationEntry` (extends `LedgerEntry`) |
| `LedgerMerkleFrontierRepository` | `runtime.repository` | References `LedgerMerkleFrontier` entity |
| `TrustScoreSnapshotRepository` | `runtime.repository` | References `TrustScoreSnapshot` entity |

**Type preparation:** Where SPI interfaces reference entity types (`ActorTrustScore`, `LedgerMerkleFrontier`, `TrustScoreSnapshot`, `ActorIdentityBindingEntry`), create api-level base POJOs in `api.model` that the JPA entities extend — following the existing `JpaLedgerEntry extends LedgerEntry` pattern. Update interface signatures to reference the api types. JPA implementations return entity subtypes (valid via inheritance).

**NoOp fallback repositories:** The runtime module contains `@DefaultBean` NoOp implementations for 5 of these interfaces (`NoOpErasureReceiptRepository`, `NoOpActorTrustScoreRepository`, `NoOpActorIdentityBindingRepository`, `NoOpLedgerMerkleFrontierRepository`, `NoOpTrustScoreSnapshotRepository`). These must be extracted to `ledger-core` as framework-neutral classes (following the existing `NoOpLedgerEntryRepository` in `ledger-core`), then re-wrapped with `@DefaultBean` in runtime and `@ConditionalOnMissingBean` in `ledger-spring`.

### Step 1: Entity extraction → ledger-jpa-common

Extract all JPA entity classes from `runtime/src/main/java/io/casehub/ledger/runtime/model/` to a new `ledger-jpa-common` module.

**Entities to extract (15 files):**

| Entity class | Current location |
|-------------|-----------------|
| `JpaLedgerEntry` | `model/jpa/JpaLedgerEntry.java` |
| `PlainLedgerEntry` | `model/PlainLedgerEntry.java` |
| `ErasureReceiptLedgerEntry` | `model/ErasureReceiptLedgerEntry.java` |
| `KeyRotationEntry` | `model/KeyRotationEntry.java` |
| `LedgerEntryArchiveRecord` | `model/LedgerEntryArchiveRecord.java` |
| `LedgerMerkleFrontier` | `model/LedgerMerkleFrontier.java` |
| `ActorTrustScore` | `model/ActorTrustScore.java` |
| `TrustScoreSnapshot` | `model/TrustScoreSnapshot.java` |
| `ActorIdentity` | `model/ActorIdentity.java` |
| `ActorIdentityBindingEntry` | `model/ActorIdentityBindingEntry.java` |
| `JpaCompensationSupplement` | `model/supplement/JpaCompensationSupplement.java` |
| `JpaComplianceSupplement` | `model/supplement/JpaComplianceSupplement.java` |
| `JpaProvenanceSupplement` | `model/supplement/JpaProvenanceSupplement.java` |
| `DomainDataConverter` | `model/converter/DomainDataConverter.java` |
| `LedgerAttestation` | `model/LedgerAttestation.java` — runtime `@Entity` with `@NamedQuery` (extends `api.model.LedgerAttestation` POJO) |

**`@EntityListeners` decoupling:** `JpaLedgerEntry` is annotated with `@EntityListeners({LedgerTraceListener.class, LedgerIdentityEnforcementListener.class})`. Both listeners are `@ApplicationScoped` CDI beans that `@Inject LedgerConfig` — they cannot live in framework-neutral `jpa-common`. Resolution:

1. Remove `@EntityListeners` annotation from `JpaLedgerEntry` in `jpa-common`
2. Extract pure validation logic to core POJOs (`TraceIdEnricherCore`, `IdentityEnforcementHandler`) — already in extraction inventory
3. Register entity listeners per-framework via `META-INF/orm.xml`:
   - **Quarkus runtime:** `orm.xml` declares `<entity-listener>` referencing CDI-wired listener thin shells
   - **Spring:** `orm.xml` in `ledger-spring-jpa` declares `<entity-listener>` referencing Spring-wired listener thin shells
4. Each framework listener thin shell delegates to the core POJO, receiving `LedgerProperties` from its framework's DI container

**Flyway migrations:** Move `db/ledger/migration/` from `runtime/src/main/resources/` to `ledger-jpa-common/src/main/resources/`. Both `runtime` and `ledger-spring-jpa` depend on `jpa-common`, so both get migrations on the classpath. Follows the platform precedent set by `memory-jpa-common`.

**Module structure:**
- Package: `io.casehub.ledger.jpa`
- Dependencies: `casehub-ledger-api`, `jakarta.persistence-api`, `jackson-databind` (provided)
- Jandex plugin for index generation

**Shared JPA infrastructure:** `LedgerPersistenceUnit` qualifier annotation and `LedgerSequenceAllocator` move to `jpa-common`. `LedgerSequenceAllocator` is extracted to accept `EntityManager` via constructor (currently `@Inject @LedgerPersistenceUnit EntityManager`). It uses pure JDBC via `Session.doReturningWork()` with dialect-specific SQL — framework-neutral once CDI injection is removed.

**runtime/ changes:** Remove entity classes, add `casehub-ledger-jpa-common` as dependency.

### Step 2: Framework-neutral config records → ledger-core

Create a `LedgerProperties` record hierarchy in ledger-core that mirrors the LedgerConfig @ConfigMapping structure.

```java
package io.casehub.ledger.core.config;

public record LedgerProperties(
    boolean enabled,
    Optional<String> datasource,
    HashChainProperties hashChain,
    DecisionContextProperties decisionContext,
    EvidenceProperties evidence,
    AttestationProperties attestations,
    TrustScoreProperties trustScore,
    RetentionProperties retention,
    MerkleProperties merkle,
    IdentityProperties identity,
    DecayProperties decay,
    HealthProperties health,
    AgentSigningProperties agentSigning,
    OutcomeProperties outcome,
    ErasureReceiptProperties erasureReceipt,
    MetadataProperties metadata,
    AgentIdentityProperties agentIdentity
) {
    // 15 top-level sub-interfaces + 10 nested = 25 total sub-interfaces
    // Each nested sub-interface requires a corresponding nested record:
    //   MerkleProperties.PublishProperties
    //   TrustScoreProperties.EigenTrustProperties
    //   TrustScoreProperties.ExportProperties
    //   TrustScoreProperties.BootstrapProperties
    //   TrustScoreProperties.MaterializationProperties
    //   TrustScoreProperties.IncrementalProperties
    //   TrustScoreProperties.SnapshotProperties
    //   IdentityProperties.TokenisationProperties
    //   AgentSigningProperties.ActorKeyProperties
    //   AgentIdentityProperties.ScimProperties
}
```

Each nested config interface in LedgerConfig maps to a nested record in LedgerProperties.

**Adapters:**
- Quarkus: `LedgerConfigAdapter` in runtime — reads `LedgerConfig` (@ConfigMapping), constructs `LedgerProperties`
- Spring: `LedgerConfigurationProperties` in ledger-spring — `@ConfigurationProperties(prefix = "casehub.ledger")`, constructs `LedgerProperties`

All core POJOs accept `LedgerProperties` (or relevant sub-record) via constructor — never the framework config type.

### Step 3: Aggressive service extraction → ledger-core

Extract ALL business logic from runtime services to constructor-injected POJOs in ledger-core. The runtime module becomes thin CDI wiring shells.

**Service extraction inventory:**

| Current (runtime) | Core POJO (ledger-core) | CDI coupling to strip |
|-------------------|------------------------|----------------------|
| `DefaultLedgerAppender` | `LedgerAppenderCore` | @DefaultBean, @Inject fields |
| `DefaultOutcomeRecorder` | `OutcomeRecorderCore` | @ApplicationScoped, @Inject |
| `LedgerEnricherPipeline` | `EnricherPipelineCore` (accepts `List<LedgerEntryEnricher>`) | Arc InjectableInstance, priority sorting |
| `TrustScoreJob` | `TrustScoreComputationService` | @Scheduled, @Transactional, @CrossTenant |
| `LedgerHealthJob` | `LedgerHealthService` | @Scheduled, @Inject |
| `LedgerRetentionJob` | `RetentionService` | @Scheduled, @Inject |
| `PerActorTrustComputer` | `PerActorTrustComputerCore` | @ApplicationScoped, @Inject |
| `IncrementalTrustUpdateObserver` | `IncrementalTrustUpdater` | CDI @Observes @TransactionPhase |
| `TrustScoreRoutingPublisher` | `TrustScorePublisherCore` (accepts `TrustScoreEventPublisher`) | CDI Event<T>, BeanManager observer detection |
| `LedgerMerklePublisher` | `MerklePublisherCore` | @ApplicationScoped, HttpClient |
| `LedgerComplianceReportService` | `ComplianceReportServiceCore` | @ApplicationScoped, @Inject |
| `LedgerProvExportService` | `ProvExportServiceCore` | @ApplicationScoped, @Inject |
| `LedgerVerificationService` | `VerificationServiceCore` | @ApplicationScoped, @Inject |
| `KeyRotationService` | `KeyRotationServiceCore` | @ApplicationScoped, @Transactional |
| `AgentSignatureVerificationService` | `SignatureVerificationCore` | @ApplicationScoped, @Inject |
| `ConfiguredAgentSigner` | `PemFileAgentSigner` — extract to `core.signing`, accept `AgentSigningProperties` instead of `LedgerConfig` | @DefaultBean, @ApplicationScoped, @Inject LedgerConfig, @PostConstruct key loading. Runtime keeps thin CDI `@DefaultBean` producer; Spring gets `@ConditionalOnMissingBean` in `ledger-spring`. Already extends `AbstractCachingAgentSigner` in core — clean extraction. |
| `LedgerErasureService` | `ErasureServiceCore` | @ApplicationScoped, @Inject EM — requires `CrossTenantLedgerEntryRepository.countByActorId()` SPI addition; uses existing `ActorIdentityProvider.tokeniseForQuery()` to replace direct EM query |
| `OutcomeRecordSaveService` | `OutcomeRecordSaveCore` | @ApplicationScoped, @Inject |
| `EigenTrustStartupValidator` | `EigenTrustValidator` (pure validation logic) | @Observes StartupEvent |
| `CachedTrustScoreSource` | stays in runtime (caching strategy is framework-specific) | @Alternative @Priority |
| `ComputedTrustScoreSource` | `ComputedTrustSourceCore` | @ApplicationScoped |
| `MaterializedTrustScoreSource` | `MaterializedTrustSourceCore` | @Alternative @Priority |
| `OtelTraceIdProvider` | stays in runtime (OTel API is framework-neutral but optional) | @ApplicationScoped |
| `LedgerTraceListener` | `TraceIdEnricherCore` | Pure enricher logic |
| `TraceIdEnricher` | `TraceIdEnricherCore` (merge with above) | @ApplicationScoped |

**Persistence infrastructure (runtime/persistence/, runtime/repository/jpa/):**

| Current | Target | Notes |
|---------|--------|-------|
| `LedgerEntityManagerProducer` | stays in runtime (Quarkus-specific) | CDI producer for `@LedgerPersistenceUnit EntityManager`. Uses `Instance<EntityManager>` + Quarkus `PersistenceUnit` annotation literal. Spring equivalent: `LedgerDataSourceConfig` in `ledger-spring-jpa` — `@Configuration` routing `DataSource`/`EntityManagerFactory` based on `LedgerProperties.datasource()`. |
| `LedgerSequenceAllocator` | moves to `jpa-common` | See Step 1. Constructor-injected `EntityManager`. |

**Interceptor context beans (runtime/service/intercept/):**

| Current | Core POJO | Notes |
|---------|-----------|-------|
| `ProvenanceContext` | `ProvenanceContext` → `ledger-core` | `@ApplicationScoped` but actually framework-neutral: static `ThreadLocal<Deque<SourceState>>`. Remove `@ApplicationScoped`, move to core as plain class. Both framework modules instantiate as singleton. |
| `ComplianceSupplementContext` | `ComplianceSupplementContext` → `ledger-core` | Same pattern: static `ThreadLocal<Deque<State>>`. Framework-neutral. |

**Federation services (runtime/service/federation/):**

| Current | Core POJO | Notes |
|---------|-----------|-------|
| `TrustBootstrapService` | `TrustBootstrapServiceCore` | @ApplicationScoped, @Inject |
| `TrustExportService` | `TrustExportServiceCore` | @ApplicationScoped, @Inject |
| `JpaTrustImportService` | stays in runtime/jpa-common (JPA-specific) | @ApplicationScoped, EntityManager |

**Persistence-memory module (in-memory test alternatives):**

The `persistence-memory` module contains 8 in-memory repository implementations plus `InMemoryAgentSigner`:

| In-memory implementation | Implements |
|-------------------------|------------|
| `InMemoryLedgerEntryRepository` | `LedgerEntryRepository` |
| `InMemoryCrossTenantLedgerEntryRepository` | `CrossTenantLedgerEntryRepository` |
| `InMemoryActorTrustScoreRepository` | `ActorTrustScoreRepository` |
| `InMemoryActorIdentityBindingRepository` | `ActorIdentityBindingRepository` |
| `InMemoryErasureReceiptRepository` | `ErasureReceiptRepository` |
| `InMemoryKeyRotationRepository` | `KeyRotationRepository` |
| `InMemoryLedgerMerkleFrontierRepository` | `LedgerMerkleFrontierRepository` |
| `InMemoryTrustScoreSnapshotRepository` | `TrustScoreSnapshotRepository` |
| `InMemoryAgentSigner` | `AgentEntrySigner` |

These are `@Alternative @Priority(1)` — they override both `@DefaultBean` NoOp fallbacks and JPA implementations when on the classpath. Each needs core extraction (convert field injection to constructor injection) so the spring-generator can produce `@AutoConfiguration` equivalents. In Spring, activation is via `@AutoConfiguration` + `@ConditionalOnClass` + `@Primary` — following the established pattern from the core extraction spec (parent#469). A separate `ledger-spring-memory` auto-configuration module is NOT needed — the spring-generator scans `persistence-memory` Jandex and produces the auto-config classes directly into the `persistence-memory` module.

**Distinction from NoOp fallbacks:** The 5 NoOp repositories in `runtime.repository` (`NoOpErasureReceiptRepository`, `NoOpActorTrustScoreRepository`, etc.) are `@DefaultBean` fallbacks — minimal no-op implementations for deployments where a feature is disabled. They serve a different purpose than the in-memory alternatives (which are full working stores for testing). NoOp repos are extracted to `ledger-core` as framework-neutral classes (Step 0); in-memory alternatives remain in `persistence-memory`.

**Identity services (runtime/service/identity/):**

| Current | Core POJO | Notes |
|---------|-----------|-------|
| `ActorDIDEnricher` | `ActorDIDEnricherCore` | Enricher — accepts ActorDIDProvider |
| `ActorIdentityValidationEnricher` | `IdentityValidationEnricherCore` | Enricher |
| `ActorIdentityBindingObserver` | `IdentityBindingHandler` | Extract handler logic, CDI observer stays |
| `AgentIdentityVerificationService` | `AgentIdentityVerificationCore` | Pure computation |
| `IdentityCacheInvalidator` | `CacheInvalidationHandler` | Extract handler, CDI @Observes stays |
| `LedgerIdentityEnforcementListener` | `IdentityEnforcementHandler` | Extract handler, CDI @Observes stays |

**Interceptors (runtime/service/intercept/):**

| Current | Core POJO | Notes |
|---------|-----------|-------|
| `AuditedInterceptor` | stays in runtime | CDI interceptor wiring — Spring uses AOP |
| `ComplianceSupplementInterceptor` | stays in runtime | CDI interceptor |
| `ProvenanceCaptureInterceptor` | stays in runtime | CDI interceptor |
| `ComplianceSupplementEnricher` | `ComplianceSupplementEnricherCore` | Pure enricher logic |
| `ProvenanceCaptureEnricher` | `ProvenanceCaptureEnricherCore` | Pure enricher logic |

**CDI → Framework adapter patterns:**

| CDI concept | Core abstraction | Quarkus impl | Spring impl |
|-------------|-----------------|-------------|-------------|
| `Event<T>.fire()` + `fireAsync()` | Typed event publisher interface (see §Event Publisher Interfaces) | CDI `Event<T>` — calls both `fire()` and `fireAsync()` | `ApplicationEventPublisher.publishEvent()` — delivers to both `@EventListener` and `@Async @EventListener` |
| `@Scheduled` | Method call by external scheduler | Quarkus `@Scheduled` | Spring `@Scheduled` |
| `Instance<T>` collection | `List<T>` constructor param | `Instance<T>` iteration | `ObjectProvider<T>` / `List<T>` |
| `InjectableInstance<T>` priority | `List<T>` sorted by enricher `priority()` in core (see §Enricher Pipeline Ordering) | Enricher `priority()` method — replaces Arc `InjectableBean.getPriority()` | Enricher `priority()` method — replaces Spring `@Order` |
| `@Observes` event | Event handler method | CDI observer | `@EventListener` |
| `@Observes(AFTER_SUCCESS)` + `@Transactional(REQUIRES_NEW)` | Observer handler called by framework shell | CDI `@Observes(during = TransactionPhase.AFTER_SUCCESS)` + Jakarta `@Transactional(TxType.REQUIRES_NEW)` | Spring `@TransactionalEventListener(phase = AFTER_COMMIT)` + `@Transactional(propagation = Propagation.REQUIRES_NEW)` |
| `@CrossTenant` qualifier | Constructor param | CDI qualifier | `@Qualifier` or explicit wiring |
| `@Transactional` | Framework shell carries `@Transactional`; core POJO has no transaction annotation (see §Transaction Boundary Strategy) | Jakarta `@Transactional` on Quarkus shell | Spring `@Transactional` on Spring shell |

#### Transaction Boundary Strategy

Core POJOs carry no `@Transactional` annotations. Transaction boundaries live on the framework shell method that calls the core POJO. Each framework (Quarkus/Spring) applies its own `@Transactional` semantics on the shell.

| Extracted Service | Transaction Owner | Notes |
|-------------------|-------------------|-------|
| `TrustScoreComputationService` | Framework shell `TrustScoreJob.computeTrustScores()` | `em.detach()` calls extracted to `ActorTrustScoreRepository.findAllDetached()` SPI method. Core POJO receives detached value objects. |
| `KeyRotationServiceCore` | Framework shell `KeyRotationService.recordRotation()` | Shell carries `@Transactional`, calls core, then fires events within the transaction boundary. |
| `ErasureServiceCore` | Framework shell `LedgerErasureService.erase()` | Shell carries `@Transactional`. Core POJO uses only SPI methods (`actorIdentityProvider`, `ledgerRepo`); no direct EM access. |
| `IncrementalTrustUpdater` | Framework shell observer method | Quarkus: `@Observes(during = TransactionPhase.AFTER_SUCCESS)` + `@Transactional(TxType.REQUIRES_NEW)`. Spring: `@TransactionalEventListener(phase = AFTER_COMMIT)` + `@Transactional(propagation = Propagation.REQUIRES_NEW)`. |
| `OutcomeRecorderCore` | Delegates to `OutcomeRecordSaveCore` which is wrapped by framework `@Transactional` | DefaultOutcomeRecorder is NOT `@Transactional` itself — it delegates to `OutcomeRecordSaveService` which IS. |
| All other extracted services | No transaction boundary needed | Services that delegate to `LedgerEntryRepository.save()` rely on the repository implementation's transaction. |

Services that currently use `EntityManager` directly (e.g. `em.detach()`, inline JPQL) must have those operations extracted to repository SPI methods before the core POJO extraction.

#### Event Publisher Interfaces

The core extraction spec (parent#469) establishes that core modules accept typed callback interfaces, not `Consumer<T>`. CDI's dual-channel dispatch (`fire()` + `fireAsync()`) is a framework concern — the core POJO calls a single publish method. The framework implementation handles sync/async delivery:

- **CDI:** calls both `fire()` and `fireAsync()` on the CDI `Event<T>`
- **Spring:** calls `ApplicationEventPublisher.publishEvent()` once — Spring delivers to both `@EventListener` (sync) and `@Async @EventListener` (async) subscribers from a single call

```java
// In ledger-core — typed event publisher interface
public interface TrustScoreEventPublisher {
    void publishFull(TrustScoreFullPayload payload);
    void publishDelta(TrustScoreDeltaPayload payload);
    void publishNotify(TrustScoreComputedAt payload);
    boolean needsDeltaPayload(); // observer detection for pre-read optimization
}

public interface LedgerEventPublisher {
    void publishKeyRotated(AgentKeyRotatedEvent event);
    void publishActorTrustUpdated(TrustScoreActorUpdatedEvent event);
    void publishAttestationRecorded(AttestationRecordedEvent event);
}
```

The `needsDeltaPayload()` method replaces `BeanManager.resolveObserverMethods()` — each framework implementation answers based on its own observer detection:
- **CDI:** `BeanManager.resolveObserverMethods()` at `@PostConstruct`
- **Spring:** `ApplicationContext.getBeansOfType(TrustScoreDeltaPayload.class)` or `@EventListener` method count inspection

#### Enricher Pipeline Ordering

The `LedgerEntryEnricher` SPI (in `ledger-core`) gains a default `priority()` method:

```java
public interface LedgerEntryEnricher {
    void enrich(LedgerEntry entry);
    default int priority() { return Integer.MAX_VALUE; }
}
```

`EnricherPipelineCore` sorts enrichers by `priority()` ascending. Each enricher implementation overrides `priority()` to return its ordering value (currently: `TraceIdEnricher` = 10, `ActorDIDEnricher` = 40, `ActorIdentityValidationEnricher` = 50). Framework-level `@Priority`/`@Order` annotations are no longer needed for enricher ordering — the ordering is intrinsic to the enricher, making it verifiable and framework-neutral.

The enricher ordering invariant (DID resolution before DID validation) is enforced by a unit test in `ledger-core` that verifies `ActorDIDEnricherCore.priority() < IdentityValidationEnricherCore.priority()`.

### Step 3b: @McpDomain impl extraction

Extract the 4 REST @McpDomain implementations to core POJOs:

| Current (rest module) | Core POJO (ledger-core) |
|-----------------------|------------------------|
| `DefaultLedgerEntryApi` | `LedgerEntryApiCore` |
| `DefaultLedgerAttestationApi` | `LedgerAttestationApiCore` |
| `DefaultLedgerTrustApi` | `LedgerTrustApiCore` |
| `DefaultLedgerVerificationApi` | `LedgerVerificationApiCore` |

The Quarkus rest module keeps @McpDomain on thin delegation shells. The graphql-spring-generator produces Spring controllers from the @McpDomain annotations. Both inject the core POJO.

GraphQL module (LedgerQueryResolver, LedgerMutationResolver) — same extraction pattern. The @GraphQLApi annotation stays on the thin Quarkus shell.

### Step 4: Create ledger-spring module

**Generated content (spring-generator plugin):**
- Scans runtime module Jandex for `@Produces` methods
- Generates `@AutoConfiguration` classes with `@Bean` methods
- `@ConditionalOnMissingBean` for `@DefaultBean` producers

**Generated content (graphql-spring-generator plugin):**
- Scans rest module Jandex for `@McpDomain` Pattern 2 classes
- Generates Spring GraphQL `@Controller` + Spring MVC `@RestController` per domain
- Delegates to core POJOs

**Generated content (rest-spring-generator plugin):**
- Scans rest module Jandex for `@Provider` classes (LedgerExceptionMapper)
- Generates Spring `@ControllerAdvice` equivalents

**Hand-written content:**
- `LedgerConfigurationProperties` — `@ConfigurationProperties(prefix = "casehub.ledger")` → `LedgerProperties`
- `LedgerSchedulingConfig` — `@Configuration` with `@Scheduled` methods calling core service methods
- `LedgerEventConfig` — `@Configuration` implementing `TrustScoreEventPublisher` and `LedgerEventPublisher` via `ApplicationEventPublisher`, with observer detection for `needsDeltaPayload()`
- `LedgerEnricherConfig` — `@Configuration` collecting `List<LedgerEntryEnricher>` beans (ordering handled by `EnricherPipelineCore` via `priority()` method — no framework-level sorting needed)
- Spring AOP equivalents for CDI interceptors (if needed by consumers)

**Dependencies:** `casehub-ledger-core`, `casehub-ledger-api`, Spring Boot auto-configuration

### Step 5: Create ledger-spring-jpa module

Spring Data JPA repositories implementing all 8 ledger repository SPI interfaces (relocated to `api.spi` in Step 0):

| SPI Interface (in `api.spi`) | Spring JPA Implementation | Quarkus JPA Implementation (existing) |
|------------------------------|--------------------------|---------------------------------------|
| `LedgerEntryRepository` | `SpringJpaLedgerEntryRepository` | `JpaLedgerEntryRepository` |
| `CrossTenantLedgerEntryRepository` | `SpringJpaCrossTenantLedgerEntryRepository` | `JpaCrossTenantLedgerEntryRepository` |
| `ActorTrustScoreRepository` | `SpringJpaActorTrustScoreRepository` | `JpaActorTrustScoreRepository` |
| `ActorIdentityBindingRepository` | `SpringJpaActorIdentityBindingRepository` | `JpaActorIdentityBindingRepository` |
| `ErasureReceiptRepository` | `SpringJpaErasureReceiptRepository` | `JpaErasureReceiptRepository` |
| `KeyRotationRepository` | `SpringJpaKeyRotationRepository` | `JpaKeyRotationRepository` |
| `LedgerMerkleFrontierRepository` | `SpringJpaLedgerMerkleFrontierRepository` | `JpaLedgerMerkleFrontierRepository` |
| `TrustScoreSnapshotRepository` | `SpringJpaTrustScoreSnapshotRepository` | `JpaTrustScoreSnapshotRepository` |

**Shared infrastructure from `jpa-common`:** `LedgerSequenceAllocator` (per-subject sequence allocation with dialect-specific SQL) is shared by all JPA repository implementations that persist `LedgerEntry` subclasses. Moved to `jpa-common` in Step 1.

**DataSource routing:** `LedgerDataSourceConfig` — `@Configuration` class that routes to the correct `DataSource`/`EntityManagerFactory` based on `LedgerProperties.datasource()`. Spring equivalent of `LedgerEntityManagerProducer` (Quarkus CDI producer using `Instance<EntityManager>` + `PersistenceUnit` annotation literal).

**Module configuration:**
- Depends on `casehub-ledger-jpa-common` for entity classes, migrations, and `LedgerSequenceAllocator`
- `@AutoConfiguration` + `@ConditionalOnClass(EntityManager.class)`
- Flyway migrations: shared from `jpa-common/src/main/resources/db/ledger/migration/` (on classpath via transitive dependency). No duplication — single source of truth for DDL.
- Entity listener registration: `META-INF/orm.xml` declaring Spring-wired listeners for `JpaLedgerEntry` (see Step 1)

### Step 6: Consolidated signing Spring module

One `ledger-signing-spring` module replaces 4 individual signing-spring modules, following the platform consolidation pattern established in the spring-module-merge spec (parent#394: 10 `agent-*-spring` → 1 `agent-spring`, 4 `streams-*-spring` → 1 `streams-spring`).

**spring-generator configuration:**

```xml
<quarkusModules>
    <quarkusModule>${project.basedir}/../signing/vault-transit-quarkus</quarkusModule>
    <quarkusModule>${project.basedir}/../signing/aws-kms-quarkus</quarkusModule>
    <quarkusModule>${project.basedir}/../signing/gcp-kms-quarkus</quarkusModule>
    <quarkusModule>${project.basedir}/../signing/azure-keyvault-quarkus</quarkusModule>
</quarkusModules>
```

The generator produces 4 separate `@AutoConfiguration` classes — one per source module, each with its own `@ConditionalOnClass` guard:

| Generated AutoConfiguration | `@ConditionalOnClass` anchor | Source |
|-----------------------------|------------------------------|--------|
| `VaultTransitAutoConfiguration` | `VaultTransitAgentSigner.class` | `vault-transit-quarkus` Jandex |
| `AwsKmsAutoConfiguration` | `AwsKmsAgentSigner.class` | `aws-kms-quarkus` Jandex |
| `GcpKmsAutoConfiguration` | `GcpKmsAgentSigner.class` | `gcp-kms-quarkus` Jandex |
| `AzureKeyVaultAutoConfiguration` | `AzureKeyVaultAgentSigner.class` | `azure-keyvault-quarkus` Jandex |

**Dependencies (compile):** all 4 signing-core modules, `spring-boot-autoconfigure`.
**Dependencies (provided):** all 4 signing-quarkus modules (for Jandex scanning).

### Step 7: Integration test

`ledger-spring-integration-test`:
- `@SpringBootTest` verifying all auto-configs compose
- PostgreSQL via Testcontainers (`@Testcontainers` + `@Container PostgreSQLContainer`) — matching the existing Quarkus test approach. H2 rejected due to known dialect divergences: `HAVING` with aggregate arithmetic, `INSERT ON CONFLICT DO UPDATE` rejection (see `LedgerSequenceAllocator.Dialect` three-way detection), and `@NamedQuery` syntax edge cases.
- Flyway migrations shared from `runtime/src/main/resources/db/ledger/migration/` — validates that Spring deployment uses the same schema as Quarkus. Hibernate DDL generation is NOT used; all schema comes from Flyway.
- `LedgerSequenceAllocator` dialect detection exercised against real PostgreSQL
- Health endpoint returns UP
- Core service beans are injectable
- Spring Data JPA repos are functional
- Enricher pipeline ordering verified (DID enricher before identity validation enricher)

## Testing Strategy

- **Entity extraction (Step 1):** Existing runtime tests must pass after entity move. `mvn test` on runtime.
- **Config records (Step 2):** Unit tests for LedgerProperties construction + adapter mapping.
- **Service extraction (Step 3):** Existing tests stay with runtime (CDI wiring tests). New unit tests for core POJOs in ledger-core (pure Java, no container).
- **Spring modules (Steps 4-6):** `mvn install` with spring-generator verifies generation. Verify goals catch drift.
- **Integration test (Step 7):** `@SpringBootTest` with PostgreSQL Testcontainers + Flyway validates full composition, dialect-specific code paths, and migration correctness.

## References

- specs/spring-deployment-completion/2026-09-15-spring-deployment-completion-design.md — platform Spring spec
- specs/issue-474-spring-boot-generators/2026-09-14-spring-boot-generators-design.md — generator design
- specs/issue-469-dual-framework-core-extraction/2026-09-07-dual-framework-core-extraction-design.md — core extraction design
- LedgerCoreProducer.java — 10 @Produces wrapping core POJOs
- LedgerPrivacyProducer.java — 2 @Produces: `actorIdentityProvider()` uses `Instance<EntityManager>` for tokenisation; `decisionContextSanitiser()` returns PassThroughContentSanitiser (no EntityManager)
- LedgerConfig.java — 25 sub-interfaces (15 top-level + 10 nested), ~55 config keys
- DefaultLedgerEntryApi.java — Pattern 2 @McpDomain impl
- LedgerEnricherPipeline.java — Arc InjectableInstance (heaviest CDI coupling)
- signing/vault-transit/ — representative signing module structure
