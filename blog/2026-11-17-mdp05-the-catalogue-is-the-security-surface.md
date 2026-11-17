---
title: The catalogue is the security surface
date: 2026-11-17
form: article
type: explanation
series: playbook-language
issue: 830
---

When an LLM can write your playbooks, the step catalogue stops being a developer convenience and becomes a security boundary. CaseHub playbooks include steps that execute shell commands (`process`), make arbitrary HTTP calls (`rest-call`), evaluate MVEL expressions with full Java reflection, and read environment variables. All fine when a developer writes them in an IDE. Not fine when the validator MCP tool hands that catalogue to a model and says "write me a playbook."

The obvious reaction is to build a trust layer: define tiers, annotate steps with minimum trust levels, create a filtering registry that checks caller permissions. We nearly went down that road. Then we looked at what was already there.

## The filter that was already doing the job

`SchemaFilteredRegistry` wraps a `PluginRegistry` and filters by capability set. Every step carries a `capability` string on its `Definition` — things like `"steps"`, `"orchestration"`, `"correlation"`, `"spotlight"`. Two built-in schemas define which capabilities are available: `client` for UI-facing playbooks, `server` for backend orchestration. A domain schema inherits from either and adds its own capabilities.

The filtering works. What doesn't work is the classification. `process` — which runs `rm -rf /` if you ask it to — has capability `"steps"`. Same as `assert`. Same as every safe structural step in the platform. The schema system can't distinguish them because they're in the same bucket.

## Reclassifying, not restructuring

The fix is four capability constants:

<figure>

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 680 320" font-family="system-ui, sans-serif">
  <defs>
    <linearGradient id="safe" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#e8f5e9"/>
      <stop offset="100%" stop-color="#c8e6c9"/>
    </linearGradient>
    <linearGradient id="risk" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#ffebee"/>
      <stop offset="100%" stop-color="#ffcdd2"/>
    </linearGradient>
  </defs>

  <text x="340" y="28" text-anchor="middle" font-size="15" font-weight="bold" fill="#333">Capability taxonomy — before and after</text>

  <!-- Before -->
  <text x="170" y="60" text-anchor="middle" font-size="13" font-weight="600" fill="#666">Before</text>
  <rect x="30" y="72" width="280" height="220" rx="8" fill="url(#safe)" stroke="#81c784" stroke-width="1.5"/>
  <text x="170" y="96" text-anchor="middle" font-size="14" font-weight="bold" fill="#2e7d32">"steps"</text>
  <text x="170" y="122" text-anchor="middle" font-size="12" fill="#555">assert, delay, rest-call,</text>
  <text x="170" y="140" text-anchor="middle" font-size="12" fill="#555">process, block, if-else,</text>
  <text x="170" y="158" text-anchor="middle" font-size="12" fill="#555">for-each, parallel, match,</text>
  <text x="170" y="176" text-anchor="middle" font-size="12" fill="#555">try-catch, race, signal, ...</text>
  <text x="170" y="210" text-anchor="middle" font-size="11" fill="#888" font-style="italic">One bucket. No way to filter</text>
  <text x="170" y="226" text-anchor="middle" font-size="11" fill="#888" font-style="italic">process from assert.</text>

  <!-- After -->
  <text x="510" y="60" text-anchor="middle" font-size="13" font-weight="600" fill="#666">After</text>
  <rect x="370" y="72" width="280" height="120" rx="8" fill="url(#safe)" stroke="#81c784" stroke-width="1.5"/>
  <text x="510" y="96" text-anchor="middle" font-size="14" font-weight="bold" fill="#2e7d32">"steps"</text>
  <text x="510" y="122" text-anchor="middle" font-size="12" fill="#555">assert, delay, block, if-else,</text>
  <text x="510" y="140" text-anchor="middle" font-size="12" fill="#555">for-each, parallel, match, ...</text>
  <text x="510" y="168" text-anchor="middle" font-size="11" fill="#888" font-style="italic">Safe steps only</text>

  <rect x="370" y="202" width="280" height="90" rx="8" fill="url(#risk)" stroke="#e57373" stroke-width="1.5"/>
  <text x="510" y="226" text-anchor="middle" font-size="12" font-weight="bold" fill="#c62828">process-execution · raw-http</text>
  <text x="510" y="248" text-anchor="middle" font-size="12" font-weight="bold" fill="#c62828">expression-mvel · env-access</text>
  <text x="510" y="274" text-anchor="middle" font-size="11" fill="#888" font-style="italic">Risk capabilities — excluded from assisted</text>

  <!-- Arrow -->
  <path d="M 315 175 L 365 175" stroke="#999" stroke-width="2" fill="none" marker-end="url(#arrow)"/>
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="8" markerHeight="8" orient="auto">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#999"/>
    </marker>
  </defs>
</svg>
```

<figcaption>Moving dangerous steps out of the shared "steps" bucket into their own capabilities. The assisted schema includes the left column but not the right.</figcaption>
</figure>

`process` moves from capability `"steps"` to `"process-execution"`. `rest-call` moves to `"raw-http"`. MVEL gets `"expression-mvel"`. Environment variable access gets `"env-access"`. These are added to the existing `server` and `client` schemas — developers see no change. A new `assisted` schema includes everything `server` has except the four risk capabilities.

The validator MCP tool creates its filtered registry with one line:

```java
SchemaFilteredRegistry.forSchema(registry, schemas, "assisted")
```

That's the entire trust boundary. The LLM sees `availableActions()` returning safe steps and managed connectors. It never sees `process`, `rest-call`, or MVEL.

## Why this works better than a trust layer

A separate trust system — `TrustTier` enum, `minimumTrust` on every definition, a `TrustFilteredRegistry` composing with `SchemaFilteredRegistry` — would have been a second filtering axis. Two registries, two sets of rules, two places to check when a step isn't showing up. The capability taxonomy already does this job. It just needed the right constants.

The `@Plugin` annotation already has a `capability` attribute. It defaults to `"steps"`. Changing it to `"process-execution"` on the `ProcessPlugin` record is a one-line change that propagates through the entire system: the annotation processor picks it up, the CDI scanner reads it, the schema filter respects it.

Managed connector plugins — the bank, voice, commerce, email APIs — keep their domain-specific capabilities and remain available under the `assisted` schema. They call managed SPIs with known inputs and outputs; the side-effect risk is handled by the existing consent infrastructure (`ConsentTier`, `WorkerAction`), which is orthogonal to the step catalogue.

## The design decision that matters most

The authoring context is determined by the calling tool, not by the playbook. An LLM cannot declare itself a developer by writing `trust: developer` in the front matter. The validator tool controls the context. CLI and IDE usage defaults to `developer` — the unfiltered registry, today's behaviour, no breaking change.

Two contexts for now: `developer` and `assisted`. A middle tier for customer-facing authoring can be added when that persona exists — it's a new schema entry with its own capability set, not a structural change.

---

The lesson is familiar but easy to forget: before building a new security layer, check whether the existing infrastructure already has the filtering machinery. It usually does. The gap is usually in the classification, not the filter.
