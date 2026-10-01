# YAML Error Reporting Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #402 — Error reporting model for YAML orchestration
**Issue group:** #402

**Goal:** Create a sealed error hierarchy in yaml-core that maps internal exceptions to structured, user-facing YAML errors with step names, source locations, and error categories.

**Architecture:** Sealed `YamlError` interface in `io.casehub.yaml.core.error` with three branches (ParseError, RuntimeStepError, CoordinationError). Each branch has concrete record implementations carrying typed context. A `YamlErrorMapper` in yaml-step-runtime translates existing exceptions at the boundary. The existing `StepError` record is replaced by `YamlError` in `StepResultStore`.

**Tech Stack:** Pure Java 21 (records, sealed interfaces, pattern matching switch). No new dependencies.

## Global Constraints

- yaml-core must remain zero-dependency — all error types are pure Java records
- All orchestration primitives use `java.util.concurrent` — never `synchronized`
- J2CL-safe: no reflection, no `java.util.ServiceLoader`

---

## Batch 1: Error model types in yaml-core

### Task 1: SourceLocation, ErrorCategory, and YamlError sealed hierarchy

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/error/SourceLocation.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/error/ErrorCategory.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/error/YamlError.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/error/ParseError.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/error/RuntimeStepError.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/error/CoordinationError.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/error/YamlErrorTest.java`

**Interfaces:**
- Produces: `YamlError` sealed interface with `stepName()`, `category()`, `summary()`, `location()`, `cause()`. `SourceLocation` record with `file`, `line`, `column`, `UNKNOWN` constant. `ErrorCategory` enum with 15 values. 15 concrete record types across 3 sealed branches.

- [ ] **Step 1: Write tests for SourceLocation and error records**

```java
package io.casehub.yaml.core.error;

import org.junit.jupiter.api.Test;
import java.time.Duration;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class YamlErrorTest {

    @Test
    void sourceLocation_unknown_isNotKnown() {
        assertThat(SourceLocation.UNKNOWN.isKnown()).isFalse();
        assertThat(SourceLocation.UNKNOWN.toString()).isEqualTo("<unknown>");
    }

    @Test
    void sourceLocation_withFile_isKnown() {
        var loc = new SourceLocation("workflow.yaml", 42, 5);
        assertThat(loc.isKnown()).isTrue();
        assertThat(loc.toString()).isEqualTo("workflow.yaml:42:5");
    }

    @Test
    void sourceLocation_noColumn_omitsColumn() {
        var loc = new SourceLocation("workflow.yaml", 42, -1);
        assertThat(loc.toString()).isEqualTo("workflow.yaml:42");
    }

    @Test
    void stepActionError_summary_includesStepAndCause() {
        var err = new RuntimeStepError.StepActionError(
                "submit-order", "rest-call", "Connection refused to /api/orders",
                SourceLocation.UNKNOWN, null);
        assertThat(err.category()).isEqualTo(ErrorCategory.STEP_ACTION_FAILED);
        assertThat(err.summary()).contains("submit-order").contains("Connection refused");
    }

    @Test
    void retryExhaustedError_summary_includesAttemptCount() {
        var err = new RuntimeStepError.RetryExhaustedError(
                "submit-order", 3, "timeout", "exponential", Duration.ofSeconds(1),
                SourceLocation.UNKNOWN, null);
        assertThat(err.summary()).contains("3 retry attempts");
        assertThat(err.category()).isEqualTo(ErrorCategory.RETRY_EXHAUSTED);
    }

    @Test
    void deadlineError_summary_includesScopeAndDuration() {
        var err = new CoordinationError.DeadlineError(
                "step-a", "trading-scope", Duration.ofSeconds(30),
                new SourceLocation("flow.yaml", 10, -1), null);
        assertThat(err.summary()).contains("trading-scope").contains("PT30S");
        assertThat(err.location().toString()).isEqualTo("flow.yaml:10");
    }

    @Test
    void unknownStepError_isParseCategoryError() {
        var err = new ParseError.UnknownStepError(
                "process-payment", "nonexistent-action",
                SourceLocation.UNKNOWN, null);
        assertThat(err.category()).isEqualTo(ErrorCategory.UNKNOWN_STEP);
        assertThat(err.summary()).contains("nonexistent-action");
    }

    @Test
    void expressionEvalError_carriesVariableSnapshot() {
        var vars = Map.<String, Object>of("orderId", 42, "status", "PENDING");
        var err = new RuntimeStepError.ExpressionEvalError(
                "check-status", "status == 'ACTIVE'", "MVEL",
                "Null pointer", vars,
                SourceLocation.UNKNOWN, null);
        assertThat(err.resolvedVariables()).containsEntry("orderId", 42);
        assertThat(err.category()).isEqualTo(ErrorCategory.EXPRESSION_EVAL);
    }

    @Test
    void channelError_nullStepName_omitsStepInSummary() {
        var err = new CoordinationError.ChannelError(
                null, "order-channel", SourceLocation.UNKNOWN, null);
        assertThat(err.summary()).contains("order-channel");
        assertThat(err.summary()).doesNotContain("step");
    }
}
```

- [ ] **Step 2: Run tests — verify they fail (classes don't exist yet)**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test -Dtest=YamlErrorTest -q 2>&1 | tail -5`
Expected: compilation failure

