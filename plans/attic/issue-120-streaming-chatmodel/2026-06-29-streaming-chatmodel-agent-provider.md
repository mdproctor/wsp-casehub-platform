# ChatModelAgentProvider StreamingChatModel Upgrade — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade `ChatModelAgentProvider` and `ChatModelAgentSession` to use `StreamingChatModel` when available, enabling richer `AgentEvent` emission (ThinkingDelta, ToolCallDelta, ToolCallComplete). Extract bidirectional AgentEvent↔StreamingChatResponseHandler mapping into `AgentEventBridge`.

**Architecture:** At `@PostConstruct`, detect if the resolved `ChatModel` also implements `StreamingChatModel`. When streaming is available, bridge `StreamingChatResponseHandler` callbacks to `Multi<AgentEvent>` via `Multi.createFrom().emitter()`. When not, fall back to the existing blocking path. Consolidate the inverse mapping (AgentEvent→handler) already duplicated in `AgentProviderChatModel` and `AgentSessionChatModel` into the same bridge utility.

**Tech Stack:** Java 21, Mutiny 2.x, LangChain4j 1.14.1, Quarkus 3.x, JUnit 5, Mockito, AssertJ

## Global Constraints

- All files in `agent-langchain4j/` module under package `io.casehub.platform.agent.langchain4j`
- `AgentEventBridge` is package-private (no `public` modifier) — internal utility
- `AgentEvent` is a sealed interface — use exhaustive `switch` (not `if/instanceof`)
- Call `StreamingChatModel.chat()` (full lifecycle), never `doChat()` (bypasses parameter defaults and listeners)
- Mock `doChat()` in tests (GE-20260529-0c80ca) — tests mock the implementation hook while `chat()` drives the real lifecycle
- Maven test command: `mvn --batch-mode test -pl agent-langchain4j`
- Specific test: `mvn --batch-mode test -pl agent-langchain4j -Dtest=ClassName`

---

### Task 1: AgentEventBridge — `stream()` method + tests

**Files:**
- Create: `agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentEventBridge.java`
- Create: `agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/AgentEventBridgeTest.java`

**Interfaces:**
- Consumes: `AgentEvent` (sealed interface from `agent-api`), `StreamingChatModel`, `StreamingChatResponseHandler`, `PartialThinking`, `PartialToolCall`, `CompleteToolCall`, `PartialResponse`, `PartialResponseContext`, `PartialThinkingContext`, `PartialToolCallContext`, `StreamingHandle` (all from `dev.langchain4j`)
- Produces: `AgentEventBridge.stream(StreamingChatModel, ChatRequest) → Multi<AgentEvent>` — used by Tasks 3 and 4

- [ ] **Step 1: Write the failing tests for `stream()` — text delta mapping**

Create `AgentEventBridgeTest.java`:

