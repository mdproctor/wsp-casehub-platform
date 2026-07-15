# Expression-Based Subscription Filters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #151 — expression-based subscription filters
**Issue group:** #151

**Goal:** Replace `List<Constraint>` with `List<ExpressionEvaluator>` across
the subscription model, stores, engine, and REST layer — eliminating the
Constraint/ConstraintOp/ConstraintCompiler abstraction.

**Architecture:** Subscription records carry typed expression evaluators
(`MvelExpressionEvaluator`, `JQExpressionEvaluator`) instead of structured
constraint triples. The `SubscriptionEngine` compiles filters directly via
`ExpressionEngineRegistry`, wraps with tenant isolation, and produces
`FilterExpression` for the alpha network. No changes to the alpha network
or expression SPI.

**Tech Stack:** Java 21, Quarkus, MVEL3, jackson-jq, Hibernate Reactive
Panache, Flyway, JUnit 5, AssertJ, Mockito

## Global Constraints

- `platform-api/` must remain zero-dependency — no Jackson annotations on
  `ExpressionEvaluator`. Custom serialization lives in consuming modules.
- Pre-release: modify existing Flyway migration V1 directly (rename column).
- `ExpressionEvaluator` is the filter type — `MvelExpressionEvaluator` and
  `JQExpressionEvaluator` are the concrete implementations (both in platform-api).
- Multiple filters are AND'd together at evaluation time.
- `$me` is a bound MVEL variable (`variables.put("$me", ownerId)`), not a
  string substitution.
- Tenant isolation is a wrapping Java predicate, not part of user expressions.

---

### Task 1: Data Model — platform-api records and SPI tests

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/Subscription.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/SubscriptionInput.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/SubscriptionUpdate.java`
- Delete: `platform-api/src/main/java/io/casehub/platform/api/subscription/Constraint.java` (use `ide_refactor_safe_delete`)
- Delete: `platform-api/src/main/java/io/casehub/platform/api/subscription/ConstraintOp.java` (use `ide_refactor_safe_delete`)
- Delete: `platform-api/src/test/java/io/casehub/platform/api/subscription/ConstraintFieldValidationTest.java` (use `ide_refactor_safe_delete`)
- Modify: `platform-api/src/test/java/io/casehub/platform/api/subscription/SubscriptionSpiTest.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/subscription/SubscriptionStoreContractTest.java`

**Interfaces:**
- Produces: `Subscription.filters()` → `List<ExpressionEvaluator>`
- Produces: `SubscriptionInput.filters()` → `List<ExpressionEvaluator>`
- Produces: `SubscriptionUpdate.filters()` → `List<ExpressionEvaluator>` (nullable)

- [ ] **Step 1: Write failing SPI test for Subscription with filters**

In `SubscriptionSpiTest`, replace the `constraint_validConstruction` test
and all Constraint-related tests with ExpressionEvaluator-based tests:

```java
@Test
void subscription_validConstruction_withFilters() {
    var filters = List.of(
            (ExpressionEvaluator) new MvelExpressionEvaluator("status == 'active'"));
    var targets = List.of(new NotificationTarget(TargetType.USER, "user-1"));
    var template = createTemplate();
    var subscription = new Subscription(
            "sub-123", "user-1", "tenant-1", "My Subscription",
            "work-item.created", filters, targets, false,
            template, true, SubscriptionScope.USER,
            Instant.now(), Instant.now());

    assertThat(subscription.filters()).hasSize(1);
    assertThat(subscription.filters().get(0).type()).isEqualTo("mvel");
}
```

Run: `mvn -pl platform-api test -Dtest=SubscriptionSpiTest#subscription_validConstruction_withFilters -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: FAIL — `Subscription` has no `filters()` method

- [ ] **Step 2: Modify Subscription record**

Use `ide_edit_member` to replace the `Subscription` record declaration.
Change `List<Constraint> constraints` to `List<ExpressionEvaluator> filters`.
Update the compact constructor: replace `Objects.requireNonNull(constraints, "constraints")` with `Objects.requireNonNull(filters, "filters")`, and `constraints = List.copyOf(constraints)` with `filters = List.copyOf(filters)`.

Add import: `io.casehub.platform.api.expression.ExpressionEvaluator`
Remove import: `Constraint` (no longer used)

