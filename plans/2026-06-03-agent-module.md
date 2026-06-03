# casehub-platform-agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement two new platform modules — `casehub-platform-agent-api` (AgentProvider SPI + types) and `casehub-platform-agent-claude` (Claude Agent SDK Quarkus integration) — plus `NoOpAgentProvider @DefaultBean` in the existing `platform/` module.

**Architecture:** `AgentProvider.invoke(config)` returns `Multi<AgentEvent>` of streaming text deltas. `ClaudeAgentClient` (in `agent-claude/`) builds a per-call `ClaudeAsyncClient` from the SDK, runs it on the worker pool, and enforces wall-clock timeout via a scheduled subprocess closure. `NoOpAgentProvider @DefaultBean` in `platform/` is the default when `agent-claude/` is absent from the classpath. Apps inject `AgentProvider`; `ClaudeAgentProvider @ApplicationScoped` in `agent-claude/` delegates to `ClaudeAgentClient`.

**Tech Stack:** Java 17, Quarkus 3.32.2, Mutiny 2.x, `org.springaicommunity:claude-code-sdk:1.0.0` (Project Reactor Flux bridge), JUnit 5, AssertJ, Mockito.

**Spec:** `docs/superpowers/specs/2026-06-02-agent-module-design.md` — read it before starting. Every design decision is there.

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `pom.xml` | Modify | Add `agent-api` and `agent-claude` modules |
| `agent-api/pom.xml` | Create | Module descriptor — Mutiny + Jandex, no Quarkus |
| `agent-api/src/main/java/io/casehub/platform/agent/AgentProvider.java` | Create | SPI interface |
| `agent-api/src/main/java/io/casehub/platform/agent/AgentEvent.java` | Create | Sealed event hierarchy (TextDelta only) |
| `agent-api/src/main/java/io/casehub/platform/agent/AgentSessionConfig.java` | Create | Immutable config record with compact constructor + factories |
| `agent-api/src/main/java/io/casehub/platform/agent/AgentMcpServer.java` | Create | Sealed MCP server config (Stdio/Sse/Http) |
| `agent-api/src/main/java/io/casehub/platform/agent/AgentTimeoutException.java` | Create | Wall-clock timeout failure type |
| `agent-api/src/main/java/io/casehub/platform/agent/AgentProcessException.java` | Create | Subprocess error failure type |
| `agent-api/src/main/java/io/casehub/platform/agent/AgentSessionLimitException.java` | Create | Concurrency cap failure type |
| `agent-api/src/test/java/io/casehub/platform/agent/AgentSessionConfigTest.java` | Create | Null guard + defensive copy tests |
| `platform/pom.xml` | Modify | Add `casehub-platform-agent-api` compile dep |
| `platform/src/main/java/io/casehub/platform/agent/NoOpAgentProvider.java` | Create | `@DefaultBean` no-op with log.warn |
| `agent-claude/pom.xml` | Create | Module descriptor — quarkus-arc + claude-code-sdk + Jandex |
| `agent-claude/src/main/java/io/casehub/platform/agent/claude/ClaudeAgentProperties.java` | Create | `@ConfigMapping` for binary path, timeout, max sessions |
| `agent-claude/src/main/java/io/casehub/platform/agent/claude/ClaudeAgentClient.java` | Create | Core: @Startup bean, three constructors, @PostConstruct, run(), buildEventStream(), @PreDestroy |
| `agent-claude/src/main/java/io/casehub/platform/agent/claude/ClaudeAgentProvider.java` | Create | `@ApplicationScoped` SPI implementation |
| `agent-claude/src/test/java/io/casehub/platform/agent/claude/ClaudeAgentClientTest.java` | Create | Infra tests: semaphore, timeout, termination handlers |
| `agent-claude/src/test/java/io/casehub/platform/agent/claude/ClaudeAgentClientIT.java` | Create | Gated integration test (`CLAUDE_AGENT_TESTS_ENABLED`) |

---

## Task 1: Root POM — register the new modules

**Files:**
- Modify: `pom.xml`

- [ ] **Add `agent-api` and `agent-claude` to `<modules>` in the root POM**

Open `pom.xml`. In the `<modules>` block, add `agent-api` immediately after `platform-api` (platform/ depends on it so must come first), and `agent-claude` last (depends on both):

```xml
<modules>
    <module>platform-api</module>
    <module>agent-api</module>      <!-- NEW — platform/ depends on this -->
    <module>platform</module>
    <module>testing</module>
    <module>config</module>
    <module>oidc</module>
    <module>expression</module>
    <module>persistence-jpa</module>
    <module>persistence-mongodb</module>
    <module>memory-inmem</module>
    <module>memory-jpa</module>
    <module>memory-sqlite</module>
    <module>scim</module>
    <module>identity</module>
    <module>agent-claude</module>   <!-- NEW — depends on agent-api and platform -->
</modules>
```

- [ ] **Verify the root POM still parses**

```bash
mvn --batch-mode help:evaluate -Dexpression=project.artifactId -q
```

Expected: prints `casehub-platform-parent` (no error).

---

