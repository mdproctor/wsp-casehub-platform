# YAML Agent Interaction Steps — Design Spec

**Issue:** casehubio/platform#681
**Date:** 2026-10-31
**Status:** Draft

## Problem

The Java agent API supports a rich interaction surface: single-shot invoke, multi-turn sessions, session pools, sticky sessions, clearing policies, AIMD admission control, and parallel batch execution. Only single-shot invoke (`agent-delegate`) is expressible from YAML playbooks. The remaining patterns require Java code (as wacky-manor demonstrates). This gap prevents YAML playbook authors from using pools, sessions, elastic expansion, or admission control.

## Goals

1. Every valid interaction pattern (64 identified) is expressible from pure YAML
2. Custom step types with reduced verbosity — not generic invoke wrappers
3. Pool lifecycle config in the manifest or inline, separate from playbook logic
4. Global admission gate with salience-based scheduling across pools
5. Full test coverage using SimulatedAgentBackend, with Ollama integration tests
6. Self-contained example playbooks for each major pattern

## Non-Goals

- New Java API surface — this wraps the existing agent-session-core/agent-gate-core APIs
- Changes to the playbook compiler's structural steps (parallel, forEach, etc.)
- Backend-specific configuration (that stays in agent-config.yaml providers section)

## Architecture

### Two-layer separation

| Layer | Manages | Where configured | Who owns it |
|-------|---------|-----------------|-------------|
| **Steps** (playbook) | What to say, when, to whom | YAML playbook | App developer |
| **Infrastructure** (manifest) | Pool sizing, clearing, admission, eviction | agent-config.yaml or inline pools | Ops / platform |

Steps reference pools and sessions by name. All lifecycle management is declarative config, not step logic.

### Admission model

The bottleneck is **active prompts** (concurrent LLM calls in flight), not open sessions. You can have 50 open sessions across 5 pools but the admission gate controls how many are actually executing a prompt at any moment.

```
┌─────────────────────────────────────────────┐
│              Admission Gate                  │
│   (global, AIMD, salience-based scheduling) │
│   max-active-prompts: 5                     │
├──────────┬──────────┬───────────────────────┤
│ Pool A   │ Pool B   │ Pool C               │
│ sal: 1   │ sal: 0   │ sal: 0               │
│ 20 sess  │ 5 sess   │ 10 sess              │
└──────────┴──────────┴───────────────────────┘
         ↓ all share ↓
┌─────────────────────────────────────────────┐
│           AgentBackend (LLM)                │
└─────────────────────────────────────────────┘
```

**Salience scheduling:**
- Default salience 0: all pools share prompt capacity via round-robin
- Elevated salience (1+): pool monopolizes prompt capacity until idle (no pending queries), then yields to the next salience level down
- Within the same salience level: fair round-robin
- Non-preemptive: a prompt in flight always completes; salience only affects which pool gets the next slot
- When a salient pool gets new work while lower-salience pools are running: current prompts finish, new slots go to the salient pool

## Custom Step Types

### `agent-invoke` — Single-shot execution

Replaces `agent-delegate`. Supports direct and pool-backed invocation.

```yaml
- agent-invoke:
    user: "Summarize: ${document}"
    system: "You are a concise summarizer"       # optional
    model: claude-sonnet-5                        # or modelQuery or modelChain
    pool: my-pool                                 # optional, implicit if one pool
    timeout: 30s                                  # optional
    response-format: text                         # text | json | { type: json, schema: "..." }
    output: summary                               # variable name for result
```

When `pool` is specified (or implicit), checks out a session, queries, and releases — transparent to the author. Without a pool, calls `AgentProvider.invoke()` directly.

### `agent-session-open` — Open a named session

```yaml
- agent-session-open:
    session: analyst                              # sticky name (required)
    system: "You are a data analyst"              # optional
    model: claude-opus-4                          # optional
    pool: analysis-pool                           # optional, implicit if one pool
    timeout: 60s                                  # default per-query timeout
```

Session persists until explicitly closed. Pool checkout is implicit. Clearing policy comes from the pool config in the manifest. The session name is the sticky ID — using the same name across steps returns the same session.

### `agent-query` — Query an open session

```yaml
- agent-query:
    session: analyst                              # session name (required)
    user: "What patterns do you see in ${data}?"  # prompt (required)
    response-format: json                         # optional
    output: analysis-result                       # optional
    priority: true                                # optional, priority admission
```