```java
public record Subscription(
        String id,
        String ownerId,
        String tenancyId,
        String name,
        String eventType,
        List<ExpressionEvaluator> filters,
        List<NotificationTarget> targets,
        boolean includeActor,
        NotificationTemplate template,
        boolean enabled,
        SubscriptionScope scope,
        Instant createdAt,
        Instant updatedAt
) {
    public Subscription {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(ownerId, "ownerId");
        Objects.requireNonNull(tenancyId, "tenancyId");
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(eventType, "eventType");
        Objects.requireNonNull(filters, "filters");
        Objects.requireNonNull(targets, "targets");
        Objects.requireNonNull(template, "template");
        Objects.requireNonNull(scope, "scope");
        Objects.requireNonNull(createdAt, "createdAt");
        Objects.requireNonNull(updatedAt, "updatedAt");
        filters = List.copyOf(filters);
        targets = List.copyOf(targets);
    }
}
```

- [ ] **Step 3: Modify SubscriptionInput record**

Same pattern: `List<Constraint> constraints` → `List<ExpressionEvaluator> filters`.
Update compact constructor accordingly.

```java
public record SubscriptionInput(
        String ownerId,
        String tenancyId,
        String name,
        String eventType,
        List<ExpressionEvaluator> filters,
        List<NotificationTarget> targets,
        boolean includeActor,
        NotificationTemplate template,
        boolean enabled,
        SubscriptionScope scope
) {
    public SubscriptionInput {
        Objects.requireNonNull(ownerId, "ownerId");
        Objects.requireNonNull(tenancyId, "tenancyId");
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(eventType, "eventType");
        Objects.requireNonNull(filters, "filters");
        Objects.requireNonNull(targets, "targets");
        Objects.requireNonNull(template, "template");
        scope   = scope != null ? scope : SubscriptionScope.USER;
        filters = List.copyOf(filters);
        targets = List.copyOf(targets);
    }
}
```

- [ ] **Step 4: Modify SubscriptionUpdate record**

Same pattern: `List<Constraint> constraints` → `List<ExpressionEvaluator> filters`.
Update compact constructor — the null-guarded copy stays the same pattern.

```java
public record SubscriptionUpdate(
        String name,
        String eventType,
        List<ExpressionEvaluator> filters,
        List<NotificationTarget> targets,
        Boolean includeActor,
        NotificationTemplate template,
        Boolean enabled
) {
    public SubscriptionUpdate {
        if (filters != null) {
            filters = List.copyOf(filters);
        }
        if (targets != null) {
            targets = List.copyOf(targets);
        }
    }
}
```

- [ ] **Step 5: Update SubscriptionSpiTest**

Replace ALL `Constraint`/`ConstraintOp` references with
`ExpressionEvaluator`/`MvelExpressionEvaluator`. Key changes:

- Remove all `constraint_*` tests (validConstruction, rejectsNull*)
- Remove `ConstraintFieldValidationTest` import references
- Replace `List.of(new Constraint("status", ConstraintOp.EQ, "active"))` with
  `List.of((ExpressionEvaluator) new MvelExpressionEvaluator("status == 'active'"))`
  throughout
- Update `subscriptionInput_makesDefensiveCopyOfConstraints` →
  `subscriptionInput_makesDefensiveCopyOfFilters`
- Update `subscription_makesDefensiveCopyOfConstraints` →
  `subscription_makesDefensiveCopyOfFilters`
- Update `subscriptionUpdate_makesDefensiveCopyOfConstraints` →
  `subscriptionUpdate_makesDefensiveCopyOfFilters`
- Update `subscriptionUpdate_validConstruction_allFieldsSet` — use
  `update.filters()` instead of `update.constraints()`
- Update `subscriptionUpdate_allFieldsNullable` — assert `update.filters()` is null

- [ ] **Step 6: Update SubscriptionStoreContractTest**

Replace `List.of(new Constraint("newField", ConstraintOp.EQ, "newValue"))` with
`List.of((ExpressionEvaluator) new MvelExpressionEvaluator("newField == 'newValue'"))`.

Update `update_changesConstraints` → `update_changesFilters`:
```java
@Test
void update_changesFilters() {
    var subscription = store().store(createInput("user-1", "tenant-1", "Name", "event-type"));

    var newFilters = List.of(
            (ExpressionEvaluator) new MvelExpressionEvaluator("newField == 'newValue'"));
    var update = new SubscriptionUpdate(null, null, newFilters, null, null, null, null);
    var updated = store().update(subscription.id(), "user-1", "tenant-1", update);

    assertThat(updated).isPresent();
    assertThat(updated.get().filters()).hasSize(1);
    assertThat(updated.get().filters().get(0).type()).isEqualTo("mvel");
}
```

