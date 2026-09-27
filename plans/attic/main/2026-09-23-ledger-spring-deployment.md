# Ledger Spring Boot Deployment — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/ledger#213 — feat: Spring Boot deployment — core extraction + auto-configuration
**Issue group:** #213

**Goal:** Complete Spring Boot deployment for casehub-ledger via aggressive core extraction, Spring auto-configuration, Spring Data JPA, consolidated signing Spring module, and integration test.

**Architecture:** Bottom-up execution: jpa-common entity extraction → framework-neutral config records → service core extraction → Spring modules with generator wiring → consolidated signing Spring → PostgreSQL Testcontainers integration test. Three-layer model: api (SPIs) / ledger-core (POJOs) / runtime (Quarkus CDI shells) / ledger-spring (auto-config).

**Tech Stack:** Java 21, Quarkus 3.32.2, Spring Boot 4, Spring Data JPA, Flyway, PostgreSQL, Testcontainers, Jackson, Jandex, platform spring-generator / graphql-spring-generator / rest-spring-generator

## Global Constraints

- All core POJOs use constructor injection — zero CDI, zero Spring imports
- Transaction boundaries live on framework shells, never on core POJOs
- Enricher ordering via `LedgerEntryEnricher.priority()` method — no `@Priority`/`@Order`
- Event publishing via typed interfaces (`TrustScoreEventPublisher`, `LedgerEventPublisher`)
- `IncrementalTrustUpdater` uses `AFTER_SUCCESS` + `REQUIRES_NEW` pattern (framework-specific)
- Integration test uses PostgreSQL Testcontainers — NOT H2 (dialect divergences)
- Use `ide_*` tools for all Java source operations — never bash for .java files
- All entity listeners registered via `META-INF/orm.xml`, not `@EntityListeners`

---

## Batch 1: Foundation — Repository SPIs + JPA Common

### Task 1: Repository SPI relocation to api module

**Files:**
- Create: `api/src/main/java/io/casehub/ledger/api/model/ActorTrustScoreBase.java`
- Create: `api/src/main/java/io/casehub/ledger/api/model/LedgerMerkleFrontierBase.java`
- Create: `api/src/main/java/io/casehub/ledger/api/model/TrustScoreSnapshotBase.java`
- Create: `api/src/main/java/io/casehub/ledger/api/model/ActorIdentityBindingBase.java`
- Move: `runtime/src/main/java/io/casehub/ledger/runtime/repository/CrossTenantLedgerEntryRepository.java` → `api/src/main/java/io/casehub/ledger/api/spi/CrossTenantLedgerEntryRepository.java` (use `ide_move_file`)
- Move: `runtime/src/main/java/io/casehub/ledger/runtime/repository/ActorTrustScoreRepository.java` → `api/src/main/java/io/casehub/ledger/api/spi/ActorTrustScoreRepository.java`
- Move: `runtime/src/main/java/io/casehub/ledger/runtime/repository/ActorIdentityBindingRepository.java` → `api/src/main/java/io/casehub/ledger/api/spi/ActorIdentityBindingRepository.java`
- Move: `runtime/src/main/java/io/casehub/ledger/runtime/repository/ErasureReceiptRepository.java` → `api/src/main/java/io/casehub/ledger/api/spi/ErasureReceiptRepository.java`
- Move: `runtime/src/main/java/io/casehub/ledger/runtime/repository/KeyRotationRepository.java` → `api/src/main/java/io/casehub/ledger/api/spi/KeyRotationRepository.java`
- Move: `runtime/src/main/java/io/casehub/ledger/runtime/repository/LedgerMerkleFrontierRepository.java` → `api/src/main/java/io/casehub/ledger/api/spi/LedgerMerkleFrontierRepository.java`
- Move: `runtime/src/main/java/io/casehub/ledger/runtime/repository/TrustScoreSnapshotRepository.java` → `api/src/main/java/io/casehub/ledger/api/spi/TrustScoreSnapshotRepository.java`
- Move: 5 NoOp repos from `runtime/src/main/java/io/casehub/ledger/runtime/repository/NoOp*.java` → `ledger-core/src/main/java/io/casehub/ledger/core/repository/`
- Test: existing runtime tests

**Interfaces:**
- Consumes: `LedgerEntryRepository` already in `api.spi` (pattern reference)
- Produces: 7 SPI interfaces in `api.spi`, 4 api-level base POJOs in `api.model`, 5 NoOp repos in `ledger-core`

- [ ] **Step 1: Create api-level base POJOs for entity types referenced by SPI interfaces**

For each entity type referenced by the SPI interfaces that doesn't yet have an api-level base, create a POJO in `api/src/main/java/io/casehub/ledger/api/model/`. Follow the existing pattern: `LedgerEntry` (api) → `JpaLedgerEntry` (runtime entity extends it).

Use `ide_create_file` for each:

```java
// api/src/main/java/io/casehub/ledger/api/model/ActorTrustScoreBase.java
package io.casehub.ledger.api.model;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

public class ActorTrustScoreBase {
    public UUID id;
    public String actorId;
    public String tenancyId;
    public double globalScore;
    public Map<String, Double> capabilityScores;
    public Map<String, Map<String, Double>> dimensionScores;
    public ScoreType scoreType;
    public Instant computedAt;
}
```

Create similar base POJOs for `LedgerMerkleFrontierBase`, `TrustScoreSnapshotBase`, `ActorIdentityBindingBase`. Read the corresponding runtime entity to extract the field set — strip JPA annotations, keep only public fields and api-level type references.

- [ ] **Step 2: Move 7 SPI interfaces from runtime to api**

Use `ide_move_file` for each interface. This updates all references across the project automatically.

```
ide_move_file: runtime/.../repository/CrossTenantLedgerEntryRepository.java → api/.../api/spi/
ide_move_file: runtime/.../repository/ActorTrustScoreRepository.java → api/.../api/spi/
ide_move_file: runtime/.../repository/ActorIdentityBindingRepository.java → api/.../api/spi/
ide_move_file: runtime/.../repository/ErasureReceiptRepository.java → api/.../api/spi/
ide_move_file: runtime/.../repository/KeyRotationRepository.java → api/.../api/spi/
ide_move_file: runtime/.../repository/LedgerMerkleFrontierRepository.java → api/.../api/spi/
ide_move_file: runtime/.../repository/TrustScoreSnapshotRepository.java → api/.../api/spi/
```

