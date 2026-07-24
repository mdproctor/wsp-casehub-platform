# EndpointRegistered Verification + AgentEvent Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify InMemoryEndpointRegistry fires EndpointRegistered (#117), then extend AgentEvent with ThinkingDelta, ToolCallDelta, ToolCallComplete, ToolResult (#118) and forward them through the LangChain4j bridge.

**Architecture:** Two independent issues on one branch. #117 adds a mock-based unit test to verify event firing behaviour. #118 extends the AgentEvent sealed interface in agent-api (pure Java, zero deps), then updates the LangChain4j bridge adapters to forward new event types to StreamingChatResponseHandler callbacks.

**Tech Stack:** Java 21 records, Mockito (mock Event<EndpointRegistered>), LangChain4j 1.14.1 streaming API (PartialThinking, PartialToolCall, CompleteToolCall, ToolExecutionRequest)

## Global Constraints

- `agent-api/` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports. Pure Java only.
- New event type records use compact constructors for validation (non-negative index, non-empty/non-blank strings).
- `TextDelta.text` inherits its unconstrained v1 contract — do not add validation.
- Mockito is managed in the parent POM — add `<dependency>` without `<version>`.

---

### Task 1: InMemoryEndpointRegistry event firing verification (#117)

**Files:**
- Modify: `endpoints-memory/pom.xml` — add mockito-core test dependency
- Create: `endpoints-memory/src/test/java/io/casehub/platform/endpoints/memory/InMemoryEndpointRegistryFireEventTest.java`

**Interfaces:**
- Consumes: `InMemoryEndpointRegistry(Event<EndpointRegistered>)` public constructor at line 56
- Produces: nothing — verification only

- [ ] **Step 1: Add mockito-core test dependency to endpoints-memory/pom.xml**

Add to `endpoints-memory/pom.xml` in the `<dependencies>` section:

```xml
<dependency>
    <groupId>org.mockito</groupId>
    <artifactId>mockito-core</artifactId>
    <scope>test</scope>
</dependency>
```

No `<version>` — managed by parent POM.

- [ ] **Step 2: Write the test class**

Create `endpoints-memory/src/test/java/io/casehub/platform/endpoints/memory/InMemoryEndpointRegistryFireEventTest.java`:

```java
package io.casehub.platform.endpoints.memory;

import io.casehub.platform.api.endpoints.EndpointCapability;
import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointPropertyKeys;
import io.casehub.platform.api.endpoints.EndpointProtocol;
import io.casehub.platform.api.endpoints.EndpointRegistered;
import io.casehub.platform.api.endpoints.EndpointType;
import io.casehub.platform.api.path.Path;
import jakarta.enterprise.event.Event;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.Map;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class InMemoryEndpointRegistryFireEventTest {

    @SuppressWarnings("unchecked")
    private final Event<EndpointRegistered> event = mock(Event.class);
    private InMemoryEndpointRegistry registry;

    @BeforeEach
    void setUp() {
        when(event.fireAsync(any())).thenReturn(CompletableFuture.completedFuture(null));
        registry = new InMemoryEndpointRegistry(event);
    }

    private static EndpointDescriptor descriptor(Path path, String tenancyId) {
        return new EndpointDescriptor(
            path, tenancyId, EndpointType.SERVICE, EndpointProtocol.HTTP,
            Map.of(EndpointPropertyKeys.URL, "https://example.com"),
            null, Set.of(EndpointCapability.SEND));
    }

    @Test
    void register_firesEndpointRegisteredWithCorrectDescriptor() {
        var desc = descriptor(Path.of("test", "endpoint"), "tenant-a");

        registry.register(desc);

        var captor = ArgumentCaptor.forClass(EndpointRegistered.class);
        verify(event).fireAsync(captor.capture());
        assertThat(captor.getValue().descriptor()).isSameAs(desc);
    }

    @Test
    void register_calledTwice_firesTwoEvents() {
        var desc1 = descriptor(Path.of("first", "endpoint"), "tenant-a");
        var desc2 = descriptor(Path.of("second", "endpoint"), "tenant-a");

        registry.register(desc1);
        registry.register(desc2);

        verify(event, times(2)).fireAsync(any(EndpointRegistered.class));
    }

    @Test
    void register_upsertSameKey_stillFiresEvent() {
        var path = Path.of("same", "path");
        var original = descriptor(path, "tenant-a");
        var updated = new EndpointDescriptor(
            path, "tenant-a", EndpointType.SYSTEM, EndpointProtocol.GRPC,
            Map.of(EndpointPropertyKeys.URL, "https://updated.com"),
            null, Set.of(EndpointCapability.QUERY));

        registry.register(original);
        registry.register(updated);

        var captor = ArgumentCaptor.forClass(EndpointRegistered.class);
        verify(event, times(2)).fireAsync(captor.capture());
        assertThat(captor.getAllValues().get(1).descriptor()).isSameAs(updated);
    }
}
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl endpoints-memory -Dtest=InMemoryEndpointRegistryFireEventTest`
Expected: 3 tests PASS

