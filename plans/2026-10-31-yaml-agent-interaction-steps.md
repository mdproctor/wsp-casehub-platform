# YAML Agent Interaction Steps — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #681 — YAML agent interaction step types — session, pool, admission, salience
**Issue group:** #681

**Goal:** Make every agent interaction pattern (sessions, pools, sticky sessions, clearing, AIMD, salience scheduling) expressible from pure YAML playbooks with 5 custom step types and full test coverage.

**Architecture:** 5 new InvokeBinding variants in yaml-core map to 4 new handlers in yaml-step-runtime. Handlers wire to the existing SessionPipeline in agent-session-core (not direct SessionPool checkout). PoolDeclaration gains clearing, salience, and prompt-size fields. A new SalienceScheduler in agent-gate-core wraps AimdAdmissionStrategy with per-pool salience-based scheduling and guaranteed minimum capacity. Inline pool declarations in playbooks are parsed by the playbook compiler and merged at runtime.

**Tech Stack:** Java 21+, yaml-core (zero-dep), yaml-jackson (Jackson deserialization), yaml-step-runtime (CDI handlers), agent-session-core, agent-gate-core, agent-config-core, JUnit 5, SimulatedAgentBackend

## Global Constraints

- `yaml-core/` and `yaml-plugin-api/` must remain zero-dependency (no Quarkus, no CDI, no Jackson)
- `agent-config-core/` is framework-neutral (Jackson + pure Java, no CDI)
- `agent-gate-core/` is framework-neutral (pure Java, no CDI)
- `agent-session-core/` is framework-neutral (pure Java, no CDI)
- All new primitives use `java.util.concurrent` — never `synchronized` (virtual thread pinning)
- Every SPI in platform-api gets a @DefaultBean implementation in platform
- No quarkus:build goal on any modified module
- Test with SimulatedAgentBackend — no real LLM calls in unit tests

---

## Batch 1: Pool Config Foundation

### Task 1: Extend PoolDeclaration with clearing, salience, and prompt-size fields

**Files:**
- Modify: `agent-config-core/src/main/java/io/casehub/platform/agent/config/PoolDeclaration.java`
- Modify: `agent-config-core/src/main/resources/schema/pool-declaration.schema.json`
- Test: `agent-config-core/src/test/java/io/casehub/platform/agent/config/PoolDeclarationTest.java`

**Interfaces:**
- Consumes: nothing (foundation)
- Produces: `PoolDeclaration` record with new fields: `salience()` (int, default 0), `clearing()` (Map<String,Object>, nullable), `maxPromptTokens()` (int, default 0 = unlimited)

- [ ] **Step 1: Write failing test for new PoolDeclaration fields**