Update `createInput` helper — change `List.of()` (empty constraints) to
`List.of()` (empty filters) — same value, just rename the conceptual role.

Update `createSystemInput` helper — same change.

- [ ] **Step 7: Delete Constraint, ConstraintOp, ConstraintFieldValidationTest**

Use `ide_refactor_safe_delete` for each:
- `platform-api/src/main/java/io/casehub/platform/api/subscription/Constraint.java`
- `platform-api/src/main/java/io/casehub/platform/api/subscription/ConstraintOp.java`
- `platform-api/src/test/java/io/casehub/platform/api/subscription/ConstraintFieldValidationTest.java`

Safe delete will confirm no remaining references in platform-api.
(Downstream modules will still reference them — those are fixed in later tasks.)

- [ ] **Step 8: Run platform-api tests**

Run: `mvn -pl platform-api test -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: ALL PASS

- [ ] **Step 9: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#151): replace Constraint with ExpressionEvaluator in subscription records"
```

---

### Task 2: Stores — InMemory, NoOp, JPA

**Files:**
- Modify: `subscriptions-inmem/src/main/java/io/casehub/platform/subscription/inmem/InMemorySubscriptionStore.java`
- Modify: `subscriptions-inmem/src/test/java/io/casehub/platform/subscription/inmem/InMemorySubscriptionStoreTest.java`
- Modify: `platform/src/main/java/io/casehub/platform/subscription/NoOpSubscriptionStore.java`
- Modify: `subscriptions-jpa/src/main/java/io/casehub/platform/subscription/jpa/SubscriptionEntity.java`
- Modify: `subscriptions-jpa/src/main/resources/db/subscription/migration/V1__subscription.sql`
- Modify: `subscriptions-jpa/src/test/java/io/casehub/platform/subscription/jpa/JpaSubscriptionStoreTest.java`

**Interfaces:**
- Consumes: `Subscription.filters()`, `SubscriptionInput.filters()`, `SubscriptionUpdate.filters()` from Task 1
- Produces: Store implementations that persist/retrieve `List<ExpressionEvaluator>`

- [ ] **Step 1: Update InMemorySubscriptionStore**

In `toSubscription()` method (line 167), change `input.constraints()` →
`input.filters()`. In `applyUpdate()` method (line 186), change
`update.constraints() != null ? update.constraints() : subscription.constraints()`
→ `update.filters() != null ? update.filters() : subscription.filters()`.

Remove `Constraint` import, add `ExpressionEvaluator` import.

- [ ] **Step 2: Update NoOpSubscriptionStore**

In `toSubscription()` method (line 75), change `input.constraints()` →
`input.filters()`.

- [ ] **Step 3: Update SubscriptionEntity — serialization**

Replace `Constraint`-based serialization with `ExpressionEvaluator` serialization.

Remove the `CONSTRAINT_LIST_TYPE` field and `serializeConstraints`/`deserializeConstraints` methods.

Add filter serialization — serialize each `ExpressionEvaluator` as
`{"type": "<type>", "expression": "<expr>"}`:

```java
private static final TypeReference<List<Map<String, String>>> FILTER_LIST_TYPE =
        new TypeReference<>() {};

static String serializeFilters(List<ExpressionEvaluator> filters, ObjectMapper mapper) {
    if (filters == null || filters.isEmpty()) {
        return null;
    }
    try {
        var entries = filters.stream()
                .map(f -> Map.of("type", f.type(),
                        "expression", ((MvelExpressionEvaluator) f instanceof MvelExpressionEvaluator m
                                ? m.expression()
                                : ((JQExpressionEvaluator) f).expression())))
                .toList();
        return mapper.writeValueAsString(entries);
    } catch (JsonProcessingException e) {
        throw new IllegalStateException("Failed to serialize filters", e);
    }
}

static List<ExpressionEvaluator> deserializeFilters(String json, ObjectMapper mapper) {
    if (json == null || json.isBlank()) {
        return List.of();
    }
    try {
        List<Map<String, String>> entries = mapper.readValue(json, FILTER_LIST_TYPE);
        return List.copyOf(entries.stream()
                .map(entry -> {
                    String type = entry.get("type");
                    String expression = entry.get("expression");
                    return (ExpressionEvaluator) switch (type) {
                        case "mvel" -> new MvelExpressionEvaluator(expression);
                        case "jq" -> new JQExpressionEvaluator(expression);
                        default -> throw new IllegalStateException(
                                "Unknown filter type: " + type);
                    };
                })
                .toList());
    } catch (JsonProcessingException e) {
        throw new IllegalStateException("Failed to deserialize filters", e);
    }
}
```

