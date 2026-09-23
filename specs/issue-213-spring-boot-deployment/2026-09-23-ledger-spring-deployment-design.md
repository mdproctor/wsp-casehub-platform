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
| api | N/A (pure SPI) | N/A | N/A | N/A | ✅ No changes needed |
| ledger-core | ✅ | N/A | N/A | N/A | Needs expansion (services, config records) |
| runtime | Partial | ✅ | ❌ | ❌ | Needs aggressive extraction → ledger-spring |
| rest | ❌ | N/A | ❌ | ❌ | Needs core extraction → graphql-spring-generator |
| graphql | ❌ | N/A | ❌ | ❌ | Needs core extraction → graphql-spring-generator |
| persistence-memory | ❌ | N/A | ❌ | ❌ | Needs spring-generator |
| signing/* | ✅ (core exists) | N/A | ❌ | ❌ | 4 Spring modules needed |

## Architecture

### New Module Inventory

| Module | Artifact | Purpose |
|--------|----------|---------|
| `ledger-jpa-common` | `casehub-ledger-jpa-common` | Shared entity classes extracted from runtime |
| `ledger-spring` | `casehub-ledger-spring` | Spring auto-config (spring-generator + graphql-spring-generator) |
| `ledger-spring-jpa` | `casehub-ledger-spring-jpa` | Spring Data JPA repositories (depends on jpa-common) |
| `signing/vault-transit-spring` | `casehub-ledger-vault-transit-spring` | Spring auto-config for Vault Transit signing |
| `signing/aws-kms-spring` | `casehub-ledger-aws-kms-spring` | Spring auto-config for AWS KMS signing |
| `signing/gcp-kms-spring` | `casehub-ledger-gcp-kms-spring` | Spring auto-config for GCP KMS signing |
| `signing/azure-keyvault-spring` | `casehub-ledger-azure-keyvault-spring` | Spring auto-config for Azure Key Vault signing |
| `ledger-spring-integration-test` | `casehub-ledger-spring-integration-test` | @SpringBootTest composition gate |

### Three-Layer Model

```
api/                    Pure Java SPIs (unchanged)
ledger-core/            Framework-neutral POJOs (expanded: services, config records)
runtime/                Quarkus CDI thin shells (slimmed: delegates to core)
ledger-spring/          Spring auto-config (generated + hand-written)
ledger-jpa-common/      Shared entity classes
ledger-spring-jpa/      Spring Data JPA repos
```

### Dependency Graph

```
api ← ledger-core ← ledger-jpa-common ← runtime (Quarkus)
                  ↖                    ← ledger-spring (Spring auto-config)
                    ledger-jpa-common  ← ledger-spring-jpa (Spring Data JPA)
```

## Execution Plan (Bottom-Up)

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
| `LedgerAttestation` | (in api module — stays there, shared by both) |

**Module structure:**
- Package: `io.casehub.ledger.jpa`
- Dependencies: `casehub-ledger-api`, `jakarta.persistence-api`, `jackson-databind` (provided)
- Jandex plugin for index generation

**runtime/ changes:** Remove entity classes, add `casehub-ledger-jpa-common` as dependency.

### Step 2: Framework-neutral config records → ledger-core

Create a `LedgerProperties` record hierarchy in ledger-core that mirrors the LedgerConfig @ConfigMapping structure.

```java
package io.casehub.ledger.core.config;

public record LedgerProperties(
    boolean enabled,
    HashChainProperties hashChain,
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
    DecisionContextProperties decisionContext,
    EvidenceProperties evidence,
    AttestationProperties attestations,
    AgentIdentityProperties agentIdentity
) {
    // Nested records for each sub-config...
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
| `TrustScoreRoutingPublisher` | `TrustScorePublisherCore` (accepts `Consumer<T>`) | CDI Event<T> |
| `LedgerMerklePublisher` | `MerklePublisherCore` | @ApplicationScoped, HttpClient |
| `LedgerComplianceReportService` | `ComplianceReportServiceCore` | @ApplicationScoped, @Inject |
| `LedgerProvExportService` | `ProvExportServiceCore` | @ApplicationScoped, @Inject |
| `LedgerVerificationService` | `VerificationServiceCore` | @ApplicationScoped, @Inject |
| `KeyRotationService` | `KeyRotationServiceCore` | @ApplicationScoped, @Transactional |
| `AgentSignatureVerificationService` | `SignatureVerificationCore` | @ApplicationScoped, @Inject |
| `ConfiguredAgentSigner` | Already in core (`AgentEntrySigner`) | Done |
| `LedgerErasureService` | `ErasureServiceCore` | @ApplicationScoped, @Inject EM |
| `OutcomeRecordSaveService` | `OutcomeRecordSaveCore` | @ApplicationScoped, @Inject |
| `EigenTrustStartupValidator` | `EigenTrustValidator` (pure validation logic) | @Observes StartupEvent |
| `CachedTrustScoreSource` | stays in runtime (caching strategy is framework-specific) | @Alternative @Priority |
| `ComputedTrustScoreSource` | `ComputedTrustSourceCore` | @ApplicationScoped |
| `MaterializedTrustScoreSource` | `MaterializedTrustSourceCore` | @Alternative @Priority |
| `OtelTraceIdProvider` | stays in runtime (OTel API is framework-neutral but optional) | @ApplicationScoped |

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
| `Event<T>.fire()` | `Consumer<T>` callback | CDI `Event<T>` | `ApplicationEventPublisher` |
| `@Scheduled` | Method call by external scheduler | Quarkus `@Scheduled` | Spring `@Scheduled` |
| `Instance<T>` collection | `List<T>` constructor param | `Instance<T>` iteration | `ObjectProvider<T>` / `List<T>` |
| `InjectableInstance<T>` priority | `List<T>` pre-sorted by priority | Arc `InjectableBean.getPriority()` | Spring `@Order` + `AnnotationAwareOrderComparator` |
| `@Observes` event | Event handler method | CDI observer | `@EventListener` |
| `@CrossTenant` qualifier | Constructor param | CDI qualifier | `@Qualifier` or explicit wiring |
| `@Transactional` | Transaction boundary in framework module | Jakarta `@Transactional` | Spring `@Transactional` |

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

**Hand-written content:**
- `LedgerConfigurationProperties` — `@ConfigurationProperties(prefix = "casehub.ledger")` → `LedgerProperties`
- `LedgerSchedulingConfig` — `@Configuration` with `@Scheduled` methods calling core service methods
- `LedgerEventConfig` — `@Configuration` bridging `Consumer<T>` callbacks to `ApplicationEventPublisher`
- `LedgerEnricherConfig` — `@Configuration` collecting `List<LedgerEntryEnricher>` beans, sorting by `@Order`
- Spring AOP equivalents for CDI interceptors (if needed by consumers)

**Dependencies:** `casehub-ledger-core`, `casehub-ledger-api`, Spring Boot auto-configuration

### Step 5: Create ledger-spring-jpa module

- Spring Data JPA repositories implementing ledger SPI interfaces
- Depends on `casehub-ledger-jpa-common` for entity classes
- `@AutoConfiguration` + `@ConditionalOnClass(EntityManager.class)`
- Shares the same Flyway migrations as the Quarkus runtime

### Step 6: Signing Spring modules

Each signing backend gets a Spring auto-config module:

| Module | Generates from | Produces |
|--------|---------------|----------|
| `vault-transit-spring` | `vault-transit-quarkus` Jandex | `@AutoConfiguration` for VaultTransitAgentSigner |
| `aws-kms-spring` | `aws-kms-quarkus` Jandex | `@AutoConfiguration` for AwsKmsAgentSigner |
| `gcp-kms-spring` | `gcp-kms-quarkus` Jandex | `@AutoConfiguration` for GcpKmsAgentSigner |
| `azure-keyvault-spring` | `azure-keyvault-quarkus` Jandex | `@AutoConfiguration` for AzureKeyVaultAgentSigner |

Each: spring-generator plugin, `@ConditionalOnClass` guard, config mapping via `@ConfigurationProperties`.

### Step 7: Integration test

`ledger-spring-integration-test`:
- `@SpringBootTest` verifying all auto-configs compose
- H2 + Hibernate DDL for JPA
- Health endpoint returns UP
- Core service beans are injectable
- Spring Data JPA repos are functional

## Testing Strategy

- **Entity extraction (Step 1):** Existing runtime tests must pass after entity move. `mvn test` on runtime.
- **Config records (Step 2):** Unit tests for LedgerProperties construction + adapter mapping.
- **Service extraction (Step 3):** Existing tests stay with runtime (CDI wiring tests). New unit tests for core POJOs in ledger-core (pure Java, no container).
- **Spring modules (Steps 4-6):** `mvn install` with spring-generator verifies generation. Verify goals catch drift.
- **Integration test (Step 7):** `@SpringBootTest` with H2 validates full composition.

## References

- specs/spring-deployment-completion/2026-09-15-spring-deployment-completion-design.md — platform Spring spec
- specs/issue-474-spring-boot-generators/2026-09-14-spring-boot-generators-design.md — generator design
- specs/issue-469-dual-framework-core-extraction/2026-09-07-dual-framework-core-extraction-design.md — core extraction design
- LedgerCoreProducer.java — 10 @Produces wrapping core POJOs
- LedgerPrivacyProducer.java — 2 @Produces with Instance<EntityManager>
- LedgerConfig.java — 15 sub-interfaces, 30+ config keys
- DefaultLedgerEntryApi.java — Pattern 2 @McpDomain impl
- LedgerEnricherPipeline.java — Arc InjectableInstance (heaviest CDI coupling)
- signing/vault-transit/ — representative signing module structure