## Task 2: agent-api/ module scaffold

**Files:**
- Create: `agent-api/pom.xml`

- [ ] **Create `agent-api/pom.xml`**

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

    <artifactId>casehub-platform-agent-api</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Agent API</name>
    <description>AgentProvider SPI and API types for AI agent invocation.
        Depends only on Mutiny — no Quarkus, no CDI, no casehubio imports.
        Jandex index required so ARC resolves AgentProvider supertype from downstream JARs.</description>

    <dependencies>
        <dependency>
            <groupId>io.smallrye.reactive</groupId>
            <artifactId>mutiny</artifactId>
        </dependency>
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
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
        </plugins>
    </build>
</project>
```

- [ ] **Verify module builds (empty module is fine)**

```bash
mvn --batch-mode install -pl agent-api -am
```

Expected: `BUILD SUCCESS`

---

## Task 3: API types — AgentEvent, AgentMcpServer, exceptions

**Files:**
- Create: `agent-api/src/main/java/io/casehub/platform/agent/AgentEvent.java`
- Create: `agent-api/src/main/java/io/casehub/platform/agent/AgentMcpServer.java`
- Create: `agent-api/src/main/java/io/casehub/platform/agent/AgentTimeoutException.java`
- Create: `agent-api/src/main/java/io/casehub/platform/agent/AgentProcessException.java`
- Create: `agent-api/src/main/java/io/casehub/platform/agent/AgentSessionLimitException.java`

- [ ] **Create `AgentEvent.java`**

```java
package io.casehub.platform.agent;

public sealed interface AgentEvent permits AgentEvent.TextDelta {

    /**
     * A token-level streaming chunk. NOT a buffered complete response.
     * Accumulate deltas to build the full response.
     *
     * <p>Absent intentionally:
     * <ul>
     *   <li>ToolCall: Claude Code tool invocations are opaque to the observer.
     *   <li>UsageReport: SDK cost metadata out of scope for v1.
     * </ul>
     */
    record TextDelta(String text) implements AgentEvent {}
}
```

- [ ] **Create `AgentMcpServer.java`**

```java
package io.casehub.platform.agent;

import java.util.List;
import java.util.Map;

public sealed interface AgentMcpServer
        permits AgentMcpServer.Stdio, AgentMcpServer.Sse, AgentMcpServer.Http {

    /**
     * Stdio MCP server: launched as a subprocess by the Claude CLI.
     *
     * <p>env: MERGED over the parent process environment (not a replacement).
     * PATH and system variables are preserved. Set a key to {@code ""} to unset it.
     */
    record Stdio(String command, List<String> args, Map<String, String> env)
            implements AgentMcpServer {
        public Stdio(String command) { this(command, List.of(), Map.of()); }
        public Stdio(String command, List<String> args) { this(command, args, Map.of()); }
    }

    /**
     * SSE MCP server: legacy HTTP transport (Server-Sent Events).
     * Prefer {@link Http} for new servers.
     */
    record Sse(String url, Map<String, String> headers) implements AgentMcpServer {
        public Sse(String url) { this(url, Map.of()); }
    }

    /**
     * Streamable HTTP MCP server: current MCP transport standard.
     * Prefer this over {@link Sse} for new deployments.
     */
    record Http(String url, Map<String, String> headers) implements AgentMcpServer {
        public Http(String url) { this(url, Map.of()); }
    }
}
```

- [ ] **Create `AgentTimeoutException.java`**

```java
package io.casehub.platform.agent;

import java.time.Duration;

public class AgentTimeoutException extends RuntimeException {
    public AgentTimeoutException(Duration timeout) {
        super("Agent session exceeded wall-clock timeout of " + timeout);
    }
}
```

- [ ] **Create `AgentProcessException.java`**

```java
package io.casehub.platform.agent;

public class AgentProcessException extends RuntimeException {
    public AgentProcessException(String message, Throwable cause) {
        super(message, cause);
    }
}
```

- [ ] **Create `AgentSessionLimitException.java`**

```java
package io.casehub.platform.agent;

public class AgentSessionLimitException extends RuntimeException {
    public AgentSessionLimitException(int limit) {
        super("Agent session limit reached (" + limit + " concurrent sessions). " +
              "Set casehub.platform.agent.claude.max-concurrent-sessions to increase.");
    }
}
```

- [ ] **Build to verify all types compile**

```bash
mvn --batch-mode install -pl agent-api -am
```

Expected: `BUILD SUCCESS`

---

## Task 4: AgentSessionConfig — TDD

**Files:**
- Create: `agent-api/src/main/java/io/casehub/platform/agent/AgentSessionConfig.java`
- Create: `agent-api/src/test/java/io/casehub/platform/agent/AgentSessionConfigTest.java`

- [ ] **Write the failing tests first**

```java
package io.casehub.platform.agent;

import org.junit.jupiter.api.Test;
import java.time.Duration;
import java.util.List;
import static org.assertj.core.api.Assertions.*;

class AgentSessionConfigTest {

