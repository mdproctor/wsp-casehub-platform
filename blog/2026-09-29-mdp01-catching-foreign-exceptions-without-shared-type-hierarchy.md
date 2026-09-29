---
layout: post
title: "Catching Foreign Exceptions Without a Shared Type Hierarchy"
date: 2026-09-29
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [mcp, reflection, exception-handling, cross-module]
---

# Catching Foreign Exceptions Without a Shared Type Hierarchy

When an MCP tool call dispatches to a domain operation and that operation throws an exception the LLM can't parse, you get a stack trace in the tool response. The LLM can't self-correct from a stack trace — it needs structured metadata. CaseHub's `McpCapabilityException` already handles this for platform code, but connectors-api defines its own `UnsupportedCapabilityException` with the same fields and no shared supertype.

The obvious fix is "just throw `McpCapabilityException` in connectors." But that creates a dependency from connectors-api on platform-api's exception type — and the whole point of having a separate connectors-api is that it doesn't know about platform internals.

The approach I chose: catch any exception from `method.invoke()`, unwrap the `InvocationTargetException`, and reflectively check whether the cause has `capability()`, `provider()`, and `supportedCapabilities()` accessor methods. If all three exist, extract the values and build a `McpOperationResult`. If any method is missing, fall through to the normal rethrow path.

```java
String capability = (String) cause.getClass()
    .getMethod("capability").invoke(cause);
String provider = (String) cause.getClass()
    .getMethod("provider").invoke(cause);
List<String> supported = (List<String>) cause.getClass()
    .getMethod("supportedCapabilities").invoke(cause);
```

This is duck typing in Java — if it has the right methods, it's a capability exception. The alternative was a marker interface in platform-api that both exception types implement, but that couples two modules that currently have no relationship. The reflection approach is six lines and handles any future exception type that follows the same accessor pattern.

The result comes back as a successful tool response, not an error. That distinction matters — an MCP error terminates the tool call; a successful result with `"outcome": "UNSUPPORTED"` gives the LLM enough metadata to try a different approach.