Rename column field: `constraintsJson` → `filtersJson`.
Update `@Column(name = "filters_json")`.

Update `fromInput()`: `entity.filtersJson = serializeFilters(input.filters(), mapper)`.
Update `toSubscription()`: `deserializeFilters(filtersJson, mapper)`.

Handle update application: in the JPA store's update logic, use `update.filters()`.

- [ ] **Step 4: Update Flyway V1 migration**

Rename `constraints_json` → `filters_json`:

```sql
CREATE TABLE subscription (
    id              VARCHAR(36) NOT NULL PRIMARY KEY,
    user_id         VARCHAR(255) NOT NULL,
    tenancy_id      VARCHAR(255) NOT NULL,
    name            VARCHAR(500) NOT NULL,
    event_type      VARCHAR(500) NOT NULL,
    filters_json    TEXT,
    template_json    TEXT NOT NULL,
    enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMP NOT NULL,
    updated_at      TIMESTAMP NOT NULL
);

CREATE INDEX idx_subscription_user_tenant_enabled
    ON subscription (user_id, tenancy_id, enabled, created_at DESC);

CREATE INDEX idx_subscription_enabled
    ON subscription (enabled) WHERE enabled = TRUE;
```

- [ ] **Step 5: Update JpaSubscriptionStoreTest**

Replace constraint-related test methods:

`entity_preservesConstraints` → `entity_preservesFilters`:
```java
@Test
void entity_preservesFilters() {
    var filters = List.of(
            (ExpressionEvaluator) new MvelExpressionEvaluator("subject == 'case-123'"),
            (ExpressionEvaluator) new MvelExpressionEvaluator("source.startsWith('/tenants/')"));
    var input = new SubscriptionInput(
            "user-1", "tenant-1", "Filter Test", "event.type",
            filters, List.of(new NotificationTarget(TargetType.USER, "user-1")),
            false, defaultTemplate(), true, null);
    var subscription = store().store(input);

    assertThat(subscription.filters()).hasSize(2);
    assertThat(subscription.filters().get(0).type()).isEqualTo("mvel");
}
```

`entity_roundTripsConstraintsOnUpdate` → `entity_roundTripsFiltersOnUpdate`:
```java
@Test
void entity_roundTripsFiltersOnUpdate() {
    var input = createInput("user-1", "tenant-1", "Name", "event-type");
    var subscription = store().store(input);

    var newFilters = List.of(
            (ExpressionEvaluator) new MvelExpressionEvaluator("newField != 'excluded'"));
    var update = new SubscriptionUpdate(null, null, newFilters, null, null, null, null);
    var updated = store().update(subscription.id(), "user-1", "tenant-1", update);

    assertThat(updated).isPresent();
    assertThat(updated.get().filters()).hasSize(1);
    assertThat(updated.get().filters().get(0).type()).isEqualTo("mvel");
}
```

Update `createInput` helper to use `List.of()` for empty filters.

- [ ] **Step 6: Update InMemorySubscriptionStoreTest**

Update any test that constructs `SubscriptionInput` with constraints — change
to use `List.of()` for empty filters or `List.of(new MvelExpressionEvaluator(...))`
for filter-bearing inputs.

- [ ] **Step 7: Run store tests**

Run: `mvn -pl subscriptions-inmem,subscriptions-jpa,platform test -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add subscriptions-inmem/ subscriptions-jpa/ platform/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#151): update subscription stores for ExpressionEvaluator filters"
```

---

### Task 3: SubscriptionEngine — direct expression compilation

**Files:**
- Modify: `subscriptions/src/main/java/io/casehub/platform/subscription/engine/SubscriptionEngine.java`
- Delete: `subscriptions/src/main/java/io/casehub/platform/subscription/engine/ConstraintCompiler.java` (use `ide_refactor_safe_delete`)
- Delete: `subscriptions/src/test/java/io/casehub/platform/subscription/engine/ConstraintCompilerTest.java` (use `ide_refactor_safe_delete`)
- Modify: `subscriptions/src/test/java/io/casehub/platform/subscription/engine/SubscriptionEngineTest.java`

**Interfaces:**
- Consumes: `ExpressionEngineRegistry.compile(type, expression, Map.class, Boolean.class, variables)`
- Consumes: `Subscription.filters()` → `List<ExpressionEvaluator>`
- Produces: `FilterExpression<Object>` for alpha network subscription