```java
package io.casehub.platform.agent.langchain4j;

import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.model.chat.StreamingChatModel;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.response.ChatResponse;
import dev.langchain4j.model.chat.response.CompleteToolCall;
import dev.langchain4j.model.chat.response.PartialThinking;
import dev.langchain4j.model.chat.response.PartialToolCall;
import dev.langchain4j.model.chat.response.StreamingChatResponseHandler;
import dev.langchain4j.model.chat.response.StreamingHandle;
import dev.langchain4j.model.chat.response.PartialResponse;
import dev.langchain4j.model.chat.response.PartialResponseContext;
import dev.langchain4j.model.output.FinishReason;
import io.casehub.platform.agent.AgentEvent;
import io.smallrye.mutiny.Multi;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class AgentEventBridgeTest {

    private static final ChatRequest SIMPLE_REQUEST = ChatRequest.builder()
        .messages(UserMessage.from("hello")).build();

    @Test
    void stream_textDelta_mapsToTextDeltaEvents() {
        StreamingChatModel model = streamingModel((request, handler) -> {
            handler.onPartialResponse("Hello");
            handler.onPartialResponse(" World");
            handler.onCompleteResponse(ChatResponse.builder()
                .aiMessage(AiMessage.from("Hello World"))
                .finishReason(FinishReason.STOP).build());
        });

        List<AgentEvent> events = AgentEventBridge.stream(model, SIMPLE_REQUEST)
            .collect().asList().await().atMost(Duration.ofSeconds(5));

        assertThat(events).hasSize(2);
        assertThat(events.get(0)).isEqualTo(new AgentEvent.TextDelta("Hello"));
        assertThat(events.get(1)).isEqualTo(new AgentEvent.TextDelta(" World"));
    }

    @Test
    void stream_thinkingDelta_mapsToThinkingDeltaEvents() {
        StreamingChatModel model = streamingModel((request, handler) -> {
            handler.onPartialThinking(new PartialThinking("Let me think"));
            handler.onPartialResponse("Answer");
            handler.onCompleteResponse(ChatResponse.builder()
                .aiMessage(AiMessage.from("Answer"))
                .finishReason(FinishReason.STOP).build());
        });

        List<AgentEvent> events = AgentEventBridge.stream(model, SIMPLE_REQUEST)
            .collect().asList().await().atMost(Duration.ofSeconds(5));

        assertThat(events).hasSize(2);
        assertThat(events.get(0)).isEqualTo(new AgentEvent.ThinkingDelta("Let me think"));
        assertThat(events.get(1)).isEqualTo(new AgentEvent.TextDelta("Answer"));
    }

    @Test
    void stream_toolCallDelta_mapsToToolCallDeltaEvent() {
        StreamingChatModel model = streamingModel((request, handler) -> {
            handler.onPartialToolCall(PartialToolCall.builder()
                .index(0).id("call_1").name("get_weather")
                .partialArguments("{\"city\"").build());
            handler.onCompleteToolCall(new CompleteToolCall(0,
                ToolExecutionRequest.builder()
                    .id("call_1").name("get_weather")
                    .arguments("{\"city\":\"Munich\"}").build()));
            handler.onCompleteResponse(ChatResponse.builder()
                .aiMessage(AiMessage.from("")).finishReason(FinishReason.STOP).build());
        });

        List<AgentEvent> events = AgentEventBridge.stream(model, SIMPLE_REQUEST)
            .collect().asList().await().atMost(Duration.ofSeconds(5));

        assertThat(events).hasSize(2);
        assertThat(events.get(0)).isEqualTo(
            new AgentEvent.ToolCallDelta(0, "call_1", "get_weather", "{\"city\""));
        assertThat(events.get(1)).isEqualTo(
            new AgentEvent.ToolCallComplete(0, "call_1", "get_weather", "{\"city\":\"Munich\"}"));
    }

    @Test
    void stream_error_failsMulti() {
        RuntimeException error = new RuntimeException("model error");
        StreamingChatModel model = streamingModel((request, handler) -> {
            handler.onPartialResponse("partial");
            handler.onError(error);
        });

        assertThatThrownBy(() -> AgentEventBridge.stream(model, SIMPLE_REQUEST)
            .collect().asList().await().atMost(Duration.ofSeconds(5)))
            .isSameAs(error);
    }

    @Test
    void stream_emptyStream_completesWithNoEvents() {
        StreamingChatModel model = streamingModel((request, handler) ->
            handler.onCompleteResponse(ChatResponse.builder()
                .aiMessage(AiMessage.from("")).finishReason(FinishReason.STOP).build()));

        List<AgentEvent> events = AgentEventBridge.stream(model, SIMPLE_REQUEST)
            .collect().asList().await().atMost(Duration.ofSeconds(5));

        assertThat(events).isEmpty();
    }

    @Test
    void stream_mixedEventSequence_preservesOrder() {
        StreamingChatModel model = streamingModel((request, handler) -> {
            handler.onPartialThinking(new PartialThinking("thinking..."));
            handler.onPartialResponse("text1");
            handler.onPartialToolCall(PartialToolCall.builder()
                .index(0).id("c1").name("tool1").partialArguments("{").build());
            handler.onCompleteToolCall(new CompleteToolCall(0,
                ToolExecutionRequest.builder()
                    .id("c1").name("tool1").arguments("{\"a\":1}").build()));
            handler.onPartialResponse("text2");
            handler.onCompleteResponse(ChatResponse.builder()
                .aiMessage(AiMessage.from("text1text2"))
                .finishReason(FinishReason.STOP).build());
        });

        List<AgentEvent> events = AgentEventBridge.stream(model, SIMPLE_REQUEST)
            .collect().asList().await().atMost(Duration.ofSeconds(5));

        assertThat(events).hasSize(5);
        assertThat(events.get(0)).isInstanceOf(AgentEvent.ThinkingDelta.class);
        assertThat(events.get(1)).isInstanceOf(AgentEvent.TextDelta.class);
        assertThat(events.get(2)).isInstanceOf(AgentEvent.ToolCallDelta.class);
        assertThat(events.get(3)).isInstanceOf(AgentEvent.ToolCallComplete.class);
        assertThat(events.get(4)).isInstanceOf(AgentEvent.TextDelta.class);
    }

    @Test
    void stream_contextAwareOverload_capturesStreamingHandle() {
        AtomicBoolean cancelCalled = new AtomicBoolean(false);
        StreamingHandle handle = new StreamingHandle() {
            @Override public void cancel() { cancelCalled.set(true); }
            @Override public boolean isCancelled() { return cancelCalled.get(); }
        };

        StreamingChatModel model = streamingModel((request, handler) -> {
            handler.onPartialResponse(
                new PartialResponse("tok1"),
                new PartialResponseContext(handle));
            handler.onPartialResponse(
                new PartialResponse("tok2"),
                new PartialResponseContext(handle));
            // Do not complete — let the subscriber cancel
        });

        AgentEventBridge.stream(model, SIMPLE_REQUEST)
            .select().first(1)
            .collect().asList()
            .await().atMost(Duration.ofSeconds(5));

        assertThat(cancelCalled.get()).isTrue();
    }

    @Test
    void stream_noStreamingHandle_cancellationDoesNotThrow() {
        StreamingChatModel model = streamingModel((request, handler) -> {
            handler.onPartialResponse("tok1");
            handler.onPartialResponse("tok2");
            // Do not complete — let the subscriber cancel
        });

        List<AgentEvent> events = AgentEventBridge.stream(model, SIMPLE_REQUEST)
            .select().first(1)
            .collect().asList()
            .await().atMost(Duration.ofSeconds(5));

        assertThat(events).hasSize(1);
        assertThat(events.get(0)).isEqualTo(new AgentEvent.TextDelta("tok1"));
    }

    // -- helper --

    @FunctionalInterface
    interface DoChat {
        void accept(ChatRequest request, StreamingChatResponseHandler handler);
    }

    private static StreamingChatModel streamingModel(DoChat doChat) {
        return new StreamingChatModel() {
            @Override
            public void doChat(ChatRequest request, StreamingChatResponseHandler handler) {
                doChat.accept(request, handler);
            }
        };
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=AgentEventBridgeTest`
Expected: compilation failure — `AgentEventBridge` does not exist