After moving, update interface method signatures to reference api-level base types instead of runtime entity types. For example, `ActorTrustScoreRepository.findAll()` returns `List<ActorTrustScoreBase>` instead of `List<ActorTrustScore>`. The JPA entity `ActorTrustScore extends ActorTrustScoreBase` — JPA implementations return entity subtypes (valid via inheritance).

- [ ] **Step 3: Add `findAllDetached()` to `ActorTrustScoreRepository`**

The spec requires this for `TrustScoreComputationService` core extraction — `em.detach()` calls must be extracted to the SPI.

```java
default List<ActorTrustScoreBase> findAllDetached(String tenancyId) {
    return findAll(tenancyId);
}
```

JPA implementations override this to call `em.detach()` on each entity before returning.

- [ ] **Step 4: Add `countByActorId()` to `CrossTenantLedgerEntryRepository`**

Required for `ErasureServiceCore` extraction — replaces direct EM query.

```java
long countByActorId(String actorId, String tenancyId);
```

- [ ] **Step 5: Move 5 NoOp repos from runtime to ledger-core**

Use `ide_move_file` for each:
- `NoOpErasureReceiptRepository` → `ledger-core/src/main/java/io/casehub/ledger/core/repository/`
- `NoOpActorTrustScoreRepository` → same
- `NoOpActorIdentityBindingRepository` → same
- `NoOpLedgerMerkleFrontierRepository` → same
- `NoOpTrustScoreSnapshotRepository` → same

Strip CDI annotations (`@DefaultBean`, `@ApplicationScoped`) — these become plain Java classes. The runtime module wraps them with thin CDI `@DefaultBean` producers.

- [ ] **Step 6: Verify compilation**

Run: `mvn --batch-mode compile -pl api,ledger-core,runtime,persistence-memory,testing -am`
Expected: BUILD SUCCESS — all references updated by ide_move_file.

- [ ] **Step 7: Run existing tests**

Run: `mvn --batch-mode test -pl runtime`
Expected: All existing tests pass.

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/ledger add api/ ledger-core/ runtime/ persistence-memory/
git -C /Users/mdproctor/claude/casehub/slots/198/ledger commit -m "refactor(#213): relocate 7 repository SPIs to api module, extract NoOp repos to core

Move CrossTenantLedgerEntryRepository, ActorTrustScoreRepository,
ActorIdentityBindingRepository, ErasureReceiptRepository,
KeyRotationRepository, LedgerMerkleFrontierRepository, and
TrustScoreSnapshotRepository from runtime.repository to api.spi.

Create api-level base POJOs for entity types. Add findAllDetached()
and countByActorId() SPI methods. Extract 5 NoOp repos to ledger-core.

Refs casehubio/ledger#213

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: Create ledger-jpa-common module + entity extraction

**Files:**
- Create: `ledger-jpa-common/pom.xml`
- Create: `ledger-jpa-common/src/main/java/io/casehub/ledger/jpa/` (package dir)
- Move: 15 entity files from `runtime/src/main/java/io/casehub/ledger/runtime/model/` → `ledger-jpa-common/src/main/java/io/casehub/ledger/jpa/`
- Move: `runtime/src/main/resources/db/ledger/migration/` → `ledger-jpa-common/src/main/resources/db/ledger/migration/`
- Move: `runtime/src/main/java/io/casehub/ledger/runtime/persistence/LedgerPersistenceUnit.java` → `ledger-jpa-common/`
- Move: `runtime/src/main/java/io/casehub/ledger/runtime/repository/jpa/LedgerSequenceAllocator.java` → `ledger-jpa-common/`
- Modify: `runtime/pom.xml` — add `casehub-ledger-jpa-common` dependency
- Modify: `pom.xml` (parent) — add `ledger-jpa-common` module
- Modify: `JpaLedgerEntry` — remove `@EntityListeners` annotation
- Create: `runtime/src/main/resources/META-INF/orm.xml` — register entity listeners for Quarkus
- Test: existing runtime tests

**Interfaces:**
- Consumes: api-level base POJOs from Task 1
- Produces: `ledger-jpa-common` module with all JPA entities, Flyway migrations, `LedgerSequenceAllocator`, `LedgerPersistenceUnit`

- [ ] **Step 1: Create `ledger-jpa-common/pom.xml`**

Use `ide_create_file`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-ledger-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-ledger-jpa-common</artifactId>
    <name>CaseHub Ledger - JPA Common</name>
    <description>Shared JPA entities, Flyway migrations, and JPA helpers for ledger persistence</description>

    <properties>
        <maven.deploy.skip>false</maven.deploy.skip>
    </properties>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-ledger-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>jakarta.persistence</groupId>
            <artifactId>jakarta.persistence-api</artifactId>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.core</groupId>
            <artifactId>jackson-databind</artifactId>
            <scope>provided</scope>
        </dependency>
        <dependency>
            <groupId>org.hibernate.orm</groupId>
            <artifactId>hibernate-core</artifactId>
            <scope>provided</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.smallrye</groupId>
                <artifactId>jandex-maven-plugin</artifactId>
                <executions>
                    <execution>
                        <id>make-index</id>
                        <goals><goal>jandex</goal></goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Add module to parent pom.xml**

Use `ide_edit_member` on `pom.xml` to add `<module>ledger-jpa-common</module>` after `<module>ledger-core</module>` in the modules list.

- [ ] **Step 3: Move entity classes**

Use `ide_move_file` for each of the 15 entity files. Target package: `io.casehub.ledger.jpa`. This is the critical step — IntelliJ updates all import references across the project.

Entity files to move (each via `ide_move_file`):
1. `runtime/.../model/jpa/JpaLedgerEntry.java`
2. `runtime/.../model/PlainLedgerEntry.java`
3. `runtime/.../model/ErasureReceiptLedgerEntry.java`
4. `runtime/.../model/KeyRotationEntry.java`
5. `runtime/.../model/LedgerEntryArchiveRecord.java`
6. `runtime/.../model/LedgerMerkleFrontier.java`
7. `runtime/.../model/ActorTrustScore.java`
8. `runtime/.../model/TrustScoreSnapshot.java`
9. `runtime/.../model/ActorIdentity.java`
10. `runtime/.../model/ActorIdentityBindingEntry.java`
11. `runtime/.../model/supplement/JpaCompensationSupplement.java`
12. `runtime/.../model/supplement/JpaComplianceSupplement.java`
13. `runtime/.../model/supplement/JpaProvenanceSupplement.java`
14. `runtime/.../model/converter/DomainDataConverter.java`
15. `runtime/.../model/LedgerAttestation.java`

