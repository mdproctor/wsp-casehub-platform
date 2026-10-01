# YAML Error Reporting Model — Design Spec

**Issue:** casehubio/platform#402
**Date:** 2026-10-01
**Module:** yaml-core (`io.casehub.yaml.core.error`), yaml-step-runtime (`YamlErrorMapper`)

## Problem

When a YAML step fails at runtime, the error surfaces as a raw Java exception — `DeadlineExceededException`, `ChannelClosedException`, or a bare `StepError(message, exceptionClass, stackTrace)`. YAML authors can't map these to their step names, decorator configuration, or YAML source locations.

## Design

### 1. Error taxonomy — sealed hierarchy in yaml-core

All error types live in `io.casehub.yaml.core.error`. Pure Java records, zero external dependencies.

```java
public sealed interface YamlError
        permits ParseError, RuntimeStepError, CoordinationError {

    String stepName();
    ErrorCategory category();
    String summary();
    SourceLocation location();
    Throwable cause();
}
```

**ErrorCategory enum:**

```java
public enum ErrorCategory {
    // Parse-time
    UNKNOWN_STEP, PARAMETER_VIOLATION, INVALID_STRUCTURE,
    EXPRESSION_PARSE, DUPLICATE_STEP,

    // Runtime
    STEP_ACTION_FAILED, TIMEOUT, RETRY_EXHAUSTED, GUARD_REJECTED,
    EXPRESSION_EVAL,

    // Coordination
    CHANNEL_CLOSED, DEADLINE_EXCEEDED, CORRELATION_TIMEOUT,
    SEMAPHORE_REENTRANCY, ILLEGAL_TRANSITION
}
```

**Parse errors** — detected during YAML loading and step resolution:

```java
public sealed interface ParseError extends YamlError
        permits UnknownStepError, ParameterError, ExpressionParseError,
                StructureError, DuplicateStepError {
}

public record UnknownStepError(
        String stepName, String referencedAction,
        SourceLocation location, Throwable cause) implements ParseError {
    @Override public ErrorCategory category() { return UNKNOWN_STEP; }
    @Override public String summary() {
        return "Step '" + stepName + "' references unknown action '" + referencedAction + "'";
    }
}

public record ParameterError(
        String stepName, String parameterName, String constraint, String value,
        SourceLocation location, Throwable cause) implements ParseError {
    @Override public ErrorCategory category() { return PARAMETER_VIOLATION; }
    @Override public String summary() {
        return "Parameter '" + parameterName + "' on step '" + stepName
                + "' violates constraint: " + constraint;
    }
}

public record ExpressionParseError(
        String stepName, String expressionText, String engineType,
        String engineMessage,
        SourceLocation location, Throwable cause) implements ParseError {
    @Override public ErrorCategory category() { return EXPRESSION_PARSE; }
    @Override public String summary() {
        return engineType + " expression failed to parse on step '" + stepName
                + "': " + engineMessage;
    }
}

public record StructureError(
        String stepName, String detail,
        SourceLocation location, Throwable cause) implements ParseError {
    @Override public ErrorCategory category() { return INVALID_STRUCTURE; }
    @Override public String summary() {
        return "Invalid YAML structure" + (stepName != null ? " at step '" + stepName + "'" : "")
                + ": " + detail;
    }
}

public record DuplicateStepError(
        String stepName,
        SourceLocation location, Throwable cause) implements ParseError {
    @Override public ErrorCategory category() { return DUPLICATE_STEP; }
    @Override public String summary() {
        return "Duplicate step name '" + stepName + "'";
    }
}
```

**Runtime step errors** — failures during step execution:

```java
public sealed interface RuntimeStepError extends YamlError
        permits StepActionError, TimeoutError, RetryExhaustedError,
                GuardRejectedError, ExpressionEvalError {
}

public record StepActionError(
        String stepName, String actionName, String rootCause,
        SourceLocation location, Throwable cause) implements RuntimeStepError {
    @Override public ErrorCategory category() { return STEP_ACTION_FAILED; }
    @Override public String summary() {
        return "Step '" + stepName + "' action '" + actionName + "' failed: " + rootCause;
    }
}

public record TimeoutError(
        String stepName, java.time.Duration timeout,
        SourceLocation location, Throwable cause) implements RuntimeStepError {
    @Override public ErrorCategory category() { return TIMEOUT; }
    @Override public String summary() {
        return "Step '" + stepName + "' timed out after " + timeout;
    }
}

public record RetryExhaustedError(
        String stepName, int maxAttempts, String lastError,
        String backoffStrategy, java.time.Duration delay,
        SourceLocation location, Throwable cause) implements RuntimeStepError {
    @Override public ErrorCategory category() { return RETRY_EXHAUSTED; }
    @Override public String summary() {
        return "Step '" + stepName + "' failed after " + maxAttempts
                + " retry attempts. Last error: " + lastError;
    }
}

public record GuardRejectedError(
        String stepName, String guardExpression, String reason,
        SourceLocation location, Throwable cause) implements RuntimeStepError {
    @Override public ErrorCategory category() { return GUARD_REJECTED; }
    @Override public String summary() {
        return "Step '" + stepName + "' guard rejected: " + reason;
    }
}

public record ExpressionEvalError(
        String stepName, String expressionText, String engineType,
        String engineMessage, java.util.Map<String, Object> resolvedVariables,
        SourceLocation location, Throwable cause) implements RuntimeStepError {
    @Override public ErrorCategory category() { return EXPRESSION_EVAL; }
    @Override public String summary() {
        return engineType + " expression failed on step '" + stepName
                + "': " + engineMessage;
    }
}
```

**Coordination errors** — orchestration primitive failures:

```java
public sealed interface CoordinationError extends YamlError
        permits ChannelError, DeadlineError, CorrelationError,
                SemaphoreError, TransitionError {
}

public record ChannelError(
        String stepName, String channelName,
        SourceLocation location, Throwable cause) implements CoordinationError {
    @Override public ErrorCategory category() { return CHANNEL_CLOSED; }
    @Override public String summary() {
        return "Channel '" + channelName + "' closed"
                + (stepName != null ? " while step '" + stepName + "' was waiting" : "");
    }
}

public record DeadlineError(
        String stepName, String scopeName, java.time.Duration deadline,
        SourceLocation location, Throwable cause) implements CoordinationError {
    @Override public ErrorCategory category() { return DEADLINE_EXCEEDED; }
    @Override public String summary() {
        return "Deadline exceeded in scope '" + scopeName + "' after " + deadline
                + (stepName != null ? " (step '" + stepName + "')" : "");
    }
}

public record CorrelationError(
        String stepName, Object correlationKey, java.time.Duration timeout,
        SourceLocation location, Throwable cause) implements CoordinationError {
    @Override public ErrorCategory category() { return CORRELATION_TIMEOUT; }
    @Override public String summary() {
        return "Correlation timeout for key '" + correlationKey + "' after " + timeout
                + (stepName != null ? " (step '" + stepName + "')" : "");
    }
}

public record SemaphoreError(
        String stepName, String semaphoreName,
        SourceLocation location, Throwable cause) implements CoordinationError {
    @Override public ErrorCategory category() { return SEMAPHORE_REENTRANCY; }
    @Override public String summary() {
        return "Reentrant acquire on semaphore '" + semaphoreName + "'"
                + (stepName != null ? " by step '" + stepName + "'" : "");
    }
}

public record TransitionError(
        String stepName, String machineName, Object fromState, Object toState,
        SourceLocation location, Throwable cause) implements CoordinationError {
    @Override public ErrorCategory category() { return ILLEGAL_TRANSITION; }
    @Override public String summary() {
        return "Invalid transition in '" + machineName + "': " + fromState + " -> " + toState;
    }
}
```

### 2. SourceLocation record

```java
// io.casehub.yaml.core.error
public record SourceLocation(String file, int line, int column) {
    public static final SourceLocation UNKNOWN = new SourceLocation(null, -1, -1);

    public boolean isKnown() { return file != null && line >= 0; }

    @Override public String toString() {
        if (!isKnown()) return "<unknown>";
        return file + ":" + line + (column >= 0 ? ":" + column : "");
    }
}
```

### 3. StepContext extension

Add `SourceLocation` to `StepContext` so it's available at the error boundary:

```java
public final class StepContext {
    private final VariableResolver resolver;
    private final DeadlineContext deadline;
    private final SourceLocation location;  // new

    // existing constructors default location to SourceLocation.UNKNOWN
}
```