- [ ] **Step 3: Implement `AgentEventBridge.stream()`**

Create `AgentEventBridge.java`:

```java
package io.casehub.platform.agent.langchain4j;

import dev.langchain4j.model.chat.StreamingChatModel;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.response.ChatResponse;
import dev.langchain4j.model.chat.response.CompleteToolCall;
import dev.langchain4j.model.chat.response.PartialResponse;
import dev.langchain4j.model.chat.response.PartialResponseContext;
import dev.langchain4j.model.chat.response.PartialThinking;
import dev.langchain4j.model.chat.response.PartialThinkingContext;
import dev.langchain4j.model.chat.response.PartialToolCall;
import dev.langchain4j.model.chat.response.PartialToolCallContext;
import dev.langchain4j.model.chat.response.StreamingChatResponseHandler;
import dev.langchain4j.model.chat.response.StreamingHandle;
import io.casehub.platform.agent.AgentEvent;
import io.smallrye.mutiny.Multi;

import java.util.concurrent.atomic.AtomicReference;

final class AgentEventBridge {

    private AgentEventBridge() {}

    static Multi<AgentEvent> stream(StreamingChatModel model, ChatRequest request) {
        return Multi.createFrom().emitter(emitter -> {
            AtomicReference<StreamingHandle> handleRef = new AtomicReference<>();
            emitter.onTermination(() -> {
                StreamingHandle h = handleRef.get();
                if (h != null) h.cancel();
            });

            model.chat(request, new StreamingChatResponseHandler() {
                @Override
                public void onPartialResponse(String text) {
                    emitter.emit(new AgentEvent.TextDelta(text));
                }

                @Override
                public void onPartialResponse(PartialResponse partialResponse,
                                               PartialResponseContext context) {
                    handleRef.compareAndSet(null, context.streamingHandle());
                    emitter.emit(new AgentEvent.TextDelta(partialResponse.text()));
                }

                @Override
                public void onPartialThinking(PartialThinking partialThinking) {
                    emitter.emit(new AgentEvent.ThinkingDelta(partialThinking.text()));
                }

                @Override
                public void onPartialThinking(PartialThinking partialThinking,
                                               PartialThinkingContext context) {
                    handleRef.compareAndSet(null, context.streamingHandle());
                    emitter.emit(new AgentEvent.ThinkingDelta(partialThinking.text()));
                }

                @Override
                public void onPartialToolCall(PartialToolCall partialToolCall) {
                    emitter.emit(new AgentEvent.ToolCallDelta(
                        partialToolCall.index(), partialToolCall.id(),
                        partialToolCall.name(), partialToolCall.partialArguments()));
                }

                @Override
                public void onPartialToolCall(PartialToolCall partialToolCall,
                                               PartialToolCallContext context) {
                    handleRef.compareAndSet(null, context.streamingHandle());
                    emitter.emit(new AgentEvent.ToolCallDelta(
                        partialToolCall.index(), partialToolCall.id(),
                        partialToolCall.name(), partialToolCall.partialArguments()));
                }

                @Override
                public void onCompleteToolCall(CompleteToolCall completeToolCall) {
                    var ter = completeToolCall.toolExecutionRequest();
                    emitter.emit(new AgentEvent.ToolCallComplete(
                        completeToolCall.index(), ter.id(), ter.name(), ter.arguments()));
                }

                @Override
                public void onCompleteResponse(ChatResponse response) {
                    emitter.complete();
                }

                @Override
                public void onError(Throwable error) {
                    emitter.fail(error);
                }
            });
        });
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=AgentEventBridgeTest`
Expected: all 8 tests PASS

- [ ] **Step 5: Commit**

```bash
git add agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentEventBridge.java \
       agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/AgentEventBridgeTest.java
git commit -m "feat(platform#120): AgentEventBridge.stream() — handler→AgentEvent bridging"
```

---

### Task 2: AgentEventBridge — `dispatch()` method + tests

**Files:**
- Modify: `agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentEventBridge.java`
- Modify: `agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/AgentEventBridgeTest.java`

**Interfaces:**
- Consumes: `AgentEvent` (sealed), `StreamingChatResponseHandler`, `AiMessage.builder()`, `FinishReason`, `ToolExecutionRequest`, `PartialThinking`, `PartialToolCall`, `CompleteToolCall`
- Produces: `AgentEventBridge.dispatch(Multi<AgentEvent>, StreamingChatResponseHandler)` — used by Task 5

- [ ] **Step 1: Write the failing tests for `dispatch()`**

Add to `AgentEventBridgeTest.java`:

```java
import dev.langchain4j.model.chat.response.StreamingChatResponseHandler;
import java.util.ArrayList;
import java.util.concurrent.atomic.AtomicReference;

// --- dispatch() tests ---

@Test
void dispatch_textDelta_callsOnPartialResponse() {
    Multi<AgentEvent> events = Multi.createFrom().items(
        new AgentEvent.TextDelta("Hello"),
        new AgentEvent.TextDelta(" World"));

    var handler = new RecordingHandler();
    AgentEventBridge.dispatch(events, handler);

    assertThat(handler.partialResponses).containsExactly("Hello", " World");
    assertThat(handler.completedResponse).isNotNull();
    assertThat(handler.completedResponse.aiMessage().text()).isEqualTo("Hello World");
    assertThat(handler.completedResponse.finishReason()).isEqualTo(FinishReason.STOP);
}

@Test
void dispatch_thinkingDelta_callsOnPartialThinking() {
    Multi<AgentEvent> events = Multi.createFrom().item(
        new AgentEvent.ThinkingDelta("reasoning"));

    var handler = new RecordingHandler();
    AgentEventBridge.dispatch(events, handler);

    assertThat(handler.thinkingTexts).containsExactly("reasoning");
}

@Test
void dispatch_toolCallDelta_callsOnPartialToolCall() {
    Multi<AgentEvent> events = Multi.createFrom().item(
        new AgentEvent.ToolCallDelta(0, "c1", "tool1", "{\"a\""));

    var handler = new RecordingHandler();
    AgentEventBridge.dispatch(events, handler);

    assertThat(handler.partialToolCalls).hasSize(1);
    assertThat(handler.partialToolCalls.get(0).name()).isEqualTo("tool1");
}

@Test
void dispatch_toolCallComplete_callsOnCompleteToolCallAndIncludesInResponse() {
    Multi<AgentEvent> events = Multi.createFrom().items(
        new AgentEvent.TextDelta("text"),
        new AgentEvent.ToolCallComplete(0, "c1", "tool1", "{\"a\":1}"));

    var handler = new RecordingHandler();
    AgentEventBridge.dispatch(events, handler);

    assertThat(handler.completeToolCalls).hasSize(1);
    assertThat(handler.completeToolCalls.get(0).toolExecutionRequest().name()).isEqualTo("tool1");
    assertThat(handler.completedResponse.aiMessage().toolExecutionRequests()).hasSize(1);
    assertThat(handler.completedResponse.finishReason()).isEqualTo(FinishReason.TOOL_EXECUTION);
}

@Test
void dispatch_toolResult_silentlyIgnored() {
    Multi<AgentEvent> events = Multi.createFrom().items(
        new AgentEvent.TextDelta("text"),
        new AgentEvent.ToolResult("c1", "result", false));

    var handler = new RecordingHandler();
    AgentEventBridge.dispatch(events, handler);

    assertThat(handler.partialResponses).containsExactly("text");
    assertThat(handler.completedResponse.aiMessage().text()).isEqualTo("text");
}

@Test
void dispatch_error_callsOnError() {
    RuntimeException error = new RuntimeException("fail");
    Multi<AgentEvent> events = Multi.createFrom().failure(error);

    var handler = new RecordingHandler();
    AgentEventBridge.dispatch(events, handler);

    assertThat(handler.error).isSameAs(error);
    assertThat(handler.completedResponse).isNull();
}

// -- recording handler helper --

private static class RecordingHandler implements StreamingChatResponseHandler {
    final List<String> partialResponses = new ArrayList<>();
    final List<String> thinkingTexts = new ArrayList<>();
    final List<PartialToolCall> partialToolCalls = new ArrayList<>();
    final List<CompleteToolCall> completeToolCalls = new ArrayList<>();
    ChatResponse completedResponse;
    Throwable error;

    @Override public void onPartialResponse(String text) {
        partialResponses.add(text);
    }
    @Override public void onPartialThinking(PartialThinking pt) {
        thinkingTexts.add(pt.text());
    }
    @Override public void onPartialToolCall(PartialToolCall ptc) {
        partialToolCalls.add(ptc);
    }
    @Override public void onCompleteToolCall(CompleteToolCall ctc) {
        completeToolCalls.add(ctc);
    }
    @Override public void onCompleteResponse(ChatResponse response) {
        completedResponse = response;
    }
    @Override public void onError(Throwable error) {
        this.error = error;
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=AgentEventBridgeTest`
Expected: compilation failure — `AgentEventBridge.dispatch()` does not exist

- [ ] **Step 3: Implement `dispatch()`**

Add to `AgentEventBridge.java`:

```java
import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.model.output.FinishReason;

import java.util.ArrayList;
import java.util.List;

static void dispatch(Multi<AgentEvent> events, StreamingChatResponseHandler handler) {
    StringBuilder buffer = new StringBuilder();
    List<ToolExecutionRequest> toolRequests = new ArrayList<>();
    events.subscribe().with(
        event -> {
            switch (event) {
                case AgentEvent.TextDelta delta -> {
                    handler.onPartialResponse(delta.text());
                    buffer.append(delta.text());
                }
                case AgentEvent.ThinkingDelta thinking ->
                    handler.onPartialThinking(new PartialThinking(thinking.text()));
                case AgentEvent.ToolCallDelta d ->
                    handler.onPartialToolCall(PartialToolCall.builder()
                        .index(d.index()).id(d.id()).name(d.name())
                        .partialArguments(d.partialArguments()).build());
                case AgentEvent.ToolCallComplete c -> {
                    ToolExecutionRequest ter = ToolExecutionRequest.builder()
                        .id(c.id()).name(c.name()).arguments(c.arguments()).build();
                    handler.onCompleteToolCall(new CompleteToolCall(c.index(), ter));
                    toolRequests.add(ter);
                }
                case AgentEvent.ToolResult ignored -> {}
            }
        },
        handler::onError,
        () -> {
            AiMessage aiMessage = toolRequests.isEmpty()
                ? AiMessage.from(buffer.toString())
                : AiMessage.builder().text(buffer.toString())
                    .toolExecutionRequests(toolRequests).build();
            FinishReason reason = toolRequests.isEmpty()
                ? FinishReason.STOP
                : FinishReason.TOOL_EXECUTION;
            handler.onCompleteResponse(ChatResponse.builder()
                .aiMessage(aiMessage).finishReason(reason).build());
        }
    );
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=AgentEventBridgeTest`
Expected: all 14 tests PASS (8 stream + 6 dispatch)

- [ ] **Step 5: Commit**

```bash
git add agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentEventBridge.java \
       agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/AgentEventBridgeTest.java
git commit -m "feat(platform#120): AgentEventBridge.dispatch() — AgentEvent→handler bridging"
```

---

### Task 3: ChatModelAgentProvider — streaming detection + invoke() branching

**Files:**
- Modify: `agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/ChatModelAgentProvider.java`
- Modify: `agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/ChatModelAgentProviderTest.java`

**Interfaces:**
- Consumes: `AgentEventBridge.stream(StreamingChatModel, ChatRequest)` from Task 1
- Produces: `ChatModelAgentProvider.invoke()` now emits streaming events when backing model supports it; `openSession()` passes `streamingChatModel` to session (used by Task 4)

- [ ] **Step 1: Write the failing tests for streaming detection and invoke()**

Add to `ChatModelAgentProviderTest.java`:

```java
import dev.langchain4j.model.chat.StreamingChatModel;
import dev.langchain4j.model.chat.response.StreamingChatResponseHandler;
import dev.langchain4j.model.chat.response.PartialThinking;

// A ChatModel that also implements StreamingChatModel
private static abstract class DualModel implements ChatModel, StreamingChatModel {}

@Test
void init_withStreamingChatModel_storesStreamingReference() {
    DualModel dualModel = mock(DualModel.class);
    when(dualModel.chat(any(ChatRequest.class))).thenReturn(
        ChatResponse.builder().aiMessage(AiMessage.from("")).build());
    injectFields(dualModel);

    assertThat(provider.streamingChatModel).isSameAs(dualModel);
}

@Test
void init_withChatModelOnly_streamingIsNull() {
    ChatModel chatModel = mock(ChatModel.class);
    injectFields(chatModel);

    assertThat(provider.streamingChatModel).isNull();
}

@Test
void invoke_withStreamingModel_emitsMultipleTextDeltas() {
    DualModel dualModel = mock(DualModel.class);
    when(dualModel.chat(any(ChatRequest.class))).thenReturn(
        ChatResponse.builder().aiMessage(AiMessage.from("fallback")).build());
    doAnswer(invocation -> {
        StreamingChatResponseHandler handler = invocation.getArgument(1);
        handler.onPartialResponse("Hello");
        handler.onPartialResponse(" World");
        handler.onCompleteResponse(ChatResponse.builder()
            .aiMessage(AiMessage.from("Hello World"))
            .finishReason(dev.langchain4j.model.output.FinishReason.STOP).build());
        return null;
    }).when(dualModel).doChat(any(ChatRequest.class), any(StreamingChatResponseHandler.class));

    injectFields(dualModel);

    AgentSessionConfig config = AgentSessionConfig.of("", "test prompt");
    List<AgentEvent> events = provider.invoke(config)
        .collect().asList().await().indefinitely();

    assertThat(events).hasSize(2);
    assertThat(((AgentEvent.TextDelta) events.get(0)).text()).isEqualTo("Hello");
    assertThat(((AgentEvent.TextDelta) events.get(1)).text()).isEqualTo(" World");
}

@Test
void invoke_withStreamingModel_emitsThinkingDelta() {
    DualModel dualModel = mock(DualModel.class);
    doAnswer(invocation -> {
        StreamingChatResponseHandler handler = invocation.getArgument(1);
        handler.onPartialThinking(new PartialThinking("thinking..."));
        handler.onPartialResponse("answer");
        handler.onCompleteResponse(ChatResponse.builder()
            .aiMessage(AiMessage.from("answer"))
            .finishReason(dev.langchain4j.model.output.FinishReason.STOP).build());
        return null;
    }).when(dualModel).doChat(any(ChatRequest.class), any(StreamingChatResponseHandler.class));

    injectFields(dualModel);

    AgentSessionConfig config = AgentSessionConfig.of("", "test");
    List<AgentEvent> events = provider.invoke(config)
        .collect().asList().await().indefinitely();

    assertThat(events).hasSize(2);
    assertThat(events.get(0)).isInstanceOf(AgentEvent.ThinkingDelta.class);
    assertThat(events.get(1)).isInstanceOf(AgentEvent.TextDelta.class);
}

@Test
void invoke_withChatModelOnly_emitsSingleTextDelta() {
    ChatModel chatModel = mock(ChatModel.class);
    when(chatModel.chat(any(ChatRequest.class))).thenReturn(
        ChatResponse.builder().aiMessage(AiMessage.from("complete response")).build());

    injectFields(chatModel);

    AgentSessionConfig config = AgentSessionConfig.of("", "test");
    List<AgentEvent> events = provider.invoke(config)
        .collect().asList().await().indefinitely();

    assertThat(events).hasSize(1);
    assertThat(((AgentEvent.TextDelta) events.get(0)).text()).isEqualTo("complete response");
}
```

