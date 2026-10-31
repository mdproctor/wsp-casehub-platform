# HANDOFF — casehub-platform

## Last Session (2026-10-31)

Implemented all YAML agent interaction steps (#681). 12 commits on `issue-681-yaml-agent-interaction-steps`. Full build passes, 684 tests in yaml-step-runtime alone.

### What's Built

- PoolDeclaration extended (salience, clearing, maxPromptTokens)
- SessionPoolRegistry name-based keying, SessionPoolConfig clearing parse
- SalienceScheduler with guaranteed minimum capacity (9 unit tests)
- 4 InvokeBinding sealed variants (SessionOpen/Query/Clear/Close) + DeclarationParser
- Agent binding extended (pool, modelChain, responseFormat)
- 4 session lifecycle handlers wired to SessionPipeline
- PlaybookCompiler: step registration + inline pool parsing from YAML
- 8 layered real-world example playbooks with compilation + execution tests
- Consumer guide updated

### Next Session: Pool Simulation Harness

The unit tests for SalienceScheduler and SessionPoolRegistry are solid (88 + 110 tests). The example execution tests verify data flow through corpus-driven simulated LLMs. What's missing is **integration testing under realistic contention**.

Build a simulation harness where:
- Simulated LLMs have configurable latency per turn (e.g., 200-500ms)
- Pool of simulated nodes has an artificial concurrent limit (e.g., 6 nodes)
- Tests exercise real contention scenarios:
  - Salience preemption: voice (salience=2) takes capacity from email (salience=0) under pressure
  - max-active blocking: 3rd request blocks when max-active=2 and both slots occupied
  - max-prompt-tokens rejection: prompt exceeding limit is rejected
  - turn-count clearing: clear triggers at the exact turn boundary
  - Guaranteed minimum: email gets its 1 reserved slot even when voice is saturating

This is a design exercise — needs brainstorming before implementation.

## References

- `specs/issue-681-yaml-agent-interaction-steps/2026-10-31-yaml-agent-interaction-steps-design.md`
- `plans/2026-10-31-yaml-agent-interaction-steps.md`
- `examples/agent-interaction-patterns/` — 8 layered examples