```java
@Test
void poolDeclaration_withClearingSalienceAndPromptLimit() {
    var clearing = Map.<String,Object>of("policy", "size-aware", "threshold", 8000);
    var pool = new PoolDeclaration("voice", "voice-agent", "claude",
            2, 10, null, Map.of(), Map.of(),
            1, clearing, 50000);
    assertEquals(1, pool.salience());
    assertEquals("size-aware", pool.clearing().get("policy"));
    assertEquals(50000, pool.maxPromptTokens());
}

@Test
void poolDeclaration_defaultsForNewFields() {
    var pool = new PoolDeclaration("basic", "agent", "claude",
            0, 5, null, Map.of(), Map.of());
    assertEquals(0, pool.salience());
    assertNull(pool.clearing());
    assertEquals(0, pool.maxPromptTokens());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl agent-config-core -Dtest=PoolDeclarationTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation error — constructor doesn't accept new fields

- [ ] **Step 3: Add new fields to PoolDeclaration record**

Add three new fields to the record: `salience` (int), `clearing` (Map<String,Object>), `maxPromptTokens` (int). Add a backward-compatible constructor that defaults the new fields (salience=0, clearing=null, maxPromptTokens=0).

```java
public record PoolDeclaration(
        String name, String agentId, String backend,
        int minActive, int maxActive, String workingDir,
        Map<String, Object> scaling, Map<String, Object> extensions,
        int salience, Map<String, Object> clearing, int maxPromptTokens) {

    public PoolDeclaration(String name, String agentId, String backend,
            int minActive, int maxActive, String workingDir,
            Map<String, Object> scaling, Map<String, Object> extensions) {
        this(name, agentId, backend, minActive, maxActive, workingDir,
                scaling, extensions, 0, null, 0);
    }

    public PoolDeclaration {
        scaling = scaling != null ? Map.copyOf(scaling) : Map.of();
        extensions = extensions != null ? Map.copyOf(extensions) : Map.of();
        clearing = clearing != null ? Map.copyOf(clearing) : null;
    }
}
```

- [ ] **Step 4: Update pool-declaration.schema.json**

Add `salience` (integer, default 0), `clearing` (object with `policy` enum + optional `threshold`/`turns`), and `max-prompt-tokens` (integer) to the JSON Schema.

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn --batch-mode test -pl agent-config-core -Dtest=PoolDeclarationTest`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add agent-config-core/
git commit -m "feat(agent-config): extend PoolDeclaration with clearing, salience, maxPromptTokens Refs #681"
```

### Task 2: Extend SessionPoolRegistry with name-based keying

**Files:**
- Modify: `agent-session-core/src/main/java/io/casehub/platform/agent/session/SessionPoolRegistry.java`
- Modify: `agent-session-core/src/main/java/io/casehub/platform/agent/session/SessionPoolConfig.java`
- Test: `agent-session-core/src/test/java/io/casehub/platform/agent/session/SessionPoolRegistryTest.java`

**Interfaces:**
- Consumes: `PoolDeclaration` with new fields (Task 1)
- Produces: `SessionPoolRegistry.findByName(String name)` → `Optional<SessionPool>`, `SessionPoolConfig.fromDeclaration()` parses clearing/salience/maxPromptTokens

- [ ] **Step 1: Write failing test for name-based pool lookup**

```java
@Test
void findByName_returnsPoolByDeclaredName() {
    var decl = new PoolDeclaration("voice", "agent", "claude", 0, 5,
            null, Map.of(), Map.of(), 1, Map.of("policy", "every-call"), 0);
    var registry = new SessionPoolRegistry(List.of(decl), backends);
    var pool = registry.findByName("voice");
    assertTrue(pool.isPresent());
}