- [ ] **Step 4: Commit**

```
git add endpoints-memory/pom.xml endpoints-memory/src/test/java/io/casehub/platform/endpoints/memory/InMemoryEndpointRegistryFireEventTest.java
git commit -m "test(platform#117): verify InMemoryEndpointRegistry fires EndpointRegistered with correct descriptor"
```

---

### Task 2: Extend AgentEvent sealed interface (#118)

**Files:**
- Modify: `agent-api/src/main/java/io/casehub/platform/agent/AgentEvent.java`
- Modify: `agent-api/src/main/java/io/casehub/platform/agent/AgentProvider.java`
- Modify: `agent-api/src/main/java/io/casehub/platform/agent/AgentSession.java`
- Create: `agent-api/src/test/java/io/casehub/platform/agent/AgentEventTest.java`

**Interfaces:**
- Consumes: nothing
- Produces: `AgentEvent.ThinkingDelta(String text)`, `AgentEvent.ToolCallDelta(int index, String id, String name, String partialArguments)`, `AgentEvent.ToolCallComplete(int index, String id, String name, String arguments)`, `AgentEvent.ToolResult(String toolCallId, String content, boolean isError)` — used by Task 3

- [ ] **Step 1: Write the failing test for new event types and validation**

Create `agent-api/src/test/java/io/casehub/platform/agent/AgentEventTest.java`:

```java
package io.casehub.platform.agent;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatIllegalArgumentException;

class AgentEventTest {

    // ── ThinkingDelta ────────────────────────────────────────────────────────

    @Test
    void thinkingDelta_carriesText() {
        var delta = new AgentEvent.ThinkingDelta("reasoning");
        assertThat(delta.text()).isEqualTo("reasoning");
    }

    @Test
    void thinkingDelta_rejectsNull() {
        assertThatIllegalArgumentException()
            .isThrownBy(() -> new AgentEvent.ThinkingDelta(null));
    }

    @Test
    void thinkingDelta_rejectsEmpty() {
        assertThatIllegalArgumentException()
            .isThrownBy(() -> new AgentEvent.ThinkingDelta(""));
    }

    // ── ToolCallDelta ────────────────────────────────────────────────────────

    @Test
    void toolCallDelta_carriesAllFields() {
        var delta = new AgentEvent.ToolCallDelta(0, "call_1", "get_weather", "{\"ci");
        assertThat(delta.index()).isZero();
        assertThat(delta.id()).isEqualTo("call_1");
        assertThat(delta.name()).isEqualTo("get_weather");
        assertThat(delta.partialArguments()).isEqualTo("{\"ci");
    }

    @Test
    void toolCallDelta_allowsNullId() {
        var delta = new AgentEvent.ToolCallDelta(0, null, "tool", "{");
        assertThat(delta.id()).isNull();
    }

    @Test
    void toolCallDelta_rejectsNegativeIndex() {
        assertThatIllegalArgumentException()
            .isThrownBy(() -> new AgentEvent.ToolCallDelta(-1, "id", "tool", "{"));
    }

    @Test
    void toolCallDelta_rejectsNullName() {
        assertThatIllegalArgumentException()
            .isThrownBy(() -> new AgentEvent.ToolCallDelta(0, "id", null, "{"));
    }

    @Test
    void toolCallDelta_rejectsBlankName() {
        assertThatIllegalArgumentException()
            .isThrownBy(() -> new AgentEvent.ToolCallDelta(0, "id", "  ", "{"));
    }

    @Test
    void toolCallDelta_rejectsNullPartialArguments() {
        assertThatIllegalArgumentException()
            .isThrownBy(() -> new AgentEvent.ToolCallDelta(0, "id", "tool", null));
    }

    @Test
    void toolCallDelta_rejectsEmptyPartialArguments() {
        assertThatIllegalArgumentException()
            .isThrownBy(() -> new AgentEvent.ToolCallDelta(0, "id", "tool", ""));
    }

    // ── ToolCallComplete ─────────────────────────────────────────────────────

    @Test
    void toolCallComplete_carriesAllFields() {
        var complete = new AgentEvent.ToolCallComplete(0, "call_1", "get_weather", "{\"city\":\"Munich\"}");
        assertThat(complete.index()).isZero();
        assertThat(complete.id()).isEqualTo("call_1");
        assertThat(complete.name()).isEqualTo("get_weather");
        assertThat(complete.arguments()).isEqualTo("{\"city\":\"Munich\"}");
    }

    @Test
    void toolCallComplete_allowsNullId() {
        var complete = new AgentEvent.ToolCallComplete(0, null, "tool", "{}");
        assertThat(complete.id()).isNull();
    }

    @Test
    void toolCallComplete_rejectsNegativeIndex() {
        assertThatIllegalArgumentException()
            .isThrownBy(() -> new AgentEvent.ToolCallComplete(-1, "id", "tool", "{}"));
    }

    @Test
    void toolCallComplete_rejectsNullName() {
        assertThatIllegalArgumentException()
            .isThrownBy(() -> new AgentEvent.ToolCallComplete(0, "id", null, "{}"));
    }

    @Test
    void toolCallComplete_rejectsBlankName() {
        assertThatIllegalArgumentException()
            .isThrownBy(() -> new AgentEvent.ToolCallComplete(0, "id", " ", "{}"));
    }

    @Test
    void toolCallComplete_rejectsNullArguments() {
        assertThatIllegalArgumentException()
            .isThrownBy(() -> new AgentEvent.ToolCallComplete(0, "id", "tool", null));
    }

    @Test
    void toolCallComplete_rejectsEmptyArguments() {
        assertThatIllegalArgumentException()
            .isThrownBy(() -> new AgentEvent.ToolCallComplete(0, "id", "tool", ""));
    }

    // ── ToolResult ───────────────────────────────────────────────────────────

    @Test
    void toolResult_carriesAllFields() {
        var result = new AgentEvent.ToolResult("call_1", "{\"temp\":22}", false);
        assertThat(result.toolCallId()).isEqualTo("call_1");
        assertThat(result.content()).isEqualTo("{\"temp\":22}");
        assertThat(result.isError()).isFalse();
    }

    @Test
    void toolResult_allowsNullToolCallId() {
        var result = new AgentEvent.ToolResult(null, "output", false);
        assertThat(result.toolCallId()).isNull();
    }

    @Test
    void toolResult_allowsEmptyContent() {
        var result = new AgentEvent.ToolResult("id", "", false);
        assertThat(result.content()).isEmpty();
    }

    @Test
    void toolResult_rejectsNullContent() {
        assertThatIllegalArgumentException()
            .isThrownBy(() -> new AgentEvent.ToolResult("id", null, false));
    }

    @Test
    void toolResult_errorFlag() {
        var result = new AgentEvent.ToolResult("call_1", "timeout", true);
        assertThat(result.isError()).isTrue();
    }

    // ── TextDelta (existing — verify unchanged v1 contract) ──────────────────

    @Test
    void textDelta_allowsEmptyText() {
        var delta = new AgentEvent.TextDelta("");
        assertThat(delta.text()).isEmpty();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-api -Dtest=AgentEventTest`
Expected: FAIL — new record types do not exist yet

- [ ] **Step 3: Implement AgentEvent with new sealed permits**

Replace `agent-api/src/main/java/io/casehub/platform/agent/AgentEvent.java` with:

```java
package io.casehub.platform.agent;

import java.util.Objects;

/**
 * Streaming event emitted by {@link AgentProvider#invoke} and {@link AgentSession#query}.
 *
 * <p>The event model captures the richest stream any reasonable LLM backend can produce.
 * Backends that don't support a particular event type (e.g. thinking, streaming tool
 * arguments) simply never emit it — consumers pattern-match only the variants they need.
 *
 * <p>Not all events are emitted by all backends:
 * <ul>
 *   <li>{@link TextDelta} — universal; every backend emits text.
 *   <li>{@link ThinkingDelta} — backends with extended thinking (Claude).
 *   <li>{@link ToolCallDelta} — backends that stream tool arguments token-by-token.
 *   <li>{@link ToolCallComplete} — universal for backends that support tool use.
 *   <li>{@link ToolResult} — observability; what the tool returned to the agent.
 * </ul>
 */
public sealed interface AgentEvent permits
        AgentEvent.TextDelta,
        AgentEvent.ThinkingDelta,
        AgentEvent.ToolCallDelta,
        AgentEvent.ToolCallComplete,
        AgentEvent.ToolResult {

    record TextDelta(String text) implements AgentEvent {}

    record ThinkingDelta(String text) implements AgentEvent {
        public ThinkingDelta {
            if (text == null || text.isEmpty())
                throw new IllegalArgumentException("text must not be null or empty");
        }
    }

    record ToolCallDelta(int index, String id, String name, String partialArguments) implements AgentEvent {
        public ToolCallDelta {
            if (index < 0)
                throw new IllegalArgumentException("index must not be negative");
            if (name == null || name.isBlank())
                throw new IllegalArgumentException("name must not be null or blank");
            if (partialArguments == null || partialArguments.isEmpty())
                throw new IllegalArgumentException("partialArguments must not be null or empty");
        }
    }

    record ToolCallComplete(int index, String id, String name, String arguments) implements AgentEvent {
        public ToolCallComplete {
            if (index < 0)
                throw new IllegalArgumentException("index must not be negative");
            if (name == null || name.isBlank())
                throw new IllegalArgumentException("name must not be null or blank");
            if (arguments == null || arguments.isEmpty())
                throw new IllegalArgumentException("arguments must not be null or empty");
        }
    }

    record ToolResult(String toolCallId, String content, boolean isError) implements AgentEvent {
        public ToolResult {
            Objects.requireNonNull(content, "content must not be null");
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl agent-api -Dtest=AgentEventTest`
Expected: all tests PASS

- [ ] **Step 5: Update AgentProvider javadoc**

In `agent-api/src/main/java/io/casehub/platform/agent/AgentProvider.java`, replace the class javadoc (lines 1-18) and the `invoke()` return doc (line 27):

Class javadoc — replace opening paragraph:
```java
/**
 * Platform SPI for AI agent invocation.
 *
 * <p>This is the platform's own abstraction for AI agent interaction — not tied to
 * any single LLM backend or SDK. Implementations may use native SDKs (Claude Agent SDK,
 * Anthropic API, Google Gemini, etc.) or bridge through LangChain4j. The SPI exists
 * because LangChain4j's abstractions sometimes impose overhead — particularly around
 * caching and token cost — that native SDK access avoids. LangChain4j is one adapter
 * path, not the ceiling.
 *
 * <p>Implementations should be {@code @ApplicationScoped} — agent infrastructure
 * is shared across requests.
```

`invoke()` return doc — change line 27 from:
```java
 * @return a cold {@code Multi} that streams {@link AgentEvent.TextDelta} items
```
to:
```java
 * @return a cold {@code Multi} that streams {@link AgentEvent} items
```

- [ ] **Step 6: Update AgentSession.query() return doc**

In `agent-api/src/main/java/io/casehub/platform/agent/AgentSession.java`, line 41 — no change needed to the method javadoc (it already says `Multi<AgentEvent>` without narrowing to TextDelta).

Verify: read the javadoc above `query()` and confirm no TextDelta-specific language.

- [ ] **Step 7: Commit**

```
git add agent-api/src/main/java/io/casehub/platform/agent/AgentEvent.java agent-api/src/main/java/io/casehub/platform/agent/AgentProvider.java agent-api/src/test/java/io/casehub/platform/agent/AgentEventTest.java
git commit -m "feat(platform#118): extend AgentEvent sealed interface — ThinkingDelta, ToolCallDelta, ToolCallComplete, ToolResult"
```

---

### Task 3: Forward new event types through LangChain4j bridge

