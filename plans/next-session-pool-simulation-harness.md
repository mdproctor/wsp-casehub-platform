# Next Session: Pool Simulation Harness

> Paste this as the opening prompt for the next session on branch `issue-681-yaml-agent-interaction-steps`.

## Context

The YAML agent interaction steps are implemented (12 commits). The unit tests for individual components are solid — SalienceScheduler (9 tests), SessionPoolRegistry (7 tests), SessionPoolConfig, clearing policies, InvokeBinding variants. There are 8 layered example playbooks with corpus-driven execution tests that verify data flows through simulated LLMs.

**What's missing:** integration tests that prove the pool infrastructure works under realistic contention. The current tests execute examples sequentially with unlimited capacity — they never stress the scheduling, blocking, or rejection paths.

## What to Build

A simulation harness where simulated LLM nodes have:

1. **Configurable latency** — each query takes 200-500ms (configurable per pool), so concurrency is observable. Without latency, everything serializes instantly and contention never occurs.

2. **Capped concurrent nodes** — a pool of e.g. 6 simulated LLM nodes with a hard semaphore. When all 6 are busy, the 7th caller blocks until one completes. This exercises the real admission path.

3. **Corpus-driven responses** — the existing `CorpusBackend` pattern maps prompts to realistic canned responses. Keep this — it's what makes output assertions meaningful.

## Contention Scenarios to Test

Each test should document the expected behavior it asserts — these tests ARE the specification for how pools behave under load.

### Salience Preemption
- 6 node capacity, 3 pools: voice (salience=2, max-active=6), chat (salience=1, max-active=4), email (salience=0, max-active=3)
- Saturate with email queries (fill all 6 slots)
- Voice query arrives — should acquire within timeout because voice has higher salience
- Email queries that were waiting should yield to voice
- When voice goes idle, email resumes

### Guaranteed Minimum Under Pressure
- 6 node capacity, 2 pools: voice (salience=1), email (salience=0)
- Voice saturates 5 of 6 slots
- Email should still get its guaranteed 1 slot (guaranteed min = max(1, 6/2) = 3... or 1 per pool — check SalienceScheduler.guaranteedMin())
- Voice trying to take the 6th slot should be blocked if email needs it

### Max-Active Blocking
- Pool with max-active=2, 200ms latency per query
- Fire 3 concurrent queries
- First 2 should complete within ~200ms
- Third should block until one of the first 2 completes, completing in ~400ms total
- Assert wall-clock timing proves serialization happened

### Max-Prompt-Tokens Rejection
- Pool with max-prompt-tokens=1000
- Query with estimated tokens < 1000 succeeds
- Query with estimated tokens > 1000 is rejected (what error? Need to check if this is implemented in the pipeline or if we need to add it)
- **Note:** check whether max-prompt-tokens rejection is actually wired in SessionPipeline or if it's only declared in PoolDeclaration without enforcement. If unwired, implement it.

### Turn-Count Clearing
- Pool with clearing policy turn-count, turns=3
- Send 4 queries to the same session
- Clear should trigger before query 4 (after 3 turns)
- Verify via the event log that clear fires at exactly the right boundary

### Every-Call Clearing Under Concurrency  
- Pool with every-call clearing, 3 concurrent sessions
- Each session sends 2 queries
- Each session should clear before its 2nd query, independently
- Clears should not interfere across sessions

### Session Eviction and Recreation
- Pool with idle timeout of 500ms
- Open session, query, wait 600ms
- Session should be evicted (pipeline.sessionFor returns null or recreates)
- Next query should transparently get a new session

### Multi-Pool Lifecycle
- 3 pools (voice/chat/email) with different configs
- Run the full lifecycle: open sessions across all pools, query each, clear some, close all
- Assert final state: zero active sessions, all pools report zero checkouts
- Assert each pool's clearing policy was respected independently

## Implementation Approach

The harness should be a test utility class (not a full CDI test) that:
- Takes pool declarations + a latency config
- Builds SessionPoolRegistry + SessionPipeline + SalienceScheduler from those declarations
- Provides `LatencyCorpusBackend` — wraps CorpusBackend with `Thread.sleep(latencyMs)` before returning
- Uses virtual threads for concurrent query submission
- Collects timing data alongside the event log for wall-clock assertions

Tests go in `yaml-step-runtime/src/test/java/io/casehub/yaml/step/handler/AgentPoolSimulationTest.java`.

## Key Files

- `agent-gate-core/.../SalienceScheduler.java` — salience scheduling with guaranteed min
- `agent-session-core/.../SessionPipeline.java` — admission, eviction, clearing
- `agent-session-core/.../SessionPoolRegistry.java` — name-based pool lookup
- `agent-session-core/.../SessionPoolConfig.java` — clearing policy parsing
- `agent-session-core/.../ManagedSession.java` — per-session clearing logic
- `yaml-step-runtime/.../AgentExampleExecutionTest.java` — existing corpus + execution pattern to extend
- `examples/agent-interaction-patterns/` — 8 example playbooks (source of pool configs)

## What NOT to Do

- Don't use Quarkus test infrastructure — keep it as plain JUnit with virtual threads
- Don't mock — use the real SalienceScheduler, real SessionPipeline, simulated backends
- Don't test parsing or compilation — that's already covered. This is purely about runtime behavior under load
- Don't add real LLM integration tests in this session — that's a separate concern (manifest-routed, needs API keys)
