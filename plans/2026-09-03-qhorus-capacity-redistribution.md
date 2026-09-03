# Qhorus Capacity Signal Source + Redistribution Executor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/qhorus#428 — feat: capacity signal source + redistribution executor
**Issue group:** #268, #151, #428

**Goal:** Bridge qhorus CONTEXT_PRESSURE ledger data into the platform capacity signal SPI and build an automated redistribution executor that HANDOFFs obligations from overloaded agents.

**Architecture:** `ContextPressureCapacitySource` reads ledger data via cross-channel global queries and implements `CapacitySignalSource`. `QhorusRedistributionExecutor` observes `CapacityPressureEvent` via `@ObservesAsync`, delegates transactional work to `RedistributionDelegate` (compress/redistribute/escalate). Stateless across sweeps — all state lives in the commitment store, capacity view, and ledger.

**Tech Stack:** Java 21, Quarkus 3.32.2, CDI, JPA (Hibernate), Flyway, JUnit 5

## Global Constraints

- All tests are CDI-free plain JUnit — dual-constructor pattern (GE-20260602-c4a68a)
- Use IntelliJ MCP for all code navigation and editing
- Pre-release: no backward compatibility concerns
- `CapacitySignalSource`, `CapacitySignalTypes`, `CapacitySignal`, `ActorCapacity`, `RedistributionPolicy`, `RedistributionContext`, `RedistributionDecision`, `CapacityPressureEvent` are in platform-api `io.casehub.platform.api.capacity` (already implemented)
- Prerequisite qhorus#429: `ChannelSummaryService.triggerUpdate()` must use `CrossTenantChannelStore` and `countMessagesSince()` must be public — verify before implementing compress path
- `MessageDispatch` is built via `.builder()` with chained setters, not positional args
- Flyway migrations use `db/qhorus/migration/` path, next version is V2006

---

## Batch 1: Schema Foundation

### Task 1: Commitment.capabilityTag — record, entity, stores, migration, service wiring

**Files:**
- Modify: `api/src/main/java/io/casehub/qhorus/api/message/Commitment.java` — add `capabilityTag` field
- Modify: `runtime/src/main/java/io/casehub/qhorus/runtime/message/CommitmentEntity.java` — add JPA column
- Modify: `runtime/src/main/java/io/casehub/qhorus/runtime/message/CommitmentService.java:52-86` — `open()` gains `tenancyId` + `capabilityTag` params
- Modify: `runtime/src/main/java/io/casehub/qhorus/runtime/message/CommitmentService.java:245-293` — `delegate()` copies `capabilityTag` + `tenancyId` to child
- Modify: `runtime/src/main/java/io/casehub/qhorus/runtime/message/MessageService.java:418-421` — extract capabilityTag from target before routing
- Modify: `persistence-memory/src/main/java/io/casehub/qhorus/persistence/memory/InMemoryCommitmentStore.java` — handle new field
- Create: `runtime/src/main/resources/db/qhorus/migration/V2006__commitment_capability_tag.sql`
- Test: `runtime/src/test/java/io/casehub/qhorus/runtime/message/CommitmentCapabilityTagTest.java`

**Interfaces:**
- Produces: `Commitment.capabilityTag()` — nullable String, the capability from the original `role:X` target
- Produces: `CommitmentService.open(UUID, String, UUID, MessageType, String, String, Instant, String, String)` — 9-param signature with `tenancyId` + `capabilityTag`

- [ ] **Step 1: Write failing test — capabilityTag populated on role-routed COMMAND**

```java
// CommitmentCapabilityTagTest.java — CDI-free, constructs CommitmentService directly
@Test
void roleRoutedCommandSetsCapabilityTag() {
    var store = new InMemoryCommitmentStore();
    var service = new CommitmentService(store, /* mocked events + tracing */);

    UUID commitmentId = UUID.randomUUID();
    service.open(commitmentId, "corr-1", UUID.randomUUID(),
            MessageType.COMMAND, "requester-1", "agent-1",
            null, "tenant-1", "analyst");

    var commitment = store.findByCorrelationId("corr-1").orElseThrow();
    assertThat(commitment.capabilityTag()).isEqualTo("analyst");
    assertThat(commitment.tenancyId()).isEqualTo("tenant-1");
}
```

- [ ] **Step 2: Write failing test — direct-addressed COMMAND has null capabilityTag**

