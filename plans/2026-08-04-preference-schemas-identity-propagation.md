# Remaining Preference Schemas + Identity Propagation Resolution

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #223 — register remaining platform preference schemas
**Issue group:** #223, #220

**Goal:** Register 4 remaining preference schemas (including the first BooleanPreference), migrate their consumers from @ConfigProperty to PreferenceProvider, and resolve the #220 identity propagation design decision with actionable engine issues.

**Architecture:** Follows the established #197 pattern — PreferenceKey constants in platform-api, schema registration in PlatformPreferenceRegistrar, PreferenceProvider.resolve().getOrDefault() at use-time in consumers. #220 produces no platform code — design resolution + engine issue filing only.

**Tech Stack:** Java 21, Quarkus CDI, PreferenceProvider SPI, JUnit 5, AssertJ

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA
- All preference resolutions use `Path.root()` scope (platform-global)
- `MockPreferenceProvider @DefaultBean` returns null for unset keys; `getOrDefault()` falls back to key's built-in default
- Use `ide_*` tools for all source file operations — never bash Edit/Write on .java files

---

### Task 1: Add 4 PreferenceKey constants to PlatformPreferenceKeys

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/preferences/PlatformPreferenceKeys.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/preferences/PlatformPreferenceKeysTest.java`

**Interfaces:**
- Produces: `PlatformPreferenceKeys.ENGAGEMENT_ENABLED` (`PreferenceKey<BooleanPreference>`), `PlatformPreferenceKeys.DELIVERY_RETRY_MAX_RETRIES` (`PreferenceKey<IntPreference>`), `PlatformPreferenceKeys.DIGEST_RETENTION_DAYS` (`PreferenceKey<IntPreference>`), `PlatformPreferenceKeys.VIEW_CACHE_TTL_SECONDS` (`PreferenceKey<IntPreference>`)

- [ ] **Step 1: Write failing tests for new keys**

Add new entries to the parameterized test source and a separate boolean key test in `PlatformPreferenceKeysTest.java`. The existing `keys()` method returns `Stream<Arguments>` of `(PreferenceKey<IntPreference>, String name, int default)`. The boolean key needs its own test since it's `PreferenceKey<BooleanPreference>`.

Add to `keys()`:
```java
Arguments.of(PlatformPreferenceKeys.DELIVERY_RETRY_MAX_RETRIES,
             "delivery.retry-max-retries", 5),
Arguments.of(PlatformPreferenceKeys.DIGEST_RETENTION_DAYS,
             "notification.digest-retention-days", 90),
Arguments.of(PlatformPreferenceKeys.VIEW_CACHE_TTL_SECONDS,
             "view.cache-ttl-seconds", 0)
```

Add new test methods for the boolean key:
```java
@Test
void engagement_enabled_key_has_correct_namespace_and_qualifiedName() {
    var key = PlatformPreferenceKeys.ENGAGEMENT_ENABLED;
    assertEquals("casehub.platform", key.namespace());
    assertEquals("delivery.engagement-enabled", key.name());
    assertEquals("casehub.platform.delivery.engagement-enabled", key.qualifiedName());
}

@Test
void engagement_enabled_key_has_correct_default() {
    assertFalse(PlatformPreferenceKeys.ENGAGEMENT_ENABLED.defaultValue().value());
}

@Test
void engagement_enabled_key_parser_round_trips() {
    BooleanPreference parsed = PlatformPreferenceKeys.ENGAGEMENT_ENABLED.parse("true");
    assertTrue(parsed.value());
    BooleanPreference parsedFalse = PlatformPreferenceKeys.ENGAGEMENT_ENABLED.parse("false");
    assertFalse(parsedFalse.value());
}
```

Update `all_keys_have_unique_qualifiedNames` — it uses `keys()` which only covers int keys. Add a combined stream or a separate uniqueness assertion that includes the boolean key.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform-api -Dtest=PlatformPreferenceKeysTest`
Expected: compilation failure — constants don't exist yet

- [ ] **Step 3: Add the 4 constants to PlatformPreferenceKeys**

Use `ide_insert_member` to add before the private constructor:

```java
public static final PreferenceKey<BooleanPreference> ENGAGEMENT_ENABLED =
        new PreferenceKey<>("casehub.platform", "delivery.engagement-enabled",
                BooleanPreference.of(false), BooleanPreference::parse);

public static final PreferenceKey<IntPreference> DELIVERY_RETRY_MAX_RETRIES =
        new PreferenceKey<>("casehub.platform", "delivery.retry-max-retries",
                IntPreference.of(5), IntPreference::parse);

public static final PreferenceKey<IntPreference> DIGEST_RETENTION_DAYS =
        new PreferenceKey<>("casehub.platform", "notification.digest-retention-days",
                IntPreference.of(90), IntPreference::parse);

public static final PreferenceKey<IntPreference> VIEW_CACHE_TTL_SECONDS =
        new PreferenceKey<>("casehub.platform", "view.cache-ttl-seconds",
                IntPreference.of(0), IntPreference::parse);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform-api -Dtest=PlatformPreferenceKeysTest`
Expected: all tests PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/preferences/PlatformPreferenceKeys.java platform-api/src/test/java/io/casehub/platform/api/preferences/PlatformPreferenceKeysTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#223): add 4 preference key constants — first BooleanPreference"
```

---

### Task 2: Register 4 new descriptors in PlatformPreferenceRegistrar

**Files:**
- Modify: `platform/src/main/java/io/casehub/platform/preferences/PlatformPreferenceRegistrar.java`
- Modify: `preferences-editor/src/test/java/io/casehub/platform/preferences/editor/PlatformPreferenceRegistrarTest.java`

**Interfaces:**
- Consumes: `PlatformPreferenceKeys.ENGAGEMENT_ENABLED`, `DELIVERY_RETRY_MAX_RETRIES`, `DIGEST_RETENTION_DAYS`, `VIEW_CACHE_TTL_SECONDS` from Task 1

- [ ] **Step 1: Write failing tests**

Update `PlatformPreferenceRegistrarTest`:

In `all_platform_keys_are_registered()`, add 4 new assertions:
```java
assertTrue(qualifiedNames.contains("casehub.platform.delivery.engagement-enabled"));
assertTrue(qualifiedNames.contains("casehub.platform.delivery.retry-max-retries"));
assertTrue(qualifiedNames.contains("casehub.platform.notification.digest-retention-days"));
assertTrue(qualifiedNames.contains("casehub.platform.view.cache-ttl-seconds"));
```

Add a new test for the boolean descriptor shape:
```java
@Test
void engagement_enabled_descriptor_has_boolean_type() {
    var descriptor = registry.resolve("casehub.platform.delivery.engagement-enabled");
    assertTrue(descriptor.isPresent());
    var d = descriptor.get();
    assertEquals("casehub.platform", d.namespace());
    assertEquals("delivery.engagement-enabled", d.name());
    assertEquals("boolean", d.type());
    assertEquals("false", d.defaultValue());
    assertFalse(d.multiValue());
    assertNotNull(d.label());
    assertNotNull(d.description());
    assertTrue(d.constraints().isEmpty());
}
```

Update `all_descriptors_have_labels_and_constraints` — add the 3 int keys to `expectedKeys`. The boolean key has no constraints, so either exclude it from the constraint assertion or adjust the check.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl preferences-editor -Dtest=PlatformPreferenceRegistrarTest`
Expected: FAIL — new qualified names not found

- [ ] **Step 3: Add 4 registration calls to PlatformPreferenceRegistrar.onStart()**

Use `ide_replace_member` on `onStart` to add 4 new `registry.register()` calls after the existing 6:

```java
registry.register(PreferenceSchemaDescriptor.of(PlatformPreferenceKeys.ENGAGEMENT_ENABLED)
        .label("Engagement tracking")
        .description("Enable engagement event recording for delivery tracking")
        .build());

registry.register(PreferenceSchemaDescriptor.of(PlatformPreferenceKeys.DELIVERY_RETRY_MAX_RETRIES)
        .label("Delivery retry limit")
        .description("Maximum retry attempts before marking delivery as expired")
        .constraints(Map.of(PreferenceConstraintKeys.MIN, 0, PreferenceConstraintKeys.MAX, 20))
        .build());

registry.register(PreferenceSchemaDescriptor.of(PlatformPreferenceKeys.DIGEST_RETENTION_DAYS)
        .label("Digest buffer retention (days)")
        .description("Days to retain digest buffer entries before purge")
        .constraints(Map.of(PreferenceConstraintKeys.MIN, 1, PreferenceConstraintKeys.MAX, 3650))
        .build());

registry.register(PreferenceSchemaDescriptor.of(PlatformPreferenceKeys.VIEW_CACHE_TTL_SECONDS)
        .label("View cache TTL (seconds)")
        .description("Time-to-live for cached view definitions (0 = disabled)")
        .constraints(Map.of(PreferenceConstraintKeys.MIN, 0, PreferenceConstraintKeys.MAX, 3600))
        .build());
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl preferences-editor -Dtest=PlatformPreferenceRegistrarTest`
Expected: all tests PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform/src/main/java/io/casehub/platform/preferences/PlatformPreferenceRegistrar.java preferences-editor/src/test/java/io/casehub/platform/preferences/editor/PlatformPreferenceRegistrarTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#223): register 4 new preference descriptors — 10 total"
```

---

### Task 3: Migrate notification-dispatch beans to PreferenceProvider

**Files:**
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/EngagementRecorder.java`
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/InAppEngagementBridge.java`
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/EngagementCallbackResource.java`
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/DeliveryRetryProcessor.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/EngagementRecorderTest.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/InAppEngagementBridgeTest.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/EngagementCallbackResourceTest.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/DeliveryRetryProcessorTest.java`

**Interfaces:**
- Consumes: `PlatformPreferenceKeys.ENGAGEMENT_ENABLED`, `PlatformPreferenceKeys.DELIVERY_RETRY_MAX_RETRIES` from Task 1

- [ ] **Step 1: Update tests to use PreferenceProvider instead of boolean/int constructor params**

Tests construct beans directly. After migration, they provide a `PreferenceProvider` via lambda that returns a `MapPreferences` with the desired value.

Helper pattern for tests (inline in each test class):
```java
private static PreferenceProvider providerWith(PreferenceKey<?> key, SingleValuePreference value) {
    return scope -> new MapPreferences(Map.of(key.qualifiedName(), value));
}
```

**EngagementRecorderTest**: Change `setUp()` to construct with `PreferenceProvider`:
```java
recorder = new EngagementRecorder(store,
    new CapturingEngagementEvent(firedEvents),
    providerWith(PlatformPreferenceKeys.ENGAGEMENT_ENABLED, BooleanPreference.of(true)));
```

Change `noOpWhenDisabled()`:
```java
var disabledRecorder = new EngagementRecorder(store,
    new CapturingEngagementEvent(firedEvents),
    providerWith(PlatformPreferenceKeys.ENGAGEMENT_ENABLED, BooleanPreference.of(false)));
```

**InAppEngagementBridgeTest**: Same pattern — replace `boolean enabled` with `PreferenceProvider`.

**EngagementCallbackResourceTest**: Same pattern — replace `boolean enabled` with `PreferenceProvider`. The test constructor changes signature.

**DeliveryRetryProcessorTest**: Replace `int maxRetries` with `PreferenceProvider`. Use `providerWith(PlatformPreferenceKeys.DELIVERY_RETRY_MAX_RETRIES, IntPreference.of(5))`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl notification-dispatch`
Expected: compilation failure — constructors no longer match

- [ ] **Step 3: Migrate EngagementRecorder**

Remove `boolean enabled` constructor parameter and `@ConfigProperty`. Add `@Inject PreferenceProvider preferenceProvider` as constructor parameter (final field). In `record()`, resolve at call time:
```java
public void record(DeliveryAttempt attempt, EngagementType type, String metadata) {
    boolean enabled = preferenceProvider
            .resolve(new SettingsScope(Path.root(), Instant.now()))
            .getOrDefault(PlatformPreferenceKeys.ENGAGEMENT_ENABLED)
            .value();
    if (!enabled) {
        return;
    }
    // ... rest unchanged
}
```

Add imports: `PreferenceProvider`, `SettingsScope`, `Path`, `PlatformPreferenceKeys`.
Remove import: `ConfigProperty`.