- [ ] **Step 1: Write failing test — expression filter matches**

Add test to `SubscriptionEngineTest` that creates a subscription with an MVEL
filter expression and verifies it matches:

```java
@Test
void event_matchesMvelFilterExpression_firesSubscriptionMatched() {
    var input = new SubscriptionInput("user-1", "tenant-1", "Test sub",
            "work-item.completed",
            List.of((ExpressionEvaluator) new MvelExpressionEvaluator("status == 'completed'")),
            List.of(new NotificationTarget(TargetType.USER, "user-1")),
            false, defaultTemplate(), true, null);
    subStore.store(input);
    engine.onStartup(null);

    pushEvent("work-item.completed", "tenant-1", UUID.randomUUID(), "actor-1");

    assertThat(firedEvents).hasSize(1);
}
```

Run: `mvn -pl subscriptions test -Dtest=SubscriptionEngineTest#event_matchesMvelFilterExpression_firesSubscriptionMatched -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: FAIL — SubscriptionEngine still uses ConstraintCompiler

- [ ] **Step 2: Write failing test — expression filter rejects non-matching event**

```java
@Test
void event_doesNotMatchMvelFilter_doesNotFire() {
    var input = new SubscriptionInput("user-1", "tenant-1", "Test sub",
            "work-item.completed",
            List.of((ExpressionEvaluator) new MvelExpressionEvaluator("status == 'pending'")),
            List.of(new NotificationTarget(TargetType.USER, "user-1")),
            false, defaultTemplate(), true, null);
    subStore.store(input);
    engine.onStartup(null);

    pushEvent("work-item.completed", "tenant-1", UUID.randomUUID(), "actor-1");

    assertThat(firedEvents).isEmpty();
}
```

- [ ] **Step 3: Write failing test — $me variable binding**

```java
@Test
void event_dollarMeVariable_substitutedWithOwnerId() {
    var input = new SubscriptionInput("actor-1", "tenant-1", "Test sub",
            "work-item.completed",
            List.of((ExpressionEvaluator) new MvelExpressionEvaluator("actor == $me")),
            List.of(new NotificationTarget(TargetType.USER, "actor-1")),
            false, defaultTemplate(), true, null);
    subStore.store(input);
    engine.onStartup(null);

    pushEvent("work-item.completed", "tenant-1", UUID.randomUUID(), "actor-1");

    assertThat(firedEvents).hasSize(1);
}
```

- [ ] **Step 4: Write failing test — multiple filters AND'd**

```java
@Test
void event_multipleFilters_allMustMatch() {
    var input = new SubscriptionInput("user-1", "tenant-1", "Test sub",
            "work-item.completed",
            List.of(
                    (ExpressionEvaluator) new MvelExpressionEvaluator("status == 'completed'"),
                    (ExpressionEvaluator) new MvelExpressionEvaluator("actor == 'actor-1'")),
            List.of(new NotificationTarget(TargetType.USER, "user-1")),
            false, defaultTemplate(), true, null);
    subStore.store(input);
    engine.onStartup(null);

    pushEvent("work-item.completed", "tenant-1", UUID.randomUUID(), "actor-1");
    assertThat(firedEvents).hasSize(1);

    firedEvents.clear();
    pushEvent("work-item.completed", "tenant-1", UUID.randomUUID(), "actor-2");
    assertThat(firedEvents).isEmpty();
}
```

- [ ] **Step 5: Modify SubscriptionEngine — replace ConstraintCompiler**

Replace the `ConstraintCompiler` field with `ExpressionEngineRegistry`.
Replace `constraintCompiler.compile(...)` calls in `wireSubscription` and
`wireAndReturnHandle` with direct expression compilation.

Constructor change:
```java
@Inject
public SubscriptionEngine(final DataSourceRegistry dataSourceRegistry,
                           final SubscriptionStore subscriptionStore,
                           final Event<SubscriptionMatched> matchEvent,
                           final ExpressionEngineRegistry expressionRegistry) {
    this.dataSourceRegistry = dataSourceRegistry;
    this.subscriptionStore = subscriptionStore;
    this.matchEvent = matchEvent;
    this.expressionRegistry = expressionRegistry;
}
```

Add `compileFilter` method:
```java
@SuppressWarnings("unchecked")
private FilterExpression<Object> compileFilter(final Subscription subscription) {
    final String tenancyId = subscription.tenancyId();
    final String ownerId = subscription.ownerId();
    final List<ExpressionEvaluator> filters = subscription.filters();

    final Predicate<Object> tenantCheck = obj ->
            obj instanceof SubscribableEvent event
            && tenancyId.equals(event.tenancyId());

    if (filters.isEmpty()) {
        return new FilterExpression<>("none",
                "tenant=" + tenancyId + ":true", tenantCheck);
    }

    final Map<String, Object> variables = Map.of("$me", ownerId);

    final List<CompiledExpression<Map<String, Object>, Boolean>> compiled =
            filters.stream()
                    .map(f -> expressionRegistry.compile(
                            f.type(), extractExpression(f),
                            (Class<Map<String, Object>>) (Class<?>) Map.class,
                            Boolean.class, variables))
                    .toList();

    final String canonicalExpr = filters.stream()
            .map(f -> f.type() + ":" + extractExpression(f))
            .collect(java.util.stream.Collectors.joining(" && "));
    final String expressionKey = "tenant=" + tenancyId + ":" + canonicalExpr;

    final Predicate<Object> predicate = obj -> {
        if (!tenantCheck.test(obj)) return false;
        if (!(obj instanceof SubscribableEvent)) return false;
        Map<String, Object> context = extractProperties(obj);
        return compiled.stream().allMatch(c -> c.eval(context));
    };

    return new FilterExpression<>(filters.get(0).type(), expressionKey, predicate);
}
```

Add `extractExpression` helper:
```java
private static String extractExpression(ExpressionEvaluator evaluator) {
    if (evaluator instanceof MvelExpressionEvaluator m) return m.expression();
    if (evaluator instanceof JQExpressionEvaluator j) return j.expression();
    throw new IllegalArgumentException("Unknown evaluator type: " + evaluator.type());
}
```

Move `extractProperties` from ConstraintCompiler to SubscriptionEngine (same
logic — reflection-based property extraction from POJOs):
```java
private static Map<String, Object> extractProperties(Object obj) {
    var result = new HashMap<String, Object>();
    for (var method : obj.getClass().getMethods()) {
        if (method.getParameterCount() != 0) continue;
        if (method.getDeclaringClass() == Object.class) continue;
        String name = method.getName();
        if (name.startsWith("get") && name.length() > 3) {
            String prop = Character.toLowerCase(name.charAt(3)) + name.substring(4);
            try { result.put(prop, method.invoke(obj)); } catch (Exception ignored) {}
        } else if (name.startsWith("is") && name.length() > 2
                   && (method.getReturnType() == boolean.class
                       || method.getReturnType() == Boolean.class)) {
            String prop = Character.toLowerCase(name.charAt(2)) + name.substring(3);
            try { result.put(prop, method.invoke(obj)); } catch (Exception ignored) {}
        } else if (!name.equals("hashCode") && !name.equals("toString")
                   && !name.equals("getClass") && !name.equals("notify")
                   && !name.equals("notifyAll") && !name.equals("wait")) {
            try { result.put(name, method.invoke(obj)); } catch (Exception ignored) {}
        }
    }
    return result;
}
```

Update `wireSubscription` and `wireAndReturnHandle` to call `compileFilter(subscription)` instead of `constraintCompiler.compile(...)`.

- [ ] **Step 6: Update SubscriptionEngineTest setUp**

Replace `ConstraintCompiler` with `ExpressionEngineRegistry`:
```java
void setUp() {
    registry = new InMemoryDataSourceRegistry(null, null, null);
    subStore = new InMemorySubscriptionStore(null, null, null);
    matchEvent = mock(Event.class);
    firedEvents = Collections.synchronizedList(new ArrayList<>());

    when(matchEvent.fireAsync(any(SubscriptionMatched.class))).thenAnswer(invocation -> {
        SubscriptionMatched event = invocation.getArgument(0);
        firedEvents.add(event);
        return CompletableFuture.completedFuture(event);
    });

    var exprRegistry = new DefaultExpressionEngineRegistry();
    exprRegistry.register(new MvelExpressionEngine());
    engine = new SubscriptionEngine(registry, subStore, matchEvent, exprRegistry);
}
```

Update `subscriptionInput` helper — use empty `List.of()` for filters:
```java
private SubscriptionInput subscriptionInput(final String ownerId, final String tenancyId,
                                            final String eventType, final boolean enabled) {
    return new SubscriptionInput(ownerId, tenancyId, "Test sub",
            eventType, List.of(),
            List.of(new NotificationTarget(TargetType.USER, ownerId)),
            false, defaultTemplate(), enabled, null);
}
```

- [ ] **Step 7: Run tests**

Run: `mvn -pl subscriptions test -Dtest=SubscriptionEngineTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: ALL PASS

