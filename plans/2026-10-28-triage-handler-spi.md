# TriageHandler SPI + NoOp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #673 — feat: TriageHandler SPI + CbrCaseEntry — governance post-failure gate
**Issue group:** #673

**Goal:** Add a post-failure governance gate to platform's execution lifecycle — when mechanical retry is exhausted, TriageHandler provides an intelligent escalation point before the operation is abandoned.

**Architecture:** TriageHandler follows the confirmation pattern exactly: SPI interface in platform-api, framework-neutral POJO in governance-core, @DefaultBean Quarkus producer in governance/, Spring @AutoConfiguration in governance-spring/. The SPI is synchronous (returns a decision), not event-based. CoordinationExhaustedEvent is a CDI event fired when triage abandons.

**Tech Stack:** Java 21+ records, sealed interfaces, JUnit 5, AssertJ, Quarkus CDI, Spring Boot auto-configuration

## Global Constraints

- platform-api must remain zero-dependency — no Quarkus, no JPA, no casehubio imports. Pure Java only.
- Follow the confirmation module pattern: SPI → core POJO → Quarkus CDI → Spring auto-config
- No comments unless the WHY is non-obvious
- CbrCaseEntry is **deferred** — the `.memory` package (MemoryInput, Memory, MemoryAttributeKeys) is not on main yet. CbrCaseEntry will be added when the memory branch lands.

---

## Batch 1: SPI Types + Default Implementation

### Task 1: Triage SPI Types in platform-api

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/governance/TriageHandler.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/governance/TriageContext.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/governance/TriageDecision.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/governance/CoordinationExhaustedEvent.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/governance/TriageContextTest.java`

**Interfaces:**
- Consumes: nothing — these are foundation types
- Produces: `TriageHandler` interface (used by governance-core NoOp, engine RecoveryCoordinator, agency LlmTriageHandler), `TriageContext` record (constructed by engine, passed to handlers), `TriageDecision` sealed interface with `Retry` and `Abandon` permits (returned by handlers), `CoordinationExhaustedEvent` record (CDI event fired by engine coordinator)

- [ ] **Step 1: Write TriageDecision sealed interface**

```java
// platform-api/.../governance/TriageDecision.java
package io.casehub.platform.api.governance;

import java.util.Map;

public sealed interface TriageDecision {

    record Retry(Map<String, Object> modifications) implements TriageDecision {
        public Retry {
            modifications = modifications != null ? Map.copyOf(modifications) : Map.of();
        }
    }

    record Abandon(String reason) implements TriageDecision {
        public Abandon {
            if (reason == null || reason.isBlank()) {
                throw new IllegalArgumentException("abandon reason required");
            }
        }
    }
}
```

- [ ] **Step 2: Write TriageContext record**

```java
// platform-api/.../governance/TriageContext.java
package io.casehub.platform.api.governance;

import java.util.Map;
import java.util.Objects;

public record TriageContext(
    String operationId,
    String operationType,
    int attemptNumber,
    int maxAttempts,
    String failureSummary,
    Map<String, Object> failureDetail,
    Map<String, Object> executionContext
) {
    public TriageContext {
        Objects.requireNonNull(operationId, "operationId required");
        Objects.requireNonNull(operationType, "operationType required");
        Objects.requireNonNull(failureSummary, "failureSummary required");
        failureDetail = failureDetail != null ? Map.copyOf(failureDetail) : Map.of();
        executionContext = executionContext != null ? Map.copyOf(executionContext) : Map.of();
        if (attemptNumber < 1) throw new IllegalArgumentException("attemptNumber must be >= 1");
        if (maxAttempts < 1) throw new IllegalArgumentException("maxAttempts must be >= 1");
    }
}
```

- [ ] **Step 3: Write TriageHandler SPI interface**

```java
// platform-api/.../governance/TriageHandler.java
package io.casehub.platform.api.governance;

public interface TriageHandler {
    TriageDecision evaluate(TriageContext context);
}
```

- [ ] **Step 4: Write CoordinationExhaustedEvent record**

```java
// platform-api/.../governance/CoordinationExhaustedEvent.java
package io.casehub.platform.api.governance;

import java.util.Map;
import java.util.Objects;

public record CoordinationExhaustedEvent(
    String operationId,
    String operationType,
    int triageAttempts,
    String abandonReason,
    Map<String, Object> lastFailureDetail
) {
    public CoordinationExhaustedEvent {
        Objects.requireNonNull(operationId, "operationId required");
        Objects.requireNonNull(operationType, "operationType required");
        Objects.requireNonNull(abandonReason, "abandonReason required");
        lastFailureDetail = lastFailureDetail != null ? Map.copyOf(lastFailureDetail) : Map.of();
    }
}
```

- [ ] **Step 5: Write TriageContext validation test**

```java
// platform-api/.../governance/TriageContextTest.java
package io.casehub.platform.api.governance;