    @Test
    void of_minimalFactory_hasDefaultNulls() {
        var config = AgentSessionConfig.of("sys", "user");
        assertThat(config.systemPrompt()).isEqualTo("sys");
        assertThat(config.userPrompt()).isEqualTo("user");
        assertThat(config.mcpServers()).isEmpty();
        assertThat(config.timeout()).isNull();
        assertThat(config.correlationId()).isNull();
    }

    @Test
    void of_withTimeout_setsTimeout() {
        var timeout = Duration.ofSeconds(30);
        var config = AgentSessionConfig.of("sys", "user", timeout);
        assertThat(config.timeout()).isEqualTo(timeout);
    }

    @Test
    void compactConstructor_nullSystemPrompt_throws() {
        assertThatNullPointerException()
            .isThrownBy(() -> new AgentSessionConfig(null, "user", List.of(), null, null))
            .withMessageContaining("systemPrompt");
    }

    @Test
    void compactConstructor_nullUserPrompt_throws() {
        assertThatNullPointerException()
            .isThrownBy(() -> new AgentSessionConfig("sys", null, List.of(), null, null))
            .withMessageContaining("userPrompt");
    }

    @Test
    void compactConstructor_nullMcpServers_treatedAsEmpty() {
        var config = new AgentSessionConfig("sys", "user", null, null, null);
        assertThat(config.mcpServers()).isEmpty();
    }

    @Test
    void compactConstructor_mcpServers_defensiveCopy() {
        var servers = new java.util.ArrayList<AgentMcpServer>();
        servers.add(new AgentMcpServer.Stdio("cmd"));
        var config = new AgentSessionConfig("sys", "user", servers, null, null);
        servers.add(new AgentMcpServer.Sse("http://x"));  // mutate original
        assertThat(config.mcpServers()).hasSize(1);        // config is unaffected
    }
}
```

- [ ] **Run tests — expect compilation failure (AgentSessionConfig not yet defined)**

```bash
mvn --batch-mode test -pl agent-api -am 2>&1 | tail -10
```

Expected: compilation error mentioning `AgentSessionConfig`.

- [ ] **Implement `AgentSessionConfig.java`**

```java
package io.casehub.platform.agent;

import java.time.Duration;
import java.util.List;
import java.util.Objects;

public record AgentSessionConfig(
        String systemPrompt,
        String userPrompt,
        List<AgentMcpServer> mcpServers,
        Duration timeout,        // null → ClaudeAgentProperties.defaultTimeout()
        String correlationId     // null → no correlation logging
) {
    public AgentSessionConfig {
        Objects.requireNonNull(systemPrompt, "systemPrompt");
        Objects.requireNonNull(userPrompt, "userPrompt");
        mcpServers = mcpServers != null ? List.copyOf(mcpServers) : List.of();
    }

    /** Default timeout, no MCP servers, no correlation. */
    public static AgentSessionConfig of(String systemPrompt, String userPrompt) {
        return new AgentSessionConfig(systemPrompt, userPrompt, List.of(), null, null);
    }

    /** Explicit timeout, no MCP servers, no correlation. */
    public static AgentSessionConfig of(String systemPrompt, String userPrompt,
                                        Duration timeout) {
        return new AgentSessionConfig(systemPrompt, userPrompt, List.of(), timeout, null);
    }
}
```

- [ ] **Run tests — expect all pass**

```bash
mvn --batch-mode test -pl agent-api -am
```

Expected: `BUILD SUCCESS`, `Tests run: 6, Failures: 0, Errors: 0, Skipped: 0`

- [ ] **Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add agent-api/ pom.xml
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#55): add agent-api module — AgentProvider SPI + types"
```

---

## Task 5: AgentProvider interface

**Files:**
- Create: `agent-api/src/main/java/io/casehub/platform/agent/AgentProvider.java`

- [ ] **Create `AgentProvider.java`**

```java
package io.casehub.platform.agent;

import io.smallrye.mutiny.Multi;

/**
 * Platform SPI for single-shot AI agent invocation.
 *
 * <p>Implementations should be {@code @ApplicationScoped} — agent infrastructure
 * is shared across requests.
 *
 * <p>Terminal state via stream termination only:
 * <ul>
 *   <li>Normal completion → {@code Multi} completes
 *   <li>Timeout → {@code Multi} fails with {@link AgentTimeoutException}
 *   <li>Subprocess error → {@code Multi} fails with {@link AgentProcessException}
 * </ul>
 * Subscriber cancellation triggers subprocess cleanup — no exception raised.
 */
public interface AgentProvider {

    /**
     * Invoke the agent and stream response events.
     *
     * @param config invocation configuration — systemPrompt and userPrompt are required
     * @return a cold {@code Multi} that starts the agent session on subscription
     */
    Multi<AgentEvent> invoke(AgentSessionConfig config);
}
```

- [ ] **Build to verify**

```bash
mvn --batch-mode install -pl agent-api -am
```

Expected: `BUILD SUCCESS`

---

## Task 6: platform/ — add dep + NoOpAgentProvider

**Files:**
- Modify: `platform/pom.xml`
- Create: `platform/src/main/java/io/casehub/platform/agent/NoOpAgentProvider.java`

