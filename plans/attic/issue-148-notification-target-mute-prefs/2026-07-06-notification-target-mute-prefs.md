# Notification Target Resolution, Mute/Snooze, Channel Preferences — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #148 — notification target resolution
**Issue group:** #148, #143, #145
**Spec:** `docs/superpowers/specs/2026-07-06-notification-target-mute-prefs-design.md`

**Goal:** Build the notification evaluation pipeline between subscription matching and delivery — target resolution expands recipients, mute/snooze suppress notifications, channel preferences route delivery.

**Architecture:** SubscriptionEngine fires `SubscriptionMatched` via CDI `fireAsync`. A new `NotificationDispatcher` observes it and orchestrates: TargetResolver → SuppressionEvaluator → TemplateResolver → ChannelRouter → per-channel delivery. Three new modules: `notification-settings-inmem/`, `notification-settings-jpa/`, `notification-dispatch/`. All new SPIs in platform-api with @DefaultBean no-ops in platform/.

**Tech Stack:** Java 21, Quarkus (CDI, RESTEasy Reactive, Hibernate ORM Panache), PostgreSQL + Flyway, ConcurrentHashMap (in-memory stores)

## Global Constraints

- `platform-api/` must remain zero-dependency — pure Java only. No Quarkus, no JPA, no casehubio imports.
- Every SPI gets a @DefaultBean no-op in `platform/`. No-ops must NOT fire CDI events.
- CDI priority ladder: @DefaultBean (mock) → @ApplicationScoped (JPA) → @Alternative @Priority(100) (in-memory).
- In-memory modules: no `quarkus-maven-plugin`, no `quarkus:build` goal.
- JPA module uses Hibernate ORM Panache (blocking-only — no reactive SPI, no Hibernate Reactive overhead).
- Flyway migration paths are module-scoped: `classpath:db/notification-settings/migration` for settings, `classpath:db/subscription/migration` for subscriptions.
- All REST endpoints enforce `CurrentPrincipal` — userId and tenancyId overridden from principal, never from request body.
- `userId` → `ownerId` rename is a breaking SPI change. All callers update mechanically.
- `excludeActor` replaced by `includeActor` (false-by-default — Java primitive default aligns with intended behaviour).

---

### Task 1: SPI Types and No-Op Defaults