import org.junit.jupiter.api.Test;
import java.util.Map;

import static org.assertj.core.api.Assertions.*;

class TriageContextTest {

    @Test
    void validContext() {
        var ctx = new TriageContext("op-1", "playbook", 1, 2,
                "step 3 failed", Map.of("step", "3"), Map.of("case", "c-1"));

        assertThat(ctx.operationId()).isEqualTo("op-1");
        assertThat(ctx.operationType()).isEqualTo("playbook");
        assertThat(ctx.attemptNumber()).isEqualTo(1);
        assertThat(ctx.maxAttempts()).isEqualTo(2);
        assertThat(ctx.failureSummary()).isEqualTo("step 3 failed");
        assertThat(ctx.failureDetail()).containsEntry("step", "3");
        assertThat(ctx.executionContext()).containsEntry("case", "c-1");
    }

    @Test
    void nullOperationIdThrows() {
        assertThatThrownBy(() -> new TriageContext(null, "playbook", 1, 2,
                "fail", Map.of(), Map.of()))
            .isInstanceOf(NullPointerException.class)
            .hasMessageContaining("operationId");
    }

    @Test
    void zeroAttemptNumberThrows() {
        assertThatThrownBy(() -> new TriageContext("op-1", "playbook", 0, 2,
                "fail", Map.of(), Map.of()))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("attemptNumber");
    }

    @Test
    void nullMapsDefaultToEmpty() {
        var ctx = new TriageContext("op-1", "playbook", 1, 2, "fail", null, null);

        assertThat(ctx.failureDetail()).isEmpty();
        assertThat(ctx.executionContext()).isEmpty();
    }

    @Test
    void mapsAreDefensivelyCopied() {
        var detail = new java.util.HashMap<String, Object>();
        detail.put("key", "val");
        var ctx = new TriageContext("op-1", "playbook", 1, 2, "fail", detail, Map.of());

        assertThatThrownBy(() -> ctx.failureDetail().put("new", "val"))
            .isInstanceOf(UnsupportedOperationException.class);
    }

    @Test
    void triageDecisionRetry() {
        TriageDecision decision = new TriageDecision.Retry(Map.of("skip", "step-3"));

        assertThat(decision).isInstanceOf(TriageDecision.Retry.class);
        assertThat(((TriageDecision.Retry) decision).modifications())
            .containsEntry("skip", "step-3");
    }

    @Test
    void triageDecisionAbandon() {
        TriageDecision decision = new TriageDecision.Abandon("max attempts reached");

        assertThat(decision).isInstanceOf(TriageDecision.Abandon.class);
        assertThat(((TriageDecision.Abandon) decision).reason())
            .isEqualTo("max attempts reached");
    }

