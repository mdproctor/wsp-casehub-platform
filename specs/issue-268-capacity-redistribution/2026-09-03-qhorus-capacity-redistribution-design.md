# Qhorus Capacity Signal Source + Redistribution Executor — Design Spec

**Issue:** casehubio/qhorus#428
**Scope:** casehub-qhorus (api + runtime + persistence-memory + testing)
**Status:** validated
**Depends on:** casehubio/platform#268 (capacity signal SPI — implemented)
**Cross-platform spec:** `wsp-casehub-qhorus/specs/cross-platform-capacity-redistribution/2026-09-02-capacity-redistribution-design.md`

---

## Problem Statement

Platform#268 delivered the capacity signal SPI and default policy, but no domain signal sources or redistribution executors exist. Qhorus has the data (`context_window_pct` on ledger entries) and the mechanism (HANDOFF messages + commitment delegation) but no bridge between them. Overloaded agents continue receiving obligations until they fail.

## Design Scope

This spec delivers:
- `ContextPressureCapacitySource` — implements `CapacitySignalSource`, reads existing CONTEXT_PRESSURE ledger data
- `QhorusRedistributionExecutor` — observes `CapacityPressureEvent`, executes compress → HANDOFF flow
- `RedistributionExecutedEvent` — CDI event for audit/notification bridge
- `Commitment.capabilityTag` — schema extension for redistribution target resolution
- `CrossTenantCommitmentStore` extensions — two new query methods
- `MessageLedgerEntryRepository.findLatestContextPressureGlobal()` — cross-channel query