Minimal — just session name, prompt, and output. The session carries model, system prompt, and pool context from open.

### `agent-session-clear` — Clear session context

```yaml
- agent-session-clear:
    session: analyst
```

Explicit mid-conversation reset. Separate from automatic clearing policies (which are config, not steps).

### `agent-session-close` — Close session

```yaml
- agent-session-close:
    session: analyst
```

Returns session to pool (if pooled) or destroys it (if direct).

### Model selection modes

All three modes available on `agent-invoke` and `agent-session-open`:

```yaml
# Direct model ID
model: claude-sonnet-5

# Alias (resolved from manifest)
model: smart-fallback

# ModelQuery (structured constraints)
modelQuery:
  tier: FLAGSHIP
  capabilities: [text, code]
  locality: CLOUD
  maxCostTier: MEDIUM

# ModelChain (ordered fallback)
modelChain:
  - model: claude-opus-4
  - model: claude-sonnet-5
  - tier: FLAGSHIP
```

### Response format modes

Available on `agent-invoke` and `agent-query`:

```yaml
# Plain text (default)
response-format: text

# Schemaless JSON
response-format: json

# Structured JSON with schema
response-format:
  type: json
  name: entity-extraction
  schema: |
    { "type": "object",
      "properties": {
        "entities": { "type": "array", "items": { "type": "string" } }
      }
    }
```

## Pool and Admission Configuration

### Pool declaration

Declarable in agent-config.yaml (shared) and/or inline in playbook (scoped to execution).

```yaml
pools:
  triage:
    backend: claude                   # backend key (required)
    min-active: 2                     # warm sessions kept ready (default: 0)
    max-active: 20                    # session ceiling (required)
    salience: 1                       # scheduling salience (default: 0)
    clearing:                         # clearing policy (default: manual)
      policy: every-call              # every-call | manual | after-n-turns | size-aware
    idle-timeout-seconds: 60          # evict idle sessions (default: 300)
    checkout-timeout-seconds: 10      # timeout waiting for session (default: 30)
    max-prompt-tokens: 50000          # hard budget per prompt execution (optional)

  analysis:
    backend: claude
    min-active: 0
    max-active: 5
    salience: 0
    clearing:
      policy: size-aware
      threshold: 8000                 # estimated tokens before auto-clear
    idle-timeout-seconds: 300

  background:
    backend: ollama
    min-active: 0
    max-active: 3
    salience: 0
    clearing:
      policy: after-n-turns
      turns: 10
    idle-timeout-seconds: 120
```

### Clearing policies

| Policy | Behavior | Use case |
|--------|----------|----------|
| `every-call` | Clear before every query (turn 2+) | Stateless classification, triage |
| `manual` | Never auto-clear; use `agent-session-clear` step | Full conversation control |
| `after-n-turns` | Clear every N turns | Bounded context growth |
| `size-aware` | Clear when estimated tokens exceed threshold | Long-running conversations |

### Admission gate

```yaml
admission:
  strategy: aimd                      # aimd | fixed | none (default: aimd)
  max-active-prompts: 5               # concurrent prompt executions (required)
  initial-window: 2                   # AIMD starting window (default: 1)
  min-window: 1                       # AIMD floor (default: 1)
  backoff-factor: 0.5                 # multiplicative decrease on failure
  ramp-rate: 1                        # additive increase on success
```

### Default pool behavior

If exactly one pool is declared (either in manifest or inline), steps use it automatically without a `pool:` attribute. Named pool references are required only when multiple pools exist.

### Prompt size budget

`max-prompt-tokens` on a pool is a hard budget per prompt execution. If the estimated input exceeds this, the query is rejected before it reaches the LLM. This is distinct from:
- Clearing policy threshold (auto-clears to keep the session usable)
- Pool sizing (min/max sessions)
- Admission gate (controls concurrency, not size)

## Composition with Structural Steps

The existing playbook structural steps handle execution shape:

### Parallel batch across sessions
```yaml
- parallel:
    forEach:
      items: ${characters}
      as: npc
      step:
        agent-query:
          session: "npc-${npc.name}"
          user: "A guest arrives. React."
          output: "response-${npc.name}"
```

