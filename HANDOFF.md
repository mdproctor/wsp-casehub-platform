# HANDOFF — casehub-platform

**Last worked:** #984 (epic) — design session, no code changes yet
**Active:** #984 on branch `issue-984-agent-service-guardrails` (design complete, implementation pending)
**Queue:** Phase 1 (#983, #985, #988) + Phase 2 (#989-#993, agency#549) queued

## This session

Full design session for epic #984: Declarative Agent Invocation — @AgentService + Guardrails.

**No code was written.** This session produced design artifacts, issues, and an implementation plan.

### Design artifacts

- **Design spec:** `specs/issue-984-agent-service-guardrails/2026-11-26-agent-service-guardrails-design.md` — 10 sections, covers annotations, guardrail SPIs, APT proxy generation, decorator stack, session integration, simulation, type changes, phasing
- **Decisions:** `specs/issue-984-agent-service-guardrails/decisions.md` — 9 decisions (D1-D9), reviewed (standard) and revised
- **Comparison doc:** `platform/docs/specs/casehub-vs-langchain4j-agent-invocation.md` — strategic comparison of CaseHub vs LangChain4j invocation architectures
- **Implementation plan:** `plans/2026-11-26-agent-service-guardrails.md` — 5 batches, 11 tasks
- **Blog:** `blog/2026-11-26-mdp01-agent-service-design.md`

### Issues filed

| Issue | Repo | What |
|-------|------|------|
| #988 | platform | Prompt caching parity — wire existing SDK features |
| #989 | platform | ModelParameters per-method overrides |
| #990 | platform | Budget limits via AutonomyBudgetPolicy |
| #991 | platform | Retry and governance via PolicyEnforcer |
| #992 | platform | Fallback implementation for resilience |
| #993 | platform | @RequiresConfirmation composability |
| #549 | agency | Built-in guardrails — PII, content policy |

### Key design decisions

1. **Guardrails** are separate CDI decorators on `AgentProvider` at `@Priority(1400)` input / `@Priority(1600)` output — before the gate at `@Priority(2000)`
2. **APT code generation** (not Quarkus extension) — agnostic core, implement Quarkus, generate Spring
3. **Resolution via AgentResolver SPI** — eidos is one implementation, clean dependency direction
4. **All three return types** — blocking (`String`/`T`), streaming (`Multi<AgentEvent>`), session (`AgentSession`)
5. **Session-backed multi-turn** — real sessions (Claude CLI) or cached replay (Anthropic HTTP)
6. **Tools via `AgentSessionConfig.tools`** — new field, backends handle execution via native SDK
7. **4 new modules** — agent-service-generator, agent-service, guardrail, guardrail-spring (+ types in agent-api)
8. **Buffer-then-validate** for output guardrails — consumer gets full response or failure, never partial
9. **Built-ins split** — platform owns JsonSchema/MaxToken, agency owns PII/ContentPolicy

### Next session should

1. Run `work continue` — the plan is written and tasks are injected
2. Start Batch 1: annotations and guardrail SPIs in `agent-api`
3. The implementation plan is at `plans/2026-11-26-agent-service-guardrails.md`

## Queue

Phase 1 (this branch):
- #983 — @AgentService core (11 tasks injected)
- #985 — Guardrails
- #988 — Caching parity

Phase 2 (follow-ups):
- #989 — ModelParameters per-method
- #990 — Budget limits
- #991 — Retry governance
- #992 — Fallback resilience
- #993 — RequiresConfirmation
- agency#549 — Built-in guardrails

## References

- Design spec: `specs/issue-984-agent-service-guardrails/2026-11-26-agent-service-guardrails-design.md`
- Decisions: `specs/issue-984-agent-service-guardrails/decisions.md`
- Plan: `plans/2026-11-26-agent-service-guardrails.md`
- Comparison: `platform/docs/specs/casehub-vs-langchain4j-agent-invocation.md`
- Blog: `blog/2026-11-26-mdp01-agent-service-design.md`
- Key files: `agent-api/AgentProvider.java`, `agent-api/AgentSessionConfig.java`, `agent-gate/GatedAgentProvider.java`, `graphql-generator/GraphQLResolverProcessor.java`
