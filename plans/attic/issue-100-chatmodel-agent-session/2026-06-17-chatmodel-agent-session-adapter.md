# ChatModel Adapter Backed by AgentSession — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `agent-claude-langchain4j/` — two classes bridging LangChain4j's `ChatModel`/`StreamingChatModel` interfaces to the platform's `AgentSession` SPI, with a stateless per-call adapter (`ClaudeAgentChatModel`) and a caller-managed multi-turn adapter (`AgentSessionChatModel`).

**Architecture:** Two separate classes with single responsibilities — `ClaudeAgentChatModel` is a CDI `@Alternative @Priority(10) @ApplicationScoped` bean that opens a fresh `AgentSession` per call; `AgentSessionChatModel` is a plain wrapper around a caller-supplied `AgentSession`. Both implement `ChatModel` and `StreamingChatModel`. Shared logic lives as private static helpers on each class — no shared base class or helper class.

**Tech Stack:** Java 21, Quarkus ARC, Mutiny, LangChain4j Core 1.14.1, JUnit 5, Mockito, AssertJ, Awaitility

**Spec:** `docs/superpowers/specs/2026-06-16-chatmodel-agent-session-design.md`

---

## File Map

| Action | Path | Purpose |
|--------|------|---------|
| Modify | `pom.xml` | Add `langchain4j.version` property, `langchain4j-core` to dependencyManagement, new module |
| Create | `agent-claude-langchain4j/pom.xml` | Module POM |
| Create | `agent-claude-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/ClaudeAgentLangchain4jProperties.java` | Config interface |
| Create | `agent-claude-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentSessionChatModel.java` | Plain multi-turn wrapper |
| Create | `agent-claude-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/ClaudeAgentChatModel.java` | CDI stateless adapter |
| Create | `agent-claude-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/AgentSessionChatModelTest.java` | Tests for the multi-turn wrapper |
| Create | `agent-claude-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/ClaudeAgentChatModelTest.java` | Tests for the stateless adapter |
| Modify | `CLAUDE.md` | Add `agent-claude-langchain4j/` to the module table |
| Modify | `../parent/docs/PLATFORM.md` | Add module to casehub-platform repo row |

---

## Task 1: Module scaffold

**Files:**
- Modify: `pom.xml`
- Create: `agent-claude-langchain4j/pom.xml`

- [ ] **Step 1.1: Add `langchain4j.version` and `langchain4j-core` to the platform parent POM**

In `pom.xml`, add `<langchain4j.version>1.14.1</langchain4j.version>` inside `<properties>`:
```xml
<properties>
    <maven.compiler.release>21</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    <quarkus.platform.version>3.32.2</quarkus.platform.version>
    <compiler-plugin.version>3.15.0</compiler-plugin.version>
    <jandex-maven-plugin.version>3.3.1</jandex-maven-plugin.version>
    <assertj.version>3.27.3</assertj.version>
    <langchain4j.version>1.14.1</langchain4j.version>
</properties>
```

In `pom.xml`, add `langchain4j-core` inside `<dependencyManagement><dependencies>`:
```xml
<dependency>
    <groupId>dev.langchain4j</groupId>
    <artifactId>langchain4j-core</artifactId>
    <version>${langchain4j.version}</version>
</dependency>
```

In `pom.xml`, add `<module>agent-claude-langchain4j</module>` after `<module>agent-claude</module>` in `<modules>`.

- [ ] **Step 1.2: Create `agent-claude-langchain4j/pom.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-agent-claude-langchain4j</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Agent Claude LangChain4j</name>
    <description>ChatModel + StreamingChatModel adapters backed by AgentSession.
        ClaudeAgentChatModel: @Alternative @Priority(10) @ApplicationScoped, fresh session per call.
        AgentSessionChatModel: plain wrapper around a caller-supplied AgentSession.
        No quarkus:build goal — library module.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-agent-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>dev.langchain4j</groupId>
            <artifactId>langchain4j-core</artifactId>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-arc</artifactId>
        </dependency>
        <!-- Test -->
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-junit5</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.mockito</groupId>
            <artifactId>mockito-core</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.awaitility</groupId>
            <artifactId>awaitility</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.smallrye</groupId>
                <artifactId>jandex-maven-plugin</artifactId>
                <version>${jandex-maven-plugin.version}</version>
                <executions>
                    <execution>
                        <id>make-index</id>
                        <goals><goal>jandex</goal></goals>
                    </execution>
                </executions>
            </plugin>
            <!-- generate-code and generate-code-tests only — no build goal (library module) -->
            <plugin>
                <groupId>io.quarkus</groupId>
                <artifactId>quarkus-maven-plugin</artifactId>
                <version>${quarkus.platform.version}</version>
                <extensions>true</extensions>
                <executions>
                    <execution>
                        <goals>
                            <goal>generate-code</goal>
                            <goal>generate-code-tests</goal>
                        </goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 1.3: Verify the module compiles (no sources yet)**

```bash
mvn --batch-mode install -pl agent-claude-langchain4j -am -DskipTests
```

Expected: `BUILD SUCCESS`. The module compiles as an empty JAR.

- [ ] **Step 1.4: Commit scaffold**

```bash
git add pom.xml agent-claude-langchain4j/
git commit -m "feat(platform#100): scaffold agent-claude-langchain4j module"
```

---

## Task 2: Config interface and `ClaudeAgentLangchain4jProperties`

**Files:**
- Create: `agent-claude-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/ClaudeAgentLangchain4jProperties.java`

- [ ] **Step 2.1: Create the config interface**

```java
package io.casehub.platform.agent.langchain4j;

import io.smallrye.config.ConfigMapping;
import io.smallrye.config.WithDefault;
import java.time.Duration;

@ConfigMapping(prefix = "casehub.platform.agent.langchain4j")
public interface ClaudeAgentLangchain4jProperties {

    @WithDefault("PT30S")
    Duration closeTimeout();
}
```

- [ ] **Step 2.2: Compile**

```bash
mvn --batch-mode install -pl agent-claude-langchain4j -am -DskipTests
```

Expected: `BUILD SUCCESS`.

- [ ] **Step 2.3: Commit**

```bash
git add agent-claude-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/ClaudeAgentLangchain4jProperties.java
git commit -m "feat(platform#100): ClaudeAgentLangchain4jProperties config interface"
```

---

## Task 3: `AgentSessionChatModel` — core implementation

**Files:**
- Create: `agent-claude-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentSessionChatModel.java`
- Create: `agent-claude-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/AgentSessionChatModelTest.java`

Note: `AgentSessionChatModel` has no CDI — plain class, two private static helpers (`extractLastUserText`, `validateNoJsonFormat`), plus `doChat()` blocking, `doChat()` streaming, `wrap()` factory, and required interface overrides. All tests use `fakeSession()` defined once as a helper.

- [ ] **Step 3.1: Write the test file with the fake session helper and basic contract tests**

```java
package io.casehub.platform.agent.langchain4j;