```java
@Test
void directAddressedCommandHasNullCapabilityTag() {
    var store = new InMemoryCommitmentStore();
    var service = new CommitmentService(store, /* mocked events + tracing */);

    UUID commitmentId = UUID.randomUUID();
    service.open(commitmentId, "corr-2", UUID.randomUUID(),
            MessageType.COMMAND, "requester-1", "agent-1",
            null, "tenant-1", null);

    var commitment = store.findByCorrelationId("corr-2").orElseThrow();
    assertThat(commitment.capabilityTag()).isNull();
}
```

- [ ] **Step 3: Write failing test — delegate() copies capabilityTag and tenancyId to child**

```java
@Test
void delegateCopiesCapabilityTagAndTenancyIdToChild() {
    var store = new InMemoryCommitmentStore();
    var service = new CommitmentService(store, /* mocked events + tracing */);

    UUID commitmentId = UUID.randomUUID();
    service.open(commitmentId, "corr-3", UUID.randomUUID(),
            MessageType.COMMAND, "requester-1", "agent-1",
            null, "tenant-1", "analyst");

    service.delegate("corr-3", "agent-2");

    var all = store.findAllByCorrelationId("corr-3");
    var child = all.stream()
            .filter(c -> c.state() == CommitmentState.OPEN)
            .findFirst().orElseThrow();
    assertThat(child.capabilityTag()).isEqualTo("analyst");
    assertThat(child.tenancyId()).isEqualTo("tenant-1");
    assertThat(child.obligor()).isEqualTo("agent-2");
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn test -Dtest=CommitmentCapabilityTagTest -pl runtime`
Expected: Compilation error — `open()` doesn't accept 9 params, `Commitment` doesn't have `capabilityTag`

- [ ] **Step 5: Add `capabilityTag` to Commitment record**

In `Commitment.java`: add `String capabilityTag` field between `tenancyId` and `createdAt`. Update the canonical constructor (15 params), `toBuilder()`, `Builder` class (add field + setter), and `build()`.

```java
// Record fields — new field after tenancyId:
String tenancyId, String capabilityTag, Instant createdAt
```

```java
// Builder — add:
private String capabilityTag;
public Builder capabilityTag(String v) { capabilityTag = v; return this; }

// build() — 15 params:
return new Commitment(id, correlationId, channelId, messageType,
        requester, obligor, state, expiresAt, acknowledgedAt,
        resolvedAt, delegatedTo, parentCommitmentId,
        tenancyId, capabilityTag, createdAt);
```

- [ ] **Step 6: Add `capabilityTag` to CommitmentEntity**

Add field after `tenancyId` (line 83):
```java
@Column(name = "capability_tag")
public String capabilityTag;
```

Update `fromDomain()`:
```java
e.capabilityTag = c.capabilityTag();
```

Update `toDomain()` — 15-param constructor:
```java
return new Commitment(id, correlationId, channelId, messageType,
        requester, obligor, state, expiresAt, acknowledgedAt,
        resolvedAt, delegatedTo, parentCommitmentId,
        tenancyId, capabilityTag, createdAt);
```

- [ ] **Step 7: Update CommitmentService.open() — add tenancyId + capabilityTag params**

New signature:
```java
public Commitment open(UUID commitmentId, String correlationId, UUID channelId,
                       MessageType type, String requester, String obligor,
                       Instant expiresAt, String tenancyId, String capabilityTag)
```

In the builder inside `open()`, add:
```java
.tenancyId(tenancyId)
.capabilityTag(capabilityTag)
```

- [ ] **Step 8: Update CommitmentService.delegate() — copy capabilityTag + tenancyId to child**

In the child Commitment builder (around line 271), add:
```java
.tenancyId(c.tenancyId())
.capabilityTag(c.capabilityTag())
```

- [ ] **Step 9: Update MessageService.dispatch() call site**

At line 418, extract capabilityTag before routing and pass to `open()`:
```java
String capabilityTag = dispatch.target() != null && dispatch.target().startsWith("role:")
        ? dispatch.target().substring("role:".length())
        : null;
commitmentService.open(
        storedCommitmentId, dispatch.correlationId(), dispatch.channelId(),
        dispatch.type(), dispatch.sender(), dispatch.target(),
        effectiveDeadline, effectiveTenancyId, capabilityTag);
```

- [ ] **Step 10: Update InMemoryCommitmentStore**

Handle the new field in any construction sites. The InMemory store persists the full `Commitment` record — the new field flows through automatically via the record constructor.

- [ ] **Step 11: Create Flyway migration**

```sql
-- V2006__commitment_capability_tag.sql
ALTER TABLE commitment ADD COLUMN capability_tag VARCHAR(255);
```

- [ ] **Step 12: Fix compilation — update all existing Commitment construction sites**