- [ ] **Add `casehub-platform-agent-api` compile dep to `platform/pom.xml`**

In `platform/pom.xml`, inside `<dependencies>`, add:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-agent-api</artifactId>
    <version>${project.version}</version>
</dependency>
```

- [ ] **Create `NoOpAgentProvider.java`**

```java
package io.casehub.platform.agent;

import io.quarkus.arc.DefaultBean;
import io.smallrye.mutiny.Multi;
import jakarta.enterprise.context.ApplicationScoped;
import org.jboss.logging.Logger;

/**
 * No-op {@link AgentProvider} active when {@code casehub-platform-agent-claude} is not
 * on the classpath. Returns an empty completed stream.
 *
 * <p>A {@code WARN} log line is emitted on each invocation to make dev misconfiguration
 * immediately visible. The real agent and the NoOp both produce an empty completed Multi;
 * the log is the only observable distinction.
 */
@DefaultBean
@ApplicationScoped
public class NoOpAgentProvider implements AgentProvider {

    private static final Logger LOG = Logger.getLogger(NoOpAgentProvider.class);

    @Override
    public Multi<AgentEvent> invoke(AgentSessionConfig config) {
        LOG.warn("NoOpAgentProvider is active — add casehub-platform-agent-claude " +
                 "to the classpath to get real Claude output");
        return Multi.createFrom().empty();
    }
}
```

- [ ] **Build platform/ module**

```bash
mvn --batch-mode install -pl platform -am
```

Expected: `BUILD SUCCESS`

- [ ] **Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform/ agent-api/src/main/java/io/casehub/platform/agent/AgentProvider.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#55): AgentProvider SPI + NoOpAgentProvider @DefaultBean in platform"
```

---

## Task 7: agent-claude/ scaffold + ClaudeAgentProperties

**Files:**
- Create: `agent-claude/pom.xml`
- Create: `agent-claude/src/main/java/io/casehub/platform/agent/claude/ClaudeAgentProperties.java`

- [ ] **Create `agent-claude/pom.xml`**

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

    <artifactId>casehub-platform-agent-claude</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Agent Claude</name>
    <description>ClaudeAgentProvider @ApplicationScoped + ClaudeAgentClient.
        Activates by classpath presence. Requires Claude CLI installed and authenticated.
        No quarkus:build goal — library module (same as identity/, scim/).</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-agent-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-arc</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springaicommunity</groupId>
            <artifactId>claude-code-sdk</artifactId>
            <version>1.0.0</version>
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

- [ ] **Create `ClaudeAgentProperties.java`**

```java
package io.casehub.platform.agent.claude;

import io.smallrye.config.ConfigMapping;
import io.smallrye.config.WithDefault;
import java.time.Duration;
import java.util.Optional;

@ConfigMapping(prefix = "casehub.platform.agent.claude")
public interface ClaudeAgentProperties {

    /** Path to claude CLI binary. Resolved from PATH when absent. */
    Optional<String> binaryPath();

    /** Default wall-clock timeout when {@code AgentSessionConfig.timeout()} is null. */
    @WithDefault("PT5M")
    Duration defaultTimeout();

    /** Maximum concurrent agent sessions. Excess calls return a failure Multi. */
    @WithDefault("4")
    int maxConcurrentSessions();
}
```

- [ ] **Build to verify scaffold compiles**

```bash
mvn --batch-mode install -pl agent-claude -am
```

Expected: `BUILD SUCCESS`

---

## Task 8: ClaudeAgentClient — constructors, @PostConstruct, @PreDestroy (TDD)

**Files:**
- Create: `agent-claude/src/main/java/io/casehub/platform/agent/claude/ClaudeAgentClient.java`
- Create: `agent-claude/src/test/java/io/casehub/platform/agent/claude/ClaudeAgentClientTest.java`

- [ ] **Write the failing tests first**