- [ ] **Step 3: Create SourceLocation record**

```java
package io.casehub.yaml.core.error;

public record SourceLocation(String file, int line, int column) {

    public static final SourceLocation UNKNOWN = new SourceLocation(null, -1, -1);

    public boolean isKnown() { return file != null && line >= 0; }

    @Override
    public String toString() {
        if (!isKnown()) return "<unknown>";
        return file + ":" + line + (column >= 0 ? ":" + column : "");
    }
}
```

- [ ] **Step 4: Create ErrorCategory enum**

```java
package io.casehub.yaml.core.error;

public enum ErrorCategory {
    UNKNOWN_STEP, PARAMETER_VIOLATION, INVALID_STRUCTURE,
    EXPRESSION_PARSE, DUPLICATE_STEP,
    STEP_ACTION_FAILED, TIMEOUT, RETRY_EXHAUSTED, GUARD_REJECTED,
    EXPRESSION_EVAL,
    CHANNEL_CLOSED, DEADLINE_EXCEEDED, CORRELATION_TIMEOUT,
    SEMAPHORE_REENTRANCY, ILLEGAL_TRANSITION
}
```

- [ ] **Step 5: Create YamlError sealed interface**

```java
package io.casehub.yaml.core.error;

public sealed interface YamlError permits ParseError, RuntimeStepError, CoordinationError {
    String stepName();
    ErrorCategory category();
    String summary();
    SourceLocation location();
    Throwable cause();
}
```

- [ ] **Step 6: Create ParseError sealed interface with record subtypes**

```java
package io.casehub.yaml.core.error;

public sealed interface ParseError extends YamlError {

    record UnknownStepError(String stepName, String referencedAction,
                            SourceLocation location, Throwable cause) implements ParseError {
        @Override public ErrorCategory category() { return ErrorCategory.UNKNOWN_STEP; }
        @Override public String summary() {
            return "Step '" + stepName + "' references unknown action '" + referencedAction + "'";
        }
    }

    record ParameterError(String stepName, String parameterName, String constraint, String value,
                          SourceLocation location, Throwable cause) implements ParseError {
        @Override public ErrorCategory category() { return ErrorCategory.PARAMETER_VIOLATION; }
        @Override public String summary() {
            return "Parameter '" + parameterName + "' on step '" + stepName
                    + "' violates constraint: " + constraint;
        }
    }

    record ExpressionParseError(String stepName, String expressionText, String engineType,
                                String engineMessage,
                                SourceLocation location, Throwable cause) implements ParseError {
        @Override public ErrorCategory category() { return ErrorCategory.EXPRESSION_PARSE; }
        @Override public String summary() {
            return engineType + " expression failed to parse on step '" + stepName
                    + "': " + engineMessage;
        }
    }

    record StructureError(String stepName, String detail,
                          SourceLocation location, Throwable cause) implements ParseError {
        @Override public ErrorCategory category() { return ErrorCategory.INVALID_STRUCTURE; }
        @Override public String summary() {
            return "Invalid YAML structure"
                    + (stepName != null ? " at step '" + stepName + "'" : "")
                    + ": " + detail;
        }
    }

    record DuplicateStepError(String stepName,
                              SourceLocation location, Throwable cause) implements ParseError {
        @Override public ErrorCategory category() { return ErrorCategory.DUPLICATE_STEP; }
        @Override public String summary() {
            return "Duplicate step name '" + stepName + "'";
        }
    }
}
```