This spec does NOT deliver:
- `Channel.routingCapacityThreshold` — belongs with Batch 2 (eidos `OVERLOADED` probe), not Batch 3. The threshold is consumed by the eidos probe step, which this spec does not deliver. Cross-platform spec to be updated: move `routingCapacityThreshold` from Batch 3 to Batch 2 scope (casehubio/qhorus#430).
- Engine `WorkloadCapacitySource` (batch 4)
- Platform gate `SessionCapacitySource` (batch 3)

---

## Architecture — Call Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ Platform (@Scheduled, every 60s)                                │
│                                                                 │
│   CapacityPressureMonitor                                       │
│     → capacityView.getOverloaded(sweepThreshold)                │
│     → fires CapacityPressureEvent per overloaded actor          │
└──────────────────────────┬──────────────────────────────────────┘
                           │ CDI fireAsync
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Qhorus (@ObservesAsync)                                         │
│                                                                 │
│   QhorusRedistributionExecutor                                  │
│     1. Query open obligations (CrossTenantCommitmentStore)       │
│     2. Query last activity (MessageLedgerEntryRepository)       │
│     3. Build RedistributionContext                              │
│     4. Call RedistributionPolicy.evaluate(context)              │
│     5. Execute decision:                                        │
│        Compress → triggerUpdate() on stale channels             │
│        Redistribute → HANDOFF via MessageService.dispatch()     │
│        Hold → no-op                                             │
│        Escalate → fire RedistributionExecutedEvent(ESCALATED)   │
│     6. Fire RedistributionExecutedEvent for audit               │
└─────────────────────────────────────────────────────────────────┘
```

---

## Component 1: ContextPressureCapacitySource

**Module:** qhorus-runtime
**Package:** `io.casehub.qhorus.runtime.capacity`

```java
@ApplicationScoped
public class ContextPressureCapacitySource implements CapacitySignalSource {

    @Inject MessageLedgerEntryRepository messageRepo;

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

### Pressure formula

`context_window_pct / 100.0` — direct mapping from the 0-100 integer scale to the 0.0-1.0 pressure scale. No transformation needed.

### Repository extensions

**`MessageLedgerEntryRepository`** — two new methods:

```java
public Optional<MessageLedgerEntry> findLatestContextPressureForActor(String actorId) {
    // Latest EVENT entry with non-null contextWindowPct for this actor
    // across ALL channels and tenants (capacity is physical, D4)
    // ORDER BY sequenceNumber DESC, LIMIT 1
}

public List<MessageLedgerEntry> findLatestContextPressureGlobal() {
    // Latest EVENT entry per actorId with non-null contextWindowPct
    // across ALL channels and tenants
    // GROUP BY actorId, MAX(sequenceNumber) — most recent per actor (D8)
}

public Optional<MessageLedgerEntry> findLatestEntryByActor(String actorId) {
    // Latest entry of ANY type for this actor across ALL channels and tenants
    // Used by the executor to derive timeSinceLastActivity
    // ORDER BY sequenceNumber DESC, LIMIT 1
}
```

**Index requirement (D8):** The global query needs an index with `actorId` as a leading column for efficient GROUP BY. Without it, the query degrades to a sequential scan on the ledger table. Add as a Flyway migration.

---

## Component 2: QhorusRedistributionExecutor

**Module:** qhorus-runtime
**Package:** `io.casehub.qhorus.runtime.capacity`

### Class structure (D11)

Two classes following the delegate pattern:

```java
@ApplicationScoped
public class QhorusRedistributionExecutor {

    @Inject RedistributionDelegate delegate;
    @Inject RedistributionPolicy policy;
    @Inject ActorCapacityView capacityView;
    @Inject CrossTenantCommitmentStore commitmentStore;
    @Inject MessageLedgerEntryRepository messageRepo;

    void onCapacityPressure(@ObservesAsync CapacityPressureEvent event) {
        // 1. Query open obligations for actor
        // 2. Compute timeSinceLastActivity
        // 3. Build RedistributionContext
        // 4. Call policy.evaluate(context)
        // 5. Dispatch to delegate based on decision
    }
}

@ApplicationScoped
public class RedistributionDelegate {

    @Inject ChannelSummaryService summaryService;
    @Inject MessageService messageService;
    @Inject RoutingBridge routingBridge;
    @Inject CrossTenantChannelStore channelStore;
    @Inject CrossTenantCommitmentStore commitmentStore;
    @Inject MessageStore messageStore;
    @Inject InboundTenancyContext inboundTenancyContext;
    @Inject Event<RedistributionExecutedEvent> executedEvents;

    @Transactional
    public void compress(String actorId, List<Commitment> obligations) { ... }

    @ActivateRequestContext
    @Transactional
    public RedistributionResult redistribute(String actorId,
                                              List<Commitment> obligations,
                                              RedistributionDecision.Redistribute decision) { ... }

    public void escalate(String actorId, String reason) { ... }
}
```

### Executor flow — `onCapacityPressure()`

```
1. actorId = event.actorId()
2. obligations = commitmentStore.findOpenByObligor(actorId)
       .stream().filter(c -> c.state().isActive()).toList()
3. timeSinceLastActivity = messageRepo.findLatestEntryByActor(actorId)
       .map(e -> Duration.between(e.createdAt(), Instant.now()))
       .orElse(Duration.ofDays(365))  // unknown → treat as long-inactive
4. context = new RedistributionContext(actorId, event.capacity(),
       event.triggerSignalType(), obligations.size(), timeSinceLastActivity)
5. decision = policy.evaluate(context)
6. switch (decision):
     Compress → delegate.compress(actorId, obligations)
     Redistribute →
       // Grace period check (D7 revised)
       lastDelegated = commitmentStore.findLatestDelegatedByObligor(actorId)
       if (lastDelegated.isPresent()
           && !decision.gracePeriod().isZero()
           && Duration.between(lastDelegated.get().resolvedAt(), Instant.now())
                      .compareTo(decision.gracePeriod()) < 0) {
           // Within cooldown — skip this sweep
           return;
       }
       result = delegate.redistribute(actorId, obligations, decision)
       if (result.successCount() == 0 && !obligations.isEmpty()) {
           // Guard #2: all routing failed → Escalate
           delegate.escalate(actorId, "redistribution requested but no targets available")
       }
     Hold → LOG.debugf("Hold for %s: %s", actorId, decision.reason())
     Escalate → delegate.escalate(actorId, decision.reason())
```

### Compress execution

**Prerequisite (casehubio/qhorus#429):** `ChannelSummaryService.triggerUpdate()` internally calls `channelService.findById()` which uses tenant-scoped `JpaChannelStore.find()`. This fails in `@ObservesAsync` context. Update `triggerUpdate()` to use `CrossTenantChannelStore.findById()` for the channel lookup. Also make `countMessagesSince()` public (currently package-private, inaccessible from `io.casehub.qhorus.runtime.capacity`).

```
1. For each unique channelId in obligations:
   a. summary = summaryService.getSummary(channelId)
   b. if (summary.isPresent()
        && summaryService.countMessagesSince(channelId, summary.get().lastUpdatedMessageId()) > 0):
      summaryService.triggerUpdate(channelId)    // freshness guard (D7 guard #1)
2. Fire RedistributionExecutedEvent(actorId, COMPRESSED, channelCount)
```

### Redistribute execution

```
1. redistributable = obligations.stream()
       .filter(c -> c.capabilityTag() != null)    // skip direct-addressed (D10)
       .toList()
2. successCount = 0
3. For each commitment in redistributable:
   a0. // Establish tenant context for this commitment's dispatch
       inboundTenancyContext.set(commitment.tenancyId())

   a. // Resolve inReplyTo — find original COMMAND/QUERY message
      originalMessages = messageStore.scan(MessageQuery.builder()
          .channelId(commitment.channelId())
          .correlationId(commitment.correlationId())
          .limit(1).build())
      if (originalMessages.isEmpty()):
          LOG.warnf("No original message for correlation %s — skipping",
                    commitment.correlationId())
          continue
      inReplyTo = originalMessages.get(0).id()

   b. // Pre-check routing — self-delegation guard
      channel = channelStore.findById(commitment.channelId()).orElse(null)
      if (channel == null): continue
      dispatch = MessageDispatch.builder()
          .channelId(commitment.channelId())
          .sender("system:redistribution")
          .type(MessageType.HANDOFF)
          .content("Capacity redistribution: pressure " + event.capacity().aggregatePressure())
          .correlationId(commitment.correlationId())
          .target("role:" + commitment.capabilityTag())
          .inReplyTo(inReplyTo)
          .tenancyId(commitment.tenancyId())
          .actorType(ActorType.SYSTEM)
          .build()
      try:
          routingOutcome = routingBridge.resolve(dispatch, channel, commitment.tenancyId())
      catch (RoutingRejectedException e):
          LOG.warnf("Cannot redistribute %s — no target for capability '%s': %s",
                    commitment.correlationId(), commitment.capabilityTag(), e.getMessage())
          continue
      if (routingOutcome == null):
          continue
      if (decision.excludeActors().contains(routingOutcome.resolvedTarget())):
          LOG.debugf("Excluded actor prevented for %s: %s",
                     commitment.correlationId(), routingOutcome.resolvedTarget())
          continue

   c. // Dispatch HANDOFF with pre-resolved target
      dispatch = dispatch.withTarget(routingOutcome.resolvedTarget())
      try:
          messageService.dispatch(dispatch)
          successCount++
      catch (Exception e):
          LOG.warnf("Redistribution failed for %s: %s",
                    commitment.correlationId(), e.getMessage())
4. Fire RedistributionExecutedEvent(actorId, REDISTRIBUTED, successCount, redistributable.size())
5. Return RedistributionResult(successCount, redistributable.size())
```

**Self-delegation guard rationale:** The executor pre-checks routing via `RoutingBridge.resolve()` before dispatching. If the resolved target is in `decision.excludeActors()`, the commitment is skipped and counted as a routing failure. This guard is necessary until Batch 2 ships the eidos `OVERLOADED` probe, which will systemically exclude overloaded agents from selection. The `excludeActors` field from `RedistributionDecision.Redistribute` is consumed directly — the default policy sets `excludeActors = Set.of(context.actorId())`, but custom policies can exclude additional actors (e.g. recently-overloaded agents from the same pool).

**Pre-resolved target:** The dispatch uses `withTarget(resolvedTarget)` to set the agent ID directly. Since the target no longer starts with `role:`, `MessageService.dispatch()` skips re-routing — no double routing. The HANDOFF triggers `commitmentService.delegate(correlationId, resolvedTarget)` which creates the child commitment on the resolved agent.

**Tenant context bridging (D11 revised):** `messageService.dispatch()` internally calls `CorrelationIntegrityChecker` and `CommitmentService.delegate()`, both of which use tenant-scoped `CommitmentStore` (via `CurrentPrincipal.tenancyId()`). In `@ObservesAsync` context, no `@RequestScoped` context exists. The delegate bridges this gap:
1. `@ActivateRequestContext` on `redistribute()` creates a CDI request scope
2. `InboundTenancyContext.set(commitment.tenancyId())` per-commitment establishes the tenant identity that `QhorusInboundCurrentPrincipal.tenancyId()` returns
3. `messageService.dispatch()` then executes within the correct tenant context

The "No `CurrentPrincipal` injection" rule (D11) remains correct for the delegate's own queries — those use `CrossTenantCommitmentStore`. The `InboundTenancyContext.set()` call establishes context for `messageService.dispatch()` internals only.

**OIDC deployment note:** In deployments with `SecurityIdentityCurrentPrincipal @Alternative @Priority(100)`, the activated request scope creates an anonymous `SecurityIdentity` which returns `DEFAULT_TENANT_ID`. This is correct for the current single-tenant deployment. Multi-tenant OIDC redistribution requires a platform-level `SystemTenantScope` mechanism — tracked separately (not blocking for Batch 3).

### Escalation

```
1. Fire RedistributionExecutedEvent(actorId, ESCALATED, reason)
2. LOG.warnf("Escalation for actor %s: %s", actorId, reason)
```

---

## Component 3: RedistributionExecutedEvent

**Module:** qhorus-api
**Package:** `io.casehub.qhorus.api.capacity`

```java
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

Fired by the executor after every action. Factory methods ensure consistent construction per outcome type. Observed by the notification bridge for alerting.

---

## Component 4: Commitment Schema Extension

**Module:** qhorus-api + runtime + persistence-memory

### Commitment record

Add `capabilityTag` (String, nullable) after `tenancyId`:

```java
public record Commitment(
    UUID id, String correlationId, UUID channelId, MessageType messageType,
    String requester, String obligor, CommitmentState state,
    Instant expiresAt, Instant acknowledgedAt, Instant resolvedAt,
    String delegatedTo, UUID parentCommitmentId,
    String tenancyId, String capabilityTag, Instant createdAt
) { ... }
```

### Population — `open()` update

`CommitmentService.open()` gains two parameters: `String tenancyId` and `String capabilityTag`.

New signature:
```java
public Commitment open(UUID commitmentId, String correlationId, UUID channelId,
                       MessageType type, String requester, String obligor,
                       Instant expiresAt, String tenancyId, String capabilityTag)
```

The single production caller is `MessageService.dispatch()` (line 418). Updated call:
```java
String capabilityTag = dispatch.target() != null && dispatch.target().startsWith("role:")
        ? dispatch.target().substring("role:".length())
        : null;
commitmentService.open(
        storedCommitmentId, dispatch.correlationId(), dispatch.channelId(),
        dispatch.type(), dispatch.sender(), dispatch.target(),
        effectiveDeadline, effectiveTenancyId, capabilityTag);
```

`capabilityTag` extraction happens BEFORE `dispatch = dispatch.withTarget(routingOutcome.resolvedTarget())` (line 206), so it reads the original `role:X` target.

`tenancyId` is `effectiveTenancyId` (already computed at line 129), fixing the pre-existing bug where `open()` never set `tenancyId` and the entity defaulted to `DEFAULT_TENANT_ID`.

No other production callers exist (verified via call hierarchy — all others are tests).

### Population — `delegate()` update

`CommitmentService.delegate()` creates a child commitment (lines 271-280) that currently omits `capabilityTag` and `tenancyId`. Both must be copied from the parent:

```java
Commitment child = Commitment.builder()
        .correlationId(correlationId)
        .channelId(c.channelId())
        .messageType(c.messageType())
        .requester(c.requester())
        .obligor(delegatedTo)
        .expiresAt(c.expiresAt())
        .state(CommitmentState.OPEN)
        .parentCommitmentId(c.id())
        .tenancyId(c.tenancyId())           // R1-05: copy from parent
        .capabilityTag(c.capabilityTag())    // R1-04: copy from parent
        .build();
```

Without `capabilityTag` on the child, redistribution chains beyond depth 1 silently fail — the executor's `c.capabilityTag() != null` filter skips the child. Without `tenancyId`, the child defaults to `DEFAULT_TENANT_ID` via `CommitmentEntity.fromDomain()`, causing wrong tenant on subsequent HANDOFF dispatches.

### Migration

Flyway migration: `ALTER TABLE commitment ADD COLUMN capability_tag VARCHAR(255)`.

### Store implementations

All `CommitmentStore` implementations (JPA, InMemory) updated to persist the new field.

---

## Component 5: CrossTenantCommitmentStore Extensions

**Module:** qhorus-api + runtime + persistence-memory

Two new methods (D11 revised):

```java
public interface CrossTenantCommitmentStore {
    // existing methods...

    List<Commitment> findOpenByObligor(String obligor);

    Optional<Commitment> findLatestDelegatedByObligor(String obligor);
}
```

**`findOpenByObligor`**: Returns active (OPEN/ACKNOWLEDGED) commitments for the actor across all tenants. Used by the executor to count and iterate obligations.

**`findLatestDelegatedByObligor`**: Returns the most recently delegated commitment for the actor, ordered by `resolvedAt` DESC. Used by the executor's grace period mechanism (D7) to derive the last-redistribution timestamp.

### JPA implementations

```sql
-- findOpenByObligor
SELECT c FROM CommitmentEntity c
WHERE c.obligor = :obligor AND c.state IN ('OPEN', 'ACKNOWLEDGED')
ORDER BY c.createdAt ASC

-- findLatestDelegatedByObligor
SELECT c FROM CommitmentEntity c
WHERE c.obligor = :obligor AND c.state = 'DELEGATED'
ORDER BY c.resolvedAt DESC
LIMIT 1
```

### InMemory implementations

Filter the backing map by obligor and state, sort accordingly.

---

## Eventual Consistency Model

The system forms a feedback loop:

```
sweep (60s) → detect → fire event → executor acts → effect → sweep → ...
```

### Convergence proof

1. Actor has O open obligations, pressure P
2. Each sweep: policy maps P to action
   - P < 0.7 → Hold → done
   - 0.7 ≤ P < 0.85 → Compress (fire-and-forget, next sweep re-evaluates)
   - P ≥ 0.85, O > 0 → Redistribute → O decreases by ≥1 per successful HANDOFF
   - P ≥ 0.85, O = 0 → Hold (nothing to move)
   - All HANDOFFs fail → Escalate (guard #2)
   - Inactive > 5m → Escalate
3. O finite → at most O redistributions → terminates
4. Every branch terminates or escalates → eventual consistency ✓

### Guards

| Guard | Prevents | Mechanism |
|-------|----------|-----------|
| Compression freshness | Wasteful LLM calls on repeat sweeps | `summaryService.countMessagesSince()` before `triggerUpdate()` |
| Self-delegation | Excluded actor selected as HANDOFF target | Pre-routing via `routingBridge.resolve()`, check `decision.excludeActors().contains(resolvedTarget)` |
| Routing failure escalation | Infinite stuck loop when no targets available | Boolean flag: zero successes + Redistribute → Escalate |
| Grace period cooldown | Oscillation (redistribute → new work → redistribute) | `findLatestDelegatedByObligor()` + `resolvedAt` comparison |

### Failure modes

| Mode | Class | Resolution |
|------|-------|------------|
| Concurrent sweeps, same actor | WASTEFUL | Commitment state machine prevents double HANDOFF |
| Self-delegation (target in excludeActors) | PREVENTED | Pre-routing guard checks `decision.excludeActors().contains(resolvedTarget)` |
| HANDOFF cascades overload target | HARMLESS | CIRCULAR_DELEGATION watchdog catches cycles |
| Threshold oscillation | WASTEFUL | Freshness guard makes repeated compress a no-op |
| Stale context_window_pct | WASTEFUL | Moves work that didn't need moving, no corruption |
| fireAsync out-of-order delivery | HARMLESS | Executor queries live state, event is just a trigger |
| Executor crash mid-HANDOFF | HARMLESS | Next sweep continues from current state |
| Target goes offline after HANDOFF | HARMLESS | Commitment expiry handles it |
| ACL-restricted channel blocks HANDOFF | GRACEFUL | `AllowedWritersPolicy` rejects `system:redistribution` sender; caught by redistribute loop, commitment skipped. Channels with `role:system` in `allowedWriters` are redistributable |

---

## Configuration

| Key | Default | Where |
|-----|---------|-------|
| `casehub.capacity.sweep-interval` | `60s` | platform (existing) |
| `casehub.capacity.redistribution.compress-threshold` | `0.7` | platform (existing) |
| `casehub.capacity.redistribution.redistribute-threshold` | `0.85` | platform (existing) |
| `casehub.capacity.redistribution.immediate-threshold` | `0.95` | platform (existing) |
| `casehub.capacity.redistribution.grace-period` | `PT30S` | platform (existing) |
| `casehub.capacity.redistribution.inactivity-escalation` | `PT5M` | platform (existing) |

No new configuration keys. The executor reads all thresholds via the policy.

---

## Testing Strategy

All tests are CDI-free plain JUnit — dual-constructor pattern (GE-20260602-c4a68a).

### ContextPressureCapacitySource tests

1. Single actor, single channel → observe returns signal with correct pressure (pct/100.0)
2. Actor with no context_window_pct → observe returns empty
3. observeOverloaded at threshold boundary → correct inclusion/exclusion
4. Multiple actors above threshold → all returned

### QhorusRedistributionExecutor tests

1. **Happy path**: pressure 0.9, 3 obligations → Redistribute → 3 HANDOFFs
2. **Compress path**: pressure 0.78 → triggerUpdate called on stale channels
3. **Freshness guard**: pressure 0.78, no new messages → triggerUpdate NOT called
4. **Routing failure escalation**: pressure 0.9, all routing rejected → Escalate fired
5. **Partial routing success**: 2 of 3 succeed → no Escalate (partial success)
6. **Zero obligations**: pressure 0.9, 0 obligations → Hold
7. **Inactivity**: inactive 6m → Escalate regardless of pressure
8. **Grace period cooldown**: recent delegation within grace → skip HANDOFF
9. **Grace period expired**: delegation older than grace → proceed with HANDOFF
10. **Immediate threshold**: pressure 0.96, grace period zero → HANDOFF immediately
11. **Direct-addressed skip**: commitments with null capabilityTag → skipped
12. **Convergence**: simulate 5 sweeps, verify obligation count decreases monotonically

### RedistributionDelegate tests

1. Compress calls triggerUpdate per channel, fires event
2. Redistribute dispatches HANDOFF with correct target, correlation, tenancy
3. Redistribute catches RoutingRejectedException per commitment, continues
4. Escalate fires event with reason
5. **inReplyTo resolution**: HANDOFF dispatch carries the original COMMAND/QUERY message ID as `inReplyTo`
6. **Self-delegation guard**: routing resolves overloaded actor as target → commitment skipped, not dispatched
7. **Cross-tenant channel access**: delegate uses `CrossTenantChannelStore.findById()`, not `ChannelService` — no `CurrentPrincipal` dependency
8. **Allowed-writers ACL**: `system:redistribution` sender against channel with restrictive allowed_writers ACL (no `role:system`) → HANDOFF dispatch throws `IllegalStateException` → caught by redistribute loop → commitment skipped, counted as routing failure
9. **Redistribution chain depth > 1**: redistributed commitment's child has `capabilityTag` and `tenancyId` → second-hop redistribution succeeds
10. **Tenant context bridging**: `redistribute()` in `@ObservesAsync` context → `@ActivateRequestContext` creates request scope → `InboundTenancyContext.set(commitment.tenancyId())` → `messageService.dispatch()` succeeds (no `ContextNotActiveException` from `CorrelationIntegrityChecker` or `CommitmentService.delegate()`)

### Commitment.capabilityTag tests

1. Role-routed COMMAND → capabilityTag populated from target
2. Direct-addressed COMMAND → capabilityTag null
3. QUERY → capabilityTag populated when role-routed

---

## Module Placement Summary

| Type | Module | Package |
|------|--------|---------|
| `ContextPressureCapacitySource` | qhorus-runtime | `io.casehub.qhorus.runtime.capacity` |
| `QhorusRedistributionExecutor` | qhorus-runtime | `io.casehub.qhorus.runtime.capacity` |
| `RedistributionDelegate` | qhorus-runtime | `io.casehub.qhorus.runtime.capacity` |
| `RedistributionExecutedEvent` | qhorus-api | `io.casehub.qhorus.api.capacity` |
| `RedistributionResult` | qhorus-runtime | `io.casehub.qhorus.runtime.capacity` |

---

## Deployment Constraints (D10 revised)

- Capacity redistribution via HANDOFF requires `casehub-eidos` on the classpath for `AgentRegistry` resolution via `RoutingBridge`
- Without eidos, `RoutingBridge.resolve()` returns null → no HANDOFF targets → guard #2 correctly falls back to Escalate
- Direct-addressed commitments (`capabilityTag = null`) are inherently non-redistributable — the executor skips them

---

## References

- `platform-api/src/main/java/io/casehub/platform/api/capacity/` — capacity signal SPI (platform#268)
- `runtime/src/main/java/io/casehub/qhorus/runtime/watchdog/WatchdogEvaluationService.java:377` — existing CONTEXT_PRESSURE evaluation
- `runtime/src/main/java/io/casehub/qhorus/runtime/ledger/MessageLedgerEntryRepository.java:499` — existing per-channel query
- `runtime/src/main/java/io/casehub/qhorus/runtime/message/CommitmentService.java:245` — delegate() mechanism
- `runtime/src/main/java/io/casehub/qhorus/runtime/message/RoutingBridge.java:61` — role:X resolution
- `runtime/src/main/java/io/casehub/qhorus/runtime/channel/ChannelSummaryService.java:88` — triggerUpdate()
- `api/src/main/java/io/casehub/qhorus/api/store/CommitmentReader.java` — existing obligation queries
- `specs/issue-268-capacity-redistribution/decisions.md` — D7–D12
- `wsp-casehub-qhorus/specs/cross-platform-capacity-redistribution/2026-09-02-capacity-redistribution-design.md` — cross-platform parent spec
- GE-20260605-373190 — @ObservesAsync + @RequestScoped constraint
- GE-20260512-6887c9 — @ObservesAsync + @Transactional delegate pattern
- GE-20260517-e10a0f — HANDOFF commitment child/parent gotcha
- GE-20260512-0fe012 — fireAsync transaction timing
- GE-20260627-f3476f — scope-safe CurrentPrincipal delegation (scope-checking pattern; redistribution uses @ActivateRequestContext instead)
- `runtime/src/main/java/io/casehub/qhorus/runtime/identity/InboundTenancyContext.java` — @RequestScoped tenant holder with set() method
- `runtime/src/main/java/io/casehub/qhorus/runtime/message/CorrelationIntegrityChecker.java:19` — TERMINAL_TYPES includes HANDOFF
- GE-20260602-6941d6 — separate @Transactional delegate pattern
- GE-20260517-5de55b — dispatch auto-opens commitment
- `api/src/main/java/io/casehub/qhorus/api/store/CrossTenantCommitmentStore.java` — extended with two new methods
