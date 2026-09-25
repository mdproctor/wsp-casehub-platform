# HANDOFF — casehub-platform

## Last Session

Implemented all 7 tasks for #433 (dynamic step catalog) across 5 batches. Step definition model types, parser, validator in yaml-core (zero-dep). StepResult.executionMetadata + YamlImport.steps field with expander filters. Jackson mixins + contract tests. New yaml-step-runtime module: CatalogEntry/StepCatalog/CatalogSource/InvokeHandler SPIs, ValidatingStepAction, 6 invoke handlers (MCP, REST, GraphQL, Python, Agent, Process), CompositeStepCatalog with 3 catalog sources, ImportScopedStepCatalog. Code review caught 3 issues (process I/O deadlock, resource leaks) — all fixed. Branch rebased onto main (resolved 2 MCP test file conflicts — modify/delete), squashed (18→17), merged. Issues #429, #432, #433 all closed.

## Follow-on Work

| Issue | Title | Scale | Complexity | Notes |
|-------|-------|-------|------------|-------|
| eidos#182 | AgentInvokeHandler — wire eidos descriptor resolution | S | Med | Stub → real AgentProvider invocation |
| platform#439 | StepParameterType / ParameterType convergence evaluation | XS | Low | Design evaluation, may result in no change |
| platform#440 | Security model hardening for invoke handlers | M | High | Process + Python execute external commands |
| platform#441 | Python script auto-discovery as catalog source | S | Low | Convention-based discovery |
| platform#443 | AptPluginSource classpath scanning | S | Low | Skeletal scanning loop needs completion |
| platform#444 | McpToolSource CDI wiring | S | Med | Auto-discover MCP tools at startup |

## Spring Boot Deployment Campaign

| Repo | Status | Issue |
|------|--------|-------|
| platform | Complete | — |
| engine | Complete | — |
| work | Complete | — |
| qhorus | Complete | — |
| neocortex | Complete | — |
| ledger | Complete | casehubio/ledger#213 |
| casehub-worker | Not started | casehubio/casehub-worker#16 |
| blocks | 3 modules exist, gaps | casehubio/blocks#297 |
| workers | Not started (blocked by casehub-worker) | casehubio/workers#24 |

## References

- `specs/issue-429-yaml-type-system/2026-09-25-dynamic-step-catalog-design.md` — reviewed design spec
- `specs/issue-429-yaml-type-system/433-decisions.md` — 5 design decisions
- `plans/2026-09-25-dynamic-step-catalog.md` — implementation plan (completed)
