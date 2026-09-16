# Pattern 2 Migration: Qhorus — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/parent#480 — Pattern 2 migration qhorus
**Issue group:** casehubio/parent#478, #480

**Goal:** Migrate qhorus from Pattern 1 (@McpDomain on resolver classes with @Query/@Mutation) to Pattern 2 (@McpDomain on SPI interfaces with @PlatformQuery/@PlatformMutation), enabling the graphql-generator APT to auto-produce both GraphQL resolvers and REST resources from a single interface definition.

**Architecture:** 4 SPI interfaces (ChannelsApi, MessagingApi, GovernanceApi, ComplianceApi) in the qhorus `api/` module, annotated with `@McpDomain` + `@PlatformQuery`/`@PlatformMutation`. 4 `@ApplicationScoped` implementation beans in `graphql/` and `compliance-report/`. The `graphql-generator` APT wired in both modules produces `Generated*Resolver` (GraphQL) and `Generated*Resource` (REST) classes. Domain types from `api/` used directly as SPI method params/returns — existing GraphQL DTO layer (`*Type`, `*Input` in `graphql/dto/`) becomes dead code and is deleted.

**Tech Stack:** Java 21, Maven, Quarkus CDI, platform graphql-generator APT, Jandex

**Qhorus repo:** `/Users/mdproctor/claude/casehub/slots/192/qhorus`
All paths below are relative to this root unless stated otherwise.

**Prerequisite:** Open qhorus in IntelliJ via `ide_open_project` with path `/Users/mdproctor/claude/casehub/slots/192/qhorus` before execution.

## Global Constraints