- [ ] **Step 7: Create RuntimeStepError sealed interface with record subtypes**

```java
package io.casehub.yaml.core.error;

import java.time.Duration;
import java.util.Map;

public sealed interface RuntimeStepError extends YamlError {

    record StepActionError(String stepName, String actionName, String rootCause,
                           SourceLocation location, Throwable cause) implements RuntimeStepError {
        @Override public ErrorCategory category() { return ErrorCategory.STEP_ACTION_FAILED; }
        @Override public String summary() {
            return "Step '" + stepName + "' action '" + actionName + "' failed: " + rootCause;
        }
    }

    record TimeoutError(String stepName, Duration timeout,
                        SourceLocation location, Throwable cause) implements RuntimeStepError {
        @Override public ErrorCategory category() { return ErrorCategory.TIMEOUT; }
        @Override public String summary() {
            return "Step '" + stepName + "' timed out after " + timeout;
        }
    }

    record RetryExhaustedError(String stepName, int maxAttempts, String lastError,
                               String backoffStrategy, Duration delay,
                               SourceLocation location, Throwable cause) implements RuntimeStepError {
        @Override public ErrorCategory category() { return ErrorCategory.RETRY_EXHAUSTED; }
        @Override public String summary() {
            return "Step '" + stepName + "' failed after " + maxAttempts
                    + " retry attempts. Last error: " + lastError;
        }
    }

    record GuardRejectedError(String stepName, String guardExpression, String reason,
                              SourceLocation location, Throwable cause) implements RuntimeStepError {
        @Override public ErrorCategory category() { return ErrorCategory.GUARD_REJECTED; }
        @Override public String summary() {
            return "Step '" + stepName + "' guard rejected: " + reason;
        }
    }

    record ExpressionEvalError(String stepName, String expressionText, String engineType,
                               String engineMessage, Map<String, Object> resolvedVariables,
                               SourceLocation location, Throwable cause) implements RuntimeStepError {
        public ExpressionEvalError {
            resolvedVariables = resolvedVariables != null ? Map.copyOf(resolvedVariables) : Map.of();
        }
        @Override public ErrorCategory category() { return ErrorCategory.EXPRESSION_EVAL; }
        @Override public String summary() {
            return engineType + " expression failed on step '" + stepName
                    + "': " + engineMessage;
        }
    }
}
```

- [ ] **Step 8: Create CoordinationError sealed interface with record subtypes**

```java
package io.casehub.yaml.core.error;

import java.time.Duration;

public sealed interface CoordinationError extends YamlError {

    record ChannelError(String stepName, String channelName,
                        SourceLocation location, Throwable cause) implements CoordinationError {
        @Override public ErrorCategory category() { return ErrorCategory.CHANNEL_CLOSED; }
        @Override public String summary() {
            return "Channel '" + channelName + "' closed"
                    + (stepName != null ? " while step '" + stepName + "' was waiting" : "");
        }
    }

    record DeadlineError(String stepName, String scopeName, Duration deadline,
                         SourceLocation location, Throwable cause) implements CoordinationError {
        @Override public ErrorCategory category() { return ErrorCategory.DEADLINE_EXCEEDED; }
        @Override public String summary() {
            return "Deadline exceeded in scope '" + scopeName + "' after " + deadline
                    + (stepName != null ? " (step '" + stepName + "')" : "");
        }
    }

    record CorrelationError(String stepName, Object correlationKey, Duration timeout,
                            SourceLocation location, Throwable cause) implements CoordinationError {
        @Override public ErrorCategory category() { return ErrorCategory.CORRELATION_TIMEOUT; }
        @Override public String summary() {
            return "Correlation timeout for key '" + correlationKey + "' after " + timeout
                    + (stepName != null ? " (step '" + stepName + "')" : "");
        }
    }

    record SemaphoreError(String stepName, String semaphoreName,
                          SourceLocation location, Throwable cause) implements CoordinationError {
        @Override public ErrorCategory category() { return ErrorCategory.SEMAPHORE_REENTRANCY; }
        @Override public String summary() {
            return "Reentrant acquire on semaphore '" + semaphoreName + "'"
                    + (stepName != null ? " by step '" + stepName + "'" : "");
        }
    }

    record TransitionError(String stepName, String machineName, Object fromState, Object toState,
                           SourceLocation location, Throwable cause) implements CoordinationError {
        @Override public ErrorCategory category() { return ErrorCategory.ILLEGAL_TRANSITION; }
        @Override public String summary() {
            return "Invalid transition in '" + machineName + "': " + fromState + " -> " + toState;
        }
    }
}
```