Search for `new Commitment(` and `Commitment.builder()` across all test files. Update 14-param constructor calls to 15-param (insert `null` for `capabilityTag` before `createdAt`). Builder-based construction doesn't need changes (new field defaults to null).

- [ ] **Step 13: Run tests to verify they pass**

Run: `JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn test -Dtest=CommitmentCapabilityTagTest -pl runtime`
Expected: 3 tests PASS

- [ ] **Step 14: Run full build to verify no regressions**

Run: `JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 15: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/171/qhorus add -A
git -C /Users/mdproctor/claude/casehub/slots/171/qhorus commit -m "feat(#428): Commitment.capabilityTag — schema, entity, service wiring

Adds capabilityTag (nullable String) to Commitment record and entity.
Populated from role:X target during CommitmentService.open(), copied
to child during delegate(). MessageService extracts capability before
routing resolution. V2006 migration adds the column.

Also fixes pre-existing gap: open() now receives tenancyId from
MessageService instead of defaulting to DEFAULT_TENANT_ID. delegate()
copies tenancyId to child commitment.

Refs #428"
```

---

### Task 2: CrossTenantCommitmentStore + MessageLedgerEntryRepository query extensions

**Files:**
- Modify: `api/src/main/java/io/casehub/qhorus/api/store/CrossTenantCommitmentStore.java` — add 2 methods
- Modify: `runtime/src/main/java/io/casehub/qhorus/runtime/store/jpa/JpaCrossTenantCommitmentStore.java` — JPA implementations
- Modify: `persistence-memory/src/main/java/io/casehub/qhorus/persistence/memory/InMemoryCrossTenantCommitmentStore.java` — InMemory implementations
- Modify: `runtime/src/main/java/io/casehub/qhorus/runtime/ledger/MessageLedgerEntryRepository.java` — 3 new methods
- Test: `runtime/src/test/java/io/casehub/qhorus/runtime/capacity/CapacityQueryExtensionsTest.java`

**Interfaces:**
- Produces: `CrossTenantCommitmentStore.findOpenByObligor(String)` → `List<Commitment>`
- Produces: `CrossTenantCommitmentStore.findLatestDelegatedByObligor(String)` → `Optional<Commitment>`
- Produces: `MessageLedgerEntryRepository.findLatestContextPressureForActor(String)` → `Optional<MessageLedgerEntry>`
- Produces: `MessageLedgerEntryRepository.findLatestContextPressureGlobal()` → `List<MessageLedgerEntry>`
- Produces: `MessageLedgerEntryRepository.findLatestEntryByActor(String)` → `Optional<MessageLedgerEntry>`

- [ ] **Step 1: Write failing test — findOpenByObligor returns active commitments cross-tenant**

```java
@Test
void findOpenByObligorReturnsActiveCommitmentsAcrossTenants() {
    var store = new InMemoryCommitmentStore();
    var crossTenantStore = new InMemoryCrossTenantCommitmentStore(store);

    // Create commitments in different tenants
    store.save(Commitment.builder().correlationId("c1").obligor("agent-1")
            .state(CommitmentState.OPEN).tenancyId("tenant-a").channelId(UUID.randomUUID())
            .messageType(MessageType.COMMAND).build());
    store.save(Commitment.builder().correlationId("c2").obligor("agent-1")
            .state(CommitmentState.OPEN).tenancyId("tenant-b").channelId(UUID.randomUUID())
            .messageType(MessageType.COMMAND).build());
    store.save(Commitment.builder().correlationId("c3").obligor("agent-1")
            .state(CommitmentState.DELEGATED).tenancyId("tenant-a").channelId(UUID.randomUUID())
            .messageType(MessageType.COMMAND).build());

    var result = crossTenantStore.findOpenByObligor("agent-1");
    assertThat(result).hasSize(2);
    assertThat(result).allMatch(c -> c.state().isActive());
}
```

- [ ] **Step 2: Write failing test — findLatestDelegatedByObligor**

```java
@Test
void findLatestDelegatedByObligorReturnsMostRecent() {
    var store = new InMemoryCommitmentStore();
    var crossTenantStore = new InMemoryCrossTenantCommitmentStore(store);

    store.save(Commitment.builder().correlationId("c1").obligor("agent-1")
            .state(CommitmentState.DELEGATED).resolvedAt(Instant.parse("2026-09-01T10:00:00Z"))
            .tenancyId("tenant-a").channelId(UUID.randomUUID())
            .messageType(MessageType.COMMAND).build());
    store.save(Commitment.builder().correlationId("c2").obligor("agent-1")
            .state(CommitmentState.DELEGATED).resolvedAt(Instant.parse("2026-09-02T10:00:00Z"))
            .tenancyId("tenant-a").channelId(UUID.randomUUID())
            .messageType(MessageType.COMMAND).build());

    var result = crossTenantStore.findLatestDelegatedByObligor("agent-1");
    assertThat(result).isPresent();
    assertThat(result.get().correlationId()).isEqualTo("c2");
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn test -Dtest=CapacityQueryExtensionsTest -pl runtime`
Expected: Compilation error — methods don't exist