All new records, enums, SPI interfaces in platform-api. No-op defaults in platform/. Subscription model changes (userId→ownerId, targets, includeActor). This is the foundation — every subsequent task depends on these types compiling.

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/Subscription.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/SubscriptionInput.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/SubscriptionUpdate.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/SubscriptionQuery.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/SubscriptionStore.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/ReactiveSubscriptionStore.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/subscription/NotificationTarget.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/subscription/TargetType.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/subscription/SubscriptionMatched.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryChannelDescriptor.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryChannels.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryChannelRegistry.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/NotificationDeliverer.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryResult.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/NotificationPreferences.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/ChannelPreference.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/QuietHours.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/NotificationPreferenceStore.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/NotificationPreferenceUpdate.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/MuteRule.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/MuteScope.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/MuteRuleInput.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/Snooze.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/SnoozeInput.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/SuppressionStore.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/SuppressionResult.java`
- Modify: `platform/src/main/java/io/casehub/platform/subscription/NoOpSubscriptionStore.java`
- Modify: `platform/src/main/java/io/casehub/platform/subscription/NoOpReactiveSubscriptionStore.java`
- Create: `platform/src/main/java/io/casehub/platform/notification/settings/NoOpNotificationPreferenceStore.java`
- Create: `platform/src/main/java/io/casehub/platform/notification/settings/NoOpSuppressionStore.java`
- Create: `platform/src/main/java/io/casehub/platform/delivery/NoOpDeliveryChannelRegistry.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/subscription/SubscriptionSpiTest.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/subscription/SubscriptionStoreContractTest.java`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: All SPI interfaces and records. Every subsequent task depends on these types.

- [ ] **Step 1: Delivery channel types (platform-api)**

Create `io.casehub.platform.api.delivery` package. Write all delivery records, enums, and SPI interfaces per spec §3. `DeliveryChannelDescriptor(channelId, displayName, external, defaultEnabled, defaultMinSeverity)`. `DeliveryChannelRegistry` with `register(descriptor, deliverer)`, `resolve(channelId)`, `resolveDeliverer(channelId)`, `discover()`. `NotificationDeliverer` with `channelId()` and `deliver(NotificationInput)`. `DeliveryResult(success, failureReason)`. `DeliveryChannels` constants class.

- [ ] **Step 2: Notification settings types (platform-api)**

Create `io.casehub.platform.api.notification.settings` package. Write all settings records, enums, and SPI interfaces per spec §4 and §5. `NotificationPreferences`, `ChannelPreference`, `QuietHours`, `NotificationPreferenceStore`, `NotificationPreferenceUpdate`. `MuteRule`, `MuteScope`, `MuteRuleInput`, `Snooze`, `SnoozeInput`, `SuppressionStore`, `SuppressionResult(isMuted, isSnoozed, quietHoursActive)`.

- [ ] **Step 3: Subscription model changes (platform-api)**

Modify subscription types per spec §1. Rename `userId` → `ownerId` in `Subscription`, `SubscriptionInput`, `SubscriptionUpdate`, `SubscriptionQuery`. Add `targets` (`List<NotificationTarget>`) and `includeActor` (boolean, default false) to `Subscription` and `SubscriptionInput`. Add nullable `targets` (`List<NotificationTarget>`) and `includeActor` (`Boolean`) to `SubscriptionUpdate`. Create `NotificationTarget(TargetType, String id)` and `TargetType` enum. Create `SubscriptionMatched(Subscription, Object pojo)` CDI event. Update `SubscriptionStore` and `ReactiveSubscriptionStore` method signatures: `userId` → `ownerId`.

- [ ] **Step 4: No-op defaults (platform/)**

Update `NoOpSubscriptionStore` and `NoOpReactiveSubscriptionStore` for new signatures (ownerId, targets, includeActor). Create `NoOpNotificationPreferenceStore` (@DefaultBean, returns Optional.empty() / structurally valid defaults), `NoOpSuppressionStore` (@DefaultBean, returns empty lists / Optional.empty() / false), `NoOpDeliveryChannelRegistry` (@DefaultBean, returns empty — does NOT fire CDI events).

- [ ] **Step 5: Fix existing tests for compilation**

Update `SubscriptionSpiTest` and `SubscriptionStoreContractTest` for userId→ownerId rename and new record components (targets, includeActor). These are compilation fixes only — new behaviour tests come in later tasks.

- [ ] **Step 6: Build and verify**

Run: `mvn --batch-mode install -pl platform-api,platform -am`
Expected: BUILD SUCCESS. All existing tests pass with updated signatures.

- [ ] **Step 7: Commit**

```
feat(platform#148,#143,#145): SPI types — delivery channels, notification settings, subscription model changes
```

---

### Task 2: Subscription Model Migration

Update subscription store implementations and REST layer for userId→ownerId, targets, includeActor. Flyway V2 migration for JPA.

**Files:**
- Modify: `subscriptions-inmem/src/main/java/io/casehub/platform/subscription/inmem/InMemorySubscriptionStore.java`
- Modify: `subscriptions-inmem/src/main/java/io/casehub/platform/subscription/inmem/InMemoryReactiveSubscriptionStore.java`
- Modify: `subscriptions-jpa/src/main/java/io/casehub/platform/subscription/jpa/SubscriptionEntity.java`
- Modify: `subscriptions-jpa/src/main/java/io/casehub/platform/subscription/jpa/JpaSubscriptionStore.java`
- Modify: `subscriptions-jpa/src/main/java/io/casehub/platform/subscription/jpa/JpaReactiveSubscriptionStore.java`
- Create: `subscriptions-jpa/src/main/resources/db/subscription/migration/V2__subscription_targets.sql`
- Modify: `subscriptions/src/main/java/io/casehub/platform/subscription/rest/SubscriptionResource.java`
- Modify: `subscriptions-inmem/src/test/java/io/casehub/platform/subscription/inmem/InMemorySubscriptionStoreTest.java`
- Modify: `subscriptions/src/test/java/io/casehub/platform/subscription/engine/SubscriptionEngineTest.java`

**Interfaces:**
- Consumes: Task 1 SPI types (Subscription, SubscriptionInput, NotificationTarget, TargetType)
- Produces: Working subscription store implementations with targets support

- [ ] **Step 1: Write contract test additions for targets + includeActor**

Add tests to `InMemorySubscriptionStoreTest` (which extends `SubscriptionStoreContractTest`): `store_withTargets_persistsTargets`, `store_withIncludeActor_persistsFlag`, `findAllEnabled_returnsTargetsAndIncludeActor`. Build subscription inputs with `List.of(new NotificationTarget(TargetType.USER, "user-1"))`.

- [ ] **Step 2: Run tests — verify they fail**

Run: `mvn --batch-mode test -pl subscriptions-inmem`
Expected: FAIL — InMemorySubscriptionStore constructor doesn't match new Subscription record shape.

- [ ] **Step 3: Update InMemorySubscriptionStore + InMemoryReactiveSubscriptionStore**

Rename `userId` → `ownerId` in all internal maps and methods. Update `Subscription` construction to include `targets` and `includeActor` from input. The in-memory store stores the `List<NotificationTarget>` directly (no serialisation needed).

- [ ] **Step 4: Run tests — verify they pass**

Run: `mvn --batch-mode test -pl subscriptions-inmem`
Expected: PASS

- [ ] **Step 5: Update JPA entity and store**

Update `SubscriptionEntity` — rename `userId` field to `ownerId`, add `targetsJson` (TEXT, JSON-serialized `List<NotificationTarget>`), add `includeActor` (boolean, default false). Update `JpaSubscriptionStore` and `JpaReactiveSubscriptionStore` — rename userId→ownerId in queries, add JSON serialization/deserialization for targets using Jackson `ObjectMapper`.

- [ ] **Step 6: Create Flyway V2 migration**

Create `V2__subscription_targets.sql`:
```sql
ALTER TABLE subscription RENAME COLUMN user_id TO owner_id;
ALTER TABLE subscription ADD COLUMN targets_json TEXT;
ALTER TABLE subscription ADD COLUMN include_actor BOOLEAN NOT NULL DEFAULT FALSE;

-- Backfill: existing subscriptions get explicit USER target pointing to owner
UPDATE subscription SET targets_json = '[{"type":"USER","id":"' || owner_id || '"}]'
    WHERE targets_json IS NULL;

ALTER TABLE subscription ALTER COLUMN targets_json SET NOT NULL;

-- Update indexes for renamed column
DROP INDEX IF EXISTS idx_subscription_user_tenant_enabled;
CREATE INDEX idx_subscription_owner_tenant_enabled
    ON subscription (owner_id, tenancy_id, enabled, created_at DESC);
```

- [ ] **Step 7: Update SubscriptionResource**

Rename `userId` → `ownerId`. In `POST /subscriptions`: if `targets` is null or empty, default to `List.of(new NotificationTarget(TargetType.USER, principal.actorId()))`. Override `input.ownerId()` from `principal.actorId()` (same pattern as existing userId override).

- [ ] **Step 8: Update SubscriptionEngineTest**

Fix compilation — the engine test constructs `Subscription` and `SubscriptionInput` directly. Update to include `targets` and `includeActor` fields. The engine's matching logic is unchanged — dispatch refactoring is Task 5.

- [ ] **Step 9: Build and verify**

Run: `mvn --batch-mode install -pl subscriptions-inmem,subscriptions-jpa,subscriptions -am`
Expected: BUILD SUCCESS

- [ ] **Step 10: Commit**

```
feat(platform#148): subscription model migration — ownerId, targets, includeActor + Flyway V2
```

---

### Task 3: In-Memory Notification Settings Stores

New `notification-settings-inmem/` module. InMemoryNotificationPreferenceStore + InMemorySuppressionStore with contract tests. This module enables testing the dispatch pipeline (Task 4) without JPA.

**Files:**
- Create: `notification-settings-inmem/pom.xml`
- Create: `notification-settings-inmem/src/main/java/io/casehub/platform/notification/settings/inmem/InMemoryNotificationPreferenceStore.java`
- Create: `notification-settings-inmem/src/main/java/io/casehub/platform/notification/settings/inmem/InMemorySuppressionStore.java`
- Create: `notification-settings-inmem/src/test/java/io/casehub/platform/notification/settings/inmem/InMemoryNotificationPreferenceStoreTest.java`
- Create: `notification-settings-inmem/src/test/java/io/casehub/platform/notification/settings/inmem/InMemorySuppressionStoreTest.java`
- Modify: `pom.xml` (add module)

**Interfaces:**
- Consumes: Task 1 SPI types (NotificationPreferenceStore, SuppressionStore, all settings records)
- Produces: Working in-memory stores for test and ephemeral use

- [ ] **Step 1: Create module pom.xml**

Maven coordinates: `io.casehub:casehub-platform-notification-settings-inmem`. Dependencies: `casehub-platform-api`, `quarkus-arc`. Test: `quarkus-junit`. No `quarkus-maven-plugin`. Add module to parent `pom.xml`.

- [ ] **Step 2: Write NotificationPreferenceStore contract tests**

`InMemoryNotificationPreferenceStoreTest`: `get_returnsEmpty_whenNoPreferencesStored`, `update_createsPreferences_whenNoneExist`, `update_updatesChannelDefaults`, `update_setsQuietHours`, `update_clearsQuietHours_whenClearFlagTrue`, `update_preservesQuietHours_whenNullAndNotCleared`, `get_isolatesByUserAndTenancy`.

- [ ] **Step 3: Implement InMemoryNotificationPreferenceStore**

`@Alternative @Priority(100) @ApplicationScoped`. ConcurrentHashMap keyed by `userId + ":" + tenancyId`. `get()` returns `Optional.empty()` for absent key. `update()` is upsert — atomically creates or updates via `compute()`. `clearQuietHours` flag clears quiet hours when true.

- [ ] **Step 4: Run preference tests — verify pass**

Run: `mvn --batch-mode test -pl notification-settings-inmem -Dtest=InMemoryNotificationPreferenceStoreTest`

- [ ] **Step 5: Write SuppressionStore contract tests**

`InMemorySuppressionStoreTest`: `addMute_storesRule`, `addMute_generatesUUIDv7Id`, `activeMutes_returnsOnlyForUser`, `activeMutes_filtersExpired_lazily`, `removeMute_returnsTrue_whenExists`, `removeMute_returnsFalse_whenNotFound`, `removeMute_enforcesUserOwnership`, `activateSnooze_storesSnooze`, `activateSnooze_replacesExisting`, `activeSnooze_returnsEmpty_whenNone`, `activeSnooze_returnsEmpty_whenExpired`, `cancelSnooze_returnsTrue_whenActive`, `cancelSnooze_returnsFalse_whenNone`, `mute_entity_scope_requiresEntityType`, `mute_category_scope_entityTypeOptional`.

- [ ] **Step 6: Implement InMemorySuppressionStore**

`@Alternative @Priority(100) @ApplicationScoped`. Two ConcurrentHashMaps — one for mute rules (`Map<String, List<MuteRule>>` keyed by userId:tenancyId), one for snooze (`Map<String, Snooze>`). `addMute()` generates UUIDv7 id, validates entityType required for ENTITY scope. `activeMutes()` filters expired lazily. `activateSnooze()` replaces existing via `put()`. `activeSnooze()` returns empty if expired. `cancelSnooze()` removes via `remove()`.

- [ ] **Step 7: Run suppression tests — verify pass**

Run: `mvn --batch-mode test -pl notification-settings-inmem -Dtest=InMemorySuppressionStoreTest`

- [ ] **Step 8: Build and verify**

Run: `mvn --batch-mode install -pl notification-settings-inmem -am`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```
feat(platform#143,#145): in-memory notification settings stores — preferences + suppression
```

---

### Task 4: Dispatch Pipeline

New `notification-dispatch/` module. The core of this branch — TargetResolver, SuppressionEvaluator, ChannelRouter, NotificationDispatcher, InAppNotificationDeliverer, InMemoryDeliveryChannelRegistry. TemplateResolver moves here from subscriptions/.

**Files:**
- Create: `notification-dispatch/pom.xml`
- Create: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/NotificationDispatcher.java`
- Create: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/TargetResolver.java`
- Create: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/SuppressionEvaluator.java`
- Create: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/ChannelRouter.java`
- Create: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/ResolvedChannel.java`
- Create: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/InAppNotificationDeliverer.java`
- Create: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/InMemoryDeliveryChannelRegistry.java`
- Move: `subscriptions/src/main/java/.../engine/TemplateResolver.java` → `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/TemplateResolver.java`
- Create: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/TargetResolverTest.java`
- Create: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/SuppressionEvaluatorTest.java`
- Create: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/ChannelRouterTest.java`
- Create: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/NotificationDispatcherTest.java`
- Move: `subscriptions/src/test/java/.../engine/TemplateResolverTest.java` → `notification-dispatch/src/test/java/.../dispatch/TemplateResolverTest.java`
- Modify: `pom.xml` (add module)

**Interfaces:**
- Consumes: Task 1 SPI types (all delivery + settings SPIs), Task 3 in-memory stores (for testing), GroupMembershipProvider, NotificationStore
- Produces: `NotificationDispatcher` that observes `SubscriptionMatched` and orchestrates the full pipeline

- [ ] **Step 1: Create module pom.xml**

Maven coordinates: `io.casehub:casehub-platform-notification-dispatch`. Dependencies: `casehub-platform-api`, `quarkus-arc`. Test: `quarkus-junit`, `casehub-platform-notification-settings-inmem`, `casehub-platform-notifications-inmem`, `casehub-platform-testing`. Add module to parent `pom.xml`.

- [ ] **Step 2: Move TemplateResolver**

Move `TemplateResolver.java` and `TemplateResolverTest.java` from `subscriptions/` to `notification-dispatch/`. Update package declaration to `io.casehub.platform.notification.dispatch`. The TemplateResolver is a plain utility class with no CDI dependencies — move is clean. In `subscriptions/`, the SubscriptionEngine will need to import from the new location — handled in Task 5.

- [ ] **Step 3: Write TargetResolver tests**

Unit tests (no CDI, constructor-inject mocks): `resolve_userTarget_addsDirectly`, `resolve_groupTarget_expandsViaGroupMembershipProvider`, `resolve_groupTarget_emptyGroup_logsWarn_returnsEmpty`, `resolve_eventFieldTarget_extractsFromPojo`, `resolve_eventFieldTarget_nullField_logsWarn_skips`, `resolve_deduplicatesAcrossTargets`, `resolve_excludesActor_byDefault`, `resolve_includesActor_whenIncludeActorTrue`, `resolve_emptyAfterExclusion_returnsEmpty`.

Use a test POJO with `type()`, `assigneeId()`, `tenancyId()`, `actorId()` methods. Mock `GroupMembershipProvider`.

- [ ] **Step 4: Implement TargetResolver**

`@ApplicationScoped`. Inject `GroupMembershipProvider`. Method: `Set<String> resolve(Subscription subscription, Object pojo)`. Iterates `subscription.targets()`: USER → add id; GROUP → `groupMembershipProvider.membersOf(id)` → add each `actorId()`; EVENT_FIELD → extract via MethodHandle (same pattern as `EventTypeObjectType.extractEventType()`). Deduplicate via `LinkedHashSet`. If `!subscription.includeActor()`, extract actor via `template.actorIdField()` MethodHandle and remove. GROUP returning empty → log WARN with group name and subscription ID.

- [ ] **Step 5: Run TargetResolver tests — verify pass**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=TargetResolverTest`

- [ ] **Step 6: Write SuppressionEvaluator tests**

Pure function tests (no CDI): `evaluate_noMutesNoSnooze_returnsAllFalse`, `evaluate_entityMuteMatches_isMutedTrue`, `evaluate_categoryMuteMatches_isMutedTrue`, `evaluate_categoryMuteWithEntityType_matchesBoth`, `evaluate_categoryMuteWithEntityType_noMatchOnDifferentEntity`, `evaluate_expiredMute_ignored`, `evaluate_activeSnooze_isSnoozedTrue`, `evaluate_expiredSnooze_isSnoozedFalse`, `evaluate_quietHoursActive_sameDayWindow`, `evaluate_quietHoursActive_crossMidnight`, `evaluate_quietHoursInactive_outsideWindow`, `evaluate_noQuietHours_quietHoursActiveFalse`.

- [ ] **Step 7: Implement SuppressionEvaluator**

`@ApplicationScoped`. No injected dependencies — pure function over pre-fetched data. Method: `SuppressionResult evaluate(List<MuteRule> activeMutes, Optional<Snooze> activeSnooze, QuietHours quietHours, String entityType, String entityId, String category)`. Mute matching: ENTITY scope checks `entityType + scopeId`, CATEGORY scope checks `scopeId` (+ optional `entityType` refinement). Expired rules filtered. Snooze: active if `until` is after `Instant.now()`. Quiet hours: convert to user's local time via `ZoneId`, handle midnight crossing per spec.

- [ ] **Step 8: Run SuppressionEvaluator tests — verify pass**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=SuppressionEvaluatorTest`

- [ ] **Step 9: Implement InMemoryDeliveryChannelRegistry + InAppNotificationDeliverer**

`InMemoryDeliveryChannelRegistry @ApplicationScoped` — ConcurrentHashMap keyed by channelId, stores both descriptors and deliverer instances. `register()` puts both. `resolve()` / `resolveDeliverer()` / `discover()` read from map.

`InAppNotificationDeliverer @ApplicationScoped` — implements `NotificationDeliverer`. `@PostConstruct` self-registers with registry: `DeliveryChannelDescriptor(IN_APP, "In-App Inbox", false, true, INFO)`. `deliver()` calls `notificationStore.store(notification)`, returns success.

- [ ] **Step 10: Write ChannelRouter tests**

Tests with pre-populated registry: `route_returnsInApp_whenNoPreferences`, `route_respectsMinSeverity_suppressesBelowThreshold`, `route_respectsEnabledFlag`, `route_marksSuppressed_whenSnoozedAndExternal`, `route_marksSuppressed_whenQuietHoursAndExternal`, `route_doesNotSuppressInApp_whenSnoozed`, `route_usesChannelDefaults_whenNoUserPreference`, `route_usesUserPreference_overChannelDefault`.

- [ ] **Step 11: Implement ChannelRouter**

`@ApplicationScoped`. Inject `DeliveryChannelRegistry`. Method: `Set<ResolvedChannel> route(Map<String, ChannelPreference> channelDefaults, SuppressionResult suppressionResult, NotificationSeverity severity)`. For each channel from `registry.discover()`: check user preference (or fall back to channel descriptor defaults), check severity threshold, check if external AND (snoozed or quiet hours). Resolve deliverer via `registry.resolveDeliverer()`. Return `ResolvedChannel(channelId, deliverer, suppressed)`.

- [ ] **Step 12: Run ChannelRouter tests — verify pass**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=ChannelRouterTest`

- [ ] **Step 13: Write NotificationDispatcher integration test**

`@QuarkusTest` with InMemory stores. Full pipeline test: create a subscription with GROUP target, push a POJO into the alpha network, verify: target resolved → mute checked → template resolved → notification stored in NotificationStore for each recipient. Test cases: `dispatch_userTarget_createsNotification`, `dispatch_groupTarget_expandsAndCreates`, `dispatch_mutedUser_dropsNotification`, `dispatch_snoozedUser_createsInApp_suppressesExternal`, `dispatch_nullTemplateResolution_skipsRecipient`, `dispatch_excludesActor_byDefault`.

- [ ] **Step 14: Implement NotificationDispatcher**

`@ApplicationScoped`. Inject `TargetResolver`, `SuppressionEvaluator`, `ChannelRouter`, `NotificationPreferenceStore`, `SuppressionStore`. Method: `void onMatch(@ObservesAsync SubscriptionMatched event)`. Pipeline per spec §2: resolve targets → per user: pre-fetch preferences + suppression → evaluate suppression → if muted skip → resolve template (null check → skip) → route to channels → per channel: if not suppressed, deliver with error isolation (try/catch per channel, log WARN on failure).

- [ ] **Step 15: Run full pipeline tests — verify pass**

Run: `mvn --batch-mode test -pl notification-dispatch`
Expected: ALL PASS

- [ ] **Step 16: Build and verify**

Run: `mvn --batch-mode install -pl notification-dispatch -am`
Expected: BUILD SUCCESS

- [ ] **Step 17: Commit**

```
feat(platform#148,#143,#145): notification dispatch pipeline — target resolver, suppression, channel routing
```

---

### Task 5: SubscriptionEngine Refactor

Decouple SubscriptionEngine from delivery — fire `SubscriptionMatched` instead of inline delivery. Remove TemplateResolver import (moved to notification-dispatch/). Update ConstraintCompiler userId→ownerId.

**Files:**
- Modify: `subscriptions/src/main/java/io/casehub/platform/subscription/engine/SubscriptionEngine.java`
- Modify: `subscriptions/src/main/java/io/casehub/platform/subscription/engine/ConstraintCompiler.java`
- Delete: `subscriptions/src/main/java/io/casehub/platform/subscription/engine/TemplateResolver.java` (moved in Task 4)
- Modify: `subscriptions/src/test/java/io/casehub/platform/subscription/engine/SubscriptionEngineTest.java`
- Modify: `subscriptions/src/test/java/io/casehub/platform/subscription/engine/ConstraintCompilerTest.java`
- Delete: `subscriptions/src/test/java/io/casehub/platform/subscription/engine/TemplateResolverTest.java` (moved in Task 4)
- Modify: `subscriptions/pom.xml` (remove TemplateResolver dep if needed, add CDI Event dependency)

**Interfaces:**
- Consumes: Task 1 SPI types (SubscriptionMatched), Task 4 (TemplateResolver moved)
- Produces: SubscriptionEngine that fires SubscriptionMatched instead of inline delivery

- [ ] **Step 1: Update SubscriptionEngineTest**

Change assertions: instead of verifying `NotificationStore.store()` was called (inline delivery), verify that `Event<SubscriptionMatched>` was fired with the correct subscription and pojo. The engine no longer needs `NotificationStore` or `TemplateResolver` injected — remove them.

- [ ] **Step 2: Run test — verify it fails**

Run: `mvn --batch-mode test -pl subscriptions -Dtest=SubscriptionEngineTest`
Expected: FAIL — SubscriptionEngine still does inline delivery.

- [ ] **Step 3: Refactor SubscriptionEngine**

Remove `NotificationStore` and `TemplateResolver` injections. Add `@Inject Event<SubscriptionMatched> matchEvent`. Change DataProcessor from `pojo -> { resolve template, store notification }` to `pojo -> matchEvent.fireAsync(new SubscriptionMatched(subscription, pojo))`. The `wireSubscription()` method simplifies — no TemplateResolver call, no NotificationStore call.

- [ ] **Step 4: Update ConstraintCompiler**

Rename the `userId` parameter to `ownerId` in `compile(constraints, tenancyId, ownerId)`. The `$me` placeholder still resolves to the subscription owner's ID — this is the subscription owner, used for constraint matching (e.g., "notify me when a work item is assigned to $me"). Update `ConstraintCompilerTest` to match.

- [ ] **Step 5: Delete moved files**

Remove `TemplateResolver.java` and `TemplateResolverTest.java` from `subscriptions/` (already copied to `notification-dispatch/` in Task 4).

- [ ] **Step 6: Run tests — verify pass**

Run: `mvn --batch-mode test -pl subscriptions`
Expected: PASS

- [ ] **Step 7: Build and verify**

Run: `mvn --batch-mode install -pl subscriptions -am`
Expected: BUILD SUCCESS

- [ ] **Step 8: Commit**

```
refactor(platform#148): SubscriptionEngine fires SubscriptionMatched — decouples matching from delivery
```

---

### Task 6: REST Endpoints

Add REST endpoints for preferences, mute, snooze, and channel discovery to the `notifications/` module.

**Files:**
- Create: `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationPreferenceResource.java`
- Create: `notifications/src/main/java/io/casehub/platform/notification/rest/SuppressionResource.java`
- Create: `notifications/src/main/java/io/casehub/platform/notification/rest/DeliveryChannelResource.java`
- Create: `notifications/src/test/java/io/casehub/platform/notification/rest/NotificationPreferenceResourceTest.java`
- Create: `notifications/src/test/java/io/casehub/platform/notification/rest/SuppressionResourceTest.java`
- Create: `notifications/src/test/java/io/casehub/platform/notification/rest/DeliveryChannelResourceTest.java`
- Modify: `notifications/pom.xml` (add notification-settings-inmem test dep)

**Interfaces:**
- Consumes: Task 1 SPI types, Task 3 in-memory stores (test dep)
- Produces: REST API for preferences, mute/snooze, channel discovery

- [ ] **Step 1: Write preference endpoint tests**

`@QuarkusTest` with in-memory store. Test `GET /notifications/preferences` returns defaults when none stored. Test `PUT /notifications/preferences` stores and returns preferences. Test tenant isolation. Test quiet hours setting and clearing.

- [ ] **Step 2: Implement NotificationPreferenceResource**

`@Path("/notifications/preferences") @ApplicationScoped`. Inject `NotificationPreferenceStore`, `CurrentPrincipal`. `GET` returns preferences or default empty prefs. `PUT` calls `update()` with userId/tenancyId from principal. Override userId/tenancyId from principal, never from request body.

- [ ] **Step 3: Run preference tests — verify pass**

Run: `mvn --batch-mode test -pl notifications -Dtest=NotificationPreferenceResourceTest`

- [ ] **Step 4: Write suppression endpoint tests**

Test `POST /notifications/mute` creates mute rule. Test `GET /notifications/mute` lists active mutes. Test `DELETE /notifications/mute/{id}` removes. Test `POST /notifications/snooze` activates. Test `GET /notifications/snooze` returns active or 404. Test `DELETE /notifications/snooze` cancels. Test tenant isolation on all.

- [ ] **Step 5: Implement SuppressionResource**

`@Path("/notifications") @ApplicationScoped`. Inject `SuppressionStore`, `CurrentPrincipal`. Mute: `POST /notifications/mute`, `GET /notifications/mute`, `DELETE /notifications/mute/{id}`. Snooze: `POST /notifications/snooze`, `GET /notifications/snooze` (404 if none), `DELETE /notifications/snooze`. Override userId/tenancyId from principal on all inputs.

- [ ] **Step 6: Run suppression tests — verify pass**

Run: `mvn --batch-mode test -pl notifications -Dtest=SuppressionResourceTest`

- [ ] **Step 7: Write channel discovery endpoint test**

Test `GET /notifications/channels` returns registered channels.

- [ ] **Step 8: Implement DeliveryChannelResource**

`@Path("/notifications/channels") @ApplicationScoped`. Inject `DeliveryChannelRegistry`. `GET` returns `registry.discover()`.

- [ ] **Step 9: Run all notification tests**

Run: `mvn --batch-mode test -pl notifications`
Expected: ALL PASS (existing notification tests + new endpoint tests)

- [ ] **Step 10: Commit**

```
feat(platform#143,#145): REST endpoints — preferences, mute/snooze, channel discovery
```

---

### Task 7: JPA Notification Settings Stores

New `notification-settings-jpa/` module. JPA entities, Flyway V1 migration, JpaNotificationPreferenceStore + JpaSuppressionStore. Hibernate ORM Panache (blocking-only).

**Files:**
- Create: `notification-settings-jpa/pom.xml`
- Create: `notification-settings-jpa/src/main/java/io/casehub/platform/notification/settings/jpa/NotificationPreferencesEntity.java`
- Create: `notification-settings-jpa/src/main/java/io/casehub/platform/notification/settings/jpa/MuteRuleEntity.java`
- Create: `notification-settings-jpa/src/main/java/io/casehub/platform/notification/settings/jpa/SnoozeEntity.java`
- Create: `notification-settings-jpa/src/main/java/io/casehub/platform/notification/settings/jpa/JpaNotificationPreferenceStore.java`
- Create: `notification-settings-jpa/src/main/java/io/casehub/platform/notification/settings/jpa/JpaSuppressionStore.java`
- Create: `notification-settings-jpa/src/main/resources/db/notification-settings/migration/V1__notification_settings.sql`
- Create: `notification-settings-jpa/src/test/java/io/casehub/platform/notification/settings/jpa/JpaNotificationPreferenceStoreTest.java`
- Create: `notification-settings-jpa/src/test/java/io/casehub/platform/notification/settings/jpa/JpaSuppressionStoreTest.java`
- Create: `notification-settings-jpa/src/test/resources/application.properties`
- Modify: `pom.xml` (add module)

**Interfaces:**
- Consumes: Task 1 SPI types
- Produces: JPA-backed preference and suppression stores with PostgreSQL

- [ ] **Step 1: Create module pom.xml**

Maven coordinates: `io.casehub:casehub-platform-notification-settings-jpa`. Dependencies: `casehub-platform-api`, `quarkus-hibernate-orm-panache`, `quarkus-jdbc-postgresql`, `quarkus-flyway`. Test: `quarkus-junit`, `casehub-platform-testing`, `quarkus-test-h2` (or DevServices PostgreSQL). No `quarkus-maven-plugin` (library module). Add module to parent `pom.xml`.

- [ ] **Step 2: Create Flyway V1 migration**

```sql
-- notification_preferences: one row per user per tenant
CREATE TABLE notification_preferences (
    user_id         VARCHAR(255) NOT NULL,
    tenancy_id      VARCHAR(255) NOT NULL,
    channel_defaults_json TEXT,
    quiet_hours_json     TEXT,
    updated_at      TIMESTAMP NOT NULL,
    PRIMARY KEY (user_id, tenancy_id)
);

-- mute_rules: multiple per user
CREATE TABLE mute_rules (
    id              VARCHAR(36) NOT NULL PRIMARY KEY,
    user_id         VARCHAR(255) NOT NULL,
    tenancy_id      VARCHAR(255) NOT NULL,
    scope           VARCHAR(20) NOT NULL,
    scope_id        VARCHAR(500) NOT NULL,
    entity_type     VARCHAR(500),
    created_at      TIMESTAMP NOT NULL,
    expires_at      TIMESTAMP
);

CREATE INDEX idx_mute_rules_user_tenant
    ON mute_rules (user_id, tenancy_id);

-- snooze: at most one per user per tenant
CREATE TABLE snooze (
    user_id         VARCHAR(255) NOT NULL,
    tenancy_id      VARCHAR(255) NOT NULL,
    until_time      TIMESTAMP NOT NULL,
    created_at      TIMESTAMP NOT NULL,
    PRIMARY KEY (user_id, tenancy_id)
);
```

- [ ] **Step 3: Create JPA entities**

`NotificationPreferencesEntity` — `@Entity @Table(name = "notification_preferences")`, composite PK `(userId, tenancyId)`, JSON columns for `channelDefaults` and `quietHours`. `MuteRuleEntity` — `@Entity @Table(name = "mute_rules")`, String PK `id`. `SnoozeEntity` — `@Entity @Table(name = "snooze")`, composite PK `(userId, tenancyId)`.

- [ ] **Step 4: Write JPA store tests**

`@QuarkusTest` with PostgreSQL DevServices. Tests mirror in-memory contract tests. Use `@TestTransaction` for isolation. Tests cover: CRUD operations, tenant isolation, expiry filtering, upsert semantics.

- [ ] **Step 5: Implement JpaNotificationPreferenceStore**

`@ApplicationScoped`. Uses `EntityManager` (not Panache static methods — per GE-20260512-66d997). `get()` queries by composite PK. `update()` does upsert via `merge()`. JSON columns serialized/deserialized via Jackson ObjectMapper.

- [ ] **Step 6: Implement JpaSuppressionStore**

`@ApplicationScoped`. `addMute()` persists MuteRuleEntity with UUIDv7 id. `activeMutes()` queries by (userId, tenancyId) — expiry filtering in Java (per in-memory pattern, keeps query simple). `removeMute()` deletes by (id, userId, tenancyId). `activateSnooze()` upserts via `merge()`. `activeSnooze()` queries by composite PK, filters expired. `cancelSnooze()` deletes by composite PK.

- [ ] **Step 7: Run JPA tests — verify pass**

Run: `mvn --batch-mode test -pl notification-settings-jpa`
Expected: ALL PASS

- [ ] **Step 8: Build and verify**

Run: `mvn --batch-mode install -pl notification-settings-jpa -am`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```
feat(platform#143,#145): JPA notification settings stores — preferences + suppression with Flyway V1
```

---

### Task 8: Full Build Verification and CLAUDE.md Update

Final integration build, CLAUDE.md update with new modules, and full test verification.

**Files:**
- Modify: `CLAUDE.md` (add new modules to module table, update package structure)

- [ ] **Step 1: Full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and test.

- [ ] **Step 2: Update CLAUDE.md**

Add new modules to the module table:
- `notification-settings-inmem/` — @Alternative @Priority(100) volatile InMemoryNotificationPreferenceStore + InMemorySuppressionStore
- `notification-settings-jpa/` — @ApplicationScoped JPA stores, Hibernate ORM Panache, Flyway at `classpath:db/notification-settings/migration`
- `notification-dispatch/` — NotificationDispatcher + TargetResolver + SuppressionEvaluator + ChannelRouter + InAppNotificationDeliverer + InMemoryDeliveryChannelRegistry

Update package structure section with new packages:
- `io.casehub.platform.api.delivery` — DeliveryChannelRegistry, DeliveryChannelDescriptor, DeliveryChannels, NotificationDeliverer, DeliveryResult
- `io.casehub.platform.api.notification.settings` — NotificationPreferenceStore, SuppressionStore, all settings records

Update subscription module description — note SubscriptionEngine fires SubscriptionMatched, TemplateResolver moved to notification-dispatch/.

- [ ] **Step 3: Commit**

```
docs(platform#148,#143,#145): CLAUDE.md — add notification dispatch, settings modules and package structure
```

---

## Self-Review Checklist

- [x] **Spec coverage:** Every section of the spec maps to a task. §1 → Task 1+2, §2 → Task 4+5, §3 → Task 4 (registry + deliverer), §4 → Task 1+3+7, §5 → Task 1+3+7, §6 → Task 1-8 (module structure throughout).
- [x] **Placeholder scan:** No TBD/TODO/vague steps. Every step has exact files, code descriptions, or commands.
- [x] **Type consistency:** `ownerId` used consistently (not userId). `includeActor` used consistently (not excludeActor). `SubscriptionMatched` matches spec. `SuppressionResult` matches spec. `ResolvedChannel` matches spec. `DeliveryChannelDescriptor` has 5 components (channelId, displayName, external, defaultEnabled, defaultMinSeverity) matching reviewed spec.
- [x] **Deferred items:** #154 (guaranteed delivery), #155 (EventTypeRegistry), #156 (channel subscriber target type) already filed as GitHub issues.