- [ ] **Step 4: Make entity classes extend api-level base POJOs**

For entity types that gained api-level bases in Task 1: update `ActorTrustScore extends ActorTrustScoreBase`, `LedgerMerkleFrontier extends LedgerMerkleFrontierBase`, etc. Use `ide_edit_member` to add `extends` clause.

- [ ] **Step 5: Remove `@EntityListeners` from `JpaLedgerEntry`**

Use `ide_edit_member` to remove the `@EntityListeners({LedgerTraceListener.class, LedgerIdentityEnforcementListener.class})` annotation from the class declaration.

- [ ] **Step 6: Create Quarkus `orm.xml` for entity listener registration**

Create `runtime/src/main/resources/META-INF/orm.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<entity-mappings xmlns="https://jakarta.ee/xml/ns/persistence/orm"
                 version="3.1">
    <entity class="io.casehub.ledger.jpa.JpaLedgerEntry">
        <entity-listeners>
            <entity-listener class="io.casehub.ledger.runtime.service.LedgerTraceListener"/>
            <entity-listener class="io.casehub.ledger.runtime.service.identity.LedgerIdentityEnforcementListener"/>
        </entity-listeners>
    </entity>
</entity-mappings>
```

- [ ] **Step 7: Move Flyway migrations**

```bash
mkdir -p /Users/mdproctor/claude/casehub/slots/198/ledger/ledger-jpa-common/src/main/resources/db/ledger/migration
mv /Users/mdproctor/claude/casehub/slots/198/ledger/runtime/src/main/resources/db/ledger/migration/* /Users/mdproctor/claude/casehub/slots/198/ledger/ledger-jpa-common/src/main/resources/db/ledger/migration/
```

- [ ] **Step 8: Move `LedgerSequenceAllocator` and `LedgerPersistenceUnit`**

Use `ide_move_file` for:
- `LedgerSequenceAllocator` → `ledger-jpa-common/.../jpa/LedgerSequenceAllocator.java`
- `LedgerPersistenceUnit` → `ledger-jpa-common/.../jpa/LedgerPersistenceUnit.java`

Extract `LedgerSequenceAllocator` to accept `EntityManager` via constructor (remove `@Inject` field).

- [ ] **Step 9: Add jpa-common dependency to runtime pom**

Use `ide_edit_member` on `runtime/pom.xml` to add:
```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-ledger-jpa-common</artifactId>
    <version>${project.version}</version>
</dependency>
```

- [ ] **Step 10: Verify and test**

Run: `mvn --batch-mode compile -pl ledger-jpa-common,runtime -am`
Then: `mvn --batch-mode test -pl runtime`
Expected: BUILD SUCCESS, all tests pass.

- [ ] **Step 11: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/ledger add ledger-jpa-common/ runtime/ pom.xml
git -C /Users/mdproctor/claude/casehub/slots/198/ledger commit -m "refactor(#213): create ledger-jpa-common — extract 15 entities, Flyway migrations, sequence allocator

Extract all JPA entity classes from runtime/model/ to ledger-jpa-common.
Move Flyway migrations and LedgerSequenceAllocator to shared module.
Remove @EntityListeners from JpaLedgerEntry, register via orm.xml.

Refs casehubio/ledger#213

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: Config Records + Adapter

### Task 3: LedgerProperties record hierarchy in ledger-core

**Files:**
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/LedgerProperties.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/HashChainProperties.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/TrustScoreProperties.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/RetentionProperties.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/MerkleProperties.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/IdentityProperties.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/DecayProperties.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/HealthProperties.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/AgentSigningProperties.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/OutcomeProperties.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/ErasureReceiptProperties.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/MetadataProperties.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/DecisionContextProperties.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/EvidenceProperties.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/AttestationProperties.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/config/AgentIdentityProperties.java`
- Test: `ledger-core/src/test/java/io/casehub/ledger/core/config/LedgerPropertiesTest.java`

**Interfaces:**
- Consumes: nothing — pure data records
- Produces: `LedgerProperties` record hierarchy (17 top-level records + 10 nested records) consumed by all core POJOs in subsequent tasks

- [ ] **Step 1: Write test for LedgerProperties construction**

```java
package io.casehub.ledger.core.config;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
import java.util.Map;
import java.util.Optional;

class LedgerPropertiesTest {