### 4. YamlErrorMapper — boundary translation

In `yaml-step-runtime` (`io.casehub.yaml.step.error`):

```java
public final class YamlErrorMapper {

    public static YamlError from(Throwable t, String stepName, SourceLocation location) {
        return switch (t) {
            case DeadlineExceededException e ->
                new DeadlineError(stepName, e.scopeName(), e.deadline(), location, e);
            case ChannelClosedException e ->
                new ChannelError(stepName, e.getMessage(), location, e);
            case CorrelationTimeoutException e ->
                new CorrelationError(stepName, /* key */ null, /* timeout */ null, location, e);
            case SemaphoreReentrancyException e ->
                new SemaphoreError(stepName, e.getMessage(), location, e);
            case IllegalTransitionException e ->
                new TransitionError(stepName, null, null, null, location, e);
            case UnresolvedVariableException e ->
                new ExpressionEvalError(stepName, e.variableName(), "variable",
                        e.getMessage(), Map.of(), location, e);
            case ConditionEvaluationException e ->
                new ExpressionEvalError(stepName, null, "condition",
                        e.getMessage(), Map.of(), location, e);
            case ParameterValidationException e ->
                new ParameterError(stepName, /* first violation */ 
                        e.violations().isEmpty() ? "" : e.violations().get(0).parameterName(),
                        e.getMessage(), null, location, e);
            default ->
                new StepActionError(stepName, null, t.getMessage(), location, t);
        };
    }
}
```

### 5. YamlErrorCollector — collect-all pattern

For parse-time validation that should report all errors (not fail on first):

```java
public final class YamlErrorCollector {
    private final List<YamlError> errors = new ArrayList<>();

    public void add(YamlError error) { errors.add(error); }
    public boolean hasErrors() { return !errors.isEmpty(); }
    public List<YamlError> errors() { return List.copyOf(errors); }

    public void throwIfErrors() {
        if (!errors.isEmpty()) {
            throw new YamlValidationException(errors);
        }
    }
}
```

### 6. YamlValidationException

Wraps multiple parse errors for fail-fast at the parse boundary:

```java
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

### 7. StepError migration

The existing `StepError(message, exceptionClass, stackTrace)` record is replaced by `YamlError`. Call sites that create `StepError` switch to `YamlErrorMapper.from()`. The `StepResultStore` and any serialization that uses `StepError` migrates to `YamlError`.

### 8. What this does NOT include

- **Guidance/remediation hints** — consumer concern, not error model
- **YAML line-number tracking in Jackson** — separate follow-up; `SourceLocation.UNKNOWN` used until then
- **Error rendering/formatting** — consumers format `YamlError` for their context (CLI, MCP, web)

## Module placement

| Type | Module | Package |
|------|--------|---------|
| `YamlError` sealed hierarchy | yaml-core | `io.casehub.yaml.core.error` |
| `SourceLocation` | yaml-core | `io.casehub.yaml.core.error` |
| `ErrorCategory` | yaml-core | `io.casehub.yaml.core.error` |
| `YamlErrorCollector` | yaml-core | `io.casehub.yaml.core.error` |
| `YamlValidationException` | yaml-core | `io.casehub.yaml.core.error` |
| `YamlErrorMapper` | yaml-step-runtime | `io.casehub.yaml.step.error` |
| `StepContext.location` | yaml-step-runtime | `io.casehub.yaml.step.eval` |

## Testing

- Unit tests for `YamlErrorMapper`: each existing exception type maps to the correct `YamlError` subtype with correct fields
- Unit tests for `YamlErrorCollector`: collect-all, throwIfErrors
- Unit test for `SourceLocation.toString()` formatting
- Each `YamlError.summary()` tested for human-readable output
- Integration: `StructuralStepEvaluator` produces `YamlError` on step failure instead of raw exceptions

## References

- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/StepError.java` — existing flat error record being replaced
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DeadlineExceededException.java` — representative orchestration exception
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/UnresolvedVariableException.java` — existing context-carrying exception
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StepContext.java` — context threading point
- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Result.java` — existing sealed Success/Failure pattern
- casehubio/platform#386 — runtime orchestration primitives (predecessor)
- casehubio/platform#402 — this issue
