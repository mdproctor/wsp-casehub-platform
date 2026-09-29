# HANDOFF — Slot 198

## Last Session

Closed work#401 (Port Panache to plain JPA) — already complete, cleaned up one stale dep in delivery-tracking-jpa. Audited Spring generator gaps and filed two new issues.

### work#401 — Port Panache to plain JPA
JPA Panache port was already done across all files. Only remaining artifact: stale `quarkus-hibernate-orm-panache` dependency in delivery-tracking-jpa/pom.xml, replaced with `quarkus-hibernate-orm`. Build verified green. Commit `192b1704` on main.

### parent#483 audit — Spring REST controllers for hand-written @Path
Audited all 5 resources listed in the issue. 4/5 already migrated to @McpDomain:
- CallbackDispatchResource — @McpDomain + @PlatformWebhook
- EngagementCallbackResource — @McpDomain + @PlatformWebhook
- SubscriptionResource + EventTypeResource — replaced by @McpDomain SPIs
- PreferenceSchemaResource — replaced by @McpDomain SPI
- **WebhookResource — still hand-written @Path** (business logic extracted to streams-webhook-core)

### Generator gap discovered
The `graphql-spring-generator` silently skips `@PlatformWebhook` methods. `generator-common`'s `McpDomainJandexScanner` only has QUERY/MUTATION/STREAM in `OperationType` — no WEBHOOK. Also missing: `@HeaderParam` → `@RequestHeader` mapping in `ResolvedParam`. This means the 3 already-migrated webhook resources have NO Spring REST controllers generated.

### platform#472 landed (other session)
MCP Spring server transport via Spring AI MCP Server Starter. Added `SpringMcpResourceRegistryBridge` + `SpringDomainResourceRegistrar` to mcp-spring/. Full MCP stack now works on both frameworks.

## Immediate Next Step

**platform#484 — graphql-spring-generator: add @PlatformWebhook + @HeaderParam support (S / Low)**

Foundational fix — must land before #485. Changes needed:
1. `generator-common/OperationType` — add WEBHOOK
2. `generator-common/McpDomainJandexScanner` — detect `@PlatformWebhook`, extract `consumes`
3. `generator-common/ResolvedParam` — add `isHeaderParam` + `headerParamName`
4. `generator-common/McpDomainJandexScanner` — scan for `@HeaderParam` annotation
5. `graphql-spring-generator/SpringDomainRestControllerWriter` — emit `@PostMapping(consumes = ...)` for webhook ops, `@RequestHeader` for header params
6. Tests + verify goal

After #484 lands, existing @PlatformWebhook resources (callback-client, notification-dispatch) will retroactively get Spring REST controllers.

## Queue Status

Position 1/2 in .plan:

| # | Issue | Scale | Blocked by | Notes |
|---|-------|-------|------------|-------|
| 1 | platform#484 | S/Low | — | Generator: @PlatformWebhook + @HeaderParam |
| 2 | platform#485 | XS/Low | #484 | Migrate WebhookResource to @McpDomain |

After these two, close parent#483.

## What Comes Next (after this .plan)

From parent#515 (Spring deployment completion), remaining platform items:
- **platform#473** — K8s Spring completion — fabric8 integration (M / High)

Remaining non-platform items:
- **parent#480** — Pattern 2 migration: qhorus — move @McpDomain to SPI interfaces (M / Med)
- **parent#495** — Generate Spring REST controllers for qhorus (10 resources) (M / Med)
- **engine#1103** — Fix compile errors: TrustGateService + AgentCapability (XS / Low)
- **workers#25-27** — Workers CLAUDE.md, docs, spring-integration-test (S-M)

## Loose Ends

- engine slot repo has uncommitted changes from another session (46 modified files) — do not reset
- work slot repo has uncommitted changes from another session — do not reset
- qhorus#459 — Pre-existing test failures (PeerAttestation, A2ATenantScoping, AgentCardTenant)

## References

- Epic: casehubio/parent#515
- .plan: position 1/2, platform#484 active