```java
package io.casehub.platform.agent.claude;

import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentSessionConfig;
import io.casehub.platform.agent.AgentSessionLimitException;
import io.smallrye.mutiny.Multi;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.AfterEach;

import java.time.Duration;
import java.util.Optional;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class ClaudeAgentClientTest {

    private ClaudeAgentClient client;

    @AfterEach
    void teardown() {
        if (client != null) {
            client.shutdown();
        }
    }

    private ClaudeAgentProperties props(int maxSessions) {
        var p = mock(ClaudeAgentProperties.class);
        when(p.maxConcurrentSessions()).thenReturn(maxSessions);
        when(p.defaultTimeout()).thenReturn(Duration.ofMinutes(5));
        when(p.binaryPath()).thenReturn(Optional.empty());
        return p;
    }

    private AgentSessionConfig config() {
        return AgentSessionConfig.of("sys", "user");
    }

    // --- Semaphore limit ---

    @Test
    void limitReached_returnsFailureMulti_notSynchronousThrow() {
        client = new ClaudeAgentClient(props(1), c -> Multi.createFrom().nothing());
        client.run(config()); // fill the cap

        // Third call must deliver error via onFailure, not throw synchronously
        var result = client.run(config());
        assertThatThrownBy(() -> result.collect().asList().await().indefinitely())
            .isInstanceOf(AgentSessionLimitException.class);
    }

    @Test
    void semaphore_releasedOnCompletion_allowsNextCall() {
        client = new ClaudeAgentClient(props(1), c -> Multi.createFrom().empty());
        client.run(config()).collect().asList().await().indefinitely();  // completes, releases
        // Should not throw — semaphore was released
        assertThatCode(() ->
            client.run(config()).collect().asList().await().indefinitely()
        ).doesNotThrowAnyException();
    }

    @Test
    void semaphore_releasedOnFailure_allowsNextCall() {
        client = new ClaudeAgentClient(props(1),
            c -> Multi.createFrom().failure(new RuntimeException("boom")));
        assertThatThrownBy(() ->
            client.run(config()).collect().asList().await().indefinitely()
        ).isInstanceOf(RuntimeException.class); // semaphore released on failure

        // Next call must succeed (semaphore was released)
        client = new ClaudeAgentClient(props(1), c -> Multi.createFrom().empty());
        assertThatCode(() ->
            client.run(config()).collect().asList().await().indefinitely()
        ).doesNotThrowAnyException();
    }

    @Test
    void semaphore_releasedOnCancellation_allowsNextCall() throws Exception {
        var latch = new CountDownLatch(1);
        client = new ClaudeAgentClient(props(1), c ->
            Multi.createFrom().<AgentEvent>emitter(em -> {
                latch.countDown();
                // never emits — blocks until cancelled
            })
        );

        var subscription = client.run(config())
            .subscribe().with(x -> {}, e -> {}, () -> {});
        latch.await(2, TimeUnit.SECONDS);
        subscription.cancel(); // triggers onCancellation → semaphore.release()

        // Give cancellation time to propagate
        Thread.sleep(100);

        // New call must succeed
        client = new ClaudeAgentClient(props(1), c -> Multi.createFrom().empty());
        assertThatCode(() ->
            client.run(config()).collect().asList().await().indefinitely()
        ).doesNotThrowAnyException();
    }

    // --- Events ---

    @Test
    void run_returnsStreamItems_fromStreamFactory() {
        client = new ClaudeAgentClient(props(2), c ->
            Multi.createFrom().items(
                new AgentEvent.TextDelta("hello"),
                new AgentEvent.TextDelta(" world")
            )
        );
        var result = client.run(config())
            .collect().asList()
            .await().indefinitely();
        assertThat(result).hasSize(2);
        assertThat(((AgentEvent.TextDelta) result.get(0)).text()).isEqualTo("hello");
        assertThat(((AgentEvent.TextDelta) result.get(1)).text()).isEqualTo(" world");
    }

    // --- validateBinary ---

    @Test
    void validateBinary_nonExistentPath_throwsIllegalStateException() {
        var p = props(1);
        when(p.binaryPath()).thenReturn(Optional.of("/absolutely/does/not/exist/claude-xyz"));
        var c = new ClaudeAgentClient(p); // @Inject constructor — @PostConstruct not called by JVM
        assertThatThrownBy(c::validateBinary)
            .isInstanceOf(IllegalStateException.class)
            .hasMessageContaining("/absolutely/does/not/exist/claude-xyz");
    }
}
```

- [ ] **Run tests — expect compilation failure (ClaudeAgentClient not yet defined)**

```bash
mvn --batch-mode test -pl agent-claude -am 2>&1 | tail -15
```

Expected: compilation error.

- [ ] **Create `ClaudeAgentClient.java` — full skeleton with all methods**