- [ ] **Step 4: Add methods to CrossTenantCommitmentStore interface**

```java
List<Commitment> findOpenByObligor(String obligor);

Optional<Commitment> findLatestDelegatedByObligor(String obligor);
```

- [ ] **Step 5: Implement in InMemoryCrossTenantCommitmentStore**

```java
@Override
public List<Commitment> findOpenByObligor(String obligor) {
    return delegate.findAllOpen().stream()
            .filter(c -> obligor.equals(c.obligor()))
            .sorted(Comparator.comparing(c -> c.createdAt() != null ? c.createdAt() : Instant.EPOCH))
            .toList();
}

@Override
public Optional<Commitment> findLatestDelegatedByObligor(String obligor) {
    return delegate.findByObligorInTenancy(obligor, null).stream()
            .filter(c -> c.state() == CommitmentState.DELEGATED)
            .filter(c -> c.resolvedAt() != null)
            .max(Comparator.comparing(Commitment::resolvedAt));
}
```

Note: InMemory implementation uses `findAllOpen()` (cross-tenant) for the first method. For `findLatestDelegatedByObligor`, iterate all commitments for the obligor and filter. The InMemory store's `findByObligorInTenancy` with null tenancy may need adjustment — check implementation and use the appropriate cross-tenant query.

- [ ] **Step 6: Implement in JpaCrossTenantCommitmentStore**

```java
@Override
public List<Commitment> findOpenByObligor(String obligor) {
    return em.createQuery(
            "SELECT c FROM CommitmentEntity c WHERE c.obligor = :obligor " +
            "AND c.state IN ('OPEN', 'ACKNOWLEDGED') ORDER BY c.createdAt ASC",
            CommitmentEntity.class)
        .setParameter("obligor", obligor)
        .getResultStream().map(CommitmentEntity::toDomain).toList();
}

@Override
public Optional<Commitment> findLatestDelegatedByObligor(String obligor) {
    return em.createQuery(
            "SELECT c FROM CommitmentEntity c WHERE c.obligor = :obligor " +
            "AND c.state = 'DELEGATED' ORDER BY c.resolvedAt DESC",
            CommitmentEntity.class)
        .setParameter("obligor", obligor)
        .setMaxResults(1)
        .getResultStream().map(CommitmentEntity::toDomain).findFirst();
}
```

- [ ] **Step 7: Add 3 methods to MessageLedgerEntryRepository**

```java
public Optional<MessageLedgerEntry> findLatestContextPressureForActor(String actorId) {
    return em.createQuery(
            "SELECT e FROM MessageLedgerEntry e WHERE e.actorId = :actorId " +
            "AND e.messageType = 'EVENT' AND e.contextWindowPct IS NOT NULL " +
            "ORDER BY e.sequenceNumber DESC",
            MessageLedgerEntry.class)
        .setParameter("actorId", actorId)
        .setMaxResults(1)
        .getResultStream().findFirst();
}

public List<MessageLedgerEntry> findLatestContextPressureGlobal() {
    return em.createQuery(
            "SELECT e FROM MessageLedgerEntry e WHERE e.messageType = 'EVENT' " +
            "AND e.contextWindowPct IS NOT NULL " +
            "AND e.sequenceNumber = (SELECT MAX(e2.sequenceNumber) FROM MessageLedgerEntry e2 " +
            "WHERE e2.actorId = e.actorId AND e2.messageType = 'EVENT' " +
            "AND e2.contextWindowPct IS NOT NULL)",
            MessageLedgerEntry.class)
        .getResultList();
}

public Optional<MessageLedgerEntry> findLatestEntryByActor(String actorId) {
    return em.createQuery(
            "SELECT e FROM MessageLedgerEntry e WHERE e.actorId = :actorId " +
            "ORDER BY e.sequenceNumber DESC",
            MessageLedgerEntry.class)
        .setParameter("actorId", actorId)
        .setMaxResults(1)
        .getResultStream().findFirst();
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn test -Dtest=CapacityQueryExtensionsTest -pl runtime`
Expected: PASS

