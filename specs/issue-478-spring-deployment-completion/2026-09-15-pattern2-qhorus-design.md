# Pattern 2 Migration: Qhorus — Design Spec

**Issue:** casehubio/parent#480
**Date:** 2026-09-15

## Goal

Migrate qhorus from Pattern 1 (@McpDomain on resolver classes with @Query/@Mutation) to Pattern 2 (@McpDomain on SPI interfaces with @PlatformQuery/@PlatformMutation). Enables the `graphql-generator` APT to produce both GraphQL resolvers and REST resources from a single interface definition.

## Scope

**Migrating (7 resolver classes → 4 SPI interfaces + 4 implementation beans):**

| Domain | SPI Interface | Impl Bean | Resolvers Deleted |
|---|---|---|---|
| `channels` | `ChannelsApi` | `ChannelsService` | ChannelsQueryResolver, ChannelsMutationResolver |
| `messaging` | `MessagingApi` | `MessagingService` | MessagingQueryResolver, MessagingMutationResolver |
| `governance` | `GovernanceApi` | `GovernanceService` | GovernanceQueryResolver |
| `compliance` (renamed from `qhorus`) | `ComplianceApi` | `ComplianceService` | ComplianceQueryResolver, ComplianceMutationResolver |

**Not migrating (stay hand-written):**
- `ChannelsSubscriptionResolver` — `@Subscription` with `Multi<>` streaming, not supported by generator
- `ChannelsModelEnricher` — implements `ModelEnricher`, not a query/mutation SPI

## Architecture

### SPI Interfaces (in `api/` module)

Each interface: `@McpDomain("domain-name")` on the interface, `@PlatformQuery`/`@PlatformMutation` on methods. Pure Java — no CDI, no GraphQL, no JAX-RS annotations.

**ChannelsApi** (7 methods):
- `@PlatformQuery` channels, channel, channelMessages
- `@PlatformMutation` createChannel, deleteChannel, pauseChannel, resumeChannel

**MessagingApi** (13 methods):
- `@PlatformQuery` message, replies, searchMessages, reactions, reactionsBatch
- `@PlatformMutation` dispatchMessage, deleteMessage, react, unreact, respondToApproval, cancelWait, waitForReply, requestApproval

**GovernanceApi** (1 method):
- `@PlatformQuery` commitments

**ComplianceApi** (13 methods):
- `@PlatformQuery` complianceAttribution, complianceObligations, complianceViolations, complianceTrustHistory, complianceProvenance, complianceReports, complianceJudgmentAttribution, complianceJudgmentFulfillment, compliancePropertyVerification
- `@PlatformMutation` createComplianceSchedule, updateComplianceSchedule, deleteComplianceSchedule, deleteComplianceReport

### Implementation Beans

Each bean: `@ApplicationScoped implements XxxApi`. Constructor-injected dependencies (same deps the current resolvers use). No GraphQL/JAX-RS annotations — those are generated.

- `ChannelsService` in `graphql/` — injects ChannelReader, ConsumerMessaging, ChannelManager
- `MessagingService` in `graphql/` — injects ConsumerMessaging, MessageReader, ReactionReader, MessageDispatcher, CurrentPrincipal, ReactionManager, MessageStore, CommitmentStore
- `GovernanceService` in `graphql/` — injects CommitmentReader
- `ComplianceService` in `compliance-report/` — injects all 10 report services + CurrentPrincipal + record/schedule stores

### Generator Wiring

Wire `graphql-generator` APT in `graphql/pom.xml` and `compliance-report/pom.xml` via `annotationProcessorPaths`. The APT scans the compilation unit for `@McpDomain` SPI interface implementations and generates:
- `@GraphQLApi` resolver per domain (delegates to SPI impl)
- `@Path` REST resource per domain (delegates to SPI impl)

### What Gets Deleted

7 resolver classes in total — replaced by generated equivalents.

## Execution Order

1. **Batch 1:** Create 4 SPI interfaces in `api/` + install
2. **Batch 2:** Create 4 implementation beans in `graphql/` and `compliance-report/`, wire APT, delete old resolvers
3. **Batch 3:** Verify — build, run existing tests, confirm generated classes appear

## Testing Strategy

- Existing `@QuarkusTest` integration tests should continue passing after migration — they test HTTP endpoints, not resolver class internals
- If tests reference resolver classes directly, update to reference the new service beans
- Build verification: `mvn install` confirms APT generates resolvers and REST resources

## References

- Platform AclApi pattern — platform-api/src/main/java/io/casehub/platform/api/acl/AclApi.java
- Platform NotificationApi pattern — platform-api notification SPIs
- graphql-generator APT — platform/graphql-generator/
- casehubio/parent#480 — tracking issue
- Memory: project_pattern2_migration.md — Pattern 2 migration tracking
