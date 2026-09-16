## D1: Approach for Spring REST parity of non-domain @Path resources

**Choice:** Core-extract business logic to -core POJOs + hand-write thin Spring @RestControllers. All 6 resources (5 non-trivial + EventTypeResource).
**Alternatives:**
- Hand-write Spring controllers directly — duplicates business logic, ongoing maintenance burden
- Improve rest-spring-generator — significant engineering effort, different issue scope (generator handles only single-delegate, no Response, no Instance<>, no @Context)
**Rationale:** Follows the established core extraction pattern used 34+ times across the platform. Creates shared business logic usable by both frameworks. Hand-written thin wrappers are trivial to maintain.
**Sources:** rest-spring-generator source (RestResourceScanner.java line 62-77 — single-delegate limitation), GE-20260910-fc414e (Consumer<T> callback pattern for Event<T>)
**Trade-offs:** More upfront work than hand-writing Spring controllers directly. But the extraction also improves the JAX-RS side — resources become thinner and more testable.
**Exploration:** quick
**Status:** captured

## D2: Spring controller location

**Choice:** All hand-written Spring @RestControllers go in `platform-spring`. It already houses all Spring auto-configurations for platform modules and depends on platform-core, platform-api, preferences-editor-core, callback-api.
**Alternatives:**
- Per-module -spring modules (subscriptions-spring, notification-dispatch-spring, etc.) — creates 4+ new modules with 1-2 classes each, excessive fragmentation
**Rationale:** Consistent with existing convergence pattern. platform-spring is the single Spring auto-config module for the platform repo.
**Trade-offs:** platform-spring gains more dependencies on -core modules. Acceptable — it's already the aggregation point.
**Exploration:** quick
**Status:** captured

## D3: New vs existing -core modules

**Choice:** Extract to existing -core modules where they exist. Create 2 new -core modules: callback-client-core (for CallbackDispatcher) and streams-webhook-core (for WebhookReceiver).
**Alternatives:**
- Create new -core modules for all 6 — unnecessary when subscriptions-core, notification-dispatch-core, preferences-editor-core already exist
- Skip -core for callback-client and streams-webhook, hand-write Spring controllers with duplicated logic — violates the core extraction pattern
**Rationale:** Reuses existing module boundaries. Only creates new modules where none exist.
**Trade-offs:** None significant.
**Depends on:** D1 (core-extract approach)
**Exploration:** quick
**Status:** captured

## D4: WebhookResource framework bridging pattern

**Choice:** Consumer<T> callback for CDI Event<CloudEvent>, constructor params for @ConfigProperty values, explicit init() method for @PostConstruct startup registration.
**Alternatives:**
- Framework-specific event interface (EventPublisher<T> with CDI and Spring impls) — more ceremony, Consumer<T> achieves the same with zero new types
- @EventListener on Spring side with shared event type — ties core to Spring event model
**Rationale:** Follows the established Consumer<T> pattern documented in GE-20260910-fc414e and used across core extractions (EngagementRecorder, NotificationDispatcher, etc.).
**Sources:** GE-20260910-fc414e (Event<T> to Consumer<T> technique)
**Trade-offs:** None significant — this is the standard platform pattern.
**Depends on:** D1 (core-extract approach)
**Exploration:** quick
**Status:** captured