@Test
void findByName_multiplePoolsSameBackend() {
    var voice = new PoolDeclaration("voice", "agent", "claude", 0, 10,
            null, Map.of(), Map.of(), 1, null, 0);
    var email = new PoolDeclaration("email", "agent", "claude", 0, 5,
            null, Map.of(), Map.of(), 0, null, 0);
    var registry = new SessionPoolRegistry(List.of(voice, email), backends);
    assertTrue(registry.findByName("voice").isPresent());
    assertTrue(registry.findByName("email").isPresent());
    assertNotSame(registry.findByName("voice").get(),
                  registry.findByName("email").get());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl agent-session-core -Dtest=SessionPoolRegistryTest`
Expected: FAIL — `findByName` doesn't exist

- [ ] **Step 3: Add name-based keying to SessionPoolRegistry**

Add a second `ConcurrentHashMap<String, SessionPool>` keyed by pool name. In the constructor, register each pool by both `poolKey(backendKey, model)` (backward compat) and by `name`. Add `findByName(String name)` method.

```java
private final Map<String, SessionPool> poolsByName = new ConcurrentHashMap<>();

public Optional<SessionPool> findByName(String name) {
    return Optional.ofNullable(poolsByName.get(name));
}
```

In the constructor loop, after creating the pool:
```java
poolsByName.put(config.name(), pool);
```

- [ ] **Step 4: Extend SessionPoolConfig.fromDeclaration() to parse new fields**

Add `salience`, `clearingPolicy`, `clearingThreshold`, `clearingTurns`, `maxPromptTokens` fields to `SessionPoolConfig`. Parse them from `PoolDeclaration.clearing()` map and direct fields.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl agent-session-core -Dtest=SessionPoolRegistryTest`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add agent-session-core/
git commit -m "feat(agent-session): name-based pool keying in SessionPoolRegistry Refs #681"
```

---

## Batch 2: Salience-Based Admission

### Task 3: Create SalienceScheduler

**Files:**
- Create: `agent-gate-core/src/main/java/io/casehub/platform/agent/gate/SalienceScheduler.java`
- Test: `agent-gate-core/src/test/java/io/casehub/platform/agent/gate/SalienceSchedulerTest.java`

**Interfaces:**
- Consumes: `AimdAdmissionStrategy` (existing), `SessionPoolConfig.salience()` (Task 2)
- Produces: `SalienceScheduler` — wraps AIMD with salience-based scheduling. `register(String poolName, int salience)`, `acquire(String poolName)`, `acquirePriority(String poolName)`, `release(String poolName)`, `activeSalience()` → int

- [ ] **Step 1: Write failing tests for salience scheduling**

```java
@Test
void defaultSalience_roundRobinFairness() {
    var scheduler = new SalienceScheduler(5);
    scheduler.register("poolA", 0);
    scheduler.register("poolB", 0);
    // Both at salience 0 — should round-robin
    assertTrue(scheduler.tryAcquire("poolA", Duration.ofSeconds(1)));
    assertTrue(scheduler.tryAcquire("poolB", Duration.ofSeconds(1)));
}

@Test
void elevatedSalience_monopolizesUntilIdle() {
    var scheduler = new SalienceScheduler(2);
    scheduler.register("voice", 1);
    scheduler.register("email", 0);
    // Voice has salience 1 — should get both slots
    assertTrue(scheduler.tryAcquire("voice", Duration.ofSeconds(1)));
    assertTrue(scheduler.tryAcquire("voice", Duration.ofSeconds(1)));
    // Email blocked while voice is active (only 2 slots, both taken by voice)
    assertFalse(scheduler.tryAcquire("email", Duration.ofMillis(100)));
    // Release one voice slot
    scheduler.release("voice");
    scheduler.release("voice");
    // Voice idle — email can now acquire
    assertTrue(scheduler.tryAcquire("email", Duration.ofSeconds(1)));
}

@Test
void guaranteedMinCapacity_preventsStarvation() {
    var scheduler = new SalienceScheduler(3);
    scheduler.register("voice", 1);
    scheduler.register("email", 0);
    // 3 slots, 2 pools → each guaranteed 1
    // Voice can take at most 2 (3 - 1 reserved for email)
    assertTrue(scheduler.tryAcquire("voice", Duration.ofSeconds(1)));
    assertTrue(scheduler.tryAcquire("voice", Duration.ofSeconds(1)));
    // Email gets its guaranteed slot even while voice is active
    assertTrue(scheduler.tryAcquire("email", Duration.ofSeconds(1)));
}

@Test
void salienceCascade_yieldsOnIdle() {
    var scheduler = new SalienceScheduler(2);
    scheduler.register("voice", 1);
    scheduler.register("email", 0);
    scheduler.register("whatsapp", 0);
    assertTrue(scheduler.tryAcquire("voice", Duration.ofSeconds(1)));
    scheduler.release("voice");
    // Voice idle — email and whatsapp share via round-robin
    assertTrue(scheduler.tryAcquire("email", Duration.ofSeconds(1)));
    assertTrue(scheduler.tryAcquire("whatsapp", Duration.ofSeconds(1)));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-gate-core -Dtest=SalienceSchedulerTest`
Expected: compilation error — class doesn't exist

- [ ] **Step 3: Implement SalienceScheduler**

```java
public class SalienceScheduler {
    private final int maxActivePrompts;
    private final Map<String, PoolEntry> pools = new ConcurrentHashMap<>();
    private final AtomicInteger totalActive = new AtomicInteger();
    private final ReentrantLock lock = new ReentrantLock();
    private final Condition slotAvailable = lock.newCondition();

    public SalienceScheduler(int maxActivePrompts) {
        this.maxActivePrompts = maxActivePrompts;
    }

    public void register(String poolName, int salience) {
        pools.put(poolName, new PoolEntry(poolName, salience));
    }

    public boolean tryAcquire(String poolName, Duration timeout) {
        // Check salience: if a higher-salience pool is active, block
        // unless this pool has guaranteed minimum capacity
        // ...implementation...
    }

    public void release(String poolName) {
        // Decrement active count for pool, signal waiters
        // ...implementation...
    }

    private int guaranteedMinSlots() {
        return pools.isEmpty() ? 0 : 1;
    }

    private int highestActiveSalience() {
        return pools.values().stream()
                .filter(p -> p.activeCount.get() > 0)
                .mapToInt(p -> p.salience)
                .max().orElse(0);
    }

    private static class PoolEntry {
        final String name;
        final int salience;
        final AtomicInteger activeCount = new AtomicInteger();
        // ...
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl agent-gate-core -Dtest=SalienceSchedulerTest`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add agent-gate-core/
git commit -m "feat(agent-gate): SalienceScheduler with guaranteed min capacity Refs #681"
```

---

## Batch 3: InvokeBinding Step Types

### Task 4: Add session step variants to InvokeBinding

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/step/InvokeBinding.java`
- Modify: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/InvokeBindingDeserializer.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/step/InvokeBindingTest.java`
- Modify: `yaml-jackson/src/test/java/io/casehub/yaml/jackson/InvokeBindingDeserializerTest.java` (if exists, else create)

**Interfaces:**
- Consumes: nothing (yaml-core is zero-dep)
- Produces: `InvokeBinding.SessionOpen` (session, system, model, modelQuery, modelChain, pool, timeout, checkoutTimeout), `InvokeBinding.SessionQuery` (session, user, responseFormat, output, priority), `InvokeBinding.SessionClear` (session), `InvokeBinding.SessionClose` (session)

- [ ] **Step 1: Write failing test for SessionOpen binding**

```java
@Test
void sessionOpen_allFields() {
    var open = new InvokeBinding.SessionOpen(
            "analyst", "You are a data analyst", "claude-opus-4",
            null, null, "analysis-pool", "60s", "10s");
    assertEquals("analyst", open.session());
    assertEquals("analysis-pool", open.pool());
    assertEquals("10s", open.checkoutTimeout());
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: compilation error — SessionOpen doesn't exist

- [ ] **Step 3: Add 4 new record variants to InvokeBinding**

```java
record SessionOpen(String session, String system, String model,
        Map<String, Object> modelQuery, List<Object> modelChain,
        String pool, String timeout, String checkoutTimeout)
        implements InvokeBinding {
    public SessionOpen {
        Objects.requireNonNull(session, "session name is required");
    }
}

record SessionQuery(String session, String user,
        Object responseFormat, String output, boolean priority)
        implements InvokeBinding {
    public SessionQuery {
        Objects.requireNonNull(session, "session name is required");
        Objects.requireNonNull(user, "user prompt is required");
    }
}

record SessionClear(String session) implements InvokeBinding {
    public SessionClear {
        Objects.requireNonNull(session, "session name is required");
    }
}

record SessionClose(String session) implements InvokeBinding {
    public SessionClose {
        Objects.requireNonNull(session, "session name is required");
    }
}
```

- [ ] **Step 4: Update InvokeBindingDeserializer for new variants**

Add deserialization branches for `agent-session-open`, `agent-query`, `agent-session-clear`, `agent-session-close` step keys in the deserializer. Map YAML fields to record constructors.

- [ ] **Step 5: Write tests for deserialization of each variant**

Test that YAML snippets for each step type deserialize correctly into the corresponding InvokeBinding variant.

- [ ] **Step 6: Run all tests**

Run: `mvn --batch-mode test -pl yaml-core,yaml-jackson`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add yaml-core/ yaml-jackson/
git commit -m "feat(yaml-core): add SessionOpen/Query/Clear/Close InvokeBinding variants Refs #681"
```

### Task 5: Update InvokeBinding.Agent to support pool, modelChain, and responseFormat

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/step/InvokeBinding.java` (Agent record)
- Modify: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/InvokeBindingDeserializer.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/step/InvokeBindingTest.java`

**Interfaces:**
- Consumes: nothing
- Produces: `InvokeBinding.Agent` with new fields: `pool` (String), `modelChain` (List<Object>), `responseFormat` (Object — String or Map)

- [ ] **Step 1: Write failing test for Agent with pool and responseFormat**

```java
@Test
void agent_withPoolAndResponseFormat() {
    var agent = new InvokeBinding.Agent("summarizer", "claude-sonnet-5",
            null, null, "You are...", "Summarize", "30s", false,
            "my-pool", null, Map.of("type", "json", "name", "summary"));
    assertEquals("my-pool", agent.pool());
    assertEquals("json", ((Map<?,?>)agent.responseFormat()).get("type"));
}
```

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Add pool, modelChain, responseFormat fields to Agent record**

Add fields with backward-compatible constructor preserving existing callers.

- [ ] **Step 4: Update deserializer for Agent's new fields**

- [ ] **Step 5: Run all tests**

Run: `mvn --batch-mode test -pl yaml-core,yaml-jackson`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add yaml-core/ yaml-jackson/
git commit -m "feat(yaml-core): extend Agent binding with pool, modelChain, responseFormat Refs #681"
```

---

## Batch 4: Step Handlers + Pipeline Wiring

### Task 6: Create step handlers for session lifecycle

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/handler/AgentSessionOpenHandler.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/handler/AgentSessionQueryHandler.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/handler/AgentSessionClearHandler.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/handler/AgentSessionCloseHandler.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/handler/AgentInvokeHandler.java` (wire pool support)
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/handler/AgentSessionOpenHandlerTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/handler/AgentSessionQueryHandlerTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/handler/AgentSessionClearHandlerTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/handler/AgentSessionCloseHandlerTest.java`

**Interfaces:**
- Consumes: `InvokeBinding.SessionOpen/Query/Clear/Close` (Task 4), `SessionPipeline` (existing), `SessionPoolRegistry` (Task 2), `SalienceScheduler` (Task 3)
- Produces: Handler beans that wire YAML steps to SessionPipeline. Each implements the handler SPI pattern matching AgentInvokeHandler.

- [ ] **Step 1: Write failing test for AgentSessionOpenHandler**

```java
@Test
void sessionOpen_createsNamedSession() {
    var binding = new InvokeBinding.SessionOpen(
            "analyst", "You are a data analyst", "claude-sonnet-5",
            null, null, null, "60s", null);
    var handler = new AgentSessionOpenHandler(pipeline, poolRegistry);
    var result = handler.execute(binding, Map.of());
    assertTrue(result.isSuccess());
    // Verify session was opened in the pipeline
    assertNotNull(pipeline.sessionFor("analyst"));
}
```

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Implement AgentSessionOpenHandler**

```java
@ApplicationScoped
public class AgentSessionOpenHandler {
    private final SessionPipeline pipeline;
    private final SessionPoolRegistry poolRegistry;

    @Inject
    public AgentSessionOpenHandler(SessionPipeline pipeline,
            SessionPoolRegistry poolRegistry) {
        this.pipeline = pipeline;
        this.poolRegistry = poolRegistry;
    }

    public Result execute(InvokeBinding.SessionOpen binding, Map<String, Object> params) {
        var init = AgentSessionInit.builder()
                .systemPrompt(binding.system())
                .model(binding.model())
                .build();
        pipeline.openSession(binding.session(), init);
        return Result.success(Map.of("session", binding.session()));
    }
}
```

- [ ] **Step 4: Implement AgentSessionQueryHandler**

Wire to `pipeline.executeSingle()` (or `executeSinglePriority()` when `binding.priority()`). Collect TextDelta events into response string. Handle response-format parsing.

- [ ] **Step 5: Implement AgentSessionClearHandler and AgentSessionCloseHandler**

Clear delegates to `pipeline.sessionFor(name).clear()`. Close delegates to `pipeline.releaseSession(name)`.

- [ ] **Step 6: Update AgentInvokeHandler for pool support**

When `binding.pool()` is set (or implicit default pool), use `poolRegistry.findByName()` → `pool.invokeViaSession()` instead of `agentProvider.invoke()`.

- [ ] **Step 7: Write remaining handler tests**

Test each handler: query with text/json output, clear, close, invoke with pool.

- [ ] **Step 8: Run all tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(yaml-step-runtime): session lifecycle handlers wired to SessionPipeline Refs #681"
```

---

## Batch 5: Playbook Compiler + Inline Pools

### Task 7: Register new step types in the playbook compiler

**Files:**
- Modify: playbook compiler step registration (find the registry/factory that maps step keys to compilers)
- Test: playbook compiler test that verifies new step types parse correctly

**Interfaces:**
- Consumes: `InvokeBinding.SessionOpen/Query/Clear/Close` (Task 4)
- Produces: Step compilers that emit the correct InvokeBinding variants when the playbook parser encounters `agent-session-open`, `agent-query`, `agent-session-clear`, `agent-session-close`

- [ ] **Step 1: Write failing test for parsing a playbook with session steps**

Create a test playbook YAML with all 5 step types and verify it parses into the correct step tree.

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Register new step types in the compiler**

Follow the existing pattern for how `agent-delegate` is registered. Add entries for `agent-invoke` (alias for agent-delegate), `agent-session-open`, `agent-query`, `agent-session-clear`, `agent-session-close`.

- [ ] **Step 4: Run tests to verify parsing works**

- [ ] **Step 5: Commit**

```bash
git add playbook-compiler/
git commit -m "feat(playbook-compiler): register session step types Refs #681"
```

### Task 8: Inline pool parsing in playbooks

**Files:**
- Modify: playbook parser (wherever the top-level YAML structure is parsed) to handle `pools:` and `admission:` sections
- Test: parser test with inline pool declarations

**Interfaces:**
- Consumes: `PoolDeclaration` record (Task 1)
- Produces: Parsed `List<PoolDeclaration>` from inline playbook `pools:` section, available to step handlers at runtime

- [ ] **Step 1: Write failing test for inline pool parsing**

```yaml
# test-playbook-with-pools.yaml
pools:
  characters:
    backend: claude
    max-active: 10
    clearing:
      policy: size-aware
      threshold: 8000

steps:
  - agent-session-open:
      session: butler
      system: "You are Jeeves"
  - agent-query:
      session: butler
      user: "Good morning"
      output: greeting
  - agent-session-close:
      session: butler
```

Test that parsing produces a CompilationResult containing pool declarations.

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Implement inline pool parsing**

In the playbook parser, detect a `pools:` key at the top level. Parse each entry into a `PoolDeclaration`. Store in the CompilationResult (or a new field on Workflow) for runtime consumption. Parse `admission:` similarly into an AdmissionConfig record.

- [ ] **Step 4: Test fail-fast on ambiguous pool reference**

Write a test with two pools declared and a step without `pool:` — verify it fails with a clear error message.

- [ ] **Step 5: Run all tests**

Run: `mvn --batch-mode test -pl playbook-compiler`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add playbook-compiler/
git commit -m "feat(playbook-compiler): inline pool and admission parsing Refs #681"
```

---

## Batch 6: Test Coverage + Examples

### Task 9: Create 12 playbook templates and 16 manifest configs

**Files:**
- Create: `yaml-step-runtime/src/test/resources/playbooks/agent/P01-direct-invoke.yaml`
- Create: `yaml-step-runtime/src/test/resources/playbooks/agent/P02-pool-invoke.yaml`
- Create: `yaml-step-runtime/src/test/resources/playbooks/agent/P03-pool-invoke-parallel.yaml`
- Create: `yaml-step-runtime/src/test/resources/playbooks/agent/P04-session-sequential.yaml`
- Create: `yaml-step-runtime/src/test/resources/playbooks/agent/P05-session-with-clear.yaml`
- Create: `yaml-step-runtime/src/test/resources/playbooks/agent/P06-session-parallel-batch.yaml`
- Create: `yaml-step-runtime/src/test/resources/playbooks/agent/P07-sticky-sequential.yaml`
- Create: `yaml-step-runtime/src/test/resources/playbooks/agent/P08-sticky-parallel.yaml`
- Create: `yaml-step-runtime/src/test/resources/playbooks/agent/P09-multi-pool.yaml`
- Create: `yaml-step-runtime/src/test/resources/playbooks/agent/P10-priority-query.yaml`
- Create: `yaml-step-runtime/src/test/resources/playbooks/agent/P11-model-selection.yaml`
- Create: `yaml-step-runtime/src/test/resources/playbooks/agent/P12-response-formats.yaml`
- Create: `yaml-step-runtime/src/test/resources/configs/agent/C01-no-pool.yaml` through `C16-multi-pool-lifecycle.yaml`

**Interfaces:**
- Consumes: all step types (Tasks 4-5), all pool config (Task 1)
- Produces: YAML test fixtures covering all 64 patterns

- [ ] **Step 1: Create P01 through P04 (core playbooks)**

Write the simplest playbook for each interaction shape: direct invoke, pool-backed invoke, pool-backed parallel, and sequential multi-turn session.

- [ ] **Step 2: Create P05 through P08 (session lifecycle playbooks)**

Write playbooks for explicit clear, parallel batch across sessions, sticky sequential, and sticky parallel.

- [ ] **Step 3: Create P09 through P12 (advanced playbooks)**

Write playbooks for multi-pool, priority query, model selection modes, and response formats.

- [ ] **Step 4: Create C01 through C08 (pool and clearing configs)**

Write manifest configs for no-pool, fixed-pool, elastic-pool, elastic-aimd, and all 4 clearing policies.

- [ ] **Step 5: Create C09 through C16 (eviction, salience, lifecycle configs)**

Write manifest configs for idle eviction, eviction+recreation, prompt size limit, salience preempt/cascade/fairness, full lifecycle, and multi-pool lifecycle.

- [ ] **Step 6: Commit**

```bash
git add yaml-step-runtime/src/test/resources/
git commit -m "test: add 12 playbook templates and 16 manifest configs for agent patterns Refs #681"
```

### Task 10: Create parameterized test harness

**Files:**
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/handler/AgentStepSimulationTest.java`
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/handler/AgentStepOllamaIT.java`

**Interfaces:**
- Consumes: playbook templates (Task 9), manifest configs (Task 9), SimulatedAgentBackend, all handlers (Task 6)
- Produces: parameterized test that runs each (playbook, config) pair with targeted assertions

- [ ] **Step 1: Write AgentStepSimulationTest skeleton**

```java
@QuarkusTest
class AgentStepSimulationTest {

    @ParameterizedTest
    @MethodSource("patternMatrix")
    void pattern(String playbook, String config, String expectedBehavior) {
        // Load playbook from resources
        // Load config from resources
        // Create SimulatedAgentBackend with AgentCorpus
        // Compile and execute playbook
        // Assert expected behavior based on pattern
    }

    static Stream<Arguments> patternMatrix() {
        return Stream.of(
            Arguments.of("P01-direct-invoke", "C01-no-pool", "single-shot"),
            Arguments.of("P02-pool-invoke", "C02-fixed-pool", "pool-checkout"),
            Arguments.of("P02-pool-invoke", "C03-elastic-pool", "elastic-growth"),
            // ... all 71 combinations
        );
    }
}
```

- [ ] **Step 2: Implement test execution engine**

Build a test helper that: loads YAML playbook, creates SimulatedAgentBackend with canned responses, instantiates the pool/admission infrastructure from the config, compiles and executes the playbook, captures results and metrics.

- [ ] **Step 3: Write assertions for each pattern category**

- Pool-backed: verify checkout/release happened
- Session: verify session persists across queries
- Clearing: verify context cleared at appropriate times
- Eviction: verify session evicted after idle timeout
- Recreation: verify evicted session transparently recreated
- Salience: verify scheduling order matches salience levels
- Prompt limit: verify rejection when exceeding max-prompt-tokens

- [ ] **Step 4: Write AgentStepOllamaIT for live validation**

```java
@QuarkusIntegrationTest
@Tag("ollama")
class AgentStepOllamaIT {
    // Run key patterns (P01, P04, P07, P08) against live Ollama
    // Requires Ollama running with a model pulled
}
```

- [ ] **Step 5: Run simulation tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=AgentStepSimulationTest`
Expected: all 71 patterns PASS

- [ ] **Step 6: Commit**

```bash
git add yaml-step-runtime/src/test/
git commit -m "test: parameterized agent step simulation covering 64 patterns Refs #681"
```

### Task 11: Example gallery and documentation

**Files:**
- Create: `examples/agent-interaction-patterns/` directory with 8 example playbooks
- Modify: `docs/guides/consumer-guide.md` — add agent step types section

**Interfaces:**
- Consumes: all step types and pool config (Tasks 1-8)
- Produces: 8 self-contained example playbooks with inline comments

- [ ] **Step 1: Create 8 example playbooks**

1. `01-direct-invoke.yaml` — simplest case
2. `02-pool-backed-invoke.yaml` — with structured output
3. `03-parallel-fan-out.yaml` — parallel classification
4. `04-multi-turn-session.yaml` — sequential analysis
5. `05-sticky-conversations.yaml` — WhatsApp-style
6. `06-multi-pool-channels.yaml` — voice/email/WhatsApp with salience
7. `07-model-chain-fallback.yaml` — model chain
8. `08-priority-admission.yaml` — priority query

- [ ] **Step 2: Update consumer-guide.md**

Add a section documenting the 5 step types, pool configuration, admission gate, and salience scheduling. Include YAML snippets from the examples.

- [ ] **Step 3: Commit**

```bash
git add examples/agent-interaction-patterns/ docs/guides/consumer-guide.md
git commit -m "docs: agent interaction pattern examples and consumer guide update Refs #681"
```

---

## References

- [2026-10-31-yaml-agent-interaction-steps-design.md] — design spec this plan implements
- `yaml-core/src/main/java/io/casehub/yaml/core/step/InvokeBinding.java` — sealed interface for step bindings
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/handler/AgentInvokeHandler.java` — existing handler
- `agent-config-core/src/main/java/io/casehub/platform/agent/config/PoolDeclaration.java` — pool config record
- `agent-session-core/src/main/java/io/casehub/platform/agent/session/SessionPoolRegistry.java` — pool registry
- `agent-session-core/src/main/java/io/casehub/platform/agent/session/SessionPipeline.java` — pipeline
- `agent-session-core/src/main/java/io/casehub/platform/agent/session/ClearingPolicy.java` — clearing enum
- `agent-gate-core/src/main/java/io/casehub/platform/agent/gate/AimdAdmissionStrategy.java` — AIMD
- `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestProcessor.java` — manifest processing
- GitHub #681 — focal issue