**Files:**
- Modify: `agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentProviderChatModel.java:100-121`
- Modify: `agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentSessionChatModel.java:79-100`
- Modify: `agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/AgentProviderChatModelTest.java`
- Modify: `agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/AgentSessionChatModelTest.java`

**Interfaces:**
- Consumes: `AgentEvent.ThinkingDelta`, `AgentEvent.ToolCallDelta`, `AgentEvent.ToolCallComplete`, `AgentEvent.ToolResult` from Task 2
- Produces: nothing — bridge forwarding only

- [ ] **Step 1: Write failing tests for AgentProviderChatModel streaming forwarding**

Add a helper to `AgentProviderChatModelTest.java` that creates a Multi of mixed event types, and four new test methods. Add these imports:

```java
import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.model.chat.response.CompleteToolCall;
import dev.langchain4j.model.chat.response.PartialThinking;
import dev.langchain4j.model.chat.response.PartialToolCall;
```

Add helper:

```java
static Multi<AgentEvent> mixedEvents() {
    return Multi.createFrom().items(
        new AgentEvent.TextDelta("hello"),
        new AgentEvent.ThinkingDelta("reasoning"),
        new AgentEvent.ToolCallDelta(0, "call_1", "get_weather", "{\"ci"),
        new AgentEvent.ToolCallComplete(0, "call_1", "get_weather", "{\"city\":\"Munich\"}"),
        new AgentEvent.ToolResult("call_1", "{\"temp\":22}", false),
        new AgentEvent.TextDelta(" world")
    );
}
```

Test 1 — ThinkingDelta forwarding:

```java
@Test
void doChat_streaming_forwardsThinkingDelta() {
    AgentProviderChatModel m = model(fakeProvider(
        Multi.createFrom().items(
            new AgentEvent.ThinkingDelta("step 1"),
            new AgentEvent.TextDelta("answer")
        )));
    List<String> thinkings = new ArrayList<>();
    ChatResponse[] completed = {null};

    m.chat(single("q"), new StreamingChatResponseHandler() {
        @Override public void onPartialResponse(String t) {}
        @Override public void onPartialThinking(PartialThinking t) { thinkings.add(t.text()); }
        @Override public void onCompleteResponse(ChatResponse r) { completed[0] = r; }
        @Override public void onError(Throwable t) { throw new RuntimeException(t); }
    });

    await().untilAsserted(() -> assertThat(completed[0]).isNotNull());
    assertThat(thinkings).containsExactly("step 1");
}
```

Test 2 — ToolCallDelta forwarding:

```java
@Test
void doChat_streaming_forwardsToolCallDelta() {
    AgentProviderChatModel m = model(fakeProvider(
        Multi.createFrom().items(
            new AgentEvent.ToolCallDelta(0, "call_1", "search", "{\"q"),
            new AgentEvent.TextDelta("done")
        )));
    List<PartialToolCall> partials = new ArrayList<>();
    ChatResponse[] completed = {null};

    m.chat(single("q"), new StreamingChatResponseHandler() {
        @Override public void onPartialResponse(String t) {}
        @Override public void onPartialToolCall(PartialToolCall p) { partials.add(p); }
        @Override public void onCompleteResponse(ChatResponse r) { completed[0] = r; }
        @Override public void onError(Throwable t) { throw new RuntimeException(t); }
    });

    await().untilAsserted(() -> assertThat(completed[0]).isNotNull());
    assertThat(partials).hasSize(1);
    assertThat(partials.get(0).index()).isZero();
    assertThat(partials.get(0).id()).isEqualTo("call_1");
    assertThat(partials.get(0).name()).isEqualTo("search");
    assertThat(partials.get(0).partialArguments()).isEqualTo("{\"q");
}
```

Test 3 — ToolCallComplete forwarding:

```java
@Test
void doChat_streaming_forwardsToolCallComplete() {
    AgentProviderChatModel m = model(fakeProvider(
        Multi.createFrom().items(
            new AgentEvent.ToolCallComplete(0, "call_1", "search", "{\"query\":\"test\"}"),
            new AgentEvent.TextDelta("done")
        )));
    List<CompleteToolCall> completes = new ArrayList<>();
    ChatResponse[] completed = {null};

    m.chat(single("q"), new StreamingChatResponseHandler() {
        @Override public void onPartialResponse(String t) {}
        @Override public void onCompleteToolCall(CompleteToolCall c) { completes.add(c); }
        @Override public void onCompleteResponse(ChatResponse r) { completed[0] = r; }
        @Override public void onError(Throwable t) { throw new RuntimeException(t); }
    });

    await().untilAsserted(() -> assertThat(completed[0]).isNotNull());
    assertThat(completes).hasSize(1);
    assertThat(completes.get(0).index()).isZero();
    assertThat(completes.get(0).toolExecutionRequest().id()).isEqualTo("call_1");
    assertThat(completes.get(0).toolExecutionRequest().name()).isEqualTo("search");
    assertThat(completes.get(0).toolExecutionRequest().arguments()).isEqualTo("{\"query\":\"test\"}");
}
```

Test 4 — ToolResult silently ignored:

```java
@Test
void doChat_streaming_toolResultSilentlyIgnored() {
    AgentProviderChatModel m = model(fakeProvider(
        Multi.createFrom().items(
            new AgentEvent.ToolResult("call_1", "output", false),
            new AgentEvent.TextDelta("text")
        )));
    List<String> partials = new ArrayList<>();
    ChatResponse[] completed = {null};

    m.chat(single("q"), new StreamingChatResponseHandler() {
        @Override public void onPartialResponse(String t) { partials.add(t); }
        @Override public void onCompleteResponse(ChatResponse r) { completed[0] = r; }
        @Override public void onError(Throwable t) { throw new RuntimeException(t); }
    });

    await().untilAsserted(() -> assertThat(completed[0]).isNotNull());
    assertThat(partials).containsExactly("text");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=AgentProviderChatModelTest#doChat_streaming_forwardsThinkingDelta+doChat_streaming_forwardsToolCallDelta+doChat_streaming_forwardsToolCallComplete+doChat_streaming_toolResultSilentlyIgnored`
Expected: FAIL — new event types are not forwarded

- [ ] **Step 3: Implement forwarding in AgentProviderChatModel.doChat(request, handler)**

In `agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentProviderChatModel.java`, add imports:

```java
import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.model.chat.response.CompleteToolCall;
import dev.langchain4j.model.chat.response.PartialThinking;
import dev.langchain4j.model.chat.response.PartialToolCall;
```

Replace the `event ->` lambda body in the streaming `doChat` method (lines 109-113) with:

```java
event -> {
    if (event instanceof AgentEvent.TextDelta delta) {
        handler.onPartialResponse(delta.text());
        buffer.append(delta.text());
    } else if (event instanceof AgentEvent.ThinkingDelta thinking) {
        handler.onPartialThinking(new PartialThinking(thinking.text()));
    } else if (event instanceof AgentEvent.ToolCallDelta d) {
        handler.onPartialToolCall(PartialToolCall.builder()
            .index(d.index()).id(d.id()).name(d.name())
            .partialArguments(d.partialArguments()).build());
    } else if (event instanceof AgentEvent.ToolCallComplete c) {
        handler.onCompleteToolCall(new CompleteToolCall(c.index(),
            ToolExecutionRequest.builder()
                .id(c.id()).name(c.name()).arguments(c.arguments())
                .build()));
    }
    // ToolResult — no StreamingChatResponseHandler callback; silently ignored
},
```

- [ ] **Step 4: Run AgentProviderChatModel tests**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=AgentProviderChatModelTest`
Expected: all tests PASS (including existing tests — no regressions)

- [ ] **Step 5: Write matching tests for AgentSessionChatModel**

Add the same four test methods to `AgentSessionChatModelTest.java` with the same imports. Adapt the helper pattern — `AgentSessionChatModel` uses `fakeSession(turnFactory)` not `fakeProvider`:

```java
@Test
void doChat_streaming_forwardsThinkingDelta() {
    AgentSessionChatModel model = AgentSessionChatModel.wrap(
        fakeSession(__ -> Multi.createFrom().items(
            new AgentEvent.ThinkingDelta("step 1"),
            new AgentEvent.TextDelta("answer")
        )));
    List<String> thinkings = new ArrayList<>();
    ChatResponse[] completed = {null};

    model.chat(single("q"), new StreamingChatResponseHandler() {
        @Override public void onPartialResponse(String t) {}
        @Override public void onPartialThinking(PartialThinking t) { thinkings.add(t.text()); }
        @Override public void onCompleteResponse(ChatResponse r) { completed[0] = r; }
        @Override public void onError(Throwable t) { throw new RuntimeException(t); }
    });

    await().untilAsserted(() -> assertThat(completed[0]).isNotNull());
    assertThat(thinkings).containsExactly("step 1");
}

