# HANDOFF — casehub-platform

## Last Session

Completed 3 issues from the follow-on queue: #479 (llm-config-core), #483 (Spring REST non-domain resources), and designed #480 (Pattern 2 qhorus migration). Queue advanced to position 3/6.

**1. #479: llm-config-core extraction (XS/Low).**

New module `llm-config-core` — extracted `LlmConfigApi` (@McpDomain interface) and 11 API records from `llm-config`. Wired as `quarkusModule` in `platform-spring` graphql-spring-generator. Now generates `LlmConfigGraphqlController` + `LlmConfigRestController`.

**2. #483: Spring REST for non-domain @Path resources (M/Med).**

6 JAX-RS resources that weren't covered by @McpDomain generators needed Spring equivalents. Core-extracted business logic to -core POJOs, wrote thin Spring @RestControllers in platform-spring.

New modules created:
- `callback-client-core` — `CallbackDispatcher` (reflection-based SPI dispatch)
- `streams-webhook-core` — `WebhookReceiver` (CloudEvents, Consumer<CloudEvent> callback pattern)

Core extractions into existing modules:
- `EventTypeService` → subscriptions-core
- `SubscriptionService` → subscriptions-core (8 methods with auth + expression validation)
- `PreferenceSchemaService` → preferences-editor-core (ETag support via SchemaResult record)
- `EngagementCallbackService` → notification-dispatch-core (Instance<> → Map<String, Handler>)

Spring controllers in platform-spring (`io.casehub.platform.spring.rest`):
- `EventTypeRestController`, `SubscriptionRestController`, `PreferenceSchemaRestController`
- `EngagementCallbackRestController`, `CallbackDispatchRestController`, `WebhookRestController`
- `RestControllersAutoConfiguration` — wires service beans with @ConditionalOnBean

**3. #480: Pattern 2 qhorus migration — designed, not yet executed.**

Spec and 5 decisions captured. 4 SPI interfaces (`ChannelsApi`, `MessagingApi`, `GovernanceApi`, `ComplianceApi`) to go in qhorus `api/` module. Compliance domain renamed from `qhorus` to `compliance`. 7 resolver classes deleted, 2 kept (Subscription + ModelEnricher). Next step: writing-plans → execution in the qhorus repo.

## Immediate Next Step

Write the implementation plan for #480 (Pattern 2 qhorus migration), then execute. This is cross-repo work — changes go to the qhorus repo at `/Users/mdproctor/claude/casehub/slots/192/qhorus`.

## Queue State

| # | Issue | Scale | Complexity | Status |
|---|-------|-------|------------|--------|
| 0 | parent#478 | L | High | Done |
| 1 | parent#479 | XS | Low | Done |
| 2 | parent#483 | M | Med | Done |
| 3 | parent#480 | M | Med | Active — designed, plan next |
| 4 | parent#481 | S | Low | Pending — Pattern 2 neocortex |
| 5 | parent#482 | S | Low | Pending — Wire graphql-spring-gen |

## Key Facts

- Platform branch `issue-478-spring-deployment-completion` — 18 commits ahead of origin/main (10 from prior sessions + 8 this session).
- 2 new -core modules this session: callback-client-core, streams-webhook-core.
- llm-config-core also new this session.
- engine#1095 (Pattern 2 migration) is NOT actually implemented in slot 192's engine checkout — the reference pattern comes from platform's own domains (acl, notifications, etc.).
- Pre-existing test failures in `notifications` module (REST resource tests) — unrelated to this branch.
- Consumer repo branches unchanged from prior session.

## Garden Entries Consulted

GE-20260420-7d28fa, GE-0138, GE-20260914-248827, GE-20260910-fc414e (Consumer<T> callback pattern), GE-20260909-c81437 (module naming), GE-20260909-81809c (Jandex generator)

## References

- `specs/spring-deployment-completion/2026-09-15-spring-deployment-completion-design.md`
- `specs/spring-deployment-completion/decisions.md` (4 decisions)
- `specs/issue-478-spring-deployment-completion/2026-09-15-spring-rest-non-domain-design.md`
- `specs/issue-478-spring-deployment-completion/decisions.md` (4 decisions for #483)
- `specs/issue-478-spring-deployment-completion/2026-09-15-pattern2-qhorus-design.md`
- `specs/issue-478-spring-deployment-completion/pattern2-qhorus-decisions.md` (5 decisions for #480)
- `plans/2026-09-15-spring-rest-non-domain.md` — implementation plan for #483
- casehubio/parent#478, #479, #480, #483 — tracking issues
- Memory: `project_pattern2_migration.md` — Pattern 2 migration tracking