- [ ] **Step 9: Run full build**

Run: `JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 10: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/171/qhorus add -A
git -C /Users/mdproctor/claude/casehub/slots/171/qhorus commit -m "feat(#428): CrossTenantCommitmentStore + ledger query extensions

Adds findOpenByObligor() and findLatestDelegatedByObligor() to
CrossTenantCommitmentStore (interface + JPA + InMemory).
Adds findLatestContextPressureForActor(), findLatestContextPressureGlobal(),
and findLatestEntryByActor() to MessageLedgerEntryRepository.

These queries support the capacity signal source (cross-channel context
pressure) and redistribution executor (obligation counting, grace period
cooldown, activity tracking).

Refs #428"
```

---

## Batch 2: Signal Source + Executor

### Task 3: ContextPressureCapacitySource

**Files:**
- Create: `runtime/src/main/java/io/casehub/qhorus/runtime/capacity/ContextPressureCapacitySource.java`
- Test: `runtime/src/test/java/io/casehub/qhorus/runtime/capacity/ContextPressureCapacitySourceTest.java`

**Interfaces:**
- Consumes: `MessageLedgerEntryRepository.findLatestContextPressureForActor(String)` from Task 2
- Consumes: `MessageLedgerEntryRepository.findLatestContextPressureGlobal()` from Task 2
- Produces: `CapacitySignalSource` implementation (CDI-discovered by `AggregatingActorCapacityView` via `@Any Instance<CapacitySignalSource>`)

- [ ] **Step 1: Write failing test — observe returns signal with correct pressure**

```java
@Test
void observeReturnsPressureFromLatestContextWindowPct() {
    var repo = mock(MessageLedgerEntryRepository.class);
    var entry = new MessageLedgerEntry();
    entry.actorId = "agent-1";
    entry.contextWindowPct = 85;
    entry.setCreatedAt(Instant.now());
    entry.subjectId = UUID.randomUUID();
    when(repo.findLatestContextPressureForActor("agent-1"))
            .thenReturn(Optional.of(entry));

    var source = new ContextPressureCapacitySource(repo);

    var signal = source.observe("agent-1");
    assertThat(signal).isPresent();
    assertThat(signal.get().pressure()).isEqualTo(0.85, within(0.001));
    assertThat(signal.get().signalType()).isEqualTo(CapacitySignalTypes.CONTEXT_PRESSURE);
    assertThat(signal.get().actorId()).isEqualTo("agent-1");
}
```

- [ ] **Step 2: Write failing test — observe returns empty for unknown actor**

```java
@Test
void observeReturnsEmptyForUnknownActor() {
    var repo = mock(MessageLedgerEntryRepository.class);
    when(repo.findLatestContextPressureForActor("unknown")).thenReturn(Optional.empty());

    var source = new ContextPressureCapacitySource(repo);
    assertThat(source.observe("unknown")).isEmpty();
}
```

- [ ] **Step 3: Write failing test — observeOverloaded threshold boundary**

```java
@Test
void observeOverloadedRespectsThresholdBoundary() {
    var repo = mock(MessageLedgerEntryRepository.class);
    var entry70 = new MessageLedgerEntry();
    entry70.actorId = "agent-at-70";
    entry70.contextWindowPct = 70;
    entry70.setCreatedAt(Instant.now());

    var entry85 = new MessageLedgerEntry();
    entry85.actorId = "agent-at-85";
    entry85.contextWindowPct = 85;
    entry85.setCreatedAt(Instant.now());

    when(repo.findLatestContextPressureGlobal()).thenReturn(List.of(entry70, entry85));

    var source = new ContextPressureCapacitySource(repo);
    var overloaded = source.observeOverloaded(0.80);

    assertThat(overloaded).hasSize(1);
    assertThat(overloaded.get(0).actorId()).isEqualTo("agent-at-85");
    assertThat(overloaded.get(0).pressure()).isEqualTo(0.85, within(0.001));
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn test -Dtest=ContextPressureCapacitySourceTest -pl runtime`
Expected: Compilation error — class doesn't exist

- [ ] **Step 5: Implement ContextPressureCapacitySource**

Create `runtime/src/main/java/io/casehub/qhorus/runtime/capacity/ContextPressureCapacitySource.java`:

```java
package io.casehub.qhorus.runtime.capacity;

import io.casehub.platform.api.capacity.CapacitySignal;
import io.casehub.platform.api.capacity.CapacitySignalSource;
import io.casehub.platform.api.capacity.CapacitySignalTypes;
import io.casehub.qhorus.runtime.ledger.MessageLedgerEntryRepository;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.util.*;

@ApplicationScoped
public class ContextPressureCapacitySource implements CapacitySignalSource {

    private final MessageLedgerEntryRepository messageRepo;

    @Inject
    public ContextPressureCapacitySource(MessageLedgerEntryRepository messageRepo) {
        this.messageRepo = messageRepo;
    }

    // package-private for CDI-free testing
    ContextPressureCapacitySource() { this.messageRepo = null; }

    @Override
    public String signalType() {
        return CapacitySignalTypes.CONTEXT_PRESSURE;
    }

    @Override
    public Optional<CapacitySignal> observe(String actorId) {
        return messageRepo.findLatestContextPressureForActor(actorId)
                .map(entry -> new CapacitySignal(
                        actorId,
                        CapacitySignalTypes.CONTEXT_PRESSURE,
                        entry.contextWindowPct / 100.0,
                        entry.createdAt(),
                        Map.of("channelId", entry.subjectId().toString())));
    }

    @Override
    public List<CapacitySignal> observeOverloaded(double threshold) {
        return messageRepo.findLatestContextPressureGlobal().stream()
                .filter(entry -> entry.contextWindowPct != null
                                 && entry.contextWindowPct / 100.0 >= threshold)
                .map(entry -> new CapacitySignal(
                        entry.actorId,
                        CapacitySignalTypes.CONTEXT_PRESSURE,
                        entry.contextWindowPct / 100.0,
                        entry.createdAt(),
                        Map.of()))
                .toList();
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn test -Dtest=ContextPressureCapacitySourceTest -pl runtime`
Expected: 3 tests PASS

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/171/qhorus add -A
git -C /Users/mdproctor/claude/casehub/slots/171/qhorus commit -m "feat(#428): ContextPressureCapacitySource — context_window_pct signal source

Implements CapacitySignalSource SPI. Reads latest context_window_pct
per actor from ledger via cross-channel global queries. Pressure formula:
pct / 100.0 (direct mapping from 0-100 integer to 0.0-1.0 scale).

CDI-discovered by AggregatingActorCapacityView via Instance<CapacitySignalSource>.

Refs #428"
```

---

### Task 4: Redistribution executor — event, delegate, orchestrator

**Files:**
- Create: `api/src/main/java/io/casehub/qhorus/api/capacity/RedistributionExecutedEvent.java`
- Create: `runtime/src/main/java/io/casehub/qhorus/runtime/capacity/RedistributionResult.java`
- Create: `runtime/src/main/java/io/casehub/qhorus/runtime/capacity/RedistributionDelegate.java`
- Create: `runtime/src/main/java/io/casehub/qhorus/runtime/capacity/QhorusRedistributionExecutor.java`
- Test: `runtime/src/test/java/io/casehub/qhorus/runtime/capacity/QhorusRedistributionExecutorTest.java`
- Test: `runtime/src/test/java/io/casehub/qhorus/runtime/capacity/RedistributionDelegateTest.java`

**Interfaces:**
- Consumes: `CrossTenantCommitmentStore.findOpenByObligor(String)` from Task 2
- Consumes: `CrossTenantCommitmentStore.findLatestDelegatedByObligor(String)` from Task 2
- Consumes: `MessageLedgerEntryRepository.findLatestEntryByActor(String)` from Task 2
- Consumes: `RedistributionPolicy.evaluate(RedistributionContext)` from platform-api
- Consumes: `RoutingBridge.resolve(MessageDispatch, Channel, String)` from qhorus-runtime
- Consumes: `MessageService.dispatch(MessageDispatch)` from qhorus-runtime
- Consumes: `ChannelSummaryService.triggerUpdate(UUID)`, `.getSummary(UUID)`, `.countMessagesSince(UUID, Long)` from qhorus-runtime
- Produces: `RedistributionExecutedEvent` CDI event (observed by notification-bridge)

- [ ] **Step 1: Create RedistributionExecutedEvent record**

Create `api/src/main/java/io/casehub/qhorus/api/capacity/RedistributionExecutedEvent.java`:

```java
package io.casehub.qhorus.api.capacity;

import java.time.Instant;