### Sequential multi-turn
```yaml
- agent-session-open:
    session: investigator
    system: "You are a detective"
- agent-query:
    session: investigator
    user: "Examine the crime scene"
    output: observations
- agent-query:
    session: investigator
    user: "Who is the suspect?"
    output: conclusion
- agent-session-close:
    session: investigator
```

### Race (first response wins)
```yaml
- race:
    branches:
      - agent-invoke:
          model: claude-opus-4
          user: "${question}"
          output: answer
      - agent-invoke:
          model: gemini-pro
          user: "${question}"
          output: answer
```

## Interaction Pattern Matrix

64 valid patterns across 4 dimensions (model selection and response format are orthogonal):

| Dimension | Values |
|-----------|--------|
| **A. Invocation mode** | A1: single-shot, A2: pool-backed invoke, A3: multi-turn session, A4: sticky session |
| **B. Pool config** | B1: no pool, B2: fixed, B3: elastic, B4: elastic+AIMD |
| **C. Clearing policy** | C1: every-call, C2: manual, C3: after-N, C4: size-aware (sessions only) |
| **D. Execution shape** | D1: sequential, D2: parallel batch, D3: priority admission |

Plus lifecycle knobs: G1 idle eviction, G2 prompt size limit, G3 transparent recreation after eviction.

### Pattern groups

| Group | Patterns | YAML steps | Config varies |
|-------|----------|-----------|---------------|
| Single-shot direct | 1 | `agent-invoke` | — |
| Pool-backed invoke | 14 | `agent-invoke` + pool | Pool type, execution shape, eviction |
| Multi-turn session | 30 | `open` → `query` × N → `close` | Pool, clearing, execution shape, eviction |
| Sticky session | 19 | `open` → `query` (across sections) | Pool, clearing, execution shape, eviction |

## Test Coverage

### Strategy

Same playbook YAML, different manifest config = different pattern tested. All tests use `SimulatedAgentBackend` for deterministic assertions.

### 12 playbook templates

| # | Playbook | Steps used | Shape tested |
|---|----------|-----------|--------------|
| P1 | `direct-invoke` | `agent-invoke` | Single-shot, no pool |
| P2 | `pool-invoke` | `agent-invoke` + pool | Single-shot via pool |
| P3 | `pool-invoke-parallel` | `forEach` + `parallel` + `agent-invoke` | Parallel single-shot via pool |
| P4 | `session-sequential` | `open` → `query` × 3 → `close` | Multi-turn, sequential |
| P5 | `session-with-clear` | `open` → `query` → `clear` → `query` → `close` | Explicit mid-session clear |
| P6 | `session-parallel-batch` | `open` × N → `parallel` { `query` × N } → `close` × N | Parallel batch across sessions |
| P7 | `sticky-sequential` | `open` → `query` → (other steps) → `query` → `close` | Sticky session across sections |
| P8 | `sticky-parallel` | `open` × N → `parallel` { `query` × N } | Sticky sessions in parallel |
| P9 | `multi-pool` | Steps using two named pools | Multiple pools with different configs |
| P10 | `priority-query` | `query` with `priority: true` | Priority admission |
| P11 | `model-selection` | `invoke` with each model mode | Direct, query, chain, alias |
| P12 | `response-formats` | `invoke`/`query` with each format | Text, JSON schema, schemaless |

### 16 manifest configs

| # | Config | Key parameters | Key assertion |
|---|--------|---------------|---------------|
| C1 | `no-pool` | No pool declaration | Direct backend call |
| C2 | `fixed-pool` | min=3, max=3 | All sessions pre-warmed |
| C3 | `elastic-pool` | min=0, max=10 | Sessions created on demand |
| C4 | `elastic-aimd` | min=0, max=10, aimd | AIMD window adjusts |
| C5 | `clearing-every-call` | policy: every-call | Context cleared each turn |
| C6 | `clearing-manual` | policy: manual | Context preserved until explicit clear |
| C7 | `clearing-after-n` | policy: after-n-turns, turns: 5 | Context cleared every 5 turns |
| C8 | `clearing-size-aware` | policy: size-aware, threshold: 8000 | Auto-clear on threshold |
| C9 | `idle-eviction` | idle-timeout: 30s | Sessions evicted after timeout |
| C10 | `eviction-recreation` | idle-timeout: 30s | Evicted session transparently recreated |
| C11 | `prompt-size-limit` | max-prompt-tokens: 1000 | Query rejected when exceeding budget |
| C12 | `salience-preempt` | 2 pools, salience 0+1 | High-salience monopolizes until idle |
| C13 | `salience-cascade` | 2 pools, salience 0+1 | Capacity cascades on idle |
| C14 | `salience-fairness` | 3 pools, all salience 0 | Round-robin among same level |
| C15 | `full-lifecycle` | size-aware + aimd + eviction | All features together |
| C16 | `multi-pool-lifecycle` | 2 pools, different configs | Independent pool lifecycles |

