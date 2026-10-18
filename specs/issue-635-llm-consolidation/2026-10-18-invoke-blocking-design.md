# AgentProvider.invokeBlocking() — Blocking Convenience API

**Issue:** casehubio/platform#637
**Branch:** issue-635-llm-consolidation
**Date:** 2026-10-18

## Summary

Add a blocking convenience method to `AgentProvider` that collects the
streaming `Multi<AgentEvent>`, joins TextDelta text, and returns a result
record with text + usage metadata.

## New Types in `agent-api`

### `AgentInvocationResult` record

```java
public record AgentInvocationResult(
    String text,
    int inputTokens,
    int outputTokens,
    int thinkingTokens,
    int cacheReadTokens,
    int cacheWriteTokens,
    Double totalCostUsd,
    long durationMs,
    String backendKey,
    String instanceId
)
```

Fields mirror `AgentEvent.InvocationComplete` plus aggregated `text`.

## API Changes

### Default method on `AgentProvider`

```java
default AgentInvocationResult invokeBlocking(AgentSessionConfig config, Duration timeout) {
    // collect Multi, join TextDelta, extract InvocationComplete
}
```

### Convenience overload

```java
default AgentInvocationResult invokeBlocking(String systemPrompt, String userPrompt, Duration timeout) {
    return invokeBlocking(AgentSessionConfig.of(systemPrompt, userPrompt), timeout);
}
```

### Static shortcut on `RoutingAgentProvider`

Not adding a separate discover+invoke static — callers can chain:
`RoutingAgentProvider.discover(dir).invokeBlocking(config, timeout)`

## References

- `agent-api/src/main/java/io/casehub/platform/agent/AgentProvider.java`
- `agent-api/src/main/java/io/casehub/platform/agent/AgentEvent.java` — InvocationComplete fields
- casehubio/platform#637