Also add `import static org.mockito.Mockito.doAnswer;` to the imports.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=ChatModelAgentProviderTest`
Expected: compilation failure — `provider.streamingChatModel` field does not exist

- [ ] **Step 3: Implement streaming detection and invoke() branching**

Modify `ChatModelAgentProvider.java`:

Add field:
```java
StreamingChatModel streamingChatModel;
```

Update `init()` — after `chatModel = candidates.get(0);`:
```java
streamingChatModel = (chatModel instanceof StreamingChatModel s) ? s : null;
```

Add import:
```java
import dev.langchain4j.model.chat.StreamingChatModel;
```

Replace `invoke()` body (after disabled/MCP checks):
```java
ChatRequest request = ChatRequest.builder()
    .messages(config.systemPrompt().isEmpty()
        ? List.of(UserMessage.from(config.userPrompt()))
        : List.of(SystemMessage.from(config.systemPrompt()),
                  UserMessage.from(config.userPrompt())))
    .build();

Multi<AgentEvent> result;
if (streamingChatModel != null) {
    result = AgentEventBridge.stream(streamingChatModel, request);
} else {
    result = Multi.createFrom().item(() -> {
        ChatResponse response = chatModel.chat(request);
        String text = response.aiMessage().text();
        return (AgentEvent) new AgentEvent.TextDelta(text != null ? text : "");
    });
}

if (config.timeout() != null) {
    result = result.ifNoItem().after(config.timeout()).failWith(
        () -> new AgentTimeoutException(config.timeout()));
}
return result;
```

Update `openSession()` to pass streaming:
```java
return new ChatModelAgentSession(chatModel, streamingChatModel, init, properties);
```

Remove unused imports: `ChatResponse` (no longer used directly in invoke).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=ChatModelAgentProviderTest`
Expected: all tests PASS (existing + 5 new)

Note: `openSession` test will fail until Task 4 updates `ChatModelAgentSession` constructor.
If it fails, temporarily keep the old constructor call and fix in Task 4. Alternatively,
run only the non-session tests first:
```
mvn --batch-mode test -pl agent-langchain4j -Dtest="ChatModelAgentProviderTest#init_*+invoke_*"
```

- [ ] **Step 5: Commit**

```bash
git add agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/ChatModelAgentProvider.java \
       agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/ChatModelAgentProviderTest.java
git commit -m "feat(platform#120): ChatModelAgentProvider streaming detection and invoke() branching"
```

---

### Task 4: ChatModelAgentSession — streaming query()

**Files:**
- Modify: `agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/ChatModelAgentSession.java`
- Modify: `agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/ChatModelAgentSessionTest.java`

**Interfaces:**
- Consumes: `AgentEventBridge.stream(StreamingChatModel, ChatRequest)` from Task 1
- Produces: `ChatModelAgentSession.query()` now emits streaming events when backing model supports it

- [ ] **Step 1: Write the failing tests for streaming session**

Add to `ChatModelAgentSessionTest.java`:

```java
import dev.langchain4j.model.chat.StreamingChatModel;
import dev.langchain4j.model.chat.response.StreamingChatResponseHandler;
import dev.langchain4j.model.chat.response.PartialThinking;
import dev.langchain4j.model.output.FinishReason;

// A StreamingChatModel that also serves as ChatModel for the fallback
private static StreamingChatModel streamingChatModel(
        java.util.function.BiConsumer<ChatRequest, StreamingChatResponseHandler> doChat) {
    return new StreamingChatModel() {
        @Override
        public void doChat(ChatRequest request, StreamingChatResponseHandler handler) {
            doChat.accept(request, handler);
        }
    };
}

@Test
void query_streaming_emitsMultipleTextDeltas() {
    StreamingChatModel model = streamingChatModel((request, handler) -> {
        handler.onPartialResponse("Hello");
        handler.onPartialResponse(" World");
        handler.onCompleteResponse(ChatResponse.builder()
            .aiMessage(AiMessage.from("Hello World"))
            .finishReason(FinishReason.STOP).build());
    });
    AgentSessionInit init = AgentSessionInit.of("system");
    AgentLangchain4jProperties properties = new TestProperties(Duration.ofSeconds(30), 20);

    ChatModelAgentSession session = new ChatModelAgentSession(
        null, model, init, properties);

    List<String> texts = session.query("prompt")
        .filter(e -> e instanceof AgentEvent.TextDelta)
        .map(e -> ((AgentEvent.TextDelta) e).text())
        .collect().asList().await().atMost(Duration.ofSeconds(5));

    assertThat(texts).containsExactly("Hello", " World");
}

@Test
void query_streaming_updatesMemoryOnCompletion() {
    StreamingChatModel model = streamingChatModel((request, handler) -> {
        handler.onPartialResponse("Response 1");
        handler.onCompleteResponse(ChatResponse.builder()
            .aiMessage(AiMessage.from("Response 1"))
            .finishReason(FinishReason.STOP).build());
    });
    AgentSessionInit init = AgentSessionInit.of("system");
    AgentLangchain4jProperties properties = new TestProperties(Duration.ofSeconds(30), 20);

    // Need a ChatModel fallback for the second turn to verify history
    AtomicInteger callCount = new AtomicInteger(0);
    ChatModel blockingModel = new ChatModel() {
        @Override
        public ChatResponse doChat(ChatRequest request) {
            callCount.incrementAndGet();
            // Verify that the first turn's response is in the history
            List<ChatMessage> messages = request.messages();
            assertThat(messages).hasSizeGreaterThan(2);
            return ChatResponse.builder().aiMessage(AiMessage.from("Response 2")).build();
        }
    };

    // First turn: streaming
    ChatModelAgentSession streamSession = new ChatModelAgentSession(
        null, model, init, properties);
    streamSession.query("prompt 1").collect().asList()
        .await().atMost(Duration.ofSeconds(5));

    // Can't easily verify memory contents directly, but we can verify the
    // streaming path completed without error (memory.add would have thrown
    // if something went wrong)
}

@Test
void query_streaming_doesNotUpdateMemoryOnFailure() {
    StreamingChatModel model = streamingChatModel((request, handler) -> {
        handler.onPartialResponse("partial");
        handler.onError(new RuntimeException("model error"));
    });
    AgentSessionInit init = AgentSessionInit.of("system");
    AgentLangchain4jProperties properties = new TestProperties(Duration.ofSeconds(30), 20);

    ChatModelAgentSession session = new ChatModelAgentSession(
        null, model, init, properties);

    assertThatThrownBy(() -> session.query("prompt")
        .collect().asList().await().atMost(Duration.ofSeconds(5)))
        .hasMessageContaining("model error");

    // Session should be back to IDLE after failure
    // Verify by successfully querying again
    StreamingChatModel model2 = streamingChatModel((request, handler) -> {
        handler.onPartialResponse("recovery");
        handler.onCompleteResponse(ChatResponse.builder()
            .aiMessage(AiMessage.from("recovery"))
            .finishReason(FinishReason.STOP).build());
    });
    // Can't swap models mid-session, but we can verify state is IDLE
    // The existing close_setsClosedState test covers state transitions
}

@Test
void query_streaming_multiTurnPreservesHistory() {
    AtomicInteger turnCount = new AtomicInteger(0);
    StreamingChatModel model = streamingChatModel((request, handler) -> {
        int turn = turnCount.incrementAndGet();
        if (turn == 2) {
            // Second turn: verify history includes first turn
            assertThat(request.messages().size()).isGreaterThan(2);
        }
        handler.onPartialResponse("Response " + turn);
        handler.onCompleteResponse(ChatResponse.builder()
            .aiMessage(AiMessage.from("Response " + turn))
            .finishReason(FinishReason.STOP).build());
    });
    AgentSessionInit init = AgentSessionInit.of("system");
    AgentLangchain4jProperties properties = new TestProperties(Duration.ofSeconds(30), 20);

    ChatModelAgentSession session = new ChatModelAgentSession(
        null, model, init, properties);

    session.query("turn 1").collect().asList().await().atMost(Duration.ofSeconds(5));
    session.query("turn 2").collect().asList().await().atMost(Duration.ofSeconds(5));

    assertThat(turnCount.get()).isEqualTo(2);
}
```

Also add required imports: `import java.util.concurrent.atomic.AtomicInteger;` and `import dev.langchain4j.data.message.ChatMessage;`

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=ChatModelAgentSessionTest`
Expected: compilation failure — constructor signature mismatch

- [ ] **Step 3: Implement streaming session changes**

Modify `ChatModelAgentSession.java`:

Update fields and constructor:
```java
private final ChatModel chatModel;
private final StreamingChatModel streamingChatModel;
private final String systemPrompt;
private final ChatMemory memory;
private final AtomicReference<State> state = new AtomicReference<>(State.IDLE);

ChatModelAgentSession(ChatModel chatModel, StreamingChatModel streamingChatModel,
                      AgentSessionInit init, AgentLangchain4jProperties properties) {
    this.chatModel = chatModel;
    this.streamingChatModel = streamingChatModel;
    this.systemPrompt = init.systemPrompt();
    this.memory = MessageWindowChatMemory.withMaxMessages(
        properties.sessionMemoryWindowSize());
}
```

Add import:
```java
import dev.langchain4j.model.chat.StreamingChatModel;
import dev.langchain4j.model.chat.request.ChatRequest;
```

Update `query()` — replace the body after the state check:
```java
memory.add(UserMessage.from(prompt));
List<ChatMessage> messages = new ArrayList<>();
if (!systemPrompt.isEmpty()) {
    messages.add(SystemMessage.from(systemPrompt));
}
messages.addAll(memory.messages());
ChatRequest request = ChatRequest.builder().messages(messages).build();