public record RedistributionExecutedEvent(
    String actorId,
    Outcome outcome,
    int successCount,
    int totalCount,
    String reason,
    Instant occurredAt
) {
    public enum Outcome { COMPRESSED, REDISTRIBUTED, ESCALATED }

    public static RedistributionExecutedEvent compressed(String actorId, int channelCount) {
        return new RedistributionExecutedEvent(actorId, Outcome.COMPRESSED,
                channelCount, channelCount, null, Instant.now());
    }

    public static RedistributionExecutedEvent redistributed(String actorId,
                                                             int successCount, int totalCount) {
        return new RedistributionExecutedEvent(actorId, Outcome.REDISTRIBUTED,
                successCount, totalCount, null, Instant.now());
    }

    public static RedistributionExecutedEvent escalated(String actorId, String reason) {
        return new RedistributionExecutedEvent(actorId, Outcome.ESCALATED,
                0, 0, reason, Instant.now());
    }
}
```

- [ ] **Step 2: Create RedistributionResult record**

Create `runtime/src/main/java/io/casehub/qhorus/runtime/capacity/RedistributionResult.java`:

```java
package io.casehub.qhorus.runtime.capacity;

public record RedistributionResult(int successCount, int totalCount) {}
```

- [ ] **Step 3: Write failing executor tests — happy path + compress + routing failure**

```java
// QhorusRedistributionExecutorTest.java
@Test
void redistributeHappyPath_threeObligationsHandedOff() {
    // Setup: actor at 0.9 pressure, 3 obligations with capabilityTag
    // Mock: policy returns Redistribute(grace=0, excludeActors=Set.of("agent-1"))
    // Mock: delegate.redistribute() returns RedistributionResult(3, 3)
    // Verify: delegate.redistribute() called once with correct args
}

@Test
void compressPath_triggersUpdateOnStaleChannels() {
    // Setup: actor at 0.78 pressure, 2 obligations
    // Mock: policy returns Compress("above compress threshold")
    // Verify: delegate.compress() called with actorId and obligations
}

@Test
void routingFailureEscalation_zeroSuccessTriggersEscalate() {
    // Setup: actor at 0.9, 2 obligations
    // Mock: policy returns Redistribute
    // Mock: delegate.redistribute() returns RedistributionResult(0, 2)
    // Verify: delegate.escalate() called with "no targets available" reason
}

@Test
void gracePeriodCooldown_recentDelegationSkipsRedistribution() {
    // Setup: actor at 0.9, 2 obligations
    // Mock: policy returns Redistribute(gracePeriod=30s)
    // Mock: commitmentStore.findLatestDelegatedByObligor returns commitment
    //       with resolvedAt = 10 seconds ago
    // Verify: delegate.redistribute() NOT called
}

@Test
void gracePeriodExpired_proceedsWithRedistribution() {
    // Setup: same as above but resolvedAt = 60 seconds ago
    // Verify: delegate.redistribute() IS called
}

@Test
void immediateThreshold_zeroGracePeriodAlwaysProceeds() {
    // Setup: actor at 0.96, recent delegation exists
    // Mock: policy returns Redistribute(gracePeriod=Duration.ZERO)
    // Verify: delegate.redistribute() IS called despite recent delegation
}

@Test
void zeroObligations_holdDecision() {
    // Setup: actor at 0.9, 0 obligations
    // Mock: policy returns Hold("no movable work")
    // Verify: no delegate calls
}

@Test
void inactivity_escalateRegardlessOfPressure() {
    // Setup: actor at 0.5, inactive 6 minutes
    // Mock: policy returns Escalate("inactive for PT6M")
    // Verify: delegate.escalate() called
}
```

- [ ] **Step 4: Write failing delegate tests — redistribute dispatches HANDOFF**

```java
// RedistributionDelegateTest.java
@Test
void redistributeDispatchesHandoffWithCorrectTarget() {
    // Mock: routingBridge.resolve() returns RoutingOutcome("agent-2", ...)
    // Mock: messageStore.scan() returns original message with id=42
    // Setup: commitment with capabilityTag="analyst", correlationId="corr-1"
    // Verify: messageService.dispatch() called with:
    //   type=HANDOFF, target="agent-2", correlationId="corr-1",
    //   sender="system:redistribution", inReplyTo=42
}

@Test
void redistributeSkipsDirectAddressedCommitments() {
    // Setup: commitment with capabilityTag=null
    // Verify: routingBridge.resolve() NOT called
    // Verify: result.totalCount() == 0
}

@Test
void redistributeCatchesRoutingRejectedAndContinues() {
    // Setup: 2 commitments with capabilityTag
    // Mock: routingBridge throws RoutingRejectedException for first
    // Mock: routingBridge succeeds for second
    // Verify: result.successCount() == 1, result.totalCount() == 2
}

@Test
void selfDelegationGuard_excludedActorSkipped() {
    // Mock: routingBridge.resolve() returns RoutingOutcome("agent-1", ...)
    // Setup: decision.excludeActors() = Set.of("agent-1")
    // Verify: messageService.dispatch() NOT called
}