- [ ] **Step 4: Migrate InAppEngagementBridge**

Same pattern. Remove `boolean enabled` constructor parameter and `@ConfigProperty`. Add `PreferenceProvider preferenceProvider`. Resolve in `onStatusChanged()`.

- [ ] **Step 5: Migrate EngagementCallbackResource**

Same pattern. Remove `boolean enabled` constructor parameter and `@ConfigProperty`. Add `PreferenceProvider preferenceProvider`. Resolve in `handleCallback()` and `recordDirect()`. Update the test constructor to accept `PreferenceProvider` instead of `boolean`.

- [ ] **Step 6: Migrate DeliveryRetryProcessor**

Remove `int maxRetries` constructor parameter and `@ConfigProperty`. Add `PreferenceProvider preferenceProvider`. Resolve `DELIVERY_RETRY_MAX_RETRIES` in `advanceOrExpire()`:
```java
int maxRetries = preferenceProvider
        .resolve(new SettingsScope(Path.root(), Instant.now()))
        .getOrDefault(PlatformPreferenceKeys.DELIVERY_RETRY_MAX_RETRIES)
        .value();
```

Keep the other 4 retry `@ConfigProperty` parameters unchanged.

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl notification-dispatch`
Expected: all tests PASS

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add notification-dispatch/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#223): migrate notification-dispatch to PreferenceProvider — engagement + retry"
```

---

### Task 4: Migrate digest buffer beans to PreferenceProvider

**Files:**
- Modify: `digest-jpa/src/main/java/io/casehub/platform/delivery/digest/jpa/JpaDigestBuffer.java`
- Modify: `digest-inmem/src/main/java/io/casehub/platform/delivery/digest/inmem/InMemoryDigestBuffer.java`

**Interfaces:**
- Consumes: `PlatformPreferenceKeys.DIGEST_RETENTION_DAYS` from Task 1

- [ ] **Step 1: Check for existing tests**

Run: `ide_search_text` for `JpaDigestBufferTest` and `InMemoryDigestBufferTest` in test files.

- [ ] **Step 2: Migrate JpaDigestBuffer**

Remove `@ConfigProperty(name = "casehub.notification.digest.retention-days", defaultValue = "90")` field. Add `@Inject PreferenceProvider preferenceProvider` field. Resolve `DIGEST_RETENTION_DAYS` at use-time wherever `retentionDays` was read.

- [ ] **Step 3: Migrate InMemoryDigestBuffer**

Same pattern — remove `@ConfigProperty` field, add `@Inject PreferenceProvider`, resolve at use-time.

- [ ] **Step 4: Run module tests**

Run: `mvn --batch-mode test -pl digest-jpa` and `mvn --batch-mode test -pl digest-inmem`
Expected: PASS (MockPreferenceProvider returns null → getOrDefault falls back to default 90)

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add digest-jpa/ digest-inmem/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#223): migrate digest buffer retention to PreferenceProvider"
```

---

### Task 5: Migrate SubjectViewOrchestrator to PreferenceProvider

**Files:**
- Modify: `platform-view/src/main/java/io/casehub/platform/view/SubjectViewOrchestrator.java`

**Interfaces:**
- Consumes: `PlatformPreferenceKeys.VIEW_CACHE_TTL_SECONDS` from Task 1

- [ ] **Step 1: Migrate SubjectViewOrchestrator**

Remove `@ConfigProperty(name = "casehub.view.cache.ttl-seconds", defaultValue = "0")` field. Add `@Inject PreferenceProvider preferenceProvider` field. Resolve `VIEW_CACHE_TTL_SECONDS` in `getViews()`:

```java
private List<SubjectViewSpec> getViews(String tenancyId) {
    int cacheTtlSeconds = preferenceProvider
            .resolve(new SettingsScope(Path.root(), Instant.now()))
            .getOrDefault(PlatformPreferenceKeys.VIEW_CACHE_TTL_SECONDS)
            .value();
    if (cacheTtlSeconds <= 0) {
        return viewStore.findByTenancy(tenancyId);
    }
    var cached = viewCache.get(tenancyId);
    if (cached != null && !cached.isExpired(cacheTtlSeconds)) {
        return cached.views();
    }
    var views = viewStore.findByTenancy(tenancyId);
    viewCache.put(tenancyId, new CachedViews(views, Instant.now()));
    return views;
}
```

Remove import: `ConfigProperty`. Add imports: `PreferenceProvider`, `SettingsScope`, `Path`, `PlatformPreferenceKeys`.

- [ ] **Step 2: Run module tests**

Run: `mvn --batch-mode test -pl platform-view`
Expected: PASS (default 0 = caching disabled, same behavior as before)

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-view/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#223): migrate view cache TTL to PreferenceProvider"
```