import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.ChatMessage;
import dev.langchain4j.data.message.SystemMessage;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.exception.UnsupportedFeatureException;
import dev.langchain4j.model.ModelProvider;
import dev.langchain4j.model.chat.Capability;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.request.ResponseFormat;
import dev.langchain4j.model.chat.request.ResponseFormatType;
import dev.langchain4j.model.chat.response.ChatResponse;
import dev.langchain4j.model.chat.response.StreamingChatResponseHandler;
import dev.langchain4j.model.output.FinishReason;
import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentSession;
import io.mutiny.Multi;
import io.mutiny.Uni;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Function;

import static org.assertj.core.api.Assertions.*;
import static org.awaitility.Awaitility.*;

class AgentSessionChatModelTest {

    // ── Helpers ──────────────────────────────────────────────────────────────

    /** Creates a fake AgentSession backed by a turn factory.
     *  Respects the IDLE/ACTIVE/CLOSED state machine: throws synchronously for CLOSED or ACTIVE. */
    static AgentSession fakeSession(Function<String, Multi<AgentEvent>> turnFactory) {
        return new AgentSession() {
            private enum State { IDLE, ACTIVE, CLOSED }
            private final AtomicReference<State> state = new AtomicReference<>(State.IDLE);

            @Override
            public Multi<AgentEvent> query(String prompt) {
                if (!state.compareAndSet(State.IDLE, State.ACTIVE)) {
                    State cur = state.get();
                    throw new IllegalStateException(cur == State.CLOSED
                        ? "session is closed"
                        : "a turn is already active");
                }
                return turnFactory.apply(prompt)
                    .onTermination().invoke(() -> state.compareAndSet(State.ACTIVE, State.IDLE));
            }

            @Override
            public Uni<Void> interrupt() { return Uni.createFrom().voidItem(); }

            @Override
            public void close(Duration maxWait) { state.set(State.CLOSED); }
        };
    }

    /** Creates a Multi that emits the given strings as TextDelta events then completes. */
    static Multi<AgentEvent> textDeltas(String... texts) {
        List<AgentEvent> events = new ArrayList<>();
        for (String t : texts) events.add(new AgentEvent.TextDelta(t));
        return Multi.createFrom().iterable(events);
    }

    /** Creates a ChatRequest with a single UserMessage. */
    static ChatRequest single(String userText) {
        return ChatRequest.builder().messages(List.of(UserMessage.from(userText))).build();
    }

    // ── Contract tests ────────────────────────────────────────────────────────

    @Test
    void wrap_returnsConcreteType() {
        AgentSessionChatModel model = AgentSessionChatModel.wrap(
            fakeSession(__ -> Multi.createFrom().empty()));
        assertThat(model).isInstanceOf(AgentSessionChatModel.class);
    }

    @Test
    void provider_returnsANTHROPIC() {
        AgentSessionChatModel model = AgentSessionChatModel.wrap(
            fakeSession(__ -> Multi.createFrom().empty()));
        assertThat(model.provider()).isEqualTo(ModelProvider.ANTHROPIC);
    }

    @Test
    void supportedCapabilities_isEmpty() {
        AgentSessionChatModel model = AgentSessionChatModel.wrap(
            fakeSession(__ -> Multi.createFrom().empty()));
        assertThat(model.supportedCapabilities()).isEmpty();
    }

    @Test
    void listeners_returnsEmptyList() {
        AgentSessionChatModel model = AgentSessionChatModel.wrap(
            fakeSession(__ -> Multi.createFrom().empty()));
        assertThat(model.listeners()).isEmpty();
    }

    // ── Blocking doChat ───────────────────────────────────────────────────────

    @Test
    void doChat_blocking_happyPath_concatenatesDeltas() {
        AgentSessionChatModel model = AgentSessionChatModel.wrap(
            fakeSession(__ -> textDeltas("Hello", ", ", "world")));
        ChatResponse response = model.chat(single("hi"));
        assertThat(response.aiMessage().text()).isEqualTo("Hello, world");
        assertThat(response.finishReason()).isEqualTo(FinishReason.STOP);
    }

    @Test
    void doChat_blocking_singleDelta() {
        AgentSessionChatModel model = AgentSessionChatModel.wrap(
            fakeSession(__ -> textDeltas("single")));
        assertThat(model.chat(single("q")).aiMessage().text()).isEqualTo("single");
    }

    @Test
    void doChat_blocking_emptyResponse() {
        AgentSessionChatModel model = AgentSessionChatModel.wrap(
            fakeSession(__ -> Multi.createFrom().empty()));
        assertThat(model.chat(single("q")).aiMessage().text()).isEmpty();
    }

    @Test
    void doChat_blocking_closedSession_throwsSynchronouslyBeforeAwait() {
        AgentSession session = fakeSession(__ -> Multi.createFrom().empty());
        session.close();
        AgentSessionChatModel model = AgentSessionChatModel.wrap(session);
        // Throws from session.query() — await() is never reached
        assertThatThrownBy(() -> model.doChat(single("hi")))
            .isInstanceOf(IllegalStateException.class)
            .hasMessageContaining("session is closed");
    }

    @Test
    void doChat_blocking_multiTurn_sendsOnlyNewUserMessage() {
        List<String> received = new ArrayList<>();
        AgentSession session = new AgentSession() {
            private final AtomicReference<Boolean> active = new AtomicReference<>(false);
            @Override public Multi<AgentEvent> query(String p) {
                received.add(p);
                return Multi.createFrom().empty();
            }
            @Override public Uni<Void> interrupt() { return Uni.createFrom().voidItem(); }
            @Override public void close(Duration d) {}
        };
        AgentSessionChatModel model = AgentSessionChatModel.wrap(session);
        model.chat(single("first"));
        model.chat(single("second"));
        assertThat(received).containsExactly("first", "second");
    }

    // ── Validation ─────────────────────────────────────────────────────────────

    @Test
    void doChat_jsonFormat_throwsUnsupportedFeature() {
        AgentSessionChatModel model = AgentSessionChatModel.wrap(
            fakeSession(__ -> Multi.createFrom().empty()));
        ChatRequest request = ChatRequest.builder()
            .messages(List.of(UserMessage.from("hi")))
            .responseFormat(ResponseFormat.builder().type(ResponseFormatType.JSON).build())
            .build();
        assertThatThrownBy(() -> model.doChat(request))
            .isInstanceOf(UnsupportedFeatureException.class);
    }

    @Test
    void doChat_aiMessagePresent_throwsIllegalArgument() {
        AgentSessionChatModel model = AgentSessionChatModel.wrap(
            fakeSession(__ -> Multi.createFrom().empty()));
        ChatRequest request = ChatRequest.builder()
            .messages(List.of(UserMessage.from("hello"), AiMessage.from("reply"), UserMessage.from("bye")))
            .build();
        assertThatThrownBy(() -> model.doChat(request))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("AiMessage");
    }