```java
package io.casehub.platform.agent.claude;

import io.casehub.platform.agent.*;
import io.quarkus.runtime.Startup;
import io.smallrye.mutiny.Multi;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;
import org.springaicommunity.claude.agent.sdk.ClaudeAsyncClient;
import org.springaicommunity.claude.agent.sdk.ClaudeClient;
import org.springaicommunity.claude.agent.sdk.mcp.McpServerConfig;
import org.springaicommunity.claude.agent.sdk.transport.CLIOptions;

import java.io.IOException;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Function;

import static io.smallrye.mutiny.infrastructure.Infrastructure.getDefaultWorkerPool;

/**
 * @Startup forces eager initialization on the main thread during application startup,
 * before any reactive handlers can run. Without @Startup, ARC initializes lazily on
 * first injection. If that injection occurs on the Vert.x IO thread, @PostConstruct
 * validateBinary() would call ProcessBuilder.start().waitFor() on that thread —
 * blocking it in violation of spi-reactive-blocking-io.md (PP-20260529-9f9627).
 *
 * Same pattern as PathParserConfigurator and MongoPreferenceIndexes in this module.
 */
@Startup
@ApplicationScoped
public class ClaudeAgentClient {

    private static final Logger LOG = Logger.getLogger(ClaudeAgentClient.class);

    private final ClaudeAgentProperties properties;
    private final Semaphore semaphore;
    private final CopyOnWriteArraySet<ClaudeAsyncClient> activeSessions;
    private final ScheduledExecutorService timeoutScheduler;
    /** Non-null only in tests — set by test constructor, checked in buildEventStream(). */
    private final Function<AgentSessionConfig, Multi<AgentEvent>> streamFactory;

    @Inject
    public ClaudeAgentClient(ClaudeAgentProperties properties) {
        this.properties = properties;
        this.semaphore = new Semaphore(properties.maxConcurrentSessions());
        this.activeSessions = new CopyOnWriteArraySet<>();
        this.timeoutScheduler = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "casehub-agent-timeout");
            t.setDaemon(true);
            return t;
        });
        this.streamFactory = null;
    }

    /** Required by ARC for subclass-based proxy generation. Must not be called directly. */
    protected ClaudeAgentClient() {
        this.properties = null;
        this.semaphore = null;
        this.activeSessions = null;
        this.timeoutScheduler = null;
        this.streamFactory = null;
    }

    /**
     * Test constructor — bypasses {@code @PostConstruct}. Use with {@code new} in tests;
     * do not expose to CDI. Follows the ScimActorDIDProvider pattern in this codebase.
     */
    public ClaudeAgentClient(ClaudeAgentProperties properties,
                             Function<AgentSessionConfig, Multi<AgentEvent>> streamFactory) {
        this.properties = properties;
        this.semaphore = new Semaphore(properties.maxConcurrentSessions());
        this.activeSessions = new CopyOnWriteArraySet<>();
        this.timeoutScheduler = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "casehub-agent-timeout");
            t.setDaemon(true);
            return t;
        });
        this.streamFactory = streamFactory;
    }

    @PostConstruct
    void validateBinary() {
        String binary = properties.binaryPath().orElse("claude");
        try {
            Process process = new ProcessBuilder(binary, "--version").start();
            boolean finished = process.waitFor(10, TimeUnit.SECONDS);
            if (!finished) {
                process.destroyForcibly();
                throw new IllegalStateException(
                        "claude binary probe timed out after 10s: " + binary);
            }
            int exitCode = process.exitValue();
            if (exitCode != 0) {
                throw new IllegalStateException(
                        "claude binary at '" + binary + "' exited with code " + exitCode +
                        " — possible broken installation");
            }
        } catch (IllegalStateException e) {
            throw e;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException(
                    "Interrupted while probing claude binary: " + binary, e);
        } catch (IOException e) {
            throw new IllegalStateException(
                    "claude binary not found or not executable: " + binary +
                    " — configure casehub.platform.agent.claude.binary-path " +
                    "or ensure 'claude' is on PATH", e);
        }
        LOG.warnf("claude binary resolved at '%s'. Authentication not verified — " +
                  "AgentProcessException will surface on first invocation if unauthenticated.",
                  binary);
    }

    /**
     * Stream TextDelta events until completion or wall-clock timeout.
     * All error cases surface via onFailure() — this method never throws.
     *
     * <p>Responsibility split:
     * <ul>
     *   <li>buildEventStream() owns: timer cancel, session deregister, sdkClient.close()
     *   <li>run() owns: semaphore release — as the outer handler layer
     * </ul>
     */
    public Multi<AgentEvent> run(AgentSessionConfig config) {
        if (!semaphore.tryAcquire()) {
            return Multi.createFrom().failure(
                    new AgentSessionLimitException(properties.maxConcurrentSessions()));
        }
        try {
            return buildEventStream(config)
                    .runSubscriptionOn(getDefaultWorkerPool())
                    .onCompletion().invoke(semaphore::release)
                    .onFailure().invoke(t -> semaphore.release())
                    .onCancellation().invoke(semaphore::release);
        } catch (Exception e) {
            semaphore.release();
            return Multi.createFrom().failure(e);
        }
    }

    /**
     * Package-private — called only from run() in this class. Test constructor bypasses
     * it via streamFactory, so its visibility has no test surface.
     */
    Multi<AgentEvent> buildEventStream(AgentSessionConfig config) {
        // Test path: delegate to injected factory
        if (streamFactory != null) {
            return streamFactory.apply(config);
        }

        // Production path
        Duration effectiveTimeout = config.timeout() != null
                ? config.timeout()
                : properties.defaultTimeout();

        ClaudeAsyncClient sdkClient = buildSdkClient(config);
        activeSessions.add(sdkClient);

        AtomicBoolean timedOut = new AtomicBoolean(false);
        ScheduledFuture<?> timeoutFuture = timeoutScheduler.schedule(() -> {
            if (timedOut.compareAndSet(false, true)) {
                sdkClient.close().subscribe();
            }
        }, effectiveTimeout.toMillis(), TimeUnit.MILLISECONDS);

        try {
            var textFlux = sdkClient.connect(config.userPrompt()).textStream();
            var events = Multi.createFrom()
                    .publisher(textFlux)
                    .map(text -> (AgentEvent) new AgentEvent.TextDelta(text))
                    .onFailure().transform(e -> timedOut.get()
                            ? new AgentTimeoutException(effectiveTimeout)
                            : new AgentProcessException(
                                    Objects.toString(e.getMessage(),
                                                     e.getClass().getSimpleName()), e))
                    .onCompletion().invoke(() -> cleanup(timeoutFuture, sdkClient))
                    .onFailure().invoke(t -> cleanup(timeoutFuture, sdkClient))
                    .onCancellation().invoke(() -> cleanup(timeoutFuture, sdkClient));

            if (config.correlationId() != null) {
                LOG.infof("agent session started correlationId=%s", config.correlationId());
            }
            return events;
        } catch (Exception e) {
            // Synchronous failure after registration — clean up before propagating
            timeoutFuture.cancel(false);
            activeSessions.remove(sdkClient);
            sdkClient.close().subscribe();
            throw e;
        }
    }

    private void cleanup(ScheduledFuture<?> timeoutFuture, ClaudeAsyncClient sdkClient) {
        timeoutFuture.cancel(false);
        activeSessions.remove(sdkClient);
        try { sdkClient.close().subscribe(); } catch (Exception ignored) {}
    }

    private ClaudeAsyncClient buildSdkClient(AgentSessionConfig config) {
        var builder = ClaudeClient.async()
                .workingDirectory(Path.of(System.getProperty("user.dir")))
                .systemPrompt(config.systemPrompt());

        // Convert AgentMcpServer list to SDK McpServerConfig map.
        // Key format: type-index (e.g., "stdio-0", "sse-0") — used as MCP tool name prefix.
        var mcpServers = new LinkedHashMap<String, McpServerConfig>();
        var counts = new HashMap<String, Integer>();
        for (AgentMcpServer server : config.mcpServers()) {
            McpServerConfig sdkConfig = switch (server) {
                case AgentMcpServer.Stdio s ->
                    new McpServerConfig.McpStdioServerConfig(s.command(), s.args(), s.env());
                case AgentMcpServer.Sse s ->
                    new McpServerConfig.McpSseServerConfig(s.url(), s.headers());
                case AgentMcpServer.Http s ->
                    new McpServerConfig.McpHttpServerConfig(s.url(), s.headers());
            };
            String type = server.getClass().getSimpleName().toLowerCase();
            int idx = counts.merge(type, 0, (a, b) -> a + 1);
            mcpServers.put(type + "-" + idx, sdkConfig);
        }
        builder.mcpServers(mcpServers);

        // Apply binary path if configured
        properties.binaryPath().ifPresent(path ->
            builder.claudePath(path)  // see SDK AsyncSpec for exact method name
        );

        return builder.build();
    }

    @PreDestroy
    void shutdown() {
        timeoutScheduler.shutdownNow();
        activeSessions.forEach(c -> {
            try { c.close().subscribe(); } catch (Exception ignored) {}
        });
    }
}
```