    @Test
    void constructsWithDefaults() {
        var props = LedgerProperties.defaults();
        assertThat(props.enabled()).isTrue();
        assertThat(props.hashChain().enabled()).isTrue();
        assertThat(props.trustScore().enabled()).isFalse();
        assertThat(props.trustScore().decayHalfLifeDays()).isEqualTo(90);
        assertThat(props.retention().enabled()).isFalse();
        assertThat(props.retention().operationalDays()).isEqualTo(180);
        assertThat(props.metadata().maxSize()).isEqualTo(65536);
        assertThat(props.datasource()).isEmpty();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl ledger-core -Dtest=LedgerPropertiesTest`
Expected: FAIL — `LedgerProperties` class not found.

- [ ] **Step 3: Create all property records**

Read `runtime/src/main/java/io/casehub/ledger/runtime/config/LedgerConfig.java` to extract every field, default value, and nesting. Create each record with a static `defaults()` factory that returns default values matching `@WithDefault` annotations.

Top-level record `LedgerProperties` references 16 sub-records. Each sub-record is a separate file in `core.config` package. Nested records (e.g., `TrustScoreProperties.EigenTrustProperties`) are defined as inner records within their parent.

Key records with defaults:

```java
// LedgerProperties.java
public record LedgerProperties(
    boolean enabled, Optional<String> datasource,
    HashChainProperties hashChain, DecisionContextProperties decisionContext,
    EvidenceProperties evidence, AttestationProperties attestations,
    TrustScoreProperties trustScore, RetentionProperties retention,
    MerkleProperties merkle, IdentityProperties identity,
    DecayProperties decay, HealthProperties health,
    AgentSigningProperties agentSigning, OutcomeProperties outcome,
    ErasureReceiptProperties erasureReceipt, MetadataProperties metadata,
    AgentIdentityProperties agentIdentity
) {
    public static LedgerProperties defaults() {
        return new LedgerProperties(true, Optional.empty(),
            HashChainProperties.defaults(), DecisionContextProperties.defaults(),
            EvidenceProperties.defaults(), AttestationProperties.defaults(),
            TrustScoreProperties.defaults(), RetentionProperties.defaults(),
            MerkleProperties.defaults(), IdentityProperties.defaults(),
            DecayProperties.defaults(), HealthProperties.defaults(),
            AgentSigningProperties.defaults(), OutcomeProperties.defaults(),
            ErasureReceiptProperties.defaults(), MetadataProperties.defaults(),
            AgentIdentityProperties.defaults());
    }
}

// HashChainProperties.java
public record HashChainProperties(boolean enabled) {
    public static HashChainProperties defaults() { return new HashChainProperties(true); }
}

// MetadataProperties.java
public record MetadataProperties(int maxSize) {
    public static MetadataProperties defaults() { return new MetadataProperties(65536); }
}

// TrustScoreProperties.java — has nested records
public record TrustScoreProperties(
    boolean enabled, int decayHalfLifeDays, boolean routingEnabled,
    double routingDeltaThreshold, String schedule,
    EigenTrustProperties eigentrust, ExportProperties export,
    BootstrapProperties bootstrap, MaterializationProperties materialization,
    IncrementalProperties incremental, SnapshotProperties snapshot,
    AttestationAggregator.Strategy aggregationStrategy
) {
    public record EigenTrustProperties(boolean enabled, double alpha, Optional<java.util.List<String>> preTrustedActors) {
        public static EigenTrustProperties defaults() { return new EigenTrustProperties(false, 0.15, Optional.empty()); }
    }
    // ... ExportProperties, BootstrapProperties, MaterializationProperties, IncrementalProperties, SnapshotProperties
    public static TrustScoreProperties defaults() { /* ... all defaults from LedgerConfig */ }
}
```

Create all 17 files. Every default value must match the `@WithDefault` annotation in `LedgerConfig.java`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl ledger-core -Dtest=LedgerPropertiesTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/ledger add ledger-core/
git -C /Users/mdproctor/claude/casehub/slots/198/ledger commit -m "feat(#213): LedgerProperties record hierarchy — 17 framework-neutral config records

Mirror LedgerConfig's 25 sub-interfaces as pure Java records in
ledger-core. Static defaults() factories match all @WithDefault values.

Refs casehubio/ledger#213

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4: LedgerConfigAdapter (Quarkus) + Event Publisher Interfaces

**Files:**
- Create: `runtime/src/main/java/io/casehub/ledger/runtime/config/LedgerConfigAdapter.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/event/TrustScoreEventPublisher.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/event/LedgerEventPublisher.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/event/TrustScoreComputedAt.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/event/TrustScoreActorUpdatedEvent.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/event/AttestationRecordedEvent.java`
- Move: `runtime/.../service/routing/TrustScoreDelta.java` → `ledger-core/.../core/event/`
- Move: `runtime/.../service/routing/TrustScoreDeltaPayload.java` → `ledger-core/.../core/event/`
- Move: `runtime/.../service/routing/TrustScoreFullPayload.java` → `ledger-core/.../core/event/`
- Move: `runtime/.../service/routing/TrustScoreComputedAt.java` → `ledger-core/.../core/event/` (if exists)
- Test: `runtime/src/test/java/io/casehub/ledger/config/LedgerConfigAdapterTest.java`

**Interfaces:**
- Consumes: `LedgerProperties` from Task 3, `LedgerConfig` (Quarkus @ConfigMapping)
- Produces: `LedgerConfigAdapter.toProperties(LedgerConfig) → LedgerProperties`, `TrustScoreEventPublisher`, `LedgerEventPublisher`, event payload records in core

- [ ] **Step 1: Write test for adapter**

```java
@QuarkusTest
class LedgerConfigAdapterTest {
    @Inject LedgerConfig config;

    @Test
    void convertsAllFieldsFromConfigMapping() {
        var props = LedgerConfigAdapter.toProperties(config);
        assertThat(props.enabled()).isEqualTo(config.enabled());
        assertThat(props.trustScore().decayHalfLifeDays()).isEqualTo(config.trustScore().decayHalfLifeDays());
        assertThat(props.metadata().maxSize()).isEqualTo(config.metadata().maxSize());
    }
}
```

- [ ] **Step 2: Create event publisher interfaces in ledger-core**

```java
// ledger-core/src/main/java/io/casehub/ledger/core/event/TrustScoreEventPublisher.java
package io.casehub.ledger.core.event;

public interface TrustScoreEventPublisher {
    void publishFull(TrustScoreFullPayload payload);
    void publishDelta(TrustScoreDeltaPayload payload);
    void publishNotify(TrustScoreComputedAt payload);
    boolean needsDeltaPayload();
}

// ledger-core/src/main/java/io/casehub/ledger/core/event/LedgerEventPublisher.java
package io.casehub.ledger.core.event;

import io.casehub.ledger.core.model.AgentKeyRotatedEvent;

public interface LedgerEventPublisher {
    void publishKeyRotated(AgentKeyRotatedEvent event);
    void publishActorTrustUpdated(TrustScoreActorUpdatedEvent event);
    void publishAttestationRecorded(AttestationRecordedEvent event);
}
```

- [ ] **Step 3: Move event payload types to ledger-core**

Use `ide_move_file` for `TrustScoreDelta`, `TrustScoreDeltaPayload`, `TrustScoreFullPayload` from `runtime.service.routing` to `ledger-core.event`. Create new event records: `TrustScoreComputedAt`, `TrustScoreActorUpdatedEvent`, `AttestationRecordedEvent`.

Update `TrustScoreFullPayload` to reference `ActorTrustScoreBase` (api type) instead of `ActorTrustScore` (JPA entity).

- [ ] **Step 4: Create `LedgerConfigAdapter`**

```java
package io.casehub.ledger.runtime.config;

import io.casehub.ledger.core.config.*;
import java.util.Optional;

public final class LedgerConfigAdapter {
    private LedgerConfigAdapter() {}

    public static LedgerProperties toProperties(LedgerConfig config) {
        return new LedgerProperties(
            config.enabled(), config.datasource(),
            new HashChainProperties(config.hashChain().enabled()),
            // ... map every sub-interface to its record
        );
    }
}
```

Map every nested config interface to its corresponding record. This is mechanical — read each getter from `LedgerConfig`, call the matching record constructor.

- [ ] **Step 5: Run test, verify, commit**

Run: `mvn --batch-mode test -pl runtime -Dtest=LedgerConfigAdapterTest`
Then commit.

---

## Batch 3: Core Extraction — Services

### Task 5: Enricher pipeline + priority system

**Files:**
- Modify: `ledger-core/src/main/java/io/casehub/ledger/core/enricher/LedgerEntryEnricher.java` — add `default int priority()`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/enricher/EnricherPipelineCore.java`
- Modify: `runtime/.../service/LedgerEnricherPipeline.java` — delegate to `EnricherPipelineCore`
- Test: `ledger-core/src/test/java/io/casehub/ledger/core/enricher/EnricherPipelineCoreTest.java`

**Interfaces:**
- Consumes: `LedgerEntryEnricher` SPI (already in core)
- Produces: `EnricherPipelineCore(List<LedgerEntryEnricher>)` — constructor-injected, sorts by `priority()`, error-isolated per enricher

- [ ] **Step 1: Write failing test**

```java
package io.casehub.ledger.core.enricher;

import io.casehub.ledger.api.model.LedgerEntry;
import org.junit.jupiter.api.Test;
import java.util.ArrayList;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class EnricherPipelineCoreTest {

    @Test
    void enrichersRunInPriorityOrder() {
        var order = new ArrayList<String>();
        var enrichers = List.<LedgerEntryEnricher>of(
            new TestEnricher("second", 20, order),
            new TestEnricher("first", 10, order),
            new TestEnricher("third", 30, order)
        );
        var pipeline = new EnricherPipelineCore(enrichers);
        pipeline.enrich(new StubLedgerEntry());
        assertThat(order).containsExactly("first", "second", "third");
    }

    @Test
    void failingEnricherDoesNotBlockPipeline() {
        var order = new ArrayList<String>();
        var enrichers = List.<LedgerEntryEnricher>of(
            new TestEnricher("before", 10, order),
            new FailingEnricher(20),
            new TestEnricher("after", 30, order)
        );
        var pipeline = new EnricherPipelineCore(enrichers);
        pipeline.enrich(new StubLedgerEntry());
        assertThat(order).containsExactly("before", "after");
    }

    record TestEnricher(String name, int prio, List<String> order) implements LedgerEntryEnricher {
        @Override public void enrich(LedgerEntry entry) { order.add(name); }
        @Override public int priority() { return prio; }
    }

    record FailingEnricher(int prio) implements LedgerEntryEnricher {
        @Override public void enrich(LedgerEntry entry) { throw new RuntimeException("boom"); }
        @Override public int priority() { return prio; }
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `mvn --batch-mode test -pl ledger-core -Dtest=EnricherPipelineCoreTest`
Expected: FAIL — `EnricherPipelineCore` not found.

- [ ] **Step 3: Add `priority()` to `LedgerEntryEnricher`**

Use `ide_insert_member` on `LedgerEntryEnricher`:

```java
default int priority() { return Integer.MAX_VALUE; }
```

- [ ] **Step 4: Implement `EnricherPipelineCore`**

```java
package io.casehub.ledger.core.enricher;

import io.casehub.ledger.api.model.LedgerEntry;
import java.util.Comparator;
import java.util.List;
import java.util.logging.Level;
import java.util.logging.Logger;

public class EnricherPipelineCore {
    private static final Logger log = Logger.getLogger(EnricherPipelineCore.class.getName());
    private final List<LedgerEntryEnricher> enrichers;

    public EnricherPipelineCore(List<LedgerEntryEnricher> enrichers) {
        this.enrichers = enrichers.stream()
                .sorted(Comparator.comparingInt(LedgerEntryEnricher::priority))
                .toList();
    }

    public void enrich(LedgerEntry entry) {
        for (var enricher : enrichers) {
            try {
                enricher.enrich(entry);
            } catch (Exception ex) {
                log.log(Level.WARNING, "Enricher {0} failed — entry will still be saved: {1}",
                        new Object[]{enricher.getClass().getSimpleName(), ex.getMessage()});
            }
        }
    }
}
```

- [ ] **Step 5: Run test, verify pass, commit**

Run: `mvn --batch-mode test -pl ledger-core -Dtest=EnricherPipelineCoreTest`
Expected: PASS.

- [ ] **Step 6: Update runtime `LedgerEnricherPipeline` to delegate**

Use `ide_replace_member` on `LedgerEnricherPipeline` to replace the `enrich()` body. The CDI bean becomes a thin shell:

```java
@ApplicationScoped
public class LedgerEnricherPipeline {
    private final EnricherPipelineCore core;

    @Inject
    LedgerEnricherPipeline(@Any Instance<LedgerEntryEnricher> enrichers) {
        this.core = new EnricherPipelineCore(enrichers.stream().toList());
    }

    public void enrich(LedgerEntry entry) { core.enrich(entry); }
}
```

- [ ] **Step 7: Run runtime tests, commit**

### Task 6: Trust scoring services extraction

**Files:**
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/trust/TrustScoreComputationService.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/trust/PerActorTrustComputerCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/trust/IncrementalTrustUpdater.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/trust/TrustScorePublisherCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/trust/ComputedTrustSourceCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/trust/MaterializedTrustSourceCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/trust/EigenTrustValidator.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/federation/TrustBootstrapServiceCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/federation/TrustExportServiceCore.java`
- Modify: corresponding runtime service classes → thin CDI shells
- Test: `ledger-core/src/test/java/io/casehub/ledger/core/trust/TrustScoreComputationServiceTest.java`

**Interfaces:**
- Consumes: `LedgerProperties.TrustScoreProperties`, `TrustScoreEventPublisher`, `ActorTrustScoreRepository`, `CrossTenantLedgerEntryRepository`, `TrustScoreCalculator`, `TrustScoreSnapshotRepository`, `TrustBootstrapSource`
- Produces: `TrustScoreComputationService(...)` — the core POJO that framework shells invoke from `@Scheduled`

- [ ] **Step 1: Write test for `TrustScoreComputationService`**

Test that `runComputation()` reads all attestations, computes scores via `TrustScoreCalculator`, saves via repository, publishes via `TrustScoreEventPublisher`.

```java
class TrustScoreComputationServiceTest {
    @Test
    void computesAndPublishesTrustScores() {
        // Arrange — mock repositories, calculator, publisher
        var trustRepo = mock(ActorTrustScoreRepository.class);
        var ledgerRepo = mock(CrossTenantLedgerEntryRepository.class);
        var calculator = new TrustScoreCalculator(
            ExponentialDecayFunction.defaults(), new AllAttestationsGlobalStrategy(), new NoOpAttestorCredibilityPolicy());
        var publisher = mock(TrustScoreEventPublisher.class);
        var snapshotRepo = mock(TrustScoreSnapshotRepository.class);
        var props = TrustScoreProperties.defaults();

        var service = new TrustScoreComputationService(
            ledgerRepo, trustRepo, snapshotRepo, calculator, publisher,
            new EigenTrustComputer(), props,
            new NoOpTrustBootstrapSource(), new NoOpTrustImportService());

        // Act
        service.runComputation("tenant-1");

        // Assert — publisher called, scores saved
        verify(publisher).publishNotify(any());
    }
}
```

- [ ] **Step 2-5: Implement each core POJO, run tests**

For each service in the extraction inventory:

**`TrustScoreComputationService`** — Constructor: `(CrossTenantLedgerEntryRepository, ActorTrustScoreRepository, TrustScoreSnapshotRepository, TrustScoreCalculator, TrustScoreEventPublisher, EigenTrustComputer, TrustScoreProperties, TrustBootstrapSource, TrustImportService)`. Methods: `runComputation(String tenancyId)`. Transaction boundary on framework shell.

**`PerActorTrustComputerCore`** — Constructor: `(CrossTenantLedgerEntryRepository, ActorTrustScoreRepository, TrustScoreCalculator, TrustScoreProperties)`. Methods: `recomputeForActor(String actorId, String tenancyId)`.

**`IncrementalTrustUpdater`** — Constructor: `(PerActorTrustComputerCore, TrustScoreEventPublisher, TrustScoreProperties)`. Methods: `handleAttestationRecorded(AttestationRecordedEvent)`. Framework shell adds `AFTER_SUCCESS + REQUIRES_NEW`.

**`TrustScorePublisherCore`** — Constructor: `(TrustScoreEventPublisher, ActorTrustScoreRepository, TrustScoreProperties)`. Methods: `publishScores(List<ActorTrustScoreBase> previous, List<ActorTrustScoreBase> current, Instant computedAt)`. Calls `needsDeltaPayload()` to skip pre-read when no observers exist.

**`ComputedTrustSourceCore`** — Constructor: `(CrossTenantLedgerEntryRepository, TrustScoreCalculator)`. Implements `TrustScoreSource`. Methods: `getScore(actorId, tenancyId)`.

**`MaterializedTrustSourceCore`** — Constructor: `(ActorTrustScoreRepository)`. Implements `TrustScoreSource`. Methods: `getScore(actorId, tenancyId)`.

**`EigenTrustValidator`** — Constructor: `(TrustScoreProperties)`. Methods: `validate()` — throws if eigentrust enabled without pre-trusted actors.

**`TrustBootstrapServiceCore`** — Constructor: `(TrustBootstrapSource, ActorTrustScoreRepository, TrustScoreCalculator)`. Methods: `bootstrapNewActors(Set<String>, tenancyId)`.

**`TrustExportServiceCore`** — Constructor: `(ActorTrustScoreRepository, TrustScoreProperties)`. Methods: `export(tenancyId) → TrustExportPayload`.

- [ ] **Step 6: Convert runtime services to thin CDI shells**

Each runtime service becomes a thin `@ApplicationScoped` CDI bean:
- Constructor `@Inject`s dependencies
- Builds the core POJO in constructor
- Delegates all method calls to core POJO
- `@Scheduled` and `@Transactional` stay on the shell

- [ ] **Step 7: Run all tests, commit**

### Task 7: Health, retention, compliance, verification, and remaining services

**Files:**
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/LedgerHealthService.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/RetentionService.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/ComplianceReportServiceCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/ProvExportServiceCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/VerificationServiceCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/KeyRotationServiceCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/SignatureVerificationCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/LedgerAppenderCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/OutcomeRecorderCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/OutcomeRecordSaveCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/ErasureServiceCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/MerklePublisherCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/signing/PemFileAgentSigner.java`
- Move: `runtime/.../service/intercept/ProvenanceContext.java` → `ledger-core/.../core/service/`
- Move: `runtime/.../service/intercept/ComplianceSupplementContext.java` → `ledger-core/.../core/service/`
- Test: one test per core POJO

**Interfaces:**
- Consumes: `LedgerProperties`, repo SPIs, `EnricherPipelineCore`, `LedgerEventPublisher`
- Produces: All remaining core POJOs

Constructor signatures for each (all fields via constructor, zero framework imports):

**`LedgerHealthService`** — `(LedgerEntryRepository, LedgerMerkleFrontierRepository, HealthProperties)`
**`RetentionService`** — `(LedgerEntryRepository, CrossTenantLedgerEntryRepository, RetentionProperties)`
**`ComplianceReportServiceCore`** — `(LedgerEntryRepository, ActorTrustScoreRepository)`
**`ProvExportServiceCore`** — `(LedgerEntryRepository)`
**`VerificationServiceCore`** — `(LedgerEntryRepository, LedgerMerkleFrontierRepository)`
**`KeyRotationServiceCore`** — `(KeyRotationRepository, LedgerEventPublisher, AgentSigningProperties)`
**`SignatureVerificationCore`** — `(LedgerEntryRepository, AgentSigner)`
**`LedgerAppenderCore`** — `(LedgerEntryRepository, MetadataProperties)`
**`OutcomeRecorderCore`** — `(LedgerAppenderCore, OutcomeRecordSaveCore, OutcomeProperties, CurrentPrincipal)`
**`OutcomeRecordSaveCore`** — `(LedgerEntryRepository, EnricherPipelineCore)`
**`ErasureServiceCore`** — `(CrossTenantLedgerEntryRepository, ActorIdentityProvider, ErasureReceiptProperties)`
**`MerklePublisherCore`** — `(LedgerMerkleFrontierRepository, MerkleProperties)`
**`PemFileAgentSigner`** — `(AgentSigningProperties)` — loads PEM key pairs in constructor, implements `AgentSigner`

Follow the same TDD pattern as Task 5: write failing test → implement core POJO → verify pass → convert runtime service to thin shell → verify runtime tests → commit.

### Task 8: Identity services + enricher core extraction

**Files:**
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/identity/ActorDIDEnricherCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/identity/IdentityValidationEnricherCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/identity/AgentIdentityVerificationCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/identity/IdentityBindingHandler.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/identity/CacheInvalidationHandler.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/identity/IdentityEnforcementHandler.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/TraceIdEnricherCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/ComplianceSupplementEnricherCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/service/ProvenanceCaptureEnricherCore.java`

**Interfaces:**
- Consumes: `LedgerEntryEnricher` SPI, `ActorDIDProvider`, `AgentCredentialValidator`, `DIDResolver`, `AgentIdentityProperties`
- Produces: enricher core POJOs implementing `LedgerEntryEnricher` with `priority()` values

Priority values: `TraceIdEnricherCore.priority() = 10`, `ActorDIDEnricherCore.priority() = 40`, `IdentityValidationEnricherCore.priority() = 50`.

Include unit test verifying ordering invariant:
```java
@Test
void didResolutionBeforeValidation() {
    assertThat(new ActorDIDEnricherCore(null, null).priority())
        .isLessThan(new IdentityValidationEnricherCore(null, null).priority());
}
```

---

## Batch 4: Core Extraction — API Layer

### Task 9: @McpDomain API impl extraction + GraphQL DTOs

**Files:**
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/api/LedgerEntryApiCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/api/LedgerAttestationApiCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/api/LedgerTrustApiCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/api/LedgerVerificationApiCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/api/LedgerQueryCore.java`
- Create: `ledger-core/src/main/java/io/casehub/ledger/core/api/LedgerMutationCore.java`
- Move: 10 GraphQL DTO files from `graphql/.../dto/` → `api/.../api/graphql/dto/` (use `ide_move_file`)
- Modify: `rest/.../api/DefaultLedger*Api.java` — thin shells delegating to core
- Modify: `graphql/.../LedgerQueryResolver.java` — thin shell delegating to core
- Modify: `graphql/.../LedgerMutationResolver.java` — thin shell delegating to core

**Interfaces:**
- Consumes: all core service POJOs, repo SPIs
- Produces: API core POJOs (consumed by Spring graphql-spring-generator output)

Each API core POJO mirrors the original `@McpDomain` class but with constructor injection instead of `@Inject` fields. Strip all CDI/JAX-RS annotations. The framework shell keeps `@McpDomain`, `@PlatformQuery`, `@PlatformMutation` and delegates.

---

## Batch 5: Spring Modules

### Task 10: Create ledger-spring module

**Files:**
- Create: `ledger-spring/pom.xml` — with spring-generator, graphql-spring-generator, rest-spring-generator plugin declarations
- Create: `ledger-spring/src/main/java/io/casehub/ledger/spring/LedgerConfigurationProperties.java`
- Create: `ledger-spring/src/main/java/io/casehub/ledger/spring/LedgerSchedulingConfig.java`
- Create: `ledger-spring/src/main/java/io/casehub/ledger/spring/LedgerEventConfig.java`
- Create: `ledger-spring/src/main/java/io/casehub/ledger/spring/LedgerEnricherConfig.java`
- Create: `ledger-spring/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`
- Modify: `pom.xml` (parent) — add `ledger-spring` module

**Interfaces:**
- Consumes: all core POJOs, `LedgerProperties` records
- Produces: Spring auto-configuration beans

`LedgerConfigurationProperties`: `@ConfigurationProperties(prefix = "casehub.ledger")` bean with a `toProperties()` method that constructs `LedgerProperties`.

`LedgerSchedulingConfig`: `@Configuration @EnableScheduling` with `@Scheduled` methods calling `TrustScoreComputationService.runComputation()`, `LedgerHealthService.check()`, `RetentionService.run()`.

`LedgerEventConfig`: `@Configuration` implementing `TrustScoreEventPublisher` and `LedgerEventPublisher` via `ApplicationEventPublisher`. `needsDeltaPayload()` scans for `@EventListener` methods at `@PostConstruct`.

Generator plugins in pom.xml:
```xml
<plugin>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-spring-generator</artifactId>
    <configuration><quarkusModule>${project.basedir}/../runtime</quarkusModule></configuration>
    <executions>
        <execution><id>generate</id><goals><goal>generate</goal></goals></execution>
        <execution><id>verify</id><phase>verify</phase><goals><goal>verify</goal></goals></execution>
    </executions>
</plugin>
<plugin>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-graphql-spring-generator</artifactId>
    <configuration><quarkusModule>${project.basedir}/../rest</quarkusModule></configuration>
    <executions>
        <execution><id>generate</id><goals><goal>generate</goal></goals></execution>
        <execution><id>verify</id><phase>verify</phase><goals><goal>verify</goal></goals></execution>
    </executions>
</plugin>
<plugin>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-rest-spring-generator</artifactId>
    <configuration><quarkusModule>${project.basedir}/../rest</quarkusModule></configuration>
    <executions>
        <execution><id>generate</id><goals><goal>generate</goal></goals></execution>
        <execution><id>verify</id><phase>verify</phase><goals><goal>verify</goal></goals></execution>
    </executions>
</plugin>
```

Run: `mvn --batch-mode install -pl ledger-spring -am`

### Task 11: Create ledger-spring-jpa module

**Files:**
- Create: `ledger-spring-jpa/pom.xml`
- Create: `ledger-spring-jpa/src/main/java/io/casehub/ledger/spring/jpa/SpringJpaLedgerEntryRepository.java`
- Create: 7 more Spring JPA repository implementations (one per SPI)
- Create: `ledger-spring-jpa/src/main/java/io/casehub/ledger/spring/jpa/LedgerDataSourceConfig.java`
- Create: `ledger-spring-jpa/src/main/java/io/casehub/ledger/spring/jpa/LedgerJpaAutoConfiguration.java`
- Create: `ledger-spring-jpa/src/main/resources/META-INF/orm.xml` — Spring entity listeners
- Modify: `pom.xml` (parent) — add module

**Interfaces:**
- Consumes: `ledger-jpa-common` entities, `api.spi` repository interfaces, `LedgerSequenceAllocator`
- Produces: Spring Data JPA implementations of all 8 repository SPIs

Each Spring JPA repository implements the api SPI interface, uses `EntityManager` + JPQL (same queries as the Quarkus Jpa* implementations). `LedgerDataSourceConfig` routes to the correct datasource based on `LedgerProperties.datasource()`.

---

## Batch 6: Signing Spring Module

### Task 12: Signing core extraction (4 backends)

**Files:**
- Create: `signing/vault-transit/src/main/java/io/casehub/ledger/signing/vault/VaultTransitAgentSignerCore.java`
- Create: `signing/vault-transit/src/main/java/io/casehub/ledger/signing/vault/VaultTransitAuthConfig.java`
- Create: similar `*AgentSignerCore` + `*AuthConfig` for aws-kms, gcp-kms, azure-keyvault
- Modify: each `signing/*-quarkus` CDI bean → thin shell extending core
- Test: unit tests for each `*AgentSignerCore`

Each signing core class: `extends AbstractCachingAgentSigner<C>`, constructor takes the signing config + auth config (core records), contains `loadContext()`, `performSign()`, `contextPublicKey()`, and auth routing logic. The Quarkus CDI bean becomes a thin shell extending the core, adding `@Scheduled` for cache refresh and `@Observes` for key rotation events.

### Task 13: Consolidated ledger-signing-spring module

**Files:**
- Create: `ledger-signing-spring/pom.xml`
- Create: `ledger-signing-spring/src/main/java/io/casehub/ledger/signing/spring/VaultTransitAutoConfiguration.java`
- Create: `ledger-signing-spring/src/main/java/io/casehub/ledger/signing/spring/VaultTransitSpringAgentSigner.java`
- Create: `ledger-signing-spring/src/main/java/io/casehub/ledger/signing/spring/VaultTransitSpringProperties.java`
- Create: similar for AwsKms, GcpKms, AzureKeyVault (4 × 3 files = 12 files)
- Modify: `pom.xml` (parent) — add module

Each `@AutoConfiguration` class uses `@ConditionalOnClass` anchored on the core signing client class (not the Quarkus bean). Each Spring `AgentSigner` extends the core class, adds `@Scheduled` for refresh and `@EventListener` for key rotation.

---

## Batch 7: Integration Test

### Task 14: ledger-spring-integration-test

**Files:**
- Create: `ledger-spring-integration-test/pom.xml`
- Create: `ledger-spring-integration-test/src/test/java/io/casehub/ledger/spring/LedgerSpringIntegrationTest.java`
- Create: `ledger-spring-integration-test/src/test/resources/application.yml`
- Modify: `pom.xml` (parent) — add module

**Test coverage:**
1. All auto-configs compose without errors
2. Health endpoint returns UP
3. Core service beans are injectable (`TrustScoreComputationService`, `LedgerAppenderCore`, `EnricherPipelineCore`)
4. Spring Data JPA repos are functional (CRUD on `PlainLedgerEntry`, `LedgerAttestation`)
5. `LedgerSequenceAllocator` dialect detection works against real PostgreSQL
6. Enricher pipeline ordering verified (DID before identity validation)
7. Flyway migrations run successfully from shared `jpa-common`

```java
@SpringBootTest
@Testcontainers
class LedgerSpringIntegrationTest {

    @Container
    static PostgreSQLContainer<?> pg = new PostgreSQLContainer<>("postgres:16-alpine");

    @DynamicPropertySource
    static void configureProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", pg::getJdbcUrl);
        registry.add("spring.datasource.username", pg::getUsername);
        registry.add("spring.datasource.password", pg::getPassword);
        registry.add("spring.flyway.locations", () -> "classpath:db/ledger/migration");
    }

    @Autowired LedgerEntryRepository ledgerRepo;
    @Autowired EnricherPipelineCore enricherPipeline;
    @Autowired LedgerAppenderCore appender;

    @Test
    void contextLoads() { /* auto-configs compose */ }

