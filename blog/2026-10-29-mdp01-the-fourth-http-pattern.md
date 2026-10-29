---
layout: post
title: "The Fourth HTTP Pattern"
date: 2026-10-29
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [code-generation, apt, streaming, sse, http, agent-api]
---

# The Fourth HTTP Pattern

The graphql-generator APT knows three HTTP patterns. Queries map to GET, mutations map to POST, streams map to GET with SSE. Each maps cleanly to a single annotation: `@PlatformQuery`, `@PlatformMutation`, `@PlatformStream`. The generator reads the annotation, picks the HTTP verb, and produces the right JAX-RS scaffolding. Straightforward.

Then agent invocation arrived, and broke the model.

## The problem with streaming agents

An LLM agent invocation needs two things simultaneously: a complex request body (system prompt, model config, MCP server list) and a streaming response (token-by-token text deltas, tool calls, completion events). Neither of the existing patterns fits.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 680 320" style="max-width:680px;font-family:'Segoe UI',system-ui,sans-serif">
  <defs>
    <marker id="ah" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="none" stroke="#475569" stroke-width="1.2"/>
    </marker>
  </defs>
  <!-- Column headers -->
  <text x="100" y="28" text-anchor="middle" font-size="13" font-weight="600" fill="#1e293b">Pattern</text>
  <text x="280" y="28" text-anchor="middle" font-size="13" font-weight="600" fill="#1e293b">Request</text>
  <text x="460" y="28" text-anchor="middle" font-size="13" font-weight="600" fill="#1e293b">Response</text>
  <text x="600" y="28" text-anchor="middle" font-size="13" font-weight="600" fill="#1e293b">Verb</text>
  <line x1="20" y1="38" x2="660" y2="38" stroke="#cbd5e1" stroke-width="1"/>

  <!-- Row 1: Query -->
  <text x="100" y="68" text-anchor="middle" font-size="12" fill="#334155">Query</text>
  <rect x="210" y="52" width="140" height="24" rx="4" fill="#dbeafe" stroke="#93c5fd"/>
  <text x="280" y="68" text-anchor="middle" font-size="11" fill="#1e40af">query params</text>
  <rect x="390" y="52" width="140" height="24" rx="4" fill="#dbeafe" stroke="#93c5fd"/>
  <text x="460" y="68" text-anchor="middle" font-size="11" fill="#1e40af">JSON body</text>
  <text x="600" y="68" text-anchor="middle" font-size="12" font-weight="600" fill="#3b82f6">GET</text>

  <!-- Row 2: Mutation -->
  <text x="100" y="118" text-anchor="middle" font-size="12" fill="#334155">Mutation</text>
  <rect x="210" y="102" width="140" height="24" rx="4" fill="#dcfce7" stroke="#86efac"/>
  <text x="280" y="118" text-anchor="middle" font-size="11" fill="#166534">JSON body</text>
  <rect x="390" y="102" width="140" height="24" rx="4" fill="#dcfce7" stroke="#86efac"/>
  <text x="460" y="118" text-anchor="middle" font-size="11" fill="#166534">JSON body</text>
  <text x="600" y="118" text-anchor="middle" font-size="12" font-weight="600" fill="#22c55e">POST</text>

  <!-- Row 3: Stream -->
  <text x="100" y="168" text-anchor="middle" font-size="12" fill="#334155">Stream</text>
  <rect x="210" y="152" width="140" height="24" rx="4" fill="#fef3c7" stroke="#fcd34d"/>
  <text x="280" y="168" text-anchor="middle" font-size="11" fill="#92400e">query params</text>
  <rect x="390" y="152" width="140" height="24" rx="4" fill="#fef3c7" stroke="#fcd34d"/>
  <text x="460" y="168" text-anchor="middle" font-size="11" fill="#92400e">SSE events</text>
  <text x="600" y="168" text-anchor="middle" font-size="12" font-weight="600" fill="#eab308">GET</text>

  <!-- Divider -->
  <line x1="20" y1="198" x2="660" y2="198" stroke="#475569" stroke-width="1" stroke-dasharray="4,4"/>

  <!-- Row 4: Streaming Mutation -->
  <rect x="20" y="212" width="640" height="40" rx="6" fill="#faf5ff" stroke="#c084fc" stroke-width="1.5"/>
  <text x="100" y="237" text-anchor="middle" font-size="12" font-weight="600" fill="#7c3aed">Streaming Mut.</text>
  <rect x="210" y="222" width="140" height="24" rx="4" fill="#ede9fe" stroke="#a78bfa"/>
  <text x="280" y="238" text-anchor="middle" font-size="11" fill="#5b21b6">JSON body</text>
  <rect x="390" y="222" width="140" height="24" rx="4" fill="#ede9fe" stroke="#a78bfa"/>
  <text x="460" y="238" text-anchor="middle" font-size="11" fill="#5b21b6">SSE events</text>
  <text x="600" y="237" text-anchor="middle" font-size="12" font-weight="600" fill="#7c3aed">POST</text>

  <!-- Caption -->
  <text x="340" y="290" text-anchor="middle" font-size="11" fill="#64748b" font-style="italic">The fourth pattern combines POST's request body with SSE's event stream.</text>
</svg>

GET can't carry a request body (technically it can, but most infrastructure drops it). `@PlatformStream` over GET works for subscriptions — "watch this resource" — where a UUID or filter string in the query params is enough context. But "invoke this model with this system prompt and this tool configuration and stream the results back" isn't a subscription. It's a mutation that happens to produce its output incrementally.

## One attribute, zero new annotations

The solution was to extend `@PlatformMutation` with a `streaming` boolean:

```java
@PlatformMutation(value = "Invoke an agent (streaming)", streaming = true)
Multi<AgentEvent> invokeStream(AgentSessionConfig config, String agentId);
```

When `streaming = true`, the generator changes three things at once. The REST resource gets `@POST` + `@Produces(SERVER_SENT_EVENTS)` + `@RestStreamElementType(APPLICATION_JSON)`. The GraphQL resolver maps to `@Subscription` instead of `@Mutation`. And the MCP tool registration skips the method entirely — streaming operations don't fit the tool call/response model.

The Spring side mirrors this: `@PostMapping` with `produces = TEXT_EVENT_STREAM_VALUE`, and the reactive `Flow.Publisher` return type bridges to an `SseEmitter` with a virtual-thread subscriber.

## Why this matters beyond agents

Every LLM vendor's API uses this exact pattern. OpenAI's `/chat/completions` with `stream: true` is POST+SSE. Anthropic's Messages API is POST+SSE. Google's Gemini streaming is POST+SSE. It's the industry's answer to "I need to send you a complex request and get a stream back."

The interesting thing is that HTTP/2 makes this pattern unnecessary — multiplexed streams over a single connection can carry bidirectional data without the SSE framing overhead. But the industry standardised on HTTP/1.1 SSE for LLM streaming because it works through every proxy, load balancer, and CDN without configuration. The pragmatic choice won.

Having `@PlatformMutation(streaming = true)` in the generator means any SPI method that returns `Multi<T>` and needs a request body gets the right HTTP surface automatically — not just agent invocations. Webhook-triggered analysis pipelines, document processing streams, real-time search results — anything that fits the "send config, receive events" shape.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 200" style="max-width:600px;font-family:'Segoe UI',system-ui,sans-serif">
  <defs>
    <marker id="ar2" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="none" stroke="#7c3aed" stroke-width="1.2"/>
    </marker>
    <marker id="ar3" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="none" stroke="#64748b" stroke-width="1.2"/>
    </marker>
  </defs>

  <!-- SPI annotation -->
  <rect x="10" y="70" width="160" height="60" rx="8" fill="#f5f3ff" stroke="#8b5cf6" stroke-width="1.5"/>
  <text x="90" y="95" text-anchor="middle" font-size="11" font-weight="600" fill="#6d28d9">@PlatformMutation</text>
  <text x="90" y="112" text-anchor="middle" font-size="10" fill="#7c3aed">(streaming = true)</text>

  <!-- Arrow to REST -->
  <line x1="170" y1="85" x2="230" y2="40" stroke="#7c3aed" stroke-width="1.2" marker-end="url(#ar2)"/>
  <!-- Arrow to GraphQL -->
  <line x1="170" y1="100" x2="230" y2="100" stroke="#7c3aed" stroke-width="1.2" marker-end="url(#ar2)"/>
  <!-- Arrow to MCP (crossed) -->
  <line x1="170" y1="115" x2="230" y2="160" stroke="#64748b" stroke-width="1.2" marker-end="url(#ar3)" stroke-dasharray="4,3"/>

  <!-- REST box -->
  <rect x="235" y="20" width="150" height="40" rx="6" fill="#ede9fe" stroke="#a78bfa"/>
  <text x="310" y="36" text-anchor="middle" font-size="10" font-weight="600" fill="#5b21b6">REST</text>
  <text x="310" y="50" text-anchor="middle" font-size="9" fill="#7c3aed">POST + SSE</text>

  <!-- GraphQL box -->
  <rect x="235" y="80" width="150" height="40" rx="6" fill="#ede9fe" stroke="#a78bfa"/>
  <text x="310" y="96" text-anchor="middle" font-size="10" font-weight="600" fill="#5b21b6">GraphQL</text>
  <text x="310" y="110" text-anchor="middle" font-size="9" fill="#7c3aed">@Subscription</text>

  <!-- MCP box (greyed) -->
  <rect x="235" y="140" width="150" height="40" rx="6" fill="#f1f5f9" stroke="#cbd5e1"/>
  <text x="310" y="156" text-anchor="middle" font-size="10" font-weight="600" fill="#94a3b8">MCP</text>
  <text x="310" y="170" text-anchor="middle" font-size="9" fill="#94a3b8">skipped</text>

  <!-- Spring equivalents -->
  <line x1="385" y1="40" x2="430" y2="40" stroke="#a78bfa" stroke-width="1" marker-end="url(#ar2)"/>
  <line x1="385" y1="100" x2="430" y2="100" stroke="#a78bfa" stroke-width="1" marker-end="url(#ar2)"/>

  <rect x="435" y="20" width="150" height="40" rx="6" fill="#faf5ff" stroke="#c084fc"/>
  <text x="510" y="36" text-anchor="middle" font-size="10" font-weight="600" fill="#7c3aed">Spring REST</text>
  <text x="510" y="50" text-anchor="middle" font-size="9" fill="#9333ea">@PostMapping + SseEmitter</text>

  <rect x="435" y="80" width="150" height="40" rx="6" fill="#faf5ff" stroke="#c084fc"/>
  <text x="510" y="96" text-anchor="middle" font-size="10" font-weight="600" fill="#7c3aed">Spring GraphQL</text>
  <text x="510" y="110" text-anchor="middle" font-size="9" fill="#9333ea">@SubscriptionMapping</text>
</svg>

The generator now handles four HTTP patterns from two annotation attributes. The taxonomy is complete — queries read state, mutations change state, streams observe state, and streaming mutations change state while reporting progress. Every combination of {request shape} × {response shape} that HTTP supports has a path through the SPI layer.