- [ ] **Step 8: Delete ConstraintCompiler and ConstraintCompilerTest**

Use `ide_refactor_safe_delete`:
- `subscriptions/src/main/java/io/casehub/platform/subscription/engine/ConstraintCompiler.java`
- `subscriptions/src/test/java/io/casehub/platform/subscription/engine/ConstraintCompilerTest.java`

- [ ] **Step 9: Run all subscriptions tests**

Run: `mvn -pl subscriptions test -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: ALL PASS

- [ ] **Step 10: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add subscriptions/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#151): SubscriptionEngine compiles expression filters directly — remove ConstraintCompiler"
```

---

### Task 4: REST Layer — Jackson deserialization and validation

**Files:**
- Modify: `subscriptions/src/main/java/io/casehub/platform/subscription/rest/SubscriptionResource.java`
- Create: `subscriptions/src/main/java/io/casehub/platform/subscription/rest/ExpressionEvaluatorDeserializer.java`
- Modify: `subscriptions/src/test/java/io/casehub/platform/subscription/rest/SubscriptionResourceTest.java`

**Interfaces:**
- Consumes: `SubscriptionInput.filters()` → `List<ExpressionEvaluator>`
- Produces: Jackson deserializer for `ExpressionEvaluator` polymorphic dispatch

- [ ] **Step 1: Write failing test — create subscription with MVEL filter**