    @Test
    void doChat_multipleUserMessages_throwsIllegalArgument() {
        AgentSessionChatModel model = AgentSessionChatModel.wrap(
            fakeSession(__ -> Multi.createFrom().empty()));
        ChatRequest request = ChatRequest.builder()
            .messages(List.of(UserMessage.from("first"), UserMessage.from("second")))
            .build();
        assertThatThrownBy(() -> model.doChat(request))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("exactly one UserMessage");
    }

    @Test
    void doChat_noUserMessage_throwsIllegalArgument() {
        AgentSessionChatModel model = AgentSessionChatModel.wrap(
            fakeSession(__ -> Multi.createFrom().empty()));
        ChatRequest request = ChatRequest.builder()
            .messages(List.of(SystemMessage.from("system only")))
            .build();
        assertThatThrownBy(() -> model.doChat(request))
            .isInstanceOf(IllegalArgumentException.class);
    }

    // ── Streaming doChat ──────────────────────────────────────────────────────

    @Test
    void doChat_streaming_happyPath() {
        AgentSessionChatModel model = AgentSessionChatModel.wrap(
            fakeSession(__ -> textDeltas("tok1", "tok2", "tok3")));

        List<String> partials = new ArrayList<>();
        ChatResponse[] completed = {null};

        model.chat(single("hi"), new StreamingChatResponseHandler() {
            @Override public void onPartialResponse(String t) { partials.add(t); }
            @Override public void onCompleteResponse(ChatResponse r) { completed[0] = r; }
            @Override public void onError(Throwable t) { throw new RuntimeException(t); }
        });

        await().untilAsserted(() -> assertThat(completed[0]).isNotNull());
        assertThat(partials).containsExactly("tok1", "tok2", "tok3");
        assertThat(completed[0].aiMessage().text()).isEqualTo("tok1tok2tok3");
        assertThat(completed[0].finishReason()).isEqualTo(FinishReason.STOP);
    }

    @Test
    void doChat_streaming_sessionNotClosed_afterCompletion() throws InterruptedException {
        AtomicBoolean closeCalled = new AtomicBoolean(false);
        AgentSession session = new AgentSession() {
            @Override public Multi<AgentEvent> query(String p) { return Multi.createFrom().empty(); }
            @Override public Uni<Void> interrupt() { return Uni.createFrom().voidItem(); }
            @Override public void close(Duration d) { closeCalled.set(true); }
        };
        AgentSessionChatModel model = AgentSessionChatModel.wrap(session);
        AtomicBoolean done = new AtomicBoolean(false);
        model.chat(single("hi"), new StreamingChatResponseHandler() {
            @Override public void onPartialResponse(String t) {}
            @Override public void onCompleteResponse(ChatResponse r) { done.set(true); }
            @Override public void onError(Throwable t) {}
        });
        await().until(done::get);
        // Adapter must never close a session it doesn't own
        assertThat(closeCalled.get()).isFalse();
    }

    @Test
    void doChat_streaming_closedSession_throwsSynchronously() {
        AgentSession session = fakeSession(__ -> Multi.createFrom().empty());
        session.close();
        AgentSessionChatModel model = AgentSessionChatModel.wrap(session);
        assertThatThrownBy(() ->
            model.doChat(single("hi"), new StreamingChatResponseHandler() {
                @Override public void onPartialResponse(String t) {}
                @Override public void onCompleteResponse(ChatResponse r) {}
                @Override public void onError(Throwable t) {}
            })
        ).isInstanceOf(IllegalStateException.class)
            .hasMessageContaining("session is closed");
    }

    @Test
    void doChat_streaming_alreadyActive_throwsSynchronously() {
        // Session that never completes (holds ACTIVE state)
        AgentSession session = new AgentSession() {
            private final AtomicReference<Boolean> active = new AtomicReference<>(false);
            @Override public Multi<AgentEvent> query(String p) {
                if (!active.compareAndSet(false, true)) {
                    throw new IllegalStateException("a turn is already active");
                }
                return Multi.createFrom().nothing(); // never completes
            }
            @Override public Uni<Void> interrupt() { return Uni.createFrom().voidItem(); }
            @Override public void close(Duration d) {}
        };
        AgentSessionChatModel model = AgentSessionChatModel.wrap(session);
        // Start a turn that never completes
        model.chat(single("first"), new StreamingChatResponseHandler() {
            @Override public void onPartialResponse(String t) {}
            @Override public void onCompleteResponse(ChatResponse r) {}
            @Override public void onError(Throwable t) {}
        });
        // Second call throws synchronously
        assertThatThrownBy(() ->
            model.doChat(single("second"), new StreamingChatResponseHandler() {
                @Override public void onPartialResponse(String t) {}
                @Override public void onCompleteResponse(ChatResponse r) {}
                @Override public void onError(Throwable t) {}
            })
        ).isInstanceOf(IllegalStateException.class)
            .hasMessageContaining("a turn is already active");
    }

    @Test
    void doChat_streaming_jsonFormat_throwsSynchronously() {
        AgentSessionChatModel model = AgentSessionChatModel.wrap(
            fakeSession(__ -> Multi.createFrom().empty()));
        ChatRequest request = ChatRequest.builder()
            .messages(List.of(UserMessage.from("hi")))
            .responseFormat(ResponseFormat.builder().type(ResponseFormatType.JSON).build())
            .build();
        assertThatThrownBy(() ->
            model.doChat(request, new StreamingChatResponseHandler() {
                @Override public void onPartialResponse(String t) {}
                @Override public void onCompleteResponse(ChatResponse r) {}
                @Override public void onError(Throwable t) {}
            })
        ).isInstanceOf(UnsupportedFeatureException.class);
    }

    @Test
    void doChat_streaming_aiMessagePresent_throwsSynchronously() {
        AgentSessionChatModel model = AgentSessionChatModel.wrap(
            fakeSession(__ -> Multi.createFrom().empty()));
        ChatRequest request = ChatRequest.builder()
            .messages(List.of(UserMessage.from("hi"), AiMessage.from("reply"), UserMessage.from("bye")))
            .build();
        assertThatThrownBy(() ->
            model.doChat(request, new StreamingChatResponseHandler() {
                @Override public void onPartialResponse(String t) {}
                @Override public void onCompleteResponse(ChatResponse r) {}
                @Override public void onError(Throwable t) {}
            })
        ).isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("AiMessage");
    }