### Coverage

71 test runs (12 playbooks × relevant configs) covers all 64 patterns plus model selection and response format. Each test run is a specific (playbook, config) pair with targeted assertions.

```
yaml-step-runtime/src/test/
├── resources/
│   ├── playbooks/agent/          # 12 playbook templates (P1–P12)
│   └── configs/agent/            # 16 manifest configs (C1–C16)
└── java/.../agent/
    ├── AgentStepSimulationTest.java   # Parameterized: playbook × config
    └── AgentStepOllamaIT.java         # Key patterns against live Ollama
```

## Example Playbooks

### Direct invoke
```yaml
steps:
  - agent-invoke:
      model: claude-sonnet-5
      system: "You are a concise summarizer"
      user: "Summarize: ${document}"
      timeout: 30s
      output: summary
```

### Multi-pool voice/WhatsApp/email
```yaml
pools:
  voice:
    backend: claude
    min-active: 2
    max-active: 10
    salience: 1
    clearing: { policy: after-n-turns, turns: 20 }
    idle-timeout-seconds: 60
    max-prompt-tokens: 50000
  email:
    backend: claude
    min-active: 0
    max-active: 5
    salience: 0
    clearing: { policy: size-aware, threshold: 16000 }
    idle-timeout-seconds: 600
  whatsapp:
    backend: claude
    min-active: 0
    max-active: 20
    salience: 0
    clearing: { policy: size-aware, threshold: 8000 }
    idle-timeout-seconds: 1800

admission:
  strategy: aimd
  max-active-prompts: 8

steps:
  - match:
      value: ${event.channel}
      cases:
        voice:
          - agent-session-open:
              session: "call-${event.callId}"
              pool: voice
              system: "You are a voice assistant. Be concise."
          - agent-query:
              session: "call-${event.callId}"
              user: "${event.transcript}"
              output: response
        email:
          - agent-session-open:
              session: "email-${event.threadId}"
              pool: email
              system: "You are an email assistant. Be thorough."
          - agent-query:
              session: "email-${event.threadId}"
              user: "${event.body}"
              output: draft
        whatsapp:
          - agent-session-open:
              session: "wa-${event.chatId}"
              pool: whatsapp
              system: "You are a WhatsApp assistant. Be brief."
          - agent-query:
              session: "wa-${event.chatId}"
              user: "${event.message}"
              output: reply
```

## Implementation Plan Outline

1. **Pool config schema extension** — extend PoolDeclaration with clearing, salience, max-prompt-tokens fields
2. **Salience-based admission scheduler** — new SalienceScheduler wrapping AimdAdmissionStrategy
3. **Step type definitions** — InvokeBinding variants for each step type
4. **Step handlers** — runtime handlers wiring steps to agent-session-core API
5. **Playbook compiler** — step compilers for each new step type
6. **Inline pool parsing** — extend playbook parser to handle pools section
7. **Test infrastructure** — parameterized test harness + 12 playbooks + 16 configs
8. **Example gallery** — 8 self-contained example playbooks
9. **Documentation** — consumer-guide and contributor-guide updates

## References

- `agent-api/` — AgentProvider, AgentSession, AgentSessionConfig, AgentEvent
- `agent-session-core/` — SessionPool, SessionPipeline, SessionLifecycleManager, ManagedSession, ClearingPolicy
- `agent-gate-core/` — AdmissionGate, AimdAdmissionStrategy, ConcurrencyStrategy
- `agent-config-core/` — PoolDeclaration, ManifestLoader, ManifestProcessor
- `agent-router-core/` — RoutingAgentProvider, ModelChain
- `playbook-compiler/` — StepCompiler, ParallelCompiler, ForEachCompiler
- `yaml-step-runtime/` — AgentInvokeHandler (existing agent-delegate handler)
- `examples/wacky-manor/` — Java-only reference for session pool patterns
- `simulation-core/` — SimulatedAgentBackend, AgentCorpus (test infrastructure)