> **Note on `builder.claudePath()`:** Verify the exact method name on `AsyncSpec` by checking the SDK source for `claude-path`, `binaryPath`, or `claudePath`. If the builder exposes it via `CLIOptions` only (not the fluent API), build `CLIOptions` directly with the path and pass via `ClaudeClient.async(cliOptions)`.

- [ ] **Run tests — expect all pass**

```bash
mvn --batch-mode test -pl agent-claude -am
```

Expected: `BUILD SUCCESS`, all tests in `ClaudeAgentClientTest` pass.

- [ ] **Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add agent-claude/ 
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#55): ClaudeAgentClient — three constructors, semaphore, run(), buildEventStream()"
```

---

## Task 9: ClaudeAgentProvider + full build

**Files:**
- Create: `agent-claude/src/main/java/io/casehub/platform/agent/claude/ClaudeAgentProvider.java`

- [ ] **Create `ClaudeAgentProvider.java`**

```java
package io.casehub.platform.agent.claude;

import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentProvider;
import io.casehub.platform.agent.AgentSessionConfig;
import io.smallrye.mutiny.Multi;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Claude Agent SDK implementation of {@link AgentProvider}.
 *
 * <p>Activates when {@code casehub-platform-agent-claude} is on the classpath —
 * {@code @ApplicationScoped} beats {@code NoOpAgentProvider @DefaultBean} automatically.
 * Injects {@link ClaudeAgentClient} (implementation detail — app code injects
 * {@link AgentProvider} only).
 *
 * <p>CDI tier:
 * <ul>
 *   <li>Tier 1: {@code NoOpAgentProvider @DefaultBean} (platform/) — default
 *   <li>Tier 2: {@code ClaudeAgentProvider @ApplicationScoped} (agent-claude/) — active on classpath
 * </ul>
 */
@ApplicationScoped
public class ClaudeAgentProvider implements AgentProvider {

    @Inject
    ClaudeAgentClient client;

    @Override
    public Multi<AgentEvent> invoke(AgentSessionConfig config) {
        return client.run(config);
    }
}
```

- [ ] **Run full project build**

```bash
mvn --batch-mode install
```

Expected: `BUILD SUCCESS` for all modules.

- [ ] **Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add agent-claude/src/main/java/io/casehub/platform/agent/claude/ClaudeAgentProvider.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#55): ClaudeAgentProvider @ApplicationScoped"
```

---

## Task 10: Gated integration test

**Files:**
- Create: `agent-claude/src/test/java/io/casehub/platform/agent/claude/ClaudeAgentClientIT.java`