    @Test
    void doChat_streaming_multipleUserMessages_throwsSynchronously() {
        AgentSessionChatModel model = AgentSessionChatModel.wrap(
            fakeSession(__ -> Multi.createFrom().empty()));
        ChatRequest request = ChatRequest.builder()
            .messages(List.of(UserMessage.from("first"), UserMessage.from("second")))
            .build();
        assertThatThrownBy(() ->
            model.doChat(request, new StreamingChatResponseHandler() {
                @Override public void onPartialResponse(String t) {}
                @Override public void onCompleteResponse(ChatResponse r) {}
                @Override public void onError(Throwable t) {}
            })
        ).isInstanceOf(IllegalArgumentException.class);
    }
}
```

- [ ] **Step 3.2: Run tests — expect compilation failure**

```bash
mvn --batch-mode test -pl agent-claude-langchain4j -am
```

Expected: COMPILATION FAILURE — `AgentSessionChatModel` does not exist yet.

- [ ] **Step 3.3: Implement `AgentSessionChatModel`**

```java
package io.casehub.platform.agent.langchain4j;

import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.ChatMessage;
import dev.langchain4j.data.message.SystemMessage;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.exception.UnsupportedFeatureException;
import dev.langchain4j.model.ModelProvider;
import dev.langchain4j.model.chat.Capability;
import dev.langchain4j.model.chat.ChatModel;
import dev.langchain4j.model.chat.StreamingChatModel;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.request.ResponseFormatType;
import dev.langchain4j.model.chat.response.ChatResponse;
import dev.langchain4j.model.chat.response.StreamingChatResponseHandler;
import dev.langchain4j.model.output.FinishReason;
import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentSession;

import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.stream.Collectors;

public final class AgentSessionChatModel implements ChatModel, StreamingChatModel {

    private final AgentSession session;

    public AgentSessionChatModel(AgentSession session) {
        this.session = Objects.requireNonNull(session, "session");
    }

    public static AgentSessionChatModel wrap(AgentSession session) {
        return new AgentSessionChatModel(session);
    }

    @Override
    public ModelProvider provider() {
        return ModelProvider.ANTHROPIC;
    }

    @Override
    public Set<Capability> supportedCapabilities() {
        return Set.of();
    }

    // listeners() inherits ChatModel default returning List.of() — v1 gap, telemetry disabled.

    @Override
    public ChatResponse doChat(ChatRequest request) {
        validateNoJsonFormat(request);
        String userMessage = extractLastUserText(request.messages());
        // session.query() throws IllegalStateException synchronously for CLOSED/ACTIVE state.
        // The filter is always true today (sealed interface, only TextDelta) — retained as
        // a forward-compatibility guard if AgentEvent is extended.
        String text = session.query(userMessage)
            .filter(e -> e instanceof AgentEvent.TextDelta)
            .map(e -> ((AgentEvent.TextDelta) e).text())
            .collect().with(Collectors.joining())
            .await().indefinitely();
        return ChatResponse.builder()
            .aiMessage(AiMessage.from(text))
            .finishReason(FinishReason.STOP)
            .build();
    }

    @Override
    public void doChat(ChatRequest request, StreamingChatResponseHandler handler) {
        validateNoJsonFormat(request);  // throws synchronously
        String userMessage = extractLastUserText(request.messages());  // throws synchronously
        // session.query() throws synchronously if CLOSED or ACTIVE.
        StringBuilder buffer = new StringBuilder();
        session.query(userMessage)
            .subscribe().with(
                event -> {
                    if (event instanceof AgentEvent.TextDelta delta) {
                        handler.onPartialResponse(delta.text());
                        buffer.append(delta.text());
                    }
                },
                handler::onError,
                () -> handler.onCompleteResponse(ChatResponse.builder()
                    .aiMessage(AiMessage.from(buffer.toString()))
                    .finishReason(FinishReason.STOP)
                    .build())
            );
        // Never calls session.close() — caller owns lifecycle.
    }

    private static String extractLastUserText(List<ChatMessage> messages) {
        for (ChatMessage m : messages) {
            if (m instanceof AiMessage) {
                throw new IllegalArgumentException(
                    "AgentSession-backed ChatModel adapters do not accept AiMessage — " +
                    "session history lives in the subprocess. " +
                    "Each call must supply only a single new UserMessage.");
            }
        }
        List<UserMessage> userMessages = messages.stream()
            .filter(m -> m instanceof UserMessage)
            .map(m -> (UserMessage) m)
            .toList();
        if (userMessages.size() > 1) {
            throw new IllegalArgumentException(
                "AgentSession-backed ChatModel adapters accept exactly one UserMessage per call — " +
                "multiple UserMessage elements indicate caller confusion about session state.");
        }
        if (userMessages.isEmpty()) {
            throw new IllegalArgumentException("ChatRequest must contain at least one UserMessage");
        }
        try {
            return userMessages.get(0).singleText();
        } catch (RuntimeException e) {
            throw new IllegalArgumentException(
                "This adapter supports text-only UserMessage; " +
                "multimodal content is not supported by the subprocess.", e);
        }
    }

    private static void validateNoJsonFormat(ChatRequest request) {
        var fmt = request.responseFormat();
        if (fmt != null && fmt.type() == ResponseFormatType.JSON) {
            throw new UnsupportedFeatureException(
                "ResponseFormat.JSON is not supported — Claude subprocess has no JSON mode; " +
                "use prompt engineering for structured output.");
        }
    }
}
```

- [ ] **Step 3.4: Run tests and verify they pass**

```bash
mvn --batch-mode test -pl agent-claude-langchain4j -am
```

Expected: `BUILD SUCCESS` — all `AgentSessionChatModelTest` tests pass.

- [ ] **Step 3.5: Commit**

```bash
git add agent-claude-langchain4j/src/
git commit -m "feat(platform#100): AgentSessionChatModel + tests — multi-turn ChatModel/StreamingChatModel wrapper"
```

---

## Task 4: `ClaudeAgentChatModel` — implementation and tests

**Files:**
- Create: `agent-claude-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/ClaudeAgentChatModel.java`
- Create: `agent-claude-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/ClaudeAgentChatModelTest.java`

Note: `ClaudeAgentChatModel` is CDI-managed. Tests use the package-private `@Inject` constructor directly (same package) with fake dependencies — no Quarkus test container needed.

- [ ] **Step 4.1: Write the test class**

```java
package io.casehub.platform.agent.langchain4j;