    @Test
    void abandonBlankReasonThrows() {
        assertThatThrownBy(() -> new TriageDecision.Abandon(""))
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void coordinationExhaustedEvent() {
        var event = new CoordinationExhaustedEvent("op-1", "playbook", 2,
                "triage exhausted", Map.of("lastStep", "3"));

        assertThat(event.operationId()).isEqualTo("op-1");
        assertThat(event.triageAttempts()).isEqualTo(2);
        assertThat(event.lastFailureDetail()).containsEntry("lastStep", "3");
    }
}
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform-api -Dtest=TriageContextTest`
Expected: FAIL — classes not found (compilation error)

- [ ] **Step 7: Create all four source files**

Write the four Java files from steps 1-4 to their paths.

- [ ] **Step 8: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform-api -Dtest=TriageContextTest`
Expected: PASS — all 9 tests green

- [ ] **Step 9: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/governance/TriageHandler.java
git add platform-api/src/main/java/io/casehub/platform/api/governance/TriageContext.java
git add platform-api/src/main/java/io/casehub/platform/api/governance/TriageDecision.java
git add platform-api/src/main/java/io/casehub/platform/api/governance/CoordinationExhaustedEvent.java
git add platform-api/src/test/java/io/casehub/platform/api/governance/TriageContextTest.java
git commit -m "feat(#673): add TriageHandler SPI, TriageContext, TriageDecision, CoordinationExhaustedEvent"
```

---

### Task 2: NoOpTriageHandler in governance-core

**Files:**
- Create: `governance-core/src/main/java/io/casehub/platform/governance/NoOpTriageHandler.java`
- Test: `governance-core/src/test/java/io/casehub/platform/governance/NoOpTriageHandlerTest.java`

**Interfaces:**
- Consumes: `TriageHandler`, `TriageContext`, `TriageDecision` from platform-api
- Produces: `NoOpTriageHandler` class (used by governance Quarkus @DefaultBean, governance-spring @ConditionalOnMissingBean)

- [ ] **Step 1: Write the failing test**

```java
// governance-core/.../governance/NoOpTriageHandlerTest.java
package io.casehub.platform.governance;

import io.casehub.platform.api.governance.TriageContext;
import io.casehub.platform.api.governance.TriageDecision;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class NoOpTriageHandlerTest {

    @Test
    void evaluate_alwaysReturnsAbandon() {
        var handler = new NoOpTriageHandler();
        var context = new TriageContext("op-1", "playbook", 1, 2,
                "step failed", Map.of(), Map.of());

        var decision = handler.evaluate(context);

        assertThat(decision).isInstanceOf(TriageDecision.Abandon.class);
        assertThat(((TriageDecision.Abandon) decision).reason())
            .isNotBlank();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl governance-core -Dtest=NoOpTriageHandlerTest`
Expected: FAIL — NoOpTriageHandler not found

- [ ] **Step 3: Write NoOpTriageHandler**

Follows the `NoOpOperationConfirmationProvider` pattern — fail-closed default that preserves existing behavior (no triage, failure propagates).

```java
// governance-core/.../governance/NoOpTriageHandler.java
package io.casehub.platform.governance;

import io.casehub.platform.api.governance.TriageContext;
import io.casehub.platform.api.governance.TriageDecision;
import io.casehub.platform.api.governance.TriageHandler;

public class NoOpTriageHandler implements TriageHandler {

    @Override
    public TriageDecision evaluate(TriageContext context) {
        return new TriageDecision.Abandon("no triage handler configured");
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl governance-core -Dtest=NoOpTriageHandlerTest`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add governance-core/src/main/java/io/casehub/platform/governance/NoOpTriageHandler.java
git add governance-core/src/test/java/io/casehub/platform/governance/NoOpTriageHandlerTest.java
git commit -m "feat(#673): add NoOpTriageHandler — fail-closed default (always abandons)"
```

---

## Batch 2: CDI + Spring Wiring

### Task 3: Quarkus @DefaultBean + Spring Auto-Configuration

**Files:**
- Modify: `governance/src/main/java/io/casehub/platform/governance/quarkus/GovernanceBeans.java` — add NoOpTriageHandler @DefaultBean producer
- Create: `governance-spring/pom.xml`
- Create: `governance-spring/src/main/java/io/casehub/platform/governance/spring/GovernanceTriageAutoConfiguration.java`
- Create: `governance-spring/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`
- Modify: `pom.xml` (root) — add `governance-spring` module

**Interfaces:**
- Consumes: `NoOpTriageHandler` from governance-core, `TriageHandler` from platform-api
- Produces: CDI-discoverable `@DefaultBean TriageHandler` for Quarkus apps, `@ConditionalOnMissingBean TriageHandler` for Spring Boot apps

- [ ] **Step 1: Add @DefaultBean producer to GovernanceBeans**

Add a new method to the existing `GovernanceBeans` class. Follow the `NoOpConfirmationProvider` pattern — separate @DefaultBean producer using @Produces.

Actually, confirmation separates the @DefaultBean into its own class (`NoOpConfirmationProvider`). Follow the same pattern for consistency.

Create: `governance/src/main/java/io/casehub/platform/governance/quarkus/NoOpTriageProvider.java`

```java
// governance/.../quarkus/NoOpTriageProvider.java
package io.casehub.platform.governance.quarkus;

import io.casehub.platform.api.governance.TriageHandler;
import io.casehub.platform.governance.NoOpTriageHandler;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Produces;

@ApplicationScoped
public class NoOpTriageProvider {

    @Produces
    @DefaultBean
    @ApplicationScoped
    TriageHandler noOpTriageHandler() {
        return new NoOpTriageHandler();
    }
}
```

- [ ] **Step 2: Create governance-spring pom.xml**

Follow the `confirmation-spring/pom.xml` pattern exactly.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.4-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-governance-spring</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Governance Spring</name>
    <description>Spring Boot auto-configuration for governance triage.
        @ConditionalOnMissingBean fail-closed handler. No quarkus:build goal.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-governance-core</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-autoconfigure</artifactId>
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

- [ ] **Step 3: Create GovernanceTriageAutoConfiguration**

```java
// governance-spring/.../spring/GovernanceTriageAutoConfiguration.java
package io.casehub.platform.governance.spring;

import io.casehub.platform.api.governance.TriageHandler;
import io.casehub.platform.governance.NoOpTriageHandler;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;

@AutoConfiguration
public class GovernanceTriageAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    TriageHandler noOpTriageHandler() {
        return new NoOpTriageHandler();
    }
}
```

- [ ] **Step 4: Create Spring auto-config imports file**

```
io.casehub.platform.governance.spring.GovernanceTriageAutoConfiguration
```

Path: `governance-spring/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`

- [ ] **Step 5: Add governance-spring to root pom.xml modules**

Add `<module>governance-spring</module>` after the existing `governance` module entry.

- [ ] **Step 6: Build the full project**

Run: `mvn --batch-mode install -DskipTests`
Expected: BUILD SUCCESS — all modules compile, governance-spring produces a jar

- [ ] **Step 7: Run all governance tests**

Run: `mvn --batch-mode test -pl platform-api,governance-core,governance`
Expected: PASS — all tests green including new triage tests

- [ ] **Step 8: Commit**

```bash
git add governance/src/main/java/io/casehub/platform/governance/quarkus/NoOpTriageProvider.java
git add governance-spring/pom.xml
git add governance-spring/src/main/java/io/casehub/platform/governance/spring/GovernanceTriageAutoConfiguration.java
git add governance-spring/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
git add pom.xml
git commit -m "feat(#673): add @DefaultBean NoOpTriageProvider (Quarkus) + GovernanceTriageAutoConfiguration (Spring)"
```

---

### Task 4: CLAUDE.md Update + Final Verification

**Files:**
- Modify: `CLAUDE.md` — update governance module description, add governance-spring module entry, update Package Structure

**Interfaces:**
- Consumes: all types from Tasks 1-3
- Produces: updated documentation

- [ ] **Step 1: Update CLAUDE.md governance module description**

In the `governance/` module table entry, append triage handler info:
```
+ `NoOpTriageProvider @Produces @DefaultBean TriageHandler` (wraps governance-core NoOpTriageHandler — returns Abandon for all triage requests, preserving existing behavior when no intelligent handler is configured)
```

- [ ] **Step 2: Add governance-spring module entry to CLAUDE.md**

After the `governance/` entry, add:
```
| `governance-spring/` | `casehub-platform-governance-spring` | Spring Boot auto-configuration for governance triage — @ConditionalOnMissingBean NoOpTriageHandler. No quarkus:build goal |
```

- [ ] **Step 3: Update Package Structure section**

In the `.governance` entry under `## Package Structure (platform-api)`, append:
```
TriageHandler (SPI: evaluate(TriageContext) → TriageDecision — post-failure intelligent escalation gate, synchronous, virtual-thread safe),
TriageContext (record: operationId, operationType, attemptNumber, maxAttempts, failureSummary, failureDetail Map, executionContext Map),
TriageDecision (sealed: Retry(modifications Map) / Abandon(reason)),
CoordinationExhaustedEvent (CDI event record: operationId, operationType, triageAttempts, abandonReason, lastFailureDetail Map)
```

- [ ] **Step 4: Full build verification**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS with all tests passing

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(#673): update CLAUDE.md — triage handler SPI, governance-spring module"
```

---

## Deferred: CbrCaseEntry

**Blocked by:** The `.memory` package (CaseMemoryStore, MemoryInput, Memory, MemoryAttributeKeys) is not on main — exists in a worktree branch. CbrCaseEntry maps to MemoryInput and uses MemoryAttributeKeys constants (SOLUTION, OUTCOME, CONFIDENCE).

**When unblocked:** Add `CbrCaseEntry` record to `platform-api/.memory` with `toMemoryInput()` and `static from(Memory)` conversion methods. Follow the same TDD pattern as Task 1.

---

## References

- `platform-api/src/main/java/io/casehub/platform/api/governance/ExecutionPolicy.java` — existing governance records pattern
- `platform-api/src/main/java/io/casehub/platform/api/confirmation/OperationConfirmationProvider.java` — template SPI pattern (pre-execution gate)
- `confirmation-core/src/main/java/io/casehub/platform/confirmation/NoOpOperationConfirmationProvider.java` — NoOp POJO pattern
- `confirmation/src/main/java/io/casehub/platform/confirmation/quarkus/NoOpConfirmationProvider.java` — @DefaultBean CDI pattern
- `confirmation-spring/src/main/java/io/casehub/platform/confirmation/spring/ConfirmationAutoConfiguration.java` — Spring auto-config pattern
- casehubio/parent#536 — parent epic (cross-repo coordination)
- casehubio/platform#668 — original feature request
- casehubio/engine#1262 — downstream: RecoveryCoordinator triage wiring
- casehubio/agency#371 — downstream: LlmTriageHandler implementation
- casehubio/neocortex#715 — downstream: executionChainId on CbrPlanRecord