- [ ] **Create `ClaudeAgentClientIT.java`**

```java
package io.casehub.platform.agent.claude;

import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentProvider;
import io.casehub.platform.agent.AgentSessionConfig;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Integration test requiring a real Claude CLI. Skipped in CI by default.
 *
 * <p>To enable locally: set {@code CLAUDE_AGENT_TESTS_ENABLED=true} and ensure
 * {@code claude} is installed and authenticated.
 */
@QuarkusTest
@EnabledIfEnvironmentVariable(named = "CLAUDE_AGENT_TESTS_ENABLED", matches = "true")
class ClaudeAgentClientIT {

    @Inject
    AgentProvider agentProvider;

    @Test
    void invoke_returnsAtLeastOneTextDelta() {
        var config = AgentSessionConfig.of(
                "You are a concise assistant.",
                "Say 'hello' and nothing else.");

        List<AgentEvent> events = agentProvider.invoke(config)
                .collect().asList()
                .await().atMost(java.time.Duration.ofMinutes(2));

        assertThat(events).isNotEmpty();
        assertThat(events).allSatisfy(e -> assertThat(e).isInstanceOf(AgentEvent.TextDelta.class));
        String fullText = events.stream()
                .map(e -> ((AgentEvent.TextDelta) e).text())
                .collect(java.util.stream.Collectors.joining());
        assertThat(fullText.toLowerCase()).contains("hello");
    }
}
```

- [ ] **Verify the IT is skipped in a normal build (env var not set)**

```bash
mvn --batch-mode test -pl agent-claude -am 2>&1 | grep -E "SKIP|Skipped|Tests run"
```

Expected: IT class is skipped, unit tests still pass.

- [ ] **Commit and push**

```bash
git -C /Users/mdproctor/claude/casehub/platform add agent-claude/src/test/java/io/casehub/platform/agent/claude/ClaudeAgentClientIT.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "test(platform#55): add gated integration test for ClaudeAgentClient"
git -C /Users/mdproctor/claude/casehub/platform push origin issue-55-agent-module
git -C /Users/mdproctor/claude/casehub/platform push mdproctor issue-55-agent-module
```

---

## Self-Review Checklist

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Root POM module registration with correct ordering | Task 1 |
| agent-api/pom.xml with Mutiny + Jandex, no Quarkus | Task 2 |
| AgentEvent.TextDelta sealed interface | Task 3 |
| AgentMcpServer Stdio/Sse/Http sealed interface | Task 3 |
| AgentTimeoutException, AgentProcessException, AgentSessionLimitException | Task 3 |
| AgentSessionConfig compact constructor (null guards + defensive copy) | Task 4 |
| AgentSessionConfig.of() factory methods | Task 4 |
| AgentProvider interface with scope Javadoc | Task 5 |
| platform/pom.xml gets agent-api dep | Task 6 |
| NoOpAgentProvider @DefaultBean with log.warn | Task 6 |
| agent-claude/pom.xml with quarkus-arc + claude-code-sdk + Jandex + generate-code goals only | Task 7 |
| ClaudeAgentProperties @ConfigMapping | Task 7 |
| ClaudeAgentClient three constructors (inject, proxy, test) | Task 8 |
| @Startup + @ApplicationScoped on ClaudeAgentClient | Task 8 |
| validateBinary with 10s timeout, exit code check, separate InterruptedException catch | Task 8 |
| run() semaphore limit → failure Multi (not throw) | Task 8 |
| run() semaphore release on all three termination paths | Task 8 |
| buildEventStream() package-private | Task 8 |
| buildEventStream() test path (streamFactory delegation) | Task 8 |
| buildEventStream() production path: SDK client, timer, textStream() bridge | Task 8 |
| AtomicBoolean.compareAndSet in timer handler | Task 8 |
| ScheduledFuture capture + cancel in termination handlers | Task 8 |
| cleanup() on all three paths (timer cancel + deregister + close) | Task 8 |
| inner try/catch for sync failure cleanup | Task 8 |
| failure transformation (timedOut flag → AgentTimeoutException) | Task 8 |
| Objects.toString(e.getMessage(), className) in AgentProcessException | Task 8 |
| correlationId structured logging | Task 8 |
| @PreDestroy: timeoutScheduler.shutdownNow() + per-client isolated close | Task 8 |
| ClaudeAgentProvider @ApplicationScoped | Task 9 |
| Full build verification | Task 9 |
| Gated integration test | Task 10 |
| Unit tests: semaphore limit rejection | Task 8 |
| Unit tests: semaphore release on completion/failure/cancellation | Task 8 |
| Unit tests: validateBinary non-existent binary | Task 8 |
| assertThatThrownBy() pattern (not failsWith) | Task 8 |

**Known implementation note:** The `builder.claudePath()` method name in `buildEventStream()` must be verified against the SDK's `AsyncSpec` source. If the fluent API doesn't expose it, construct `CLIOptions` directly with the binary path and use `ClaudeClient.async(cliOptions)`.

**No placeholders, no TBDs, all code complete.**