    @Test
    void repositoryPersistsAndFinds() { /* CRUD test */ }

    @Test
    void enricherPipelineOrderingCorrect() { /* priority ordering test */ }

    @Test
    void sequenceAllocatorDetectsPostgresDialect() { /* dialect detection test */ }
}
```

### Task 15: Consumer guide update

**Files:**
- Modify: `docs/guides/consumer-guide.md` — add Spring section

Add a "Spring Boot" section documenting:
- Maven dependency (`casehub-ledger-spring`, `casehub-ledger-spring-jpa`)
- Configuration properties (`casehub.ledger.*`)
- Optional signing module (`casehub-ledger-signing-spring`)
- Auto-detected beans and how to override defaults

### Task 16: Final verification + CLAUDE.md update

- [ ] Run full build: `mvn --batch-mode install`
- [ ] Verify all generator verify goals pass: `mvn --batch-mode verify -pl ledger-spring`
- [ ] Update `CLAUDE.md` module table with new modules
- [ ] Commit all changes

---

## References

- [2026-09-23-ledger-spring-deployment-design.md](../specs/issue-213-spring-boot-deployment/2026-09-23-ledger-spring-deployment-design.md) — design spec this plan implements
- [decisions.md](../specs/issue-213-spring-boot-deployment/decisions.md) — 6 design decisions
- `runtime/src/main/java/io/casehub/ledger/runtime/LedgerCoreProducer.java` — 10 @Produces methods
- `runtime/src/main/java/io/casehub/ledger/runtime/config/LedgerConfig.java:1-785` — 25 sub-interfaces
- `runtime/src/main/java/io/casehub/ledger/runtime/service/LedgerEnricherPipeline.java` — Arc InjectableInstance
- `ledger-core/src/main/java/io/casehub/ledger/core/enricher/LedgerEntryEnricher.java` — enricher SPI
- `api/src/main/java/io/casehub/ledger/api/spi/LedgerEntryRepository.java` — existing api SPI
- casehubio/ledger#213 — focal issue