- [ ] **Step 9: Run tests — verify they pass**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test -Dtest=YamlErrorTest -q`
Expected: all 8 tests PASS

- [ ] **Step 10: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/error/ yaml-core/src/test/java/io/casehub/yaml/core/error/
git commit -m "feat(#402): YamlError sealed hierarchy — SourceLocation, ErrorCategory, 15 error records

Refs #402"
```

### Task 2: YamlErrorCollector and YamlValidationException

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/error/YamlErrorCollector.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/error/YamlValidationException.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/error/YamlErrorCollectorTest.java`

**Interfaces:**
- Consumes: `YamlError`, `ParseError` subtypes from Task 1
- Produces: `YamlErrorCollector` (add/hasErrors/errors/throwIfErrors), `YamlValidationException` (extends RuntimeException, carries `List<YamlError>`)

- [ ] **Step 1: Write tests**

```java
package io.casehub.yaml.core.error;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class YamlErrorCollectorTest {

    @Test
    void empty_hasNoErrors() {
        var collector = new YamlErrorCollector();
        assertThat(collector.hasErrors()).isFalse();
        assertThat(collector.errors()).isEmpty();
    }

    @Test
    void add_collectsErrors() {
        var collector = new YamlErrorCollector();
        collector.add(new ParseError.UnknownStepError("s1", "action-a", SourceLocation.UNKNOWN, null));
        collector.add(new ParseError.DuplicateStepError("s2", SourceLocation.UNKNOWN, null));
        assertThat(collector.hasErrors()).isTrue();
        assertThat(collector.errors()).hasSize(2);
    }

    @Test
    void throwIfErrors_noErrors_doesNotThrow() {
        new YamlErrorCollector().throwIfErrors();
    }

    @Test
    void throwIfErrors_withErrors_throwsValidationException() {
        var collector = new YamlErrorCollector();
        collector.add(new ParseError.UnknownStepError("s1", "x", SourceLocation.UNKNOWN, null));
        assertThatThrownBy(collector::throwIfErrors)
                .isInstanceOf(YamlValidationException.class)
                .satisfies(ex -> {
                    var ve = (YamlValidationException) ex;
                    assertThat(ve.errors()).hasSize(1);
                    assertThat(ve.getMessage()).contains("1 validation error");
                });
    }

    @Test
    void validationException_messageIncludesSummaries() {
        var collector = new YamlErrorCollector();
        collector.add(new ParseError.UnknownStepError("s1", "a", SourceLocation.UNKNOWN, null));
        collector.add(new ParseError.DuplicateStepError("s2", SourceLocation.UNKNOWN, null));
        assertThatThrownBy(collector::throwIfErrors)
                .hasMessageContaining("2 validation error")
                .hasMessageContaining("unknown action")
                .hasMessageContaining("Duplicate step");
    }

    @Test
    void errors_returnsDefensiveCopy() {
        var collector = new YamlErrorCollector();
        collector.add(new ParseError.DuplicateStepError("s1", SourceLocation.UNKNOWN, null));
        var list = collector.errors();
        collector.add(new ParseError.DuplicateStepError("s2", SourceLocation.UNKNOWN, null));
        assertThat(list).hasSize(1);
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test -Dtest=YamlErrorCollectorTest -q 2>&1 | tail -5`
Expected: compilation failure

- [ ] **Step 3: Create YamlValidationException**

```java
package io.casehub.yaml.core.error;

import java.util.List;
import java.util.stream.Collectors;

public class YamlValidationException extends RuntimeException {

    private final List<YamlError> errors;

    public YamlValidationException(List<YamlError> errors) {
        super(errors.size() + " validation error(s):\n"
                + errors.stream().map(YamlError::summary)
                        .collect(Collectors.joining("\n  - ", "  - ", "")));
        this.errors = List.copyOf(errors);
    }

    public List<YamlError> errors() { return errors; }
}
```

- [ ] **Step 4: Create YamlErrorCollector**

```java
package io.casehub.yaml.core.error;

import java.util.ArrayList;
import java.util.List;

public final class YamlErrorCollector {

    private final List<YamlError> errors = new ArrayList<>();

    public void add(YamlError error) { errors.add(error); }

    public boolean hasErrors() { return !errors.isEmpty(); }

    public List<YamlError> errors() { return List.copyOf(errors); }

    public void throwIfErrors() {
        if (!errors.isEmpty()) {
            throw new YamlValidationException(List.copyOf(errors));
        }
    }
}
```

- [ ] **Step 5: Run tests — verify they pass**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test -Dtest=YamlErrorCollectorTest -q`
Expected: all 6 tests PASS

- [ ] **Step 6: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/error/YamlErrorCollector.java yaml-core/src/main/java/io/casehub/yaml/core/error/YamlValidationException.java yaml-core/src/test/java/io/casehub/yaml/core/error/YamlErrorCollectorTest.java
git commit -m "feat(#402): YamlErrorCollector and YamlValidationException

Refs #402"
```

## Batch 2: Boundary mapper and StepError migration

### Task 3: YamlErrorMapper in yaml-step-runtime

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/error/YamlErrorMapper.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/error/YamlErrorMapperTest.java`

**Interfaces:**
- Consumes: `YamlError` hierarchy from Task 1, existing exception classes from yaml-core (`DeadlineExceededException`, `ChannelClosedException`, `CorrelationTimeoutException`, `SemaphoreReentrancyException`, `IllegalTransitionException`, `UnresolvedVariableException`, `ConditionEvaluationException`, `ParameterValidationException`)
- Produces: `YamlErrorMapper.from(Throwable, String, SourceLocation) → YamlError`

- [ ] **Step 1: Write tests**

```java
package io.casehub.yaml.step.error;

import io.casehub.yaml.core.error.*;
import io.casehub.yaml.core.orchestration.*;
import io.casehub.yaml.core.condition.ConditionEvaluationException;
import io.casehub.yaml.core.module.ParameterValidationException;
import io.casehub.yaml.core.module.ParameterViolation;
import io.casehub.yaml.core.resolver.UnresolvedVariableException;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class YamlErrorMapperTest {

    private static final SourceLocation LOC = new SourceLocation("test.yaml", 10, -1);

    @Test
    void deadlineExceeded_mapsToDeadlineError() {
        var ex = new DeadlineExceededException("my-scope", Duration.ofSeconds(5));
        YamlError err = YamlErrorMapper.from(ex, "step-a", LOC);
        assertThat(err).isInstanceOf(CoordinationError.DeadlineError.class);
        assertThat(err.category()).isEqualTo(ErrorCategory.DEADLINE_EXCEEDED);
        var de = (CoordinationError.DeadlineError) err;
        assertThat(de.scopeName()).isEqualTo("my-scope");
        assertThat(de.deadline()).isEqualTo(Duration.ofSeconds(5));
    }

    @Test
    void channelClosed_mapsToChannelError() {
        var ex = new ChannelClosedException("order-ch");
        YamlError err = YamlErrorMapper.from(ex, "step-b", LOC);
        assertThat(err).isInstanceOf(CoordinationError.ChannelError.class);
        assertThat(err.category()).isEqualTo(ErrorCategory.CHANNEL_CLOSED);
    }

    @Test
    void semaphoreReentrancy_mapsToSemaphoreError() {
        var ex = new SemaphoreReentrancyException("gate", "step-c");
        YamlError err = YamlErrorMapper.from(ex, "step-c", LOC);
        assertThat(err).isInstanceOf(CoordinationError.SemaphoreError.class);
        assertThat(err.category()).isEqualTo(ErrorCategory.SEMAPHORE_REENTRANCY);
    }

    @Test
    void illegalTransition_mapsToTransitionError() {
        var ex = new IllegalTransitionException("fsm", "IDLE", "COMPLETED");
        YamlError err = YamlErrorMapper.from(ex, "step-d", LOC);
        assertThat(err).isInstanceOf(CoordinationError.TransitionError.class);
        assertThat(err.category()).isEqualTo(ErrorCategory.ILLEGAL_TRANSITION);
    }

    @Test
    void unresolvedVariable_mapsToExpressionEvalError() {
        var ex = new UnresolvedVariableException("orderId", "step-e", "No source found");
        YamlError err = YamlErrorMapper.from(ex, "step-e", LOC);
        assertThat(err).isInstanceOf(RuntimeStepError.ExpressionEvalError.class);
        assertThat(err.category()).isEqualTo(ErrorCategory.EXPRESSION_EVAL);
    }

    @Test
    void conditionEvaluation_mapsToExpressionEvalError() {
        var ex = new ConditionEvaluationException("Null pointer in expression");
        YamlError err = YamlErrorMapper.from(ex, "step-f", LOC);
        assertThat(err).isInstanceOf(RuntimeStepError.ExpressionEvalError.class);
    }

    @Test
    void parameterValidation_mapsToParameterError() {
        var ex = new ParameterValidationException(
                List.of(new ParameterViolation("retries", "min", "0", "must be >= 1")));
        YamlError err = YamlErrorMapper.from(ex, "step-g", LOC);
        assertThat(err).isInstanceOf(ParseError.ParameterError.class);
        assertThat(err.category()).isEqualTo(ErrorCategory.PARAMETER_VIOLATION);
    }

    @Test
    void unknownException_mapsToStepActionError() {
        var ex = new RuntimeException("Something unexpected");
        YamlError err = YamlErrorMapper.from(ex, "step-h", LOC);
        assertThat(err).isInstanceOf(RuntimeStepError.StepActionError.class);
        assertThat(err.category()).isEqualTo(ErrorCategory.STEP_ACTION_FAILED);
        assertThat(err.summary()).contains("Something unexpected");
    }

    @Test
    void nullStepName_acceptedGracefully() {
        var ex = new ChannelClosedException("ch");
        YamlError err = YamlErrorMapper.from(ex, null, LOC);
        assertThat(err.stepName()).isNull();
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

Run: `/opt/homebrew/bin/mvn -f yaml-step-runtime/pom.xml test -Dtest=YamlErrorMapperTest -q 2>&1 | tail -5`
Expected: compilation failure

- [ ] **Step 3: Check ParameterViolation record signature**

Read: `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterViolation.java`
Verify the record fields match what the test expects.

- [ ] **Step 4: Create YamlErrorMapper**

```java
package io.casehub.yaml.step.error;

import io.casehub.yaml.core.condition.ConditionEvaluationException;
import io.casehub.yaml.core.error.*;
import io.casehub.yaml.core.module.ParameterValidationException;
import io.casehub.yaml.core.orchestration.*;
import io.casehub.yaml.core.resolver.UnresolvedVariableException;

import java.util.Map;

public final class YamlErrorMapper {

    private YamlErrorMapper() {}

    public static YamlError from(Throwable t, String stepName, SourceLocation location) {
        return switch (t) {
            case DeadlineExceededException e ->
                    new CoordinationError.DeadlineError(stepName, e.scopeName(), e.deadline(), location, e);
            case ChannelClosedException e ->
                    new CoordinationError.ChannelError(stepName, e.getMessage(), location, e);
            case CorrelationTimeoutException e ->
                    new CoordinationError.CorrelationError(stepName, null, null, location, e);
            case SemaphoreReentrancyException e ->
                    new CoordinationError.SemaphoreError(stepName, e.getMessage(), location, e);
            case IllegalTransitionException e ->
                    new CoordinationError.TransitionError(stepName, null, null, null, location, e);
            case UnresolvedVariableException e ->
                    new RuntimeStepError.ExpressionEvalError(
                            stepName, e.variableName(), "variable",
                            e.getMessage(), Map.of(), location, e);
            case ConditionEvaluationException e ->
                    new RuntimeStepError.ExpressionEvalError(
                            stepName, null, "condition",
                            e.getMessage(), Map.of(), location, e);
            case ParameterValidationException e ->
                    new ParseError.ParameterError(
                            stepName,
                            e.violations().isEmpty() ? "" : e.violations().get(0).parameterName(),
                            e.getMessage(), null, location, e);
            default ->
                    new RuntimeStepError.StepActionError(
                            stepName, null, t.getMessage(), location, t);
        };
    }
}
```

- [ ] **Step 5: Run tests — verify they pass**

Run: `/opt/homebrew/bin/mvn -f yaml-step-runtime/pom.xml test -Dtest=YamlErrorMapperTest -q`
Expected: all 9 tests PASS

- [ ] **Step 6: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/error/ yaml-step-runtime/src/test/java/io/casehub/yaml/step/error/
git commit -m "feat(#402): YamlErrorMapper — boundary translation from exceptions to YamlError

Refs #402"
```

### Task 4: Migrate StepResultStore from StepError to YamlError

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/StepResultStore.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultStepResultStore.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/DefaultStepResultStoreTest.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java:392-436`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/scenario/CompiledScenario.java:80-86`
- Delete: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/StepError.java` (use `ide_refactor_safe_delete`)

**Interfaces:**
- Consumes: `YamlError` from Task 1, `YamlErrorMapper` from Task 3
- Produces: `StepResultStore.recordFailure(String, YamlError)`, `StepResultStore.error(String) → YamlError`

- [ ] **Step 1: Update DefaultStepResultStoreTest to use YamlError**

Replace `StepError` references with `RuntimeStepError.StepActionError`:

```java
// Line 22: replace
var error = new StepError("failed", "RuntimeException", "at Test.run");
// with
var error = new RuntimeStepError.StepActionError("step1", null, "failed", SourceLocation.UNKNOWN, null);

// Line 50: replace
store.recordFailure("step1", new StepError("err", "E", ""));
// with
store.recordFailure("step1", new RuntimeStepError.StepActionError("step1", null, "err", SourceLocation.UNKNOWN, null));
```

Add imports: `io.casehub.yaml.core.error.*`

- [ ] **Step 2: Run tests — verify they fail (StepResultStore still uses StepError)**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test -Dtest=DefaultStepResultStoreTest -q 2>&1 | tail -5`
Expected: compilation failure

- [ ] **Step 3: Update StepResultStore interface**

Replace `StepError` with `YamlError` in both methods:

```java
// recordFailure signature: StepError → YamlError
void recordFailure(String stepName, io.casehub.yaml.core.error.YamlError error);

// error return type: StepError → YamlError
io.casehub.yaml.core.error.YamlError error(String stepName);
```

- [ ] **Step 4: Update DefaultStepResultStore**

Replace `ConcurrentHashMap<String, StepError>` with `ConcurrentHashMap<String, io.casehub.yaml.core.error.YamlError>`. Update method signatures to match.

- [ ] **Step 5: Run yaml-core tests — verify they pass**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test -q`
Expected: PASS

- [ ] **Step 6: Update StructuralStepEvaluator.recordResult**

Replace lines 398-400. Change:
```java
String message = result instanceof Result.Failure f ? f.message() : "unknown error";
store.recordFailure(stepName,
                    new io.casehub.yaml.core.orchestration.StepError(message, null, null));
```
To:
```java
String message = result instanceof Result.Failure f ? f.message() : "unknown error";
store.recordFailure(stepName,
                    new io.casehub.yaml.core.error.RuntimeStepError.StepActionError(
                            stepName, null, message,
                            io.casehub.yaml.core.error.SourceLocation.UNKNOWN, null));
```

- [ ] **Step 7: Update StructuralStepEvaluator.buildResultSource**

Replace lines 421-434. Change the error Map construction to use `YamlError` fields:
```java
io.casehub.yaml.core.error.YamlError err = store.error(name);
// ...
if (output == null) {
    return Map.of("error", Map.of(
            "message", err.summary(),
            "category", err.category().name(),
            "step", err.stepName() != null ? err.stepName() : ""));
}
// ... (same pattern for composite case)
```

- [ ] **Step 8: Update CompiledScenario.executeSteps**

Replace lines 82-84. Change:
```java
String message = result instanceof Result.Failure f ? f.message() : "unknown error";
scope.resultStore().recordFailure(stepName,
        new io.casehub.yaml.core.orchestration.StepError(message, null, null));
```
To:
```java
String message = result instanceof Result.Failure f ? f.message() : "unknown error";
scope.resultStore().recordFailure(stepName,
        new io.casehub.yaml.core.error.RuntimeStepError.StepActionError(
                stepName, null, message,
                io.casehub.yaml.core.error.SourceLocation.UNKNOWN, null));
```

- [ ] **Step 9: Safe-delete StepError.java**

Use `ide_refactor_safe_delete` on `io.casehub.yaml.core.orchestration.StepError`. If references remain (docs), remove them manually.

- [ ] **Step 10: Run full yaml-core + yaml-step-runtime tests**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test -q && /opt/homebrew/bin/mvn -f yaml-step-runtime/pom.xml test -q`
Expected: PASS

- [ ] **Step 11: Commit**

```bash
git add yaml-core/ yaml-step-runtime/
git commit -m "refactor(#402): migrate StepResultStore from StepError to YamlError

StepError record replaced by sealed YamlError hierarchy. StepResultStore,
DefaultStepResultStore, StructuralStepEvaluator, and CompiledScenario updated.

Refs #402"
```

## Batch 3: StepContext extension

### Task 5: Add SourceLocation to StepContext

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StepContext.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/StepContextTest.java` (create if not exists)

**Interfaces:**
- Consumes: `SourceLocation` from Task 1
- Produces: `StepContext.location()`, `StepContext.withLocation(SourceLocation)`

- [ ] **Step 1: Write test**

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.error.SourceLocation;
import io.casehub.yaml.core.resolver.VariableResolver;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class StepContextTest {

    private final VariableResolver noOpResolver = (name, ctx) -> null;

    @Test
    void defaultLocation_isUnknown() {
        var ctx = new StepContext(noOpResolver);
        assertThat(ctx.location()).isEqualTo(SourceLocation.UNKNOWN);
    }

    @Test
    void withLocation_returnsNewContextWithLocation() {
        var ctx = new StepContext(noOpResolver);
        var loc = new SourceLocation("flow.yaml", 42, 5);
        var updated = ctx.withLocation(loc);
        assertThat(updated.location()).isEqualTo(loc);
        assertThat(updated.resolver()).isSameAs(ctx.resolver());
        assertThat(updated.deadline()).isSameAs(ctx.deadline());
    }
}
```

- [ ] **Step 2: Run test — verify it fails**

Run: `/opt/homebrew/bin/mvn -f yaml-step-runtime/pom.xml test -Dtest=StepContextTest -q 2>&1 | tail -5`
Expected: compilation failure (no `location()` method)

- [ ] **Step 3: Add SourceLocation field to StepContext**

Add field, update constructors to default to `SourceLocation.UNKNOWN`, add `location()` accessor and `withLocation()` factory:

```java
private final SourceLocation location;

public StepContext(VariableResolver resolver) {
    this(resolver, DeadlineContext.NONE, SourceLocation.UNKNOWN);
}

public StepContext(VariableResolver resolver, DeadlineContext deadline) {
    this(resolver, deadline, SourceLocation.UNKNOWN);
}

public StepContext(VariableResolver resolver, DeadlineContext deadline, SourceLocation location) {
    this.resolver = resolver;
    this.deadline = deadline;
    this.location = location;
}

public SourceLocation location() { return location; }

public StepContext withLocation(SourceLocation location) {
    return new StepContext(resolver, deadline, location);
}

public StepContext withDeadline(Duration timeout) {
    return new StepContext(resolver, deadline.withTimeout(timeout), location);
}
```

- [ ] **Step 4: Run tests — verify they pass**

Run: `/opt/homebrew/bin/mvn -f yaml-step-runtime/pom.xml test -q`
Expected: all tests PASS

- [ ] **Step 5: Run full platform build**

Run: `/opt/homebrew/bin/mvn --batch-mode install -q`
Expected: BUILD SUCCESS

- [ ] **Step 6: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StepContext.java yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/StepContextTest.java
git commit -m "feat(#402): add SourceLocation to StepContext for error location threading

Refs #402"
```

## References

- `specs/epic-502-yaml-parity/2026-10-01-yaml-error-reporting-design.md` — design spec
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/StepError.java:3` — existing record being replaced
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/StepResultStore.java:7-9` — SPI consuming StepError
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultStepResultStore.java` — impl
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java:392-436` — creation and resolution sites
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/scenario/CompiledScenario.java:80-86` — creation site
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StepContext.java` — context threading point
- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Result.java` — existing sealed Success/Failure pattern
- casehubio/platform#402 — focal issue
- casehubio/platform#386 — predecessor (orchestration primitives)