- `api/` module must remain dependency-light: no CDI, no GraphQL, no JPA. New types must be pure Java records.
- SPI annotations import from `io.casehub.platform.api.mcp` — `McpDomain`, `PlatformQuery`, `PlatformMutation`, `RestMethod`, `HttpMethod`, `PathParam`.
- graphql-generator APT version uses `${casehub-platform.version}` (NOT `${project.version}` which is qhorus's own version).
- `ChannelsSubscriptionResolver` and `ChannelsModelEnricher` stay hand-written — do NOT migrate.
- Old resolver classes MUST be deleted BEFORE the APT is wired — the APT's skip detection suppresses generation for any domain that already has a hand-written `@GraphQLApi @McpDomain` resolver.
- Existing `@QuarkusTest` integration tests are the acceptance criteria — they must pass after migration.
- All commits reference `Refs casehubio/parent#480`.
- Compliance domain renamed from `@McpDomain("qhorus")` to `@McpDomain("compliance")` (decision D3).

---

## Batch 1: API layer — types + SPI interfaces in api/ module

### Task 1: Create supporting domain types in api/

Create records needed by the SPI interfaces that don't already exist in `api/`. Also move compliance model types from `compliance-report/` to `api/` so ComplianceApi can reference them.

**Files:**
- Create: `api/src/main/java/io/casehub/qhorus/api/channel/ChannelQuery.java`
- Create: `api/src/main/java/io/casehub/qhorus/api/channel/ChannelPage.java`
- Create: `api/src/main/java/io/casehub/qhorus/api/message/DispatchMessageRequest.java`
- Create: `api/src/main/java/io/casehub/qhorus/api/message/WaitResult.java`
- Create: `api/src/main/java/io/casehub/qhorus/api/message/CancelWaitResult.java`
- Create: `api/src/main/java/io/casehub/qhorus/api/message/DeleteMessageResult.java`
- Create: `api/src/main/java/io/casehub/qhorus/api/message/MessageReactions.java`
- Create: `api/src/main/java/io/casehub/qhorus/api/judgment/CommitmentQuery.java` (verify Commitment's package with `ide_find_class Commitment`)
- Create: `api/src/main/java/io/casehub/qhorus/api/judgment/CommitmentPage.java`
- Move: all `compliance-report/src/main/java/io/casehub/qhorus/compliance/model/*.java` → `api/src/main/java/io/casehub/qhorus/api/compliance/report/` (use `ide_move_file` for each — updates imports across the project)
- Create: `api/src/main/java/io/casehub/qhorus/api/compliance/ComplianceScheduleInput.java`
- Create: `api/src/main/java/io/casehub/qhorus/api/compliance/ComplianceScheduleUpdateInput.java`
- Create: `api/src/main/java/io/casehub/qhorus/api/compliance/ComplianceScheduleView.java`
- Create: `api/src/main/java/io/casehub/qhorus/api/compliance/ComplianceReportRecordView.java`

**Interfaces:**
- Consumes: existing types from api/ — `Channel`, `Message`, `Reaction`, `ReactionGroup`, `DispatchResult`, `Commitment`, `ChannelCreateRequest`
- Produces: all new records + moved compliance types — consumed by SPI interfaces in Task 2

- [ ] **Step 1: Read existing DTO types to capture exact field names and types**

Read these files with `ide_read_file` or `Read` tool to get exact field names, types, and any default values:

```
graphql/src/main/java/io/casehub/qhorus/graphql/dto/ChannelFilterInput.java
graphql/src/main/java/io/casehub/qhorus/graphql/dto/DispatchMessageInput.java
graphql/src/main/java/io/casehub/qhorus/graphql/dto/WaitResultType.java
graphql/src/main/java/io/casehub/qhorus/graphql/dto/CancelWaitResultType.java
graphql/src/main/java/io/casehub/qhorus/graphql/dto/DeleteMessageResultType.java
graphql/src/main/java/io/casehub/qhorus/graphql/dto/MessageReactionsType.java
graphql/src/main/java/io/casehub/qhorus/graphql/dto/CommitmentFilterInput.java
compliance-report/src/main/java/io/casehub/qhorus/compliance/graphql/ComplianceScheduleInput.java
compliance-report/src/main/java/io/casehub/qhorus/compliance/graphql/ComplianceScheduleUpdateInput.java
```

Also read the JPA entities to capture fields for view projections:
```
compliance-report/src/main/java/io/casehub/qhorus/compliance/storage/ComplianceReportSchedule.java
compliance-report/src/main/java/io/casehub/qhorus/compliance/storage/ComplianceReportRecord.java
```

Use `ide_find_class` for any types not found at these paths.

- [ ] **Step 2: Create channel types**

Create `ChannelQuery.java` — a plain record mirroring `ChannelFilterInput` fields plus pagination. Read `ChannelFilterInput.java` for exact field names/types.

```java
package io.casehub.qhorus.api.channel;

import java.util.UUID;

public record ChannelQuery(
    // Filter fields — copy exact names and types from ChannelFilterInput
    String keyword,
    String namePrefix,
    String semantic,
    Boolean paused,
    UUID spaceId,
    // Pagination
    Integer offset,
    Integer limit,
    String cursor
) {}
```

Create `ChannelPage.java`:

```java
package io.casehub.qhorus.api.channel;

import java.util.List;

public record ChannelPage(
    List<Channel> channels,
    boolean hasNext,
    String cursor
) {}
```

- [ ] **Step 3: Create messaging types**

Create each record in `api/src/main/java/io/casehub/qhorus/api/message/`. Mirror field names and types from the corresponding DTO types read in Step 1. For references to other DTO types (e.g., `WaitResultType.message` references `MessageType`), use the domain type instead (`Message`).

`DispatchMessageRequest.java` — mirror fields from `DispatchMessageInput`:
```java
package io.casehub.qhorus.api.message;

import java.util.UUID;

public record DispatchMessageRequest(
    // Copy exact fields from DispatchMessageInput
    UUID channelId,
    String type,
    String content,
    String correlationId,
    Long inReplyTo,
    String target,
    String topic,
    String deadline
) {}
```

`WaitResult.java`:
```java
package io.casehub.qhorus.api.message;

public record WaitResult(
    boolean found,
    boolean timedOut,
    String correlationId,
    Message message,
    String status
) {}
```

`CancelWaitResult.java`:
```java
package io.casehub.qhorus.api.message;

public record CancelWaitResult(
    String correlationId,
    boolean cancelled,
    String message
) {}
```

`DeleteMessageResult.java`:
```java
package io.casehub.qhorus.api.message;

public record DeleteMessageResult(
    Long messageId,
    boolean deleted,
    String sender,
    String messageType,
    String preview,
    String status
) {}
```

`MessageReactions.java`:
```java
package io.casehub.qhorus.api.message;

import java.util.List;

public record MessageReactions(
    Long messageId,
    List<ReactionGroup> reactions
) {}
```

Verify field names/types match the DTO sources read in Step 1. Adjust types as needed — the records above are templates; the executor MUST verify against the actual DTO source.

- [ ] **Step 4: Create governance types**

Find where `Commitment` lives: `ide_find_class Commitment`. Create the query and page records in the same package.

`CommitmentQuery.java`:
```java
package io.casehub.qhorus.api.judgment; // verify package

import java.util.UUID;

public record CommitmentQuery(
    // Fields from CommitmentFilterInput
    UUID channelId,
    String state,
    String obligor,
    String requester,
    // Pagination
    Integer offset,
    Integer limit,
    String cursor
) {}
```

`CommitmentPage.java`:
```java
package io.casehub.qhorus.api.judgment; // verify package

import java.util.List;

public record CommitmentPage(
    List<Commitment> commitments,
    boolean hasNext,
    String cursor
) {}
```

- [ ] **Step 5: Move compliance model types to api/**

List all files in the compliance model directory:
```bash
find compliance-report/src/main/java/io/casehub/qhorus/compliance/model -name "*.java" -type f
```

For each file, use `ide_move_file` to move it to `api/src/main/java/io/casehub/qhorus/api/compliance/report/`. IntelliJ updates all imports across the project automatically.

Verify: after all moves, run `mvn -pl api compile` to confirm the moved types compile in api/ (they should — they're pure records with only `java.*` and `io.casehub.qhorus.api.*` imports).

- [ ] **Step 6: Create compliance input/view records**

Read the JPA entities `ComplianceReportSchedule` and `ComplianceReportRecord` (from Step 1) to capture fields. Create projection records in `api/src/main/java/io/casehub/qhorus/api/compliance/`:

`ComplianceScheduleInput.java`:
```java
package io.casehub.qhorus.api.compliance;

public record ComplianceScheduleInput(
    // Fields from ComplianceScheduleInput DTO — verify exact fields
    String reportType,
    String channelId,
    String scheduleJson,
    String format
) {}
```

`ComplianceScheduleUpdateInput.java`:
```java
package io.casehub.qhorus.api.compliance;

import java.util.UUID;

public record ComplianceScheduleUpdateInput(
    UUID id,
    Boolean enabled,
    String scheduleJson
) {}
```

`ComplianceScheduleView.java` — mirrors JPA entity fields as a record:
```java
package io.casehub.qhorus.api.compliance;

import java.time.Instant;
import java.util.UUID;

public record ComplianceScheduleView(
    // Mirror fields from ComplianceReportSchedule JPA entity
    UUID id,
    String reportType,
    String channelId,
    String scheduleJson,
    String format,
    boolean enabled,
    Instant createdAt,
    Instant updatedAt
) {}
```

`ComplianceReportRecordView.java` — mirrors JPA entity fields:
```java
package io.casehub.qhorus.api.compliance;

import java.time.Instant;
import java.util.UUID;

public record ComplianceReportRecordView(
    // Mirror fields from ComplianceReportRecord JPA entity
    UUID id,
    String reportType,
    String channelId,
    byte[] content,
    String format,
    Instant generatedAt
) {}
```

Verify all field names and types against the actual JPA entities.

- [ ] **Step 7: Verify api/ compiles and install**

```bash
mvn -f /Users/mdproctor/claude/casehub/slots/192/qhorus/api/pom.xml clean install
```

Expected: BUILD SUCCESS. If compilation fails, fix import issues from the compliance model move.

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/192/qhorus add api/ compliance-report/
git -C /Users/mdproctor/claude/casehub/slots/192/qhorus commit -m "feat(#480): add SPI supporting types and move compliance models to api

Create domain records for Pattern 2 SPI interfaces:
- ChannelQuery, ChannelPage, DispatchMessageRequest, WaitResult,
  CancelWaitResult, DeleteMessageResult, MessageReactions
- CommitmentQuery, CommitmentPage
- ComplianceScheduleInput/UpdateInput, ComplianceScheduleView,
  ComplianceReportRecordView

Move compliance report model types from compliance-report/model/
to api/compliance/report/ (pure records, no dependency changes).

Refs casehubio/parent#480"
```

---

### Task 2: Create 4 SPI interfaces in api/

**Files:**
- Create: `api/src/main/java/io/casehub/qhorus/api/spi/channels/ChannelsApi.java`
- Create: `api/src/main/java/io/casehub/qhorus/api/spi/messaging/MessagingApi.java`
- Create: `api/src/main/java/io/casehub/qhorus/api/spi/governance/GovernanceApi.java`
- Create: `api/src/main/java/io/casehub/qhorus/api/spi/compliance/ComplianceApi.java`

**Interfaces:**
- Consumes: all types from Task 1 + existing api/ types (Channel, Message, Reaction, ReactionGroup, DispatchResult, Commitment, ChannelCreateRequest)
- Produces: 4 SPI interfaces — consumed by implementation beans in Task 3

- [ ] **Step 1: Create ChannelsApi**

```java
package io.casehub.qhorus.api.spi.channels;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.qhorus.api.channel.Channel;
import io.casehub.qhorus.api.channel.ChannelCreateRequest;
import io.casehub.qhorus.api.channel.ChannelPage;
import io.casehub.qhorus.api.channel.ChannelQuery;
import io.casehub.qhorus.api.message.Message;

import java.util.List;
import java.util.UUID;

@McpDomain("channels")
public interface ChannelsApi {

    @PlatformQuery("List channels matching filter criteria")
    ChannelPage channels(ChannelQuery query);

    @PlatformQuery("Get a channel by ID or name")
    Channel channel(UUID id, String name);

    @PlatformQuery("Get messages in a channel")
    List<Message> channelMessages(UUID channelId, Long afterId, Integer limit);

    @PlatformMutation("Create a new channel")
    Channel createChannel(ChannelCreateRequest input);

    @PlatformMutation("Delete a channel")
    long deleteChannel(UUID channelId, Boolean force);

    @PlatformMutation("Pause a channel")
    Channel pauseChannel(UUID channelId);

    @PlatformMutation("Resume a paused channel")
    Channel resumeChannel(UUID channelId);
}
```

Note: `ChannelCreateRequest` may need verification — use `ide_find_class ChannelCreateRequest` to confirm the exact class name and package in api/.

- [ ] **Step 2: Create MessagingApi**

```java
package io.casehub.qhorus.api.spi.messaging;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.qhorus.api.message.*;

import java.util.List;
import java.util.UUID;

@McpDomain("messaging")
public interface MessagingApi {

    @PlatformQuery("Get a message by ID")
    Message message(Long id);

    @PlatformQuery("Get replies to a message")
    List<Message> replies(Long messageId, Long afterId, Integer limit);

    @PlatformQuery("Search messages")
    List<Message> searchMessages(String query, UUID channelId, Integer limit);

    @PlatformQuery("Get reactions for a message")
    List<ReactionGroup> reactions(Long messageId);

    @PlatformQuery("Get reactions for multiple messages")
    List<MessageReactions> reactionsBatch(List<Long> messageIds);

    @PlatformMutation("Dispatch a message")
    DispatchResult dispatchMessage(DispatchMessageRequest input);

    @PlatformMutation("Delete a message")
    DeleteMessageResult deleteMessage(Long messageId);

    @PlatformMutation("Add a reaction")
    Reaction react(Long messageId, String emoji);

    @PlatformMutation("Remove a reaction")
    boolean unreact(Long messageId, String emoji);

    @PlatformMutation("Respond to an approval request")
    DispatchResult respondToApproval(String correlationId, String responseText, UUID channelId);

    @PlatformMutation("Cancel a wait")
    CancelWaitResult cancelWait(String correlationId);

    @PlatformMutation("Wait for a reply in a channel")
    WaitResult waitForReply(UUID channelId, String correlationId, Integer timeoutSeconds);

    @PlatformMutation("Request approval in a channel")
    WaitResult requestApproval(UUID channelId, String content, Integer timeoutSeconds);
}
```

- [ ] **Step 3: Create GovernanceApi**

```java
package io.casehub.qhorus.api.spi.governance;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.qhorus.api.judgment.CommitmentPage;
import io.casehub.qhorus.api.judgment.CommitmentQuery;

@McpDomain("governance")
public interface GovernanceApi {

    @PlatformQuery("List commitments matching filter criteria")
    CommitmentPage commitments(CommitmentQuery query);
}
```

- [ ] **Step 4: Create ComplianceApi**

```java
package io.casehub.qhorus.api.spi.compliance;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.qhorus.api.compliance.*;
import io.casehub.qhorus.api.compliance.report.*;

import java.util.List;
import java.util.UUID;

@McpDomain("compliance")
public interface ComplianceApi {

    @PlatformQuery("Get compliance attribution report")
    AttributionReport complianceAttribution(String correlationId, Integer limit);

    @PlatformQuery("Get compliance obligations report")
    ObligationReport complianceObligations(String channelId, String from, String to);

    @PlatformQuery("Get compliance violations report")
    ViolationReport complianceViolations(String channelId, String from, String to);

    @PlatformQuery("Get compliance trust history report")
    TrustHistoryReport complianceTrustHistory(String actorId, String from, String to);

    @PlatformQuery("Get compliance provenance report")
    ProvenanceReport complianceProvenance(String correlationId, Integer limit);

    @PlatformQuery("List compliance reports")
    List<ComplianceReportRecordView> complianceReports(String reportType, Integer limit);

    @PlatformQuery("Get judgment attribution report")
    JudgmentAttributionReport complianceJudgmentAttribution(String judgmentId, Integer limit);

    @PlatformQuery("Get judgment fulfillment report")
    JudgmentFulfillmentReport complianceJudgmentFulfillment(String from, String to, String judgmentType, String actorId);

    @PlatformQuery("Get property verification report")
    PropertyVerificationReport compliancePropertyVerification(String from, String to);

    @PlatformMutation("Create a compliance report schedule")
    ComplianceScheduleView createComplianceSchedule(ComplianceScheduleInput input);

    @PlatformMutation("Update a compliance report schedule")
    ComplianceScheduleView updateComplianceSchedule(ComplianceScheduleUpdateInput input);

    @PlatformMutation("Delete a compliance report schedule")
    boolean deleteComplianceSchedule(UUID id);

    @PlatformMutation("Delete a compliance report")
    boolean deleteComplianceReport(UUID id);
}
```

- [ ] **Step 5: Verify api/ compiles and install**

```bash
mvn -f /Users/mdproctor/claude/casehub/slots/192/qhorus/api/pom.xml clean install
```

Expected: BUILD SUCCESS. If any import or type resolution failures, fix them. The SPI interfaces should compile cleanly since all referenced types are in api/.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/192/qhorus add api/
git -C /Users/mdproctor/claude/casehub/slots/192/qhorus commit -m "feat(#480): add Pattern 2 SPI interfaces for channels, messaging, governance, compliance

4 @McpDomain SPI interfaces in api/:
- ChannelsApi (7 methods) — channels, messaging
- MessagingApi (13 methods) — dispatch, reactions, approval flows
- GovernanceApi (1 method) — commitments
- ComplianceApi (13 methods, domain renamed from 'qhorus' to 'compliance')

Refs casehubio/parent#480"
```

---

## Batch 2: Implementation + wiring (graphql/ + compliance-report/)

### Task 3: Create implementation beans

Create `@ApplicationScoped` beans that implement the SPI interfaces. Method bodies are copied from the existing resolver classes with these conversions:
- **Return types:** where resolvers return DTO types (`ChannelType`, `MessageType`), the impl bean returns domain types (`Channel`, `Message`) directly — the `from()` conversion layer is removed.
- **Input types:** where resolvers take GraphQL `@Input` types, the impl bean takes the new api/ records.
- **Private helpers:** `groupReactions()`, `resolveCommitments()`, `findTerminalMessage()` move into the impl bean as private methods.
- **`@Transactional`:** `deleteMessage` keeps its `@Transactional` annotation on the impl bean.

**Files:**
- Create: `graphql/src/main/java/io/casehub/qhorus/graphql/channels/ChannelsService.java`
- Create: `graphql/src/main/java/io/casehub/qhorus/graphql/messaging/MessagingService.java`
- Create: `graphql/src/main/java/io/casehub/qhorus/graphql/governance/GovernanceService.java`
- Create: `compliance-report/src/main/java/io/casehub/qhorus/compliance/ComplianceService.java`

**Interfaces:**
- Consumes: SPI interfaces from Task 2; existing service/reader/store beans (ChannelReader, ConsumerMessaging, ChannelManager, MessageDispatcher, MessageReader, ReactionReader, ReactionManager, MessageStore, CommitmentStore, CommitmentReader, CurrentPrincipal, all compliance report services)
- Produces: 4 CDI beans implementing the SPI interfaces — consumed by generated resolvers/resources after APT wiring in Task 4

- [ ] **Step 1: Create ChannelsService**

Read `ChannelsQueryResolver.java` and `ChannelsMutationResolver.java` for the method bodies. Create:

```java
package io.casehub.qhorus.graphql.channels;

import io.casehub.qhorus.api.channel.*;
import io.casehub.qhorus.api.message.Message;
import io.casehub.qhorus.api.spi.channels.ChannelsApi;
// import existing service dependencies — same as resolver injections

import jakarta.enterprise.context.ApplicationScoped;
import java.util.List;
import java.util.UUID;

@ApplicationScoped
public class ChannelsService implements ChannelsApi {

    private final ChannelReader channelReader;
    private final ConsumerMessaging consumerMessaging;
    private final ChannelManager channelManager;

    public ChannelsService(ChannelReader channelReader,
                           ConsumerMessaging consumerMessaging,
                           ChannelManager channelManager) {
        this.channelReader = channelReader;
        this.consumerMessaging = consumerMessaging;
        this.channelManager = channelManager;
    }

    @Override
    public ChannelPage channels(ChannelQuery query) {
        // Body from ChannelsQueryResolver.channels()
        // Convert ChannelQuery fields to whatever the reader expects
        // Return ChannelPage (List<Channel>, hasNext, cursor)
        // instead of the old ChannelPage(List<ChannelType>, PageInfo)
    }

    @Override
    public Channel channel(UUID id, String name) {
        // Body from ChannelsQueryResolver.channel()
        // Return Channel directly (no ChannelType.from() conversion)
    }

    @Override
    public List<Message> channelMessages(UUID channelId, Long afterId, Integer limit) {
        // Body from ChannelsQueryResolver.channelMessages()
        // Return List<Message> directly (no MessageType.from() conversion)
    }

    @Override
    public Channel createChannel(ChannelCreateRequest input) {
        // Body from ChannelsMutationResolver.createChannel()
    }

    @Override
    public long deleteChannel(UUID channelId, Boolean force) {
        // Body from ChannelsMutationResolver.deleteChannel()
    }

    @Override
    public Channel pauseChannel(UUID channelId) {
        // Body from ChannelsMutationResolver.pauseChannel()
    }

    @Override
    public Channel resumeChannel(UUID channelId) {
        // Body from ChannelsMutationResolver.resumeChannel()
    }
}
```

**Key conversion pattern:** Wherever the old resolver has:
```java
return ChannelType.from(channel); // DTO wrapping
```
Replace with:
```java
return channel; // return domain type directly
```

Wherever pagination was built with `PageInfo`:
```java
return new ChannelPage(list.stream().map(ChannelType::from).toList(), pageInfo);
```
Replace with:
```java
return new ChannelPage(list, hasNext, cursor);
```

Verify exact imports: use `ide_find_class` for `ChannelReader`, `ConsumerMessaging`, `ChannelManager` to get correct package names.

- [ ] **Step 2: Create MessagingService**

Read `MessagingQueryResolver.java` and `MessagingMutationResolver.java`. Create `MessagingService` with:
- Constructor: inject `ConsumerMessaging`, `MessageReader`, `ReactionReader`, `MessageDispatcher`, `CurrentPrincipal`, `ReactionManager`, `MessageStore`, `CommitmentStore`
- Move `groupReactions()` helper as a private method
- Move `findTerminalMessage()` helper as a private method
- Keep `@Transactional` on `deleteMessage()`
- `waitForReply` and `requestApproval` keep their blocking poll logic unchanged — only the return type changes (`WaitResult` instead of `WaitResultType`)
- `reactionsBatch` returns `List<MessageReactions>` (using the new `MessageReactions` record) instead of `List<MessageReactionsType>`

- [ ] **Step 3: Create GovernanceService**

Read `GovernanceQueryResolver.java`. Create `GovernanceService`:
- Constructor: inject `CommitmentReader`
- Move `resolveCommitments()` helper as a private method
- Convert `CommitmentQuery` fields to the reader's expected format
- Return `CommitmentPage` instead of the old DTO page

- [ ] **Step 4: Create ComplianceService**

Read `ComplianceQueryResolver.java` and `ComplianceMutationResolver.java`. Create `ComplianceService` in `compliance-report/`:
- Constructor: inject all 10 report services + `CurrentPrincipal` + `ComplianceReportScheduleStore` + `ComplianceReportStorageService`
- Query methods return report types from `api/compliance/report/` directly (no DTO conversion — the report types ARE the SPI types now)
- `complianceReports()` must convert `ComplianceReportRecord` JPA entity to `ComplianceReportRecordView` record
- Mutation methods convert JPA entity `ComplianceReportSchedule` to `ComplianceScheduleView` on return

**Entity-to-view conversion pattern:**
```java
private ComplianceScheduleView toView(ComplianceReportSchedule entity) {
    return new ComplianceScheduleView(
        entity.getId(), entity.getReportType(), entity.getChannelId(),
        entity.getScheduleJson(), entity.getFormat(), entity.isEnabled(),
        entity.getCreatedAt(), entity.getUpdatedAt()
    );
}
```

- [ ] **Step 5: Verify modules compile**

```bash
mvn -f /Users/mdproctor/claude/casehub/slots/192/qhorus/pom.xml -pl graphql compile -am
mvn -f /Users/mdproctor/claude/casehub/slots/192/qhorus/pom.xml -pl compliance-report compile -am
```

Expected: BUILD SUCCESS. The impl beans compile against the SPI interfaces from api/. No generated resolvers yet — that's Task 4.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/192/qhorus add graphql/ compliance-report/
git -C /Users/mdproctor/claude/casehub/slots/192/qhorus commit -m "feat(#480): add Pattern 2 implementation beans

4 @ApplicationScoped beans implementing SPI interfaces:
- ChannelsService (graphql/) — channels + messaging queries/mutations
- MessagingService (graphql/) — dispatch, reactions, approval flows
- GovernanceService (graphql/) — commitment queries
- ComplianceService (compliance-report/) — reports + schedules

Method bodies from existing resolvers with DTO layer removed.

Refs casehubio/parent#480"
```

---

### Task 4: Wire APT, delete old resolvers and dead DTOs, verify

**Files:**
- Modify: `graphql/pom.xml` — add graphql-generator APT
- Modify: `compliance-report/pom.xml` — add graphql-generator APT
- Delete: `graphql/src/main/java/io/casehub/qhorus/graphql/channels/ChannelsQueryResolver.java`
- Delete: `graphql/src/main/java/io/casehub/qhorus/graphql/channels/ChannelsMutationResolver.java`
- Delete: `graphql/src/main/java/io/casehub/qhorus/graphql/messaging/MessagingQueryResolver.java`
- Delete: `graphql/src/main/java/io/casehub/qhorus/graphql/messaging/MessagingMutationResolver.java`
- Delete: `graphql/src/main/java/io/casehub/qhorus/graphql/governance/GovernanceQueryResolver.java`
- Delete: `compliance-report/src/main/java/io/casehub/qhorus/compliance/graphql/ComplianceQueryResolver.java`
- Delete: `compliance-report/src/main/java/io/casehub/qhorus/compliance/graphql/ComplianceMutationResolver.java`
- Delete: all DTO types in `graphql/src/main/java/io/casehub/qhorus/graphql/dto/` that are no longer referenced (ChannelType, MessageType, ChannelPage, ChannelFilterInput, CommitmentType, CommitmentPage, CommitmentFilterInput, DispatchResultType, DispatchMessageInput, WaitResultType, CancelWaitResultType, DeleteMessageResultType, ReactionGroupType, ReactionType, MessageReactionsType)
- Delete: all DTO types in `compliance-report/src/main/java/io/casehub/qhorus/compliance/graphql/` that are no longer referenced (ComplianceScheduleInput, ComplianceScheduleUpdateInput, ComplianceReportScheduleType, ComplianceReportRecordType, and all *Type wrappers for report models)
- Keep: `PresenceType` (used by ChannelsSubscriptionResolver which stays hand-written)
- Test: existing integration tests in graphql/ and compliance-report/

**Interfaces:**
- Consumes: impl beans from Task 3, SPI interfaces from Task 2
- Produces: generated `GeneratedChannelsResolver`, `GeneratedMessagingResolver`, `GeneratedGovernanceResolver`, `GeneratedComplianceResolver` + corresponding `Generated*Resource` REST resources

- [ ] **Step 1: Delete old resolver classes**

Delete BEFORE wiring APT — the APT's skip detection checks for hand-written `@GraphQLApi @McpDomain` resolvers and suppresses generation for matching domains.

Use `ide_refactor_safe_delete` for each resolver to check for references first:

```
graphql/.../channels/ChannelsQueryResolver.java
graphql/.../channels/ChannelsMutationResolver.java
graphql/.../messaging/MessagingQueryResolver.java
graphql/.../messaging/MessagingMutationResolver.java
graphql/.../governance/GovernanceQueryResolver.java
compliance-report/.../compliance/graphql/ComplianceQueryResolver.java
compliance-report/.../compliance/graphql/ComplianceMutationResolver.java
```

If `ide_refactor_safe_delete` reports references (e.g., from tests that directly inject a resolver), note them — they'll need updating in Step 5.

- [ ] **Step 2: Delete dead DTO types**

Find all DTO types that are no longer referenced after the resolver deletion. Check with `ide_find_references` before deleting each one — some may be used by `ChannelsSubscriptionResolver` (which stays).

Definitely keep:
- `PresenceType` — used by `ChannelsSubscriptionResolver`
- `MessageType` — check if `ChannelsSubscriptionResolver` uses it for `channelActivity` subscription return type

Delete everything else in `graphql/dto/` and `compliance/graphql/dto/` that has zero remaining references.

- [ ] **Step 3: Wire graphql-generator APT in graphql/pom.xml**

Add to `<dependencies>` (for reactor ordering):
```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-graphql-generator</artifactId>
    <version>${casehub-platform.version}</version>
    <scope>provided</scope>
</dependency>
```

Add to `<build><plugins>` → `maven-compiler-plugin` `<configuration>`:
```xml
<annotationProcessorPaths>
    <path>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-graphql-generator</artifactId>
        <version>${casehub-platform.version}</version>
    </path>
    <path>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-qhorus-api</artifactId>
        <version>${project.version}</version>
    </path>
</annotationProcessorPaths>
<compilerArgs>
    <arg>-AdomainFilter=channels,messaging,governance</arg>
</compilerArgs>
```

Note: `casehub-platform-api` may also be needed in `annotationProcessorPaths` if the generator requires it for annotation resolution. Check if the build fails without it and add if needed.

- [ ] **Step 4: Wire graphql-generator APT in compliance-report/pom.xml**

Same pattern as Step 3, but with `domainFilter=compliance`:

Add dependency (provided scope) and annotationProcessorPaths. CompilerArgs:
```xml
<compilerArgs>
    <arg>-AdomainFilter=compliance</arg>
</compilerArgs>
```

- [ ] **Step 5: Full build and verify**

```bash
mvn -f /Users/mdproctor/claude/casehub/slots/192/qhorus/pom.xml clean install
```

Expected: BUILD SUCCESS.

Verify generated classes exist:
```bash
find /Users/mdproctor/claude/casehub/slots/192/qhorus/graphql/target/generated-sources -name "Generated*" -type f
find /Users/mdproctor/claude/casehub/slots/192/qhorus/compliance-report/target/generated-sources -name "Generated*" -type f
```

Expected generated files:
- `GeneratedChannelsResolver.java` — `@GraphQLApi @McpDomain("channels")`
- `GeneratedChannelsResource.java` — `@Path("/channels")`
- `GeneratedMessagingResolver.java` — `@GraphQLApi @McpDomain("messaging")`
- `GeneratedMessagingResource.java` — `@Path("/messaging")`
- `GeneratedGovernanceResolver.java` — `@GraphQLApi @McpDomain("governance")`
- `GeneratedGovernanceResource.java` — `@Path("/governance")`
- `GeneratedComplianceResolver.java` — `@GraphQLApi @McpDomain("compliance")`
- `GeneratedComplianceResource.java` — `@Path("/compliance")`

If tests fail:
- Tests that directly reference old resolver class names need updating to reference the new service beans or generated resolvers
- Tests that reference DTO types (ChannelType, MessageType) need updating to use domain types (Channel, Message)
- Tests that reference `@McpDomain("qhorus")` need updating to `@McpDomain("compliance")`

- [ ] **Step 6: Verify ChannelsSubscriptionResolver still works**

Confirm `ChannelsSubscriptionResolver` compiles and any subscription tests pass. It stays hand-written and must coexist with the generated resolver. The generated `GeneratedChannelsResolver` handles queries/mutations; the subscription resolver handles `@Subscription` methods. Both share the `@McpDomain("channels")` domain — the generator skips `@Subscription` methods (not `@PlatformQuery`/`@PlatformMutation`).

Also verify `ChannelsModelEnricher` is unaffected — it implements `ModelEnricher`, not a SPI interface.

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/192/qhorus add graphql/ compliance-report/
git -C /Users/mdproctor/claude/casehub/slots/192/qhorus commit -m "feat(#480): wire graphql-generator APT, delete old resolvers and DTOs

Wire graphql-generator APT in graphql/ (channels, messaging, governance)
and compliance-report/ (compliance). Delete 7 old resolver classes and
dead GraphQL DTO types. Generated resolvers + REST resources now auto-
produced from SPI interfaces.

ChannelsSubscriptionResolver and ChannelsModelEnricher stay hand-written.

Refs casehubio/parent#480"
```

---

## References

- `specs/issue-478-spring-deployment-completion/2026-09-15-pattern2-qhorus-design.md` — design spec
- `specs/issue-478-spring-deployment-completion/pattern2-qhorus-decisions.md` — 5 design decisions
- `platform-api/src/main/java/io/casehub/platform/api/acl/AclApi.java` — reference Pattern 2 SPI interface
- `platform/notifications/pom.xml`, `platform/acl-admin/pom.xml` — reference APT wiring
- `platform/graphql-generator/` — APT processor source
- casehubio/parent#478, #480 — tracking issues
- Memory: `project_pattern2_migration.md` — Pattern 2 migration tracking