Update `SubscriptionResourceTest` — replace constraint-bearing input with
expression filter:

```java
@Test
void create_returnsSubscriptionWithGeneratedId() {
    var input = new SubscriptionInput(
            "user-1", "tenant-1", "Work item alerts",
            "work-item.completed",
            List.of((ExpressionEvaluator) new MvelExpressionEvaluator("priority == 'HIGH'")),
            List.of(new NotificationTarget(TargetType.USER, "user-1")),
            false, defaultTemplate(), true, null);

    // ... rest of test
}
```

Run: `mvn -pl subscriptions test -Dtest=SubscriptionResourceTest#create_returnsSubscriptionWithGeneratedId -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: FAIL — Jackson cannot deserialize `ExpressionEvaluator`

- [ ] **Step 2: Create ExpressionEvaluatorDeserializer**

Create `subscriptions/src/main/java/io/casehub/platform/subscription/rest/ExpressionEvaluatorDeserializer.java`:

```java
package io.casehub.platform.subscription.rest;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationContext;
import com.fasterxml.jackson.databind.JsonDeserializer;
import com.fasterxml.jackson.databind.JsonNode;
import io.casehub.platform.api.expression.ExpressionEvaluator;
import io.casehub.platform.api.expression.JQExpressionEvaluator;
import io.casehub.platform.api.expression.MvelExpressionEvaluator;

import java.io.IOException;

public class ExpressionEvaluatorDeserializer extends JsonDeserializer<ExpressionEvaluator> {

    @Override
    public ExpressionEvaluator deserialize(JsonParser p, DeserializationContext ctxt)
            throws IOException {
        JsonNode node = p.getCodec().readTree(p);
        String type = node.get("type").asText();
        String expression = node.get("expression").asText();
        return switch (type) {
            case "mvel" -> new MvelExpressionEvaluator(expression);
            case "jq" -> new JQExpressionEvaluator(expression);
            default -> throw new IOException("Unknown expression type: " + type);
        };
    }
}
```

- [ ] **Step 3: Register the deserializer via ObjectMapperCustomizer**

Create `subscriptions/src/main/java/io/casehub/platform/subscription/rest/ExpressionEvaluatorModule.java`:

```java
package io.casehub.platform.subscription.rest;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.module.SimpleModule;
import io.casehub.platform.api.expression.ExpressionEvaluator;
import io.quarkus.jackson.ObjectMapperCustomizer;
import jakarta.enterprise.context.ApplicationScoped;

@ApplicationScoped
public class ExpressionEvaluatorModule implements ObjectMapperCustomizer {