---

### Task 6: Identity propagation resolution (#220)

**Files:**
- Modify: `docs/specs/2026-06-08-acl-authorization-model-design.md` (§14 resolution)

- [ ] **Step 1: Update ACL spec §14**

Replace the body of §14 with the resolution:

> **Resolved:** Store `actorId` on `CaseInstance` at creation. `CaseHubReactor` populates `instance.actorId` from `currentPrincipal.actorId()` at save time. CaseInstance is the durable identity record; PropagationContext carries identity for runtime propagation during active execution. See engine issues for implementation.

- [ ] **Step 2: File engine issues**

File 3 issues on `casehubio/engine`:

**Issue 1:** "feat: populate PropagationContext with identity at createRoot()"
Body: All 4 call sites (CaseHubReactor ×2, EmptyWorkerContextProvider, CaseContextChangedEventHandler). Capture `Map.of("userId", currentPrincipal.actorId(), "roles", String.join(",", currentPrincipal.roles()))` into `inheritedAttributes`. Verify createChild() propagates. Refs platform ACL spec §12.

**Issue 2:** "feat: store actorId on CaseInstance at creation"
Body: Add `actorId` column to CaseInstanceEntity (Flyway migration). CaseHubReactor sets actorId from currentPrincipal.actorId() at save. Resolves §14 identity gap. Refs platform ACL spec §14.

**Issue 3:** "feat: read identity from PropagationContext in CasehubDispatch"
Body: Extract userId/roles from PropagationContext.inheritedAttributes when submitting via WorkOrchestrator. Identity available for ACL checks on dispatched work. Refs platform ACL spec §13.

Label all: `enhancement`, `acl`, `scale: M`, `complexity: Med`.

- [ ] **Step 3: Commit spec update**

```bash
git -C /Users/mdproctor/claude/casehub/platform add docs/specs/2026-06-08-acl-authorization-model-design.md
git -C /Users/mdproctor/claude/casehub/platform commit -m "docs(#220): resolve §14 — actorId on CaseInstance + PropagationContext"
```

---

### Task 7: Doc updates + full build verification

**Files:**
- Modify: `CLAUDE.md` — update `platform/` module description (10 schemas, was 6)
- Modify: `docs/guides/consumer-guide.md` — add new preference keys to config table

- [ ] **Step 1: Update CLAUDE.md module description**

In the `platform/` row of the Modules table, update `PlatformPreferenceRegistrar` description:
- Change "registers 6 retention PreferenceSchemaDescriptors" to "registers 10 PreferenceSchemaDescriptors (6 retention + engagement toggle + retry limit + digest retention + view cache TTL)"

- [ ] **Step 2: Update consumer-guide.md**

Add 4 new rows to the preference configuration table:

```
| `casehub.platform.delivery.engagement-enabled` | Enable engagement event recording | false |
| `casehub.platform.delivery.retry-max-retries` | Maximum delivery retry attempts | 5 |
| `casehub.platform.notification.digest-retention-days` | Digest buffer retention (days) | 90 |
| `casehub.platform.view.cache-ttl-seconds` | View cache TTL (0 = disabled) | 0 |
```

Note the BooleanPreference pattern — first boolean key. Add a brief note near the preference registration section if one exists.

- [ ] **Step 3: Full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and tests pass

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add CLAUDE.md docs/guides/consumer-guide.md
git -C /Users/mdproctor/claude/casehub/platform commit -m "docs(#223): update CLAUDE.md + consumer-guide with new preference keys"
```