@Test
void escalateFiresEvent() {
    // Verify: executedEvents.fireAsync() called with ESCALATED outcome
}
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn test -Dtest=QhorusRedistributionExecutorTest,RedistributionDelegateTest -pl runtime`
Expected: Compilation error — classes don't exist

- [ ] **Step 6: Implement RedistributionDelegate**

Create `runtime/src/main/java/io/casehub/qhorus/runtime/capacity/RedistributionDelegate.java` following the spec's Component 2 — compress, redistribute, and escalate methods. Key points:
- `@ApplicationScoped` with `@Transactional` on `compress()` and `redistribute()`
- `@ActivateRequestContext` on `redistribute()` for tenant context bridging
- `InboundTenancyContext.set(commitment.tenancyId())` per commitment iteration
- Pre-routing via `RoutingBridge.resolve()` with `excludeActors` check
- `inReplyTo` resolution from `messageStore.scan()` for the original COMMAND/QUERY
- Dual constructor (CDI + test) per GE-20260602-c4a68a

- [ ] **Step 7: Implement QhorusRedistributionExecutor**

Create `runtime/src/main/java/io/casehub/qhorus/runtime/capacity/QhorusRedistributionExecutor.java` following the spec's executor flow:
- `@ApplicationScoped` with `@ObservesAsync` handler
- Queries `commitmentStore.findOpenByObligor(actorId)`
- Derives `timeSinceLastActivity` from `messageRepo.findLatestEntryByActor(actorId)`
- Builds `RedistributionContext`, calls `policy.evaluate()`
- Grace period check via `commitmentStore.findLatestDelegatedByObligor(actorId)`
- Routing failure escalation: `result.successCount() == 0 && !obligations.isEmpty()`
- Dual constructor (CDI + test)

- [ ] **Step 8: Run tests to verify they pass**

Run: `JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn test -Dtest=QhorusRedistributionExecutorTest,RedistributionDelegateTest -pl runtime`
Expected: All tests PASS

- [ ] **Step 9: Run full build**

Run: `JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 10: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/171/qhorus add -A
git -C /Users/mdproctor/claude/casehub/slots/171/qhorus commit -m "feat(#428): QhorusRedistributionExecutor — capacity redistribution via HANDOFF

Observes CapacityPressureEvent via @ObservesAsync. Stateless executor
with sweep-based re-evaluation:
- Compress: triggerUpdate() on stale channels (freshness guard)
- Redistribute: HANDOFF via MessageService.dispatch() with pre-routing
  (self-delegation guard, excludeActors check, grace period cooldown)
- Escalate: fire RedistributionExecutedEvent for notification bridge
- Routing failure escalation: zero successes → Escalate

RedistributionDelegate handles transactional work with
@ActivateRequestContext for tenant context bridging.
RedistributionExecutedEvent in qhorus-api for external observers.

Refs #428"
```

---

## References

- `specs/issue-268-capacity-redistribution/2026-09-03-qhorus-capacity-redistribution-design.md` — design spec
- `specs/issue-268-capacity-redistribution/decisions.md` — D7–D12
- `api/src/main/java/io/casehub/qhorus/api/message/Commitment.java` — record to extend
- `api/src/main/java/io/casehub/qhorus/api/store/CrossTenantCommitmentStore.java` — interface to extend
- `runtime/src/main/java/io/casehub/qhorus/runtime/message/CommitmentService.java:52,245` — open() + delegate()
- `runtime/src/main/java/io/casehub/qhorus/runtime/message/MessageService.java:418` — capabilityTag extraction point
- `runtime/src/main/java/io/casehub/qhorus/runtime/message/CommitmentEntity.java:98` — JPA mapping
- `runtime/src/main/java/io/casehub/qhorus/runtime/ledger/MessageLedgerEntryRepository.java:499` — existing per-channel query
- `runtime/src/main/java/io/casehub/qhorus/runtime/message/RoutingBridge.java:61` — role:X resolution
- `runtime/src/main/java/io/casehub/qhorus/runtime/channel/ChannelSummaryService.java:88` — triggerUpdate()
- GE-20260602-c4a68a — dual-constructor CDI-free testing pattern
- GE-20260605-373190 — @ObservesAsync + @RequestScoped constraint
- GE-20260512-6887c9 — @ObservesAsync + @Transactional delegate pattern
- GE-20260517-e10a0f — HANDOFF commitment child/parent gotcha
- casehubio/qhorus#428 — focal issue
- casehubio/qhorus#429 — prerequisite: ChannelSummaryService cross-tenant fix