@Test
void doChat_streaming_forwardsToolCallDelta() {
    AgentSessionChatModel model = AgentSessionChatModel.wrap(
        fakeSession(__ -> Multi.createFrom().items(
            new AgentEvent.ToolCallDelta(0, "call_1", "search", "{\"q"),
            new AgentEvent.TextDelta("done")
        )));
    List<PartialToolCall> partials = new ArrayList<>();
    ChatResponse[] completed = {null};

    model.chat(single("q"), new StreamingChatResponseHandler() {
        @Override public void onPartialResponse(String t) {}
        @Override public void onPartialToolCall(PartialToolCall p) { partials.add(p); }
        @Override public void onCompleteResponse(ChatResponse r) { completed[0] = r; }
        @Override public void onError(Throwable t) { throw new RuntimeException(t); }
    });

    await().untilAsserted(() -> assertThat(completed[0]).isNotNull());
    assertThat(partials).hasSize(1);
    assertThat(partials.get(0).name()).isEqualTo("search");
}

@Test
void doChat_streaming_forwardsToolCallComplete() {
    AgentSessionChatModel model = AgentSessionChatModel.wrap(
        fakeSession(__ -> Multi.createFrom().items(
            new AgentEvent.ToolCallComplete(0, "call_1", "search", "{\"query\":\"test\"}"),
            new AgentEvent.TextDelta("done")
        )));
    List<CompleteToolCall> completes = new ArrayList<>();
    ChatResponse[] completed = {null};

    model.chat(single("q"), new StreamingChatResponseHandler() {
        @Override public void onPartialResponse(String t) {}
        @Override public void onCompleteToolCall(CompleteToolCall c) { completes.add(c); }
        @Override public void onCompleteResponse(ChatResponse r) { completed[0] = r; }
        @Override public void onError(Throwable t) { throw new RuntimeException(t); }
    });

    await().untilAsserted(() -> assertThat(completed[0]).isNotNull());
    assertThat(completes).hasSize(1);
    assertThat(completes.get(0).toolExecutionRequest().name()).isEqualTo("search");
}

@Test
void doChat_streaming_toolResultSilentlyIgnored() {
    AgentSessionChatModel model = AgentSessionChatModel.wrap(
        fakeSession(__ -> Multi.createFrom().items(
            new AgentEvent.ToolResult("call_1", "output", false),
            new AgentEvent.TextDelta("text")
        )));
    List<String> partials = new ArrayList<>();
    ChatResponse[] completed = {null};

    model.chat(single("q"), new StreamingChatResponseHandler() {
        @Override public void onPartialResponse(String t) { partials.add(t); }
        @Override public void onCompleteResponse(ChatResponse r) { completed[0] = r; }
        @Override public void onError(Throwable t) { throw new RuntimeException(t); }
    });

    await().untilAsserted(() -> assertThat(completed[0]).isNotNull());
    assertThat(partials).containsExactly("text");
}
```

- [ ] **Step 6: Implement forwarding in AgentSessionChatModel.doChat(request, handler)**

In `agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentSessionChatModel.java`, add imports:

```java
import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.model.chat.response.CompleteToolCall;
import dev.langchain4j.model.chat.response.PartialThinking;
import dev.langchain4j.model.chat.response.PartialToolCall;
```

Replace the `event ->` lambda body in the streaming `doChat` method (lines 87-91) with the same pattern as AgentProviderChatModel (Step 3).

- [ ] **Step 7: Run all agent-langchain4j tests**

Run: `mvn --batch-mode test -pl agent-langchain4j`
Expected: all tests PASS

- [ ] **Step 8: Run full project build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```
git add agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentProviderChatModel.java agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentSessionChatModel.java agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/AgentProviderChatModelTest.java agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/AgentSessionChatModelTest.java
git commit -m "feat(platform#118): forward ThinkingDelta, ToolCallDelta, ToolCallComplete through LangChain4j bridge"
```