    @Override
    public void customize(ObjectMapper mapper) {
        var module = new SimpleModule();
        module.addDeserializer(ExpressionEvaluator.class,
                new ExpressionEvaluatorDeserializer());
        mapper.registerModule(module);
    }
}
```

- [ ] **Step 4: Update SubscriptionResource — expression validation + $me check**

Add expression validation at subscription creation — validate each filter
expression via the registry before persisting. Inject `ExpressionEngineRegistry`
into `SubscriptionResource`:

```java
@Inject
ExpressionEngineRegistry expressionRegistry;
```

Before the `store.store()` call, validate all filters:
```java
for (var filter : securedInput.filters()) {
    try {
        expressionRegistry.validate(filter.type(), extractExpression(filter));
    } catch (Exception e) {
        return Uni.createFrom().item(Response.status(400)
                .entity("Invalid filter expression: " + e.getMessage()).build());
    }
}
```

Replace the constraint-value `$me` check for SYSTEM scope with an expression
string scan:

```java
if (effectiveScope == SubscriptionScope.SYSTEM) {
    if (!principal.hasGroup(SubscriptionConstants.SYSTEM_SUBSCRIPTION_ADMIN_GROUP)) {
        return Uni.createFrom().item(Response.status(403).build());
    }
    if (input.targets() == null || input.targets().isEmpty()) {
        return Uni.createFrom().item(Response.status(400)
                .entity("SYSTEM scope requires explicit targets").build());
    }
    for (var filter : input.filters()) {
        String expr = extractExpression(filter);
        if (expr.contains("$me")) {
            return Uni.createFrom().item(Response.status(400)
                    .entity("$me filter not allowed for SYSTEM scope").build());
        }
    }
}
```

Add `extractExpression` helper (same pattern as SubscriptionEngine):
```java
private static String extractExpression(ExpressionEvaluator evaluator) {
    if (evaluator instanceof MvelExpressionEvaluator m) return m.expression();
    if (evaluator instanceof JQExpressionEvaluator j) return j.expression();
    throw new IllegalArgumentException("Unknown evaluator type: " + evaluator.type());
}
```

Update the `securedInput` construction — change `input.constraints()` to
`input.filters()`.

- [ ] **Step 5: Update SubscriptionResourceTest**

Replace all `Constraint`/`ConstraintOp` references:

- `create_returnsSubscriptionWithGeneratedId` — use `MvelExpressionEvaluator`
- `create_systemScope_dollarMeConstraintRejected` → `create_systemScope_dollarMeFilterRejected`:
  ```java
  @Test
  void create_systemScope_dollarMeFilterRejected() {
      var input = new SubscriptionInput(
              "admin-1", "tenant-1", "Alert",
              "alert.triggered",
              List.of((ExpressionEvaluator) new MvelExpressionEvaluator("assigneeId == $me")),
              List.of(new NotificationTarget(TargetType.GROUP, "all-users")),
              false, defaultTemplate(), true, SubscriptionScope.SYSTEM);

      var response = resource.create(input).await().indefinitely();
      assertThat(response.getStatus()).isEqualTo(400);
  }
  ```

Add test for invalid expression rejection:
```java
@Test
void create_invalidFilterExpression_returns400() {
    var input = new SubscriptionInput(
            "user-1", "tenant-1", "Bad filter",
            "work-item.completed",
            List.of((ExpressionEvaluator) new MvelExpressionEvaluator("")),
            List.of(new NotificationTarget(TargetType.USER, "user-1")),
            false, defaultTemplate(), true, null);

    var response = resource.create(input).await().indefinitely();
    assertThat(response.getStatus()).isEqualTo(400);
}
```

Update all other test methods that construct `SubscriptionInput` — change
`List.of()` for empty constraints to `List.of()` for empty filters (same
value, updated imports).

Remove `Constraint` and `ConstraintOp` imports.

- [ ] **Step 6: Run all tests**

Run: `mvn -pl subscriptions test -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: ALL PASS

- [ ] **Step 7: Full build**

Run: `mvn --batch-mode install -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: BUILD SUCCESS

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add subscriptions/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#151): REST layer Jackson deserialization for expression filters"
```

---

### Task 5: CLAUDE.md and cleanup

**Files:**
- Modify: `CLAUDE.md` — update package structure documentation

**Interfaces:** None — documentation only.

- [ ] **Step 1: Update CLAUDE.md package structure**

In the `## Package Structure (platform-api)` section, under `.subscription`,
remove `Constraint` and `ConstraintOp` entries. Replace with note that
subscriptions use `ExpressionEvaluator` filters from the `.expression` package.

- [ ] **Step 2: Final full build**

Run: `mvn --batch-mode install -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: BUILD SUCCESS, all tests pass

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add CLAUDE.md
git -C /Users/mdproctor/claude/casehub/platform commit -m "docs(#151): update CLAUDE.md — remove Constraint/ConstraintOp from package structure"
```