import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.SystemMessage;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.exception.UnsupportedFeatureException;
import dev.langchain4j.model.ModelProvider;
import dev.langchain4j.model.chat.listener.ChatModelListener;
import dev.langchain4j.model.chat.listener.ChatModelRequestContext;
import dev.langchain4j.model.chat.listener.ChatModelResponseContext;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.request.ResponseFormat;
import dev.langchain4j.model.chat.request.ResponseFormatType;
import dev.langchain4j.model.chat.response.ChatResponse;
import dev.langchain4j.model.chat.response.StreamingChatResponseHandler;
import dev.langchain4j.model.output.FinishReason;
import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentProvider;
import io.casehub.platform.agent.AgentSession;
import io.casehub.platform.agent.AgentSessionConfig;
import io.casehub.platform.agent.AgentSessionInit;
import io.casehub.platform.agent.AgentSessionLimitException;
import io.mutiny.Multi;
import jakarta.enterprise.inject.Instance;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.*;
import static org.awaitility.Awaitility.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ClaudeAgentChatModelTest {

    // ── Helpers ───────────────────────────────────────────────────────────────

    /** Stub Instance<ChatModelListener> whose stream() returns an empty stream. */
    @SuppressWarnings("unchecked")
    static Instance<ChatModelListener> emptyListeners() {
        Instance<ChatModelListener> stub = mock(Instance.class);
        when(stub.stream()).thenReturn(Stream.empty());
        return stub;
    }

    /** Stub Instance<ChatModelListener> returning a single mock listener. */
    @SuppressWarnings("unchecked")
    static Instance<ChatModelListener> singleListener(ChatModelListener listener) {
        Instance<ChatModelListener> stub = mock(Instance.class);
        when(stub.stream()).thenReturn(Stream.of(listener));
        return stub;
    }

    static ClaudeAgentLangchain4jProperties testProps() {
        return new ClaudeAgentLangchain4jProperties() {
            @Override public Duration closeTimeout() { return Duration.ofSeconds(5); }
        };
    }

    /** Multi emitting the given texts as TextDelta events. */
    static Multi<AgentEvent> textDeltas(String... texts) {
        List<AgentEvent> events = new ArrayList<>();
        for (String t : texts) events.add(new AgentEvent.TextDelta(t));
        return Multi.createFrom().iterable(events);
    }

    /** Fake AgentProvider with configurable session behaviour. */
    static AgentProvider fakeProvider(AgentSession sessionToReturn) {
        return new AgentProvider() {
            @Override public Multi<AgentEvent> invoke(AgentSessionConfig c) { return Multi.createFrom().empty(); }
            @Override public AgentSession openSession(AgentSessionInit init) { return sessionToReturn; }
        };
    }

    /** Fake AgentProvider that throws AgentSessionLimitException on openSession(). */
    static AgentProvider limitedProvider() {
        return new AgentProvider() {
            @Override public Multi<AgentEvent> invoke(AgentSessionConfig c) { return Multi.createFrom().empty(); }
            @Override public AgentSession openSession(AgentSessionInit init) {
                throw new AgentSessionLimitException("max sessions reached");
            }
        };
    }

    /** Fake AgentSession (using AgentSessionChatModelTest helper — same package). */
    static AgentSession fakeSession(java.util.function.Function<String, Multi<AgentEvent>> turnFactory) {
        return AgentSessionChatModelTest.fakeSession(turnFactory);
    }

    /** Creates a ChatRequest with a single UserMessage. */
    static ChatRequest single(String text) {
        return ChatRequest.builder().messages(List.of(UserMessage.from(text))).build();
    }

    /** Creates a ChatRequest with a SystemMessage + single UserMessage. */
    static ChatRequest withSystem(String system, String user) {
        return ChatRequest.builder()
            .messages(List.of(SystemMessage.from(system), UserMessage.from(user)))
            .build();
    }

    // ── Factory method ────────────────────────────────────────────────────────

    ClaudeAgentChatModel model(AgentProvider provider) {
        // Calls the package-private @Inject constructor directly — same package, no CDI needed.
        return new ClaudeAgentChatModel(provider, emptyListeners(), testProps());
    }

    // ── Contract ──────────────────────────────────────────────────────────────

    @Test
    void provider_returnsANTHROPIC() {
        assertThat(model(fakeProvider(fakeSession(__ -> Multi.createFrom().empty()))).provider())
            .isEqualTo(ModelProvider.ANTHROPIC);
    }

    @Test
    void supportedCapabilities_isEmpty() {
        assertThat(model(fakeProvider(fakeSession(__ -> Multi.createFrom().empty()))).supportedCapabilities())
            .isEmpty();
    }

    @Test
    void listeners_returnsInjectedListeners() {
        ChatModelListener mock = mock(ChatModelListener.class);
        ClaudeAgentChatModel m = new ClaudeAgentChatModel(
            fakeProvider(fakeSession(__ -> Multi.createFrom().empty())),
            singleListener(mock),
            testProps());
        assertThat(m.listeners()).containsExactly(mock);
    }

    // ── Blocking doChat ───────────────────────────────────────────────────────

    @Test
    void doChat_blocking_happyPath() {
        ClaudeAgentChatModel m = model(fakeProvider(fakeSession(__ -> textDeltas("Hello", " world"))));
        ChatResponse response = m.chat(single("hi"));
        assertThat(response.aiMessage().text()).isEqualTo("Hello world");
        assertThat(response.finishReason()).isEqualTo(FinishReason.STOP);
    }

    @Test
    void doChat_blocking_systemPromptPassedToSession() {
        List<String> capturedSystems = new ArrayList<>();
        AgentProvider provider = new AgentProvider() {
            @Override public Multi<AgentEvent> invoke(AgentSessionConfig c) { return Multi.createFrom().empty(); }
            @Override public AgentSession openSession(AgentSessionInit init) {
                capturedSystems.add(init.systemPrompt());
                return fakeSession(__ -> textDeltas("ok"));
            }
        };
        model(provider).chat(withSystem("You are helpful", "query"));
        assertThat(capturedSystems).containsExactly("You are helpful");
    }

    @Test
    void doChat_blocking_noSystemMessage_usesEmptyPrompt() {
        List<String> capturedSystems = new ArrayList<>();
        AgentProvider provider = new AgentProvider() {
            @Override public Multi<AgentEvent> invoke(AgentSessionConfig c) { return Multi.createFrom().empty(); }
            @Override public AgentSession openSession(AgentSessionInit init) {
                capturedSystems.add(init.systemPrompt());
                return fakeSession(__ -> textDeltas("ok"));
            }
        };
        model(provider).chat(single("just a user message"));
        assertThat(capturedSystems).containsExactly("");
    }

    @Test
    void doChat_blocking_sessionClosedAfterSuccess() {
        AtomicBoolean closeCalled = new AtomicBoolean(false);
        AgentSession session = new AgentSession() {
            @Override public Multi<AgentEvent> query(String p) { return textDeltas("done"); }
            @Override public io.mutiny.Uni<Void> interrupt() { return io.mutiny.Uni.createFrom().voidItem(); }
            @Override public void close(Duration d) { closeCalled.set(true); }
        };
        model(fakeProvider(session)).chat(single("hi"));
        assertThat(closeCalled.get()).isTrue();
    }

    @Test
    void doChat_blocking_sessionClosedAfterFailure() {
        AtomicBoolean closeCalled = new AtomicBoolean(false);
        AgentSession session = new AgentSession() {
            @Override public Multi<AgentEvent> query(String p) {
                return Multi.createFrom().failure(new RuntimeException("subprocess died"));
            }
            @Override public io.mutiny.Uni<Void> interrupt() { return io.mutiny.Uni.createFrom().voidItem(); }
            @Override public void close(Duration d) { closeCalled.set(true); }
        };
        assertThatThrownBy(() -> model(fakeProvider(session)).chat(single("hi")))
            .isInstanceOf(RuntimeException.class);
        assertThat(closeCalled.get()).isTrue();
    }

    @Test
    void doChat_blocking_jsonFormat_throws() {
        ClaudeAgentChatModel m = model(fakeProvider(fakeSession(__ -> Multi.createFrom().empty())));
        ChatRequest request = ChatRequest.builder()
            .messages(List.of(UserMessage.from("hi")))
            .responseFormat(ResponseFormat.builder().type(ResponseFormatType.JSON).build())
            .build();
        assertThatThrownBy(() -> m.doChat(request)).isInstanceOf(UnsupportedFeatureException.class);
    }

    @Test
    void doChat_blocking_aiMessagePresent_throws() {
        ClaudeAgentChatModel m = model(fakeProvider(fakeSession(__ -> Multi.createFrom().empty())));
        ChatRequest request = ChatRequest.builder()
            .messages(List.of(UserMessage.from("hi"), AiMessage.from("reply"), UserMessage.from("bye")))
            .build();
        assertThatThrownBy(() -> m.doChat(request)).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void doChat_blocking_multipleUserMessages_throws() {
        ClaudeAgentChatModel m = model(fakeProvider(fakeSession(__ -> Multi.createFrom().empty())));
        ChatRequest request = ChatRequest.builder()
            .messages(List.of(UserMessage.from("one"), UserMessage.from("two")))
            .build();
        assertThatThrownBy(() -> m.doChat(request)).isInstanceOf(IllegalArgumentException.class);
    }

    // ── Streaming doChat ──────────────────────────────────────────────────────

    @Test
    void doChat_streaming_happyPath() {
        ClaudeAgentChatModel m = model(fakeProvider(fakeSession(__ -> textDeltas("a", "b", "c"))));
        List<String> partials = new ArrayList<>();
        ChatResponse[] completed = {null};

        m.chat(single("q"), new StreamingChatResponseHandler() {
            @Override public void onPartialResponse(String t) { partials.add(t); }
            @Override public void onCompleteResponse(ChatResponse r) { completed[0] = r; }
            @Override public void onError(Throwable t) { throw new RuntimeException(t); }
        });

        await().untilAsserted(() -> assertThat(completed[0]).isNotNull());
        assertThat(partials).containsExactly("a", "b", "c");
        assertThat(completed[0].aiMessage().text()).isEqualTo("abc");
        assertThat(completed[0].finishReason()).isEqualTo(FinishReason.STOP);
    }

    @Test
    void doChat_streaming_sessionClosedInOnCompletion() {
        AtomicBoolean closeCalled = new AtomicBoolean(false);
        AgentSession session = new AgentSession() {
            @Override public Multi<AgentEvent> query(String p) { return Multi.createFrom().empty(); }
            @Override public io.mutiny.Uni<Void> interrupt() { return io.mutiny.Uni.createFrom().voidItem(); }
            @Override public void close(Duration d) { closeCalled.set(true); }
        };
        AtomicBoolean done = new AtomicBoolean(false);
        model(fakeProvider(session)).chat(single("q"), new StreamingChatResponseHandler() {
            @Override public void onPartialResponse(String t) {}
            @Override public void onCompleteResponse(ChatResponse r) { done.set(true); }
            @Override public void onError(Throwable t) {}
        });
        await().until(done::get);
        assertThat(closeCalled.get()).isTrue();
    }

    @Test
    void doChat_streaming_sessionClosedInOnFailure() {
        AtomicBoolean closeCalled = new AtomicBoolean(false);
        AgentSession session = new AgentSession() {
            @Override public Multi<AgentEvent> query(String p) {
                return Multi.createFrom().failure(new RuntimeException("error"));
            }
            @Override public io.mutiny.Uni<Void> interrupt() { return io.mutiny.Uni.createFrom().voidItem(); }
            @Override public void close(Duration d) { closeCalled.set(true); }
        };
        AtomicBoolean errorReceived = new AtomicBoolean(false);
        model(fakeProvider(session)).chat(single("q"), new StreamingChatResponseHandler() {
            @Override public void onPartialResponse(String t) {}
            @Override public void onCompleteResponse(ChatResponse r) {}
            @Override public void onError(Throwable t) { errorReceived.set(true); }
        });
        await().until(errorReceived::get);
        assertThat(closeCalled.get()).isTrue();
    }

    @Test
    void doChat_streaming_sessionLimitExceeded_routesToHandlerError() {
        AtomicBoolean errorReceived = new AtomicBoolean(false);
        model(limitedProvider()).chat(single("q"), new StreamingChatResponseHandler() {
            @Override public void onPartialResponse(String t) {}
            @Override public void onCompleteResponse(ChatResponse r) {}
            @Override public void onError(Throwable t) { errorReceived.set(true); }
        });
        assertThat(errorReceived.get()).isTrue(); // synchronous — AgentSessionLimitException is caught before subscribe
    }

    @Test
    void doChat_streaming_jsonFormat_throwsSynchronously() {
        ClaudeAgentChatModel m = model(fakeProvider(fakeSession(__ -> Multi.createFrom().empty())));
        ChatRequest request = ChatRequest.builder()
            .messages(List.of(UserMessage.from("hi")))
            .responseFormat(ResponseFormat.builder().type(ResponseFormatType.JSON).build())
            .build();
        assertThatThrownBy(() ->
            m.doChat(request, new StreamingChatResponseHandler() {
                @Override public void onPartialResponse(String t) {}
                @Override public void onCompleteResponse(ChatResponse r) {}
                @Override public void onError(Throwable t) {}
            })
        ).isInstanceOf(UnsupportedFeatureException.class);
    }

    @Test
    void doChat_streaming_aiMessagePresent_throwsSynchronously() {
        ClaudeAgentChatModel m = model(fakeProvider(fakeSession(__ -> Multi.createFrom().empty())));
        ChatRequest request = ChatRequest.builder()
            .messages(List.of(UserMessage.from("hi"), AiMessage.from("reply"), UserMessage.from("bye")))
            .build();
        assertThatThrownBy(() ->
            m.doChat(request, new StreamingChatResponseHandler() {
                @Override public void onPartialResponse(String t) {}
                @Override public void onCompleteResponse(ChatResponse r) {}
                @Override public void onError(Throwable t) {}
            })
        ).isInstanceOf(IllegalArgumentException.class);
    }

    // ── Listener telemetry ────────────────────────────────────────────────────

    @Test
    void doChat_listenerEmpty_noTelemetryFired() {
        // Construct with empty listeners — just verify no NPE and call succeeds
        ClaudeAgentChatModel m = new ClaudeAgentChatModel(
            fakeProvider(fakeSession(__ -> textDeltas("ok"))),
            emptyListeners(),
            testProps());
        assertThatNoException().isThrownBy(() -> m.chat(single("hi")));
    }

    @Test
    void doChat_listenerPresent_onRequestAndOnResponseCalled() {
        ChatModelListener listener = mock(ChatModelListener.class);
        ClaudeAgentChatModel m = new ClaudeAgentChatModel(
            fakeProvider(fakeSession(__ -> textDeltas("response text"))),
            singleListener(listener),
            testProps());
        m.chat(single("hello"));
        verify(listener).onRequest(any(ChatModelRequestContext.class));
        verify(listener).onResponse(any(ChatModelResponseContext.class));
        verifyNoMoreInteractions(listener);
    }
}
```

- [ ] **Step 4.2: Run tests — expect compilation failure**

```bash
mvn --batch-mode test -pl agent-claude-langchain4j -am
```

Expected: COMPILATION FAILURE — `ClaudeAgentChatModel` does not exist yet.

- [ ] **Step 4.3: Implement `ClaudeAgentChatModel`**

```java
package io.casehub.platform.agent.langchain4j;

import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.ChatMessage;
import dev.langchain4j.data.message.SystemMessage;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.exception.UnsupportedFeatureException;
import dev.langchain4j.model.ModelProvider;
import dev.langchain4j.model.chat.Capability;
import dev.langchain4j.model.chat.ChatModel;
import dev.langchain4j.model.chat.StreamingChatModel;
import dev.langchain4j.model.chat.listener.ChatModelListener;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.request.ResponseFormatType;
import dev.langchain4j.model.chat.response.ChatResponse;
import dev.langchain4j.model.chat.response.StreamingChatResponseHandler;
import dev.langchain4j.model.output.FinishReason;
import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentProvider;
import io.casehub.platform.agent.AgentSession;
import io.casehub.platform.agent.AgentSessionInit;
import io.casehub.platform.agent.AgentSessionLimitException;
import jakarta.annotation.Priority;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Alternative;
import jakarta.enterprise.inject.Any;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;

import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

@Alternative
@Priority(10)
@ApplicationScoped
public class ClaudeAgentChatModel implements ChatModel, StreamingChatModel {

    private final AgentProvider agentProvider;
    private final Instance<ChatModelListener> injectedListeners;
    private final ClaudeAgentLangchain4jProperties properties;

    @Inject
    ClaudeAgentChatModel(AgentProvider agentProvider,
                         @Any Instance<ChatModelListener> listeners,
                         ClaudeAgentLangchain4jProperties properties) {
        this.agentProvider = agentProvider;
        this.injectedListeners = listeners;
        this.properties = properties;
    }

    /** For ARC proxy generation — must not be called directly. */
    protected ClaudeAgentChatModel() {
        this.agentProvider = null;
        this.injectedListeners = null;
        this.properties = null;
    }

    @Override
    public ModelProvider provider() {
        return ModelProvider.ANTHROPIC;
    }

    @Override
    public Set<Capability> supportedCapabilities() {
        return Set.of();
    }

    @Override
    public List<ChatModelListener> listeners() {
        return injectedListeners.stream().toList();
        // Without this, provider() is meaningless — ChatModel.chat() fires
        // onRequest/onResponse/onError against an empty listener list.
    }

    @Override
    public ChatResponse doChat(ChatRequest request) {
        validateNoJsonFormat(request);
        String systemPrompt = extractSystemPrompt(request.messages());
        String userMessage = extractLastUserText(request.messages());
        AgentSession session = agentProvider.openSession(AgentSessionInit.of(systemPrompt));
        try {
            // The TextDelta filter is always true today (sealed interface, only TextDelta).
            // Retained as a forward-compatibility guard.
            String text = session.query(userMessage)
                .filter(e -> e instanceof AgentEvent.TextDelta)
                .map(e -> ((AgentEvent.TextDelta) e).text())
                .collect().with(Collectors.joining())
                .await().indefinitely();
            // Wall-clock bound: session-level timeout fires as AgentTimeoutException via the Multi
            // and is rethrown by await() — this call cannot hang indefinitely.
            return ChatResponse.builder()
                .aiMessage(AiMessage.from(text))
                .finishReason(FinishReason.STOP)
                .build();
        } finally {
            session.close(properties.closeTimeout());
        }
    }

    @Override
    public void doChat(ChatRequest request, StreamingChatResponseHandler handler) {
        validateNoJsonFormat(request);          // throws synchronously
        String systemPrompt = extractSystemPrompt(request.messages());
        String userMessage = extractLastUserText(request.messages()); // throws synchronously
        AgentSession session;
        try {
            session = agentProvider.openSession(AgentSessionInit.of(systemPrompt));
        } catch (AgentSessionLimitException e) {
            handler.onError(e);  // operational condition — route to handler
            return;
        }
        StringBuilder buffer = new StringBuilder();
        session.query(userMessage)  // throws synchronously if CLOSED/ACTIVE
            .subscribe().with(
                event -> {
                    if (event instanceof AgentEvent.TextDelta delta) {
                        handler.onPartialResponse(delta.text());
                        buffer.append(delta.text());
                    }
                },
                error -> {
                    session.close(properties.closeTimeout());
                    handler.onError(error);
                },
                () -> {
                    session.close(properties.closeTimeout());
                    handler.onCompleteResponse(ChatResponse.builder()
                        .aiMessage(AiMessage.from(buffer.toString()))
                        .finishReason(FinishReason.STOP)
                        .build());
                }
            );
    }

    private static String extractSystemPrompt(List<ChatMessage> messages) {
        return SystemMessage.findFirst(messages).map(SystemMessage::text).orElse("");
    }

    private static String extractLastUserText(List<ChatMessage> messages) {
        for (ChatMessage m : messages) {
            if (m instanceof AiMessage) {
                throw new IllegalArgumentException(
                    "AgentSession-backed ChatModel adapters do not accept AiMessage — " +
                    "session history lives in the subprocess. " +
                    "Each call must supply only a single new UserMessage.");
            }
        }
        List<UserMessage> userMessages = messages.stream()
            .filter(m -> m instanceof UserMessage)
            .map(m -> (UserMessage) m)
            .toList();
        if (userMessages.size() > 1) {
            throw new IllegalArgumentException(
                "AgentSession-backed ChatModel adapters accept exactly one UserMessage per call — " +
                "multiple UserMessage elements indicate caller confusion about session state.");
        }
        if (userMessages.isEmpty()) {
            throw new IllegalArgumentException("ChatRequest must contain at least one UserMessage");
        }
        try {
            return userMessages.get(0).singleText();
        } catch (RuntimeException e) {
            throw new IllegalArgumentException(
                "This adapter supports text-only UserMessage; " +
                "multimodal content is not supported by the subprocess.", e);
        }
    }

    private static void validateNoJsonFormat(ChatRequest request) {
        var fmt = request.responseFormat();
        if (fmt != null && fmt.type() == ResponseFormatType.JSON) {
            throw new UnsupportedFeatureException(
                "ResponseFormat.JSON is not supported — Claude subprocess has no JSON mode; " +
                "use prompt engineering for structured output.");
        }
    }
}
```

- [ ] **Step 4.4: Run all tests**

```bash
mvn --batch-mode test -pl agent-claude-langchain4j -am
```

Expected: `BUILD SUCCESS` — all tests in both `AgentSessionChatModelTest` and `ClaudeAgentChatModelTest` pass.

- [ ] **Step 4.5: Commit**

```bash
git add agent-claude-langchain4j/src/
git commit -m "feat(platform#100): ClaudeAgentChatModel + tests — @Alternative @Priority(10) stateless ChatModel/StreamingChatModel adapter"
```

---

## Task 5: CLAUDE.md and PLATFORM.md updates

**Files:**
- Modify: `CLAUDE.md` (project repo at `/Users/mdproctor/claude/casehub/platform/CLAUDE.md`)
- Modify: `/Users/mdproctor/claude/casehub/parent/docs/PLATFORM.md`

- [ ] **Step 5.1: Add module to `CLAUDE.md` module table**

In `CLAUDE.md`, find the `## Modules` table and add a row after the `agent-claude` row:

```
| `agent-claude-langchain4j/` | `casehub-platform-agent-claude-langchain4j` | `ChatModel` + `StreamingChatModel` adapters backed by `AgentSession`. Two paths: `ClaudeAgentChatModel` (`@Alternative @Priority(10) @ApplicationScoped` — fresh session per call, system prompt cached at Anthropic level) and `AgentSessionChatModel` (plain wrapper — caller-supplied session, multi-turn). Not compatible with `engine.Agent` (which forces `ResponseFormatType.JSON`). No quarkus:build goal. `listeners()` injects CDI `ChatModelListener` beans on `ClaudeAgentChatModel`; `AgentSessionChatModel` v1 gap. |
```

- [ ] **Step 5.2: Add module to `PLATFORM.md` casehub-platform repo row**

In `PLATFORM.md`, find the casehub-platform row in the Repository Map table. Append to its description after the `agent-claude/` entry:

```
`agent-claude-langchain4j/` (ChatModel + StreamingChatModel adapters backed by AgentSession — stateless ClaudeAgentChatModel @Alternative @Priority(10) + multi-turn AgentSessionChatModel plain wrapper; not for use with engine.Agent which forces JSON mode)
```

- [ ] **Step 5.3: Add to Cross-Repo Dependency Map note**

In `PLATFORM.md`, find the Cross-Repo Dependency Map section and add a comment below the existing table:

> Note: Add `casehub-platform-agent-claude-langchain4j → consuming repo` row here when a consumer (e.g. `casehub-eidos`) adds this dependency.

- [ ] **Step 5.4: Commit docs updates to project repo**

```bash
git -C /Users/mdproctor/claude/casehub/platform add CLAUDE.md
git -C /Users/mdproctor/claude/casehub/platform commit -m "docs(platform#100): add agent-claude-langchain4j to CLAUDE.md module table"
```

- [ ] **Step 5.5: Commit PLATFORM.md update to parent repo**

```bash
git -C /Users/mdproctor/claude/casehub/parent add docs/PLATFORM.md
git -C /Users/mdproctor/claude/casehub/parent commit -m "docs(platform#100): add agent-claude-langchain4j to casehub-platform repo row"
```

---

## Task 6: Full build verification

- [ ] **Step 6.1: Run the full platform build**

```bash
mvn --batch-mode install
```

Expected: `BUILD SUCCESS` — all modules including `agent-claude-langchain4j` build and test successfully.

- [ ] **Step 6.2: Verify the new module is in the installed artifact list**

```bash
mvn --batch-mode install -pl agent-claude-langchain4j -am -DskipTests 2>&1 | grep "BUILD"
```

Expected: `BUILD SUCCESS`.

---

## Self-Review Checklist

**Spec coverage:**

| Spec requirement | Covered by |
|-----------------|-----------|
| `ClaudeAgentLangchain4jProperties` `public interface` | Task 2 |
| `AgentSessionChatModel.wrap()` returns `AgentSessionChatModel` | Task 3 |
| `provider()` → `ModelProvider.ANTHROPIC` (both classes) | Tasks 3, 4 |
| `supportedCapabilities()` → `Set.of()` (both classes) | Tasks 3, 4 |
| `listeners()` injects CDI beans (`ClaudeAgentChatModel`) | Task 4 |
| `listeners()` returns `List.of()` (`AgentSessionChatModel`, v1 gap) | Task 3 |
| `extractSystemPrompt` via `SystemMessage.findFirst()` | Task 4 |
| `extractLastUserText` — AiMessage guard | Tasks 3, 4 |
| `extractLastUserText` — multiple UserMessage guard | Tasks 3, 4 |
| `extractLastUserText` — multimodal `singleText()` wrap | Tasks 3, 4 |
| `validateNoJsonFormat` → `UnsupportedFeatureException` | Tasks 3, 4 |
| Blocking: filter TextDelta, collect.joining, await.indefinitely | Tasks 3, 4 |
| `FinishReason.STOP` in all `ChatResponse` instances | Tasks 3, 4 |
| `finally: session.close()` in `ClaudeAgentChatModel` blocking | Task 4 |
| Session NOT closed in `AgentSessionChatModel` | Task 3 |
| Streaming: session closed in `onFailure` and `onCompletion` (`ClaudeAgentChatModel`) | Task 4 |
| `AgentSessionLimitException` → `handler.onError()` in streaming | Task 4 |
| `IllegalStateException` (CLOSED/already-active) — synchronous from `doChat()` | Tasks 3, 4 |
| TextDelta filter sealed-interface note | Tasks 3, 4 |
| `CLAUDE.md` + `PLATFORM.md` updates | Task 5 |
| Architectural boundary note (not for `engine.Agent`) | `CLAUDE.md` note in Task 5 |

No gaps found.

**Placeholder scan:** No TBDs or "implement later" phrases.

**Type consistency:** `AgentSessionChatModel.wrap()` declared returning `AgentSessionChatModel` in Task 3. `ClaudeAgentChatModel` uses the same private static helper signatures as `AgentSessionChatModel` — no shared helper class, duplicated intentionally. Both use `ChatResponse.builder().aiMessage(...).finishReason(FinishReason.STOP).build()`. Both test files use the same pattern for `fakeSession` (Task 4 reuses Task 3's `AgentSessionChatModelTest.fakeSession()` via same-package access).