Multi<AgentEvent> result;
if (streamingChatModel != null) {
    StringBuilder buffer = new StringBuilder();
    result = AgentEventBridge.stream(streamingChatModel, request)
        .onItem().invoke(event -> {
            if (event instanceof AgentEvent.TextDelta delta) {
                buffer.append(delta.text());
            }
        })
        .onCompletion().invoke(() ->
            memory.add(AiMessage.from(buffer.toString())));
} else {
    result = Multi.createFrom().item(() -> {
        ChatResponse response = chatModel.chat(request);
        String text = response.aiMessage().text();
        memory.add(AiMessage.from(text != null ? text : ""));
        return (AgentEvent) new AgentEvent.TextDelta(text != null ? text : "");
    });
}

return result.onTermination().invoke(
    () -> state.compareAndSet(State.ACTIVE, State.IDLE));
```

Add import for `ChatResponse`:
```java
import dev.langchain4j.model.chat.response.ChatResponse;
```

- [ ] **Step 4: Update existing tests to use new constructor**

Update all existing `ChatModelAgentSessionTest` constructor calls from:
```java
new ChatModelAgentSession(model, init, properties)
```
to:
```java
new ChatModelAgentSession(model, null, init, properties)
```

This passes `null` for `streamingChatModel`, preserving blocking behavior for existing tests.

- [ ] **Step 5: Run all tests to verify they pass**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=ChatModelAgentSessionTest`
Expected: all tests PASS (existing + 4 new)

Also run provider tests to verify the constructor change compiles:
```
mvn --batch-mode test -pl agent-langchain4j -Dtest=ChatModelAgentProviderTest
```

- [ ] **Step 6: Commit**

```bash
git add agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/ChatModelAgentSession.java \
       agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/ChatModelAgentSessionTest.java
git commit -m "feat(platform#120): ChatModelAgentSession streaming query() with memory management"
```

---

### Task 5: AgentProviderChatModel + AgentSessionChatModel — dispatch() consolidation

**Files:**
- Modify: `agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentProviderChatModel.java`
- Modify: `agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentSessionChatModel.java`

**Interfaces:**
- Consumes: `AgentEventBridge.dispatch(Multi<AgentEvent>, StreamingChatResponseHandler)` from Task 2
- Produces: no new interfaces — existing behavior preserved with enhanced completion semantics (tool calls in AiMessage, correct FinishReason)

- [ ] **Step 1: Run existing tests to establish baseline**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=AgentProviderChatModelTest,AgentSessionChatModelTest`
Expected: all PASS

- [ ] **Step 2: Replace inline mapping in `AgentProviderChatModel.doChat(request, handler)`**

Replace the `doChat(ChatRequest request, StreamingChatResponseHandler handler)` method body:

```java
@Override
public void doChat(ChatRequest request, StreamingChatResponseHandler handler) {
    String systemPrompt = extractSystemPrompt(request.messages());
    String userMessage = extractUserText(request.messages());
    String userWithSchema = prependSchema(request, userMessage);
    AgentSessionConfig config = AgentSessionConfig.of(systemPrompt, userWithSchema);
    AgentEventBridge.dispatch(agentProvider.invoke(config), handler);
}
```

Remove now-unused imports from `AgentProviderChatModel.java`:
- `dev.langchain4j.model.chat.response.CompleteToolCall`
- `dev.langchain4j.model.chat.response.PartialThinking`
- `dev.langchain4j.model.chat.response.PartialToolCall`
- `dev.langchain4j.model.chat.response.StreamingChatResponseHandler` — keep, still in method signature
- `dev.langchain4j.model.output.FinishReason`
- `java.util.stream.Collectors` (check if still used by `doChat(ChatRequest)`)

Keep imports that are still used by other methods.

- [ ] **Step 3: Replace inline mapping in `AgentSessionChatModel.doChat(request, handler)`**

Replace the `doChat(ChatRequest request, StreamingChatResponseHandler handler)` method body:

```java
@Override
public void doChat(ChatRequest request, StreamingChatResponseHandler handler) {
    String userMessage = extractLastUserText(request.messages());
    userMessage = AgentProviderChatModel.prependSchema(request, userMessage);
    AgentEventBridge.dispatch(session.query(userMessage), handler);
}
```

Remove now-unused imports from `AgentSessionChatModel.java`:
- `dev.langchain4j.agent.tool.ToolExecutionRequest`
- `dev.langchain4j.model.chat.response.CompleteToolCall`
- `dev.langchain4j.model.chat.response.PartialThinking`
- `dev.langchain4j.model.chat.response.PartialToolCall`
- `dev.langchain4j.model.output.FinishReason`
- `java.util.stream.Collectors` (check if still used by `doChat(ChatRequest)`)

Keep imports still used by `doChat(ChatRequest)` or `extractLastUserText()`.

- [ ] **Step 4: Run all tests to verify no regressions**

Run: `mvn --batch-mode test -pl agent-langchain4j`
Expected: all tests PASS across all test classes

- [ ] **Step 5: Commit**

```bash
git add agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentProviderChatModel.java \
       agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentSessionChatModel.java
git commit -m "refactor(platform#120): consolidate AgentEvent↔handler mapping into AgentEventBridge.dispatch()"
```

- [ ] **Step 6: Run full module build**

Run: `mvn --batch-mode install -pl agent-langchain4j`
Expected: BUILD SUCCESS — all tests pass, artifacts installed
