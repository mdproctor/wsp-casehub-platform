# Event Sequence Patterns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #600 — epic: Event sequence patterns — composable CEP primitives for playbook language
**Issue group:** #601, #602, #603, #604, #605

**Goal:** Add composable event sequence matching to the playbook language via ConsumerHandle, from: hardening, pause/resume control, race: step, and temporal pattern composition.

**Architecture:** Two modules only — yaml-core (new ConsumerHandle primitive, OrcChannel.isClosed()) and yaml-step-runtime (from: hardening, ControlStep, RaceStep, Walker parsing, schema). Pure Java, no CDI, virtual-thread-safe (no `synchronized`).

**Tech Stack:** Java 21+, virtual threads, LockSupport, j.u.c atomics, JUnit 5

## Global Constraints

- yaml-core must remain zero-dependency and J2CL-safe
- All primitives MUST use j.u.c locks or lock-free atomics — never `synchronized` (virtual thread pinning)
- OrcChannel uses LinkedBlockingQueue — competing consumers on shared channels consume events exclusively
- ResolvedStep sealed hierarchy grows from 10 to 12 variants (RaceStep + ControlStep)
- `pause`/`resume` keywords replace the `stop`/`start` proposed in #602

---

## Batch 1: Foundation — ConsumerHandle + from: hardening + ControlStep

After this batch: named consumers can be paused/resumed, from: handles channel close and until: conditions, pause:/resume: YAML keywords work end-to-end.

### Task 1: ConsumerHandle primitive + OrcChannel.isClosed()

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ConsumerHandle.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultConsumerHandle.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcChannel.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcChannel.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/PrimitiveFactory.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultPrimitiveFactory.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ExecutionScope.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultExecutionScope.java`
- Create: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ConsumerHandleTest.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/OrcChannelTest.java`

**Interfaces:**
- Produces: `ConsumerHandle` interface (`pause()`, `resume()`, `isRunning()`, `isReleased()`, `registerThread(Thread)`)
- Produces: `OrcChannel.isClosed()` method
- Produces: `ExecutionScope.consumerHandle(String name)` method
- Produces: `PrimitiveFactory.createConsumerHandle(String name)` method

- [ ] **Step 1: Write ConsumerHandle test — pause/resume basics**

```java
package io.casehub.yaml.core.orchestration;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ConsumerHandleTest {

    @Test
    void startsRunning() {
        ConsumerHandle handle = new DefaultConsumerHandle("test");
        assertTrue(handle.isRunning());
        assertFalse(handle.isReleased());
    }

    @Test
    void pauseSetsNotRunning() {
        ConsumerHandle handle = new DefaultConsumerHandle("test");
        handle.pause();
        assertFalse(handle.isRunning());
    }

    @Test
    void resumeAfterPause() {
        ConsumerHandle handle = new DefaultConsumerHandle("test");
        handle.pause();
        handle.resume();
        assertTrue(handle.isRunning());
    }

    @Test
    void releaseForCloseSetsReleased() {
        ConsumerHandle handle = new DefaultConsumerHandle("test");
        handle.releaseForClose();
        assertTrue(handle.isReleased());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ConsumerHandleTest -DfailIfNoTests=false`
Expected: Compilation failure — ConsumerHandle and DefaultConsumerHandle do not exist

- [ ] **Step 3: Create ConsumerHandle interface**

Create `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ConsumerHandle.java`:

```java
package io.casehub.yaml.core.orchestration;

public interface ConsumerHandle extends OrcPrimitive {
    void pause();
    void resume();
    boolean isRunning();
    boolean isReleased();
    void registerThread(Thread thread);
}
```

- [ ] **Step 4: Create DefaultConsumerHandle implementation**

Create `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultConsumerHandle.java`:

```java
package io.casehub.yaml.core.orchestration;

import java.util.concurrent.locks.LockSupport;

public final class DefaultConsumerHandle implements ConsumerHandle {

    private final String name;
    private volatile boolean running = true;
    private volatile boolean released = false;
    private volatile Thread consumerThread;

    public DefaultConsumerHandle(String name) {
        this.name = name;
    }

    @Override
    public void pause() {
        running = false;
    }

    @Override
    public void resume() {
        running = true;
        Thread t = consumerThread;
        if (t != null) {
            LockSupport.unpark(t);
        }
    }

    @Override
    public boolean isRunning() {
        return running;
    }

    @Override
    public boolean isReleased() {
        return released;
    }

    @Override
    public void registerThread(Thread thread) {
        this.consumerThread = thread;
    }

    @Override
    public void releaseForClose() {
        released = true;
        Thread t = consumerThread;
        if (t != null) {
            LockSupport.unpark(t);
        }
    }

    @Override
    public String toString() {
        return "ConsumerHandle[" + name + ", running=" + running + ", released=" + released + "]";
    }
}
```

- [ ] **Step 5: Run ConsumerHandle tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ConsumerHandleTest`
Expected: 4 tests PASS

- [ ] **Step 6: Write concurrent pause/resume test**

Add to `ConsumerHandleTest.java`:

```java
@Test
void resumeUnparksPausedThread() throws Exception {
    ConsumerHandle handle = new DefaultConsumerHandle("test");
    handle.pause();
    var arrived = new java.util.concurrent.CountDownLatch(1);
    var resumed = new java.util.concurrent.CountDownLatch(1);

    Thread consumer = Thread.ofVirtual().start(() -> {
        handle.registerThread(Thread.currentThread());
        arrived.countDown();
        while (!handle.isRunning() && !handle.isReleased()) {
            LockSupport.park();
            if (Thread.interrupted()) return;
        }
        resumed.countDown();
    });

    assertTrue(arrived.await(1, java.util.concurrent.TimeUnit.SECONDS));
    assertFalse(handle.isRunning());

    handle.resume();
    assertTrue(resumed.await(1, java.util.concurrent.TimeUnit.SECONDS));
    assertTrue(handle.isRunning());
}

@Test
void releaseForCloseUnparksPausedThread() throws Exception {
    ConsumerHandle handle = new DefaultConsumerHandle("test");
    handle.pause();
    var arrived = new java.util.concurrent.CountDownLatch(1);
    var exited = new java.util.concurrent.CountDownLatch(1);

    Thread consumer = Thread.ofVirtual().start(() -> {
        handle.registerThread(Thread.currentThread());
        arrived.countDown();
        while (!handle.isReleased()) {
            LockSupport.park();
            if (Thread.interrupted()) break;
        }
        exited.countDown();
    });

    assertTrue(arrived.await(1, java.util.concurrent.TimeUnit.SECONDS));
    handle.releaseForClose();
    assertTrue(exited.await(1, java.util.concurrent.TimeUnit.SECONDS));
    assertTrue(handle.isReleased());
}
```

- [ ] **Step 7: Run all ConsumerHandle tests**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ConsumerHandleTest`
Expected: 6 tests PASS

- [ ] **Step 8: Add isClosed() to OrcChannel and write test**

Add to `OrcChannel.java` interface:
```java
boolean isClosed();
```

Add to `DefaultOrcChannel.java`:
```java
@Override
public boolean isClosed() {
    return closed;
}
```

Add test to `OrcChannelTest.java`:
```java
@Test
void isClosedReturnsFalseBeforeClose() {
    OrcChannel<String> channel = new DefaultOrcChannel<>("test");
    assertFalse(channel.isClosed());
}

@Test
void isClosedReturnsTrueAfterClose() {
    OrcChannel<String> channel = new DefaultOrcChannel<>("test");
    channel.close();
    assertTrue(channel.isClosed());
}

@Test
void isClosedReturnsTrueAfterErrorClose() {
    OrcChannel<String> channel = new DefaultOrcChannel<>("test");
    channel.close(new RuntimeException("error"));
    assertTrue(channel.isClosed());
    assertTrue(channel.isErrorClosed());
}
```

- [ ] **Step 9: Add ConsumerHandle to PrimitiveFactory and ExecutionScope**

Add to `PrimitiveFactory.java`:
```java
ConsumerHandle createConsumerHandle(String name);
```

Add to `DefaultPrimitiveFactory.java`:
```java
@Override
public ConsumerHandle createConsumerHandle(String name) {
    return new DefaultConsumerHandle(name);
}
```

Add to `ExecutionScope.java`:
```java
ConsumerHandle consumerHandle(String name);
```

Add to `DefaultExecutionScope.java` (follow existing `getOrCreate` pattern):
```java
@Override
public ConsumerHandle consumerHandle(String name) {
    return getOrCreate(name, ConsumerHandle.class, () -> factory.createConsumerHandle(name));
}
```

- [ ] **Step 10: Run full yaml-core test suite**

Run: `mvn --batch-mode test -pl yaml-core`
Expected: All tests PASS (existing + 9 new)

- [ ] **Step 11: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ConsumerHandle.java yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultConsumerHandle.java yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcChannel.java yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcChannel.java yaml-core/src/main/java/io/casehub/yaml/core/orchestration/PrimitiveFactory.java yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultPrimitiveFactory.java yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ExecutionScope.java yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultExecutionScope.java yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ConsumerHandleTest.java yaml-core/src/test/java/io/casehub/yaml/core/orchestration/OrcChannelTest.java
git commit -m "feat(#601,#602): add ConsumerHandle primitive and OrcChannel.isClosed()

ConsumerHandle extends OrcPrimitive with pause/resume/isRunning/isReleased
and LockSupport-based thread management. OrcChannel gains isClosed() to
distinguish timed-receive timeout from channel close.

Refs #600"
```

---

### Task 2: from: decorator hardening — until, channel close, named consumers

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java`
- Modify: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/DecoratorChainTest.java`

**Interfaces:**
- Consumes: `ConsumerHandle` (`pause()`, `resume()`, `isRunning()`, `isReleased()`, `registerThread(Thread)`)
- Consumes: `OrcChannel.isClosed()`, `OrcChannel.isErrorClosed()`, `OrcChannel.closeError()`
- Consumes: `ExecutionScope.consumerHandle(String name)`
- Produces: Enhanced `wrapFromSingleChannel` and `wrapFromFanIn` supporting `until:`, `name:`, and channel close

- [ ] **Step 1: Write test — from: channel close returns stream-ended**

Add to `DecoratorChainTest.java`:

```java
@Test
void fromChannelCloseReturnsStreamEnded() throws Exception {
    ExecutionScope scope = new DefaultExecutionScope("test", new DefaultPrimitiveFactory());
    var chain = new DecoratorChain(conditionEvaluator, SpeedMultiplier.identity(), scope);

    OrcChannel<Object> channel = scope.channel("data");
    channel.close();

    var decorators = Map.<String, Object>of("from", Map.of("channel", "data"));
    DecoratedExecution inner = ctx -> Result.of(Map.of("ran", true));
    DecoratedExecution wrapped = chain.apply(decorators, inner);

    Result result = wrapped.execute(new StepContext(resolver));
    assertTrue(result.isSuccess());
    assertEquals(true, result.output().get("from.stream-ended"));
}
```

- [ ] **Step 2: Write test — from: error-closed channel returns failure**

```java
@Test
void fromErrorClosedChannelReturnsFailure() throws Exception {
    ExecutionScope scope = new DefaultExecutionScope("test", new DefaultPrimitiveFactory());
    var chain = new DecoratorChain(conditionEvaluator, SpeedMultiplier.identity(), scope);

    OrcChannel<Object> channel = scope.channel("data");
    channel.close(new RuntimeException("connection lost"));

    var decorators = Map.<String, Object>of("from", Map.of("channel", "data"));
    DecoratedExecution inner = ctx -> Result.of(Map.of());
    DecoratedExecution wrapped = chain.apply(decorators, inner);

    Result result = wrapped.execute(new StepContext(resolver));
    assertFalse(result.isSuccess());
    assertTrue(((Result.Failure) result).message().contains("connection lost"));
}
```

- [ ] **Step 3: Write test — from: until condition exits**

```java
@Test
void fromUntilConditionExitsGracefully() throws Exception {
    ExecutionScope scope = new DefaultExecutionScope("test", new DefaultPrimitiveFactory());
    var chain = new DecoratorChain(conditionEvaluator, SpeedMultiplier.identity(), scope);

    var decorators = Map.<String, Object>of(
        "from", Map.of("channel", "data", "until", "true"));
    DecoratedExecution inner = ctx -> Result.of(Map.of("ran", true));
    DecoratedExecution wrapped = chain.apply(decorators, inner);

    Result result = wrapped.execute(new StepContext(resolver));
    assertTrue(result.isSuccess());
    assertEquals(true, result.output().get("from.stream-ended"));
}
```

- [ ] **Step 4: Write test — from: named consumer registers handle eagerly**

```java
@Test
void fromNamedConsumerRegistersHandleEagerly() throws Exception {
    ExecutionScope scope = new DefaultExecutionScope("test", new DefaultPrimitiveFactory());
    var chain = new DecoratorChain(conditionEvaluator, SpeedMultiplier.identity(), scope);

    var decorators = Map.<String, Object>of(
        "from", Map.of("channel", "data", "name", "enricher"));
    DecoratedExecution inner = ctx -> Result.of(Map.of());
    chain.apply(decorators, inner);

    ConsumerHandle handle = scope.consumerHandle("enricher");
    assertNotNull(handle);
    assertTrue(handle.isRunning());
}
```

- [ ] **Step 5: Write test — from: paused consumer blocks until resumed**

```java
@Test
void fromPausedConsumerBlocksUntilResumed() throws Exception {
    ExecutionScope scope = new DefaultExecutionScope("test", new DefaultPrimitiveFactory());
    var chain = new DecoratorChain(conditionEvaluator, SpeedMultiplier.identity(), scope);

    OrcChannel<Object> channel = scope.channel("data");
    var decorators = Map.<String, Object>of(
        "from", Map.of("channel", "data", "name", "enricher"));
    DecoratedExecution inner = ctx -> Result.of(Map.of("item", ctx.resolver().resolve("from")));
    DecoratedExecution wrapped = chain.apply(decorators, inner);

    ConsumerHandle handle = scope.consumerHandle("enricher");
    handle.pause();

    var resultRef = new java.util.concurrent.atomic.AtomicReference<Result>();
    var started = new java.util.concurrent.CountDownLatch(1);
    Thread t = Thread.ofVirtual().start(() -> {
        started.countDown();
        resultRef.set(wrapped.execute(new StepContext(resolver)));
    });

    assertTrue(started.await(1, java.util.concurrent.TimeUnit.SECONDS));
    Thread.sleep(200);
    assertNull(resultRef.get());

    handle.resume();
    channel.send("hello");
    t.join(2000);
    assertNotNull(resultRef.get());
    assertTrue(resultRef.get().isSuccess());
}
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=DecoratorChainTest#fromChannelCloseReturnsStreamEnded+fromErrorClosedChannelReturnsFailure+fromUntilConditionExitsGracefully+fromNamedConsumerRegistersHandleEagerly+fromPausedConsumerBlocksUntilResumed -DfailIfNoTests=false`
Expected: FAIL — current wrapFrom doesn't handle these cases

- [ ] **Step 7: Implement from: hardening in wrapFromSingleChannel**

Rewrite `DecoratorChain.wrapFromSingleChannel()` to implement the unified receive loop from the spec. Key changes:

1. Parse `until` and `name` from the `fromMap` in `wrapFrom()`
2. If `name` is present, eagerly register ConsumerHandle via `scope.consumerHandle(name)` during lambda construction
3. In the receive lambda, implement the spec's receive loop:
   - Check `handle.isReleased()` → return stream-ended
   - Check `handle.isRunning()` → if paused, `LockSupport.park()`, check interrupt, continue
   - Check until condition → if true, return stream-ended
   - Timed receive (100ms) from channel
   - Check `channel.isClosed()` / `channel.isErrorClosed()` on null
   - Apply filter → if rejected, continue
   - Inject into scope, execute inner step
4. When no `name` and no `until`, retain current blocking receive (backward compat)

The method signature and position in the decorator chain remain unchanged. Only the internal receive loop logic changes.

Apply the same changes to `wrapFromFanIn()` — same until/name/close handling, shared ConsumerHandle across all channels in the fan-in group.

- [ ] **Step 8: Run from: hardening tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=DecoratorChainTest`
Expected: All existing tests PASS + 5 new tests PASS

- [ ] **Step 9: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/DecoratorChainTest.java
git commit -m "feat(#601,#602): harden from: decorator — until, channel close, named consumers

Add until: condition check, channel close/error-close detection, and named
consumer handle with LockSupport-based pause/resume to wrapFromSingleChannel
and wrapFromFanIn. ConsumerHandle registered eagerly to prevent background
spawn race.

Refs #600"
```

---

### Task 3: ControlStep + Walker parsing + StepSchemaComposer

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java`
- Modify: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/StructuralStepEvaluatorTest.java`

**Interfaces:**
- Consumes: `ConsumerHandle` (`pause()`, `resume()`)
- Consumes: `ExecutionScope.primitive(String name, Class<T> type)` for handle lookup
- Produces: `ResolvedStep.ControlStep` record
- Produces: `evaluateControl()` in StructuralStepEvaluator
- Produces: Walker parsing for `pause:` and `resume:` keywords

- [ ] **Step 1: Write ControlStep evaluation test — pause dispatches**

Add to `StructuralStepEvaluatorTest.java`:

```java
@Test
void controlStepPausesNamedConsumer() {
    ExecutionScope scope = new DefaultExecutionScope("test", new DefaultPrimitiveFactory());
    var evaluator = new StructuralStepEvaluator(conditionEvaluator, scope);

    ConsumerHandle handle = scope.consumerHandle("enricher");
    assertTrue(handle.isRunning());

    var step = new ResolvedStep.ControlStep(null, "enricher", false, Map.of());
    Result result = evaluator.evaluate(step, resolver, runner);

    assertTrue(result.isSuccess());
    assertFalse(handle.isRunning());
}

@Test
void controlStepResumesNamedConsumer() {
    ExecutionScope scope = new DefaultExecutionScope("test", new DefaultPrimitiveFactory());
    var evaluator = new StructuralStepEvaluator(conditionEvaluator, scope);

    ConsumerHandle handle = scope.consumerHandle("enricher");
    handle.pause();
    assertFalse(handle.isRunning());

    var step = new ResolvedStep.ControlStep(null, "enricher", true, Map.of());
    Result result = evaluator.evaluate(step, resolver, runner);

    assertTrue(result.isSuccess());
    assertTrue(handle.isRunning());
}

@Test
void controlStepMissingHandleReturnsFailure() {
    ExecutionScope scope = new DefaultExecutionScope("test", new DefaultPrimitiveFactory());
    var evaluator = new StructuralStepEvaluator(conditionEvaluator, scope);

    var step = new ResolvedStep.ControlStep(null, "nonexistent", false, Map.of());
    Result result = evaluator.evaluate(step, resolver, runner);

    assertFalse(result.isSuccess());
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=StructuralStepEvaluatorTest#controlStepPausesNamedConsumer+controlStepResumesNamedConsumer+controlStepMissingHandleReturnsFailure -DfailIfNoTests=false`
Expected: Compilation failure — ControlStep does not exist

- [ ] **Step 3: Add ControlStep to ResolvedStep sealed hierarchy**

Add to `ResolvedStep.java` permits clause:
```java
ResolvedStep.ControlStep
```

Add record inside the interface:
```java
record ControlStep(
        String name,
        String target,
        boolean activate,
        Map<String, Object> decorators) implements ResolvedStep {

    public ControlStep {
        if (target == null || target.isBlank()) {
            throw new IllegalArgumentException(
                "pause/resume requires a non-blank target consumer name");
        }
        decorators = Map.copyOf(decorators);
    }
}
```

- [ ] **Step 4: Add evaluateControl to StructuralStepEvaluator**

Add to `dispatchStep()` switch:
```java
case ResolvedStep.ControlStep c -> evaluateControl(c);
```

Add method:
```java
private Result evaluateControl(ResolvedStep.ControlStep control) {
    if (scope == null) {
        return Result.failed("'pause'/'resume' requires an ExecutionScope");
    }
    ConsumerHandle handle = scope.primitive(control.target(), ConsumerHandle.class);
    if (handle == null) {
        return Result.failed("Consumer '" + control.target() + "' not found");
    }
    if (control.activate()) {
        handle.resume();
    } else {
        handle.pause();
    }
    return Result.of(Map.of());
}
```

Also add `ControlStep` to `preRegisterLatches` and `validateBarrierQuorumReferences` default cases if needed.

- [ ] **Step 5: Add pause/resume to Walker RESERVED_KEYS and resolveOne()**

Add `"pause"`, `"resume"` to `Walker.RESERVED_KEYS`.

In `resolveOne()`, add structural keyword handling before the `matchedAction` check (after the quorum block, before line 272):

```java
if ("race".equals(structuralType)) {
    // handled in Task 4
}
```

For pause/resume, these are RESERVED_KEYS but need explicit handling. Add to the key-scanning loop, alongside `"block"`, `"parallel"` etc.:

In the `for (Map.Entry...)` loop, add `"pause"` and `"resume"` to the structural keyword branch:
```java
} else if ("pause".equals(key) || "resume".equals(key)) {
    structuralType  = key;
    structuralValue = e.getValue();
```

After the quorum block in `resolveOne()`:
```java
if ("pause".equals(structuralType)) {
    return new ResolvedStep.ControlStep(stepName, String.valueOf(structuralValue), false, decorators);
}
if ("resume".equals(structuralType)) {
    return new ResolvedStep.ControlStep(stepName, String.valueOf(structuralValue), true, decorators);
}
```

Also add the **decorator-only step fallback** before the final `throw`:
```java
if (!decorators.isEmpty()) {
    return new ResolvedStep.BlockStep(stepName, List.of(), decorators);
}
```

- [ ] **Step 6: Add ControlStep to Walker.validateBarrierQuorumReferences()**

Add `case ResolvedStep.ControlStep c -> {}` to the switch in `validateBarrierQuorumReferences` to prevent exhaustiveness compiler error.

- [ ] **Step 7: Add pause/resume schema variants to StepSchemaComposer**

In `StepSchemaComposer.compose()`, add `oneOf` entries for `pause:` and `resume:`:

```java
ObjectNode pauseVariant = mapper.createObjectNode();
ObjectNode pauseProps = pauseVariant.putObject("properties");
pauseProps.putObject("pause").put("type", "string");
pauseVariant.putArray("required").add("pause");
oneOf.add(pauseVariant);

ObjectNode resumeVariant = mapper.createObjectNode();
ObjectNode resumeProps = resumeVariant.putObject("properties");
resumeProps.putObject("resume").put("type", "string");
resumeVariant.putArray("required").add("resume");
oneOf.add(resumeVariant);
```

- [ ] **Step 8: Run ControlStep tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=StructuralStepEvaluatorTest`
Expected: All tests PASS including 3 new ControlStep tests

- [ ] **Step 9: Run full yaml-step-runtime test suite**

Run: `mvn --batch-mode test -pl yaml-step-runtime`
Expected: All tests PASS

- [ ] **Step 10: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/StructuralStepEvaluatorTest.java
git commit -m "feat(#602): add ControlStep for pause:/resume: + Walker parsing + decorator-only fallback

ControlStep dispatches to ConsumerHandle.pause()/resume() via ExecutionScope.
Walker parses pause:/resume: as structural keywords. Decorator-only steps
(e.g., standalone from:, delay:, publish:) desugar to empty BlockStep wrapped
by their decorators.

Refs #600"
```

---

## Batch 2: RaceStep — first-to-complete alternation

After this batch: race: YAML keyword launches branches on virtual threads, first successful result wins, losers cancelled via thread interruption.

### Task 4: RaceStep + evaluator + Walker parsing

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java`
- Modify: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/StructuralStepEvaluatorTest.java`

**Interfaces:**
- Consumes: `evaluateInternal(ResolvedStep, StepContext, StepRunner)` from StructuralStepEvaluator
- Produces: `ResolvedStep.RaceStep` record
- Produces: `evaluateRace()` in StructuralStepEvaluator
- Produces: Walker parsing for `race:` keyword

- [ ] **Step 1: Write RaceStep test — first successful branch wins**

```java
@Test
void raceFirstSuccessfulBranchWins() throws Exception {
    ExecutionScope scope = new DefaultExecutionScope("test", new DefaultPrimitiveFactory());
    var evaluator = new StructuralStepEvaluator(conditionEvaluator, scope);

    OrcChannel<Object> fastChannel = scope.channel("fast");
    OrcChannel<Object> slowChannel = scope.channel("slow");

    var fastBranch = new ResolvedStep.BlockStep(null, List.of(
        new ResolvedStep.BlockStep(null, List.of(), Map.of("from", Map.of("channel", "fast")))
    ), Map.of());
    var slowBranch = new ResolvedStep.BlockStep(null, List.of(
        new ResolvedStep.BlockStep(null, List.of(), Map.of("from", Map.of("channel", "slow")))
    ), Map.of());

    var raceStep = new ResolvedStep.RaceStep(null, List.of(fastBranch, slowBranch), Map.of());

    Thread.ofVirtual().start(() -> {
        try {
            Thread.sleep(50);
            fastChannel.send("fast-wins");
        } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    });

    Result result = evaluator.evaluate(raceStep, resolver, runner);
    assertTrue(result.isSuccess());
}
```

- [ ] **Step 2: Write RaceStep test — all branches fail**

```java
@Test
void raceAllBranchesFailReportsErrors() {
    ExecutionScope scope = new DefaultExecutionScope("test", new DefaultPrimitiveFactory());
    var evaluator = new StructuralStepEvaluator(conditionEvaluator, scope);

    var failStep1 = new ResolvedStep.BlockStep(null, List.of(), Map.of("timeout", "50ms"));
    var failStep2 = new ResolvedStep.BlockStep(null, List.of(), Map.of("timeout", "50ms"));

    // Use plugin steps that return failure
    StepRunner failRunner = (step, res) -> Result.failed("branch failed");
    var branch1 = new ResolvedStep.PluginStep(null, "fail1", Map.of(), Map.of());
    var branch2 = new ResolvedStep.PluginStep(null, "fail2", Map.of(), Map.of());

    var raceStep = new ResolvedStep.RaceStep(null, List.of(branch1, branch2), Map.of());
    Result result = evaluator.evaluate(raceStep, resolver, failRunner);

    assertFalse(result.isSuccess());
    assertTrue(((Result.Failure) result).message().contains("All race branches failed"));
}
```

- [ ] **Step 3: Write RaceStep test — minimum 2 branches validation**

```java
@Test
void raceRequiresAtLeastTwoBranches() {
    var singleBranch = new ResolvedStep.BlockStep(null, List.of(), Map.of());
    assertThrows(IllegalArgumentException.class,
        () -> new ResolvedStep.RaceStep(null, List.of(singleBranch), Map.of()));
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=StructuralStepEvaluatorTest#raceFirstSuccessfulBranchWins+raceAllBranchesFailReportsErrors+raceRequiresAtLeastTwoBranches -DfailIfNoTests=false`
Expected: Compilation failure — RaceStep does not exist

- [ ] **Step 5: Add RaceStep to ResolvedStep sealed hierarchy**

Add to `ResolvedStep.java` permits clause:
```java
ResolvedStep.RaceStep
```

Add record inside the interface:
```java
record RaceStep(
        String name,
        List<ResolvedStep> branches,
        Map<String, Object> decorators) implements ResolvedStep {

    public RaceStep {
        if (branches == null || branches.size() < 2) {
            throw new IllegalArgumentException("race requires at least 2 branches");
        }
        branches = List.copyOf(branches);
        decorators = Map.copyOf(decorators);
    }
}
```

- [ ] **Step 6: Add evaluateRace to StructuralStepEvaluator**

Add to `dispatchStep()` switch:
```java
case ResolvedStep.RaceStep r -> evaluateRace(r, ctx, runner);
```

Add the `evaluateRace()` method from the spec (§4, lines 280-329). Key implementation points:
- `AtomicReference<Result> winnerResult` + `AtomicInteger winnerIndex` for CAS
- `AtomicReference<String>[]` for branch failure messages
- `newVirtualThreadPerTaskExecutor()` for branch threads
- Winner cancels losers via `future.cancel(true)`
- `finally` block cancels all futures before executor close (hang prevention)
- All-fail diagnostic message aggregates branch errors

Add `RaceStep` to `preRegisterLatches` and `validateBarrierQuorumReferences`:
```java
case ResolvedStep.RaceStep r -> {
    for (ResolvedStep branch : r.branches()) {
        if (branch instanceof ResolvedStep.BlockStep b) preRegisterLatches(b.steps());
    }
}
```

- [ ] **Step 7: Add race: parsing to Walker.resolveOne()**

In Walker's key-scanning loop, `race` is already in RESERVED_KEYS and goes to the decorators map. But it should be handled as a structural keyword. Move `"race"` to the structural keyword branch alongside `"block"`, `"parallel"`:

```java
} else if ("block".equals(key) || "parallel".equals(key) || "try".equals(key) || "select".equals(key) || "barrier".equals(key) || "quorum".equals(key) || "race".equals(key) || "pause".equals(key) || "resume".equals(key)) {
```

After the quorum block, add race handling:
```java
if ("race".equals(structuralType)) {
    @SuppressWarnings("unchecked")
    var branches = (List<Map<String, Object>>) structuralValue;
    var resolvedBranches = resolve(branches, registry, depth + 1, stepPath + " → race", seenNames);
    return new ResolvedStep.RaceStep(stepName, resolvedBranches, decorators);
}
```

- [ ] **Step 8: Add race schema variant to StepSchemaComposer**

Add `oneOf` entry for `race:`:
```java
ObjectNode raceVariant = mapper.createObjectNode();
ObjectNode raceProps = raceVariant.putObject("properties");
ObjectNode raceSchema = raceProps.putObject("race");
raceSchema.put("type", "array");
raceSchema.putObject("items").put("$ref", "#/definitions/step");
raceVariant.putArray("required").add("race");
oneOf.add(raceVariant);
```

Remove `"race"` from `DECORATOR_KEYS` set since it's now a structural keyword handled before decorator extraction.

- [ ] **Step 9: Run RaceStep tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=StructuralStepEvaluatorTest`
Expected: All tests PASS including 3 new RaceStep tests

- [ ] **Step 10: Run full yaml-step-runtime test suite**

Run: `mvn --batch-mode test -pl yaml-step-runtime`
Expected: All tests PASS

- [ ] **Step 11: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/StructuralStepEvaluatorTest.java
git commit -m "feat(#603): add RaceStep — first-to-complete alternation with cancellation

RaceStep launches branches on virtual threads, first successful result wins
via CAS, losers cancelled via future.cancel(true). All-fail diagnostic includes
per-branch error messages. Walker parses race: as structural keyword.

Refs #600"
```

---

## Batch 3: Integration tests — temporal patterns + recursive composition

After this batch: all temporal pattern compositions verified, recursive sub-pattern grammar proven, epic #600 complete.

### Task 5: Temporal pattern tests

**Files:**
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/TemporalPatternTest.java`

**Interfaces:**
- Consumes: All from Tasks 1-4 (ConsumerHandle, from: hardening, ControlStep, RaceStep)
- Produces: Integration tests verifying timed absence, delayed sequence, periodic heartbeat

- [ ] **Step 1: Write timed absence test — timeout fires (absence detected)**

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.orchestration.*;
import io.casehub.yaml.core.runtime.SpeedMultiplier;
import io.casehub.yaml.plugin.api.Result;
import io.casehub.yaml.step.catalog.ResolvedStep;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

class TemporalPatternTest {

    @Test
    void timedAbsenceDetected_timeoutFires() throws Exception {
        ExecutionScope scope = new DefaultExecutionScope("test", new DefaultPrimitiveFactory());
        var evaluator = new StructuralStepEvaluator(conditionEvaluator, scope);

        OrcChannel<Object> events = scope.channel("events");

        // Send event A but NOT event B — absence should be detected
        events.send(Map.of("type", "EXPANSION"));

        // Block: from A, then block(from B) with timeout 200ms + on-error
        var fromA = new ResolvedStep.BlockStep(null, List.of(),
            Map.of("from", Map.of("channel", "events", "filter", "from.type == 'EXPANSION'")));
        var fromB = new ResolvedStep.BlockStep(null, List.of(),
            Map.of("from", Map.of("channel", "events", "filter", "from.type == 'DEFENSE'")));
        var timedFromB = new ResolvedStep.BlockStep(null, List.of(fromB),
            Map.of("timeout", "200ms", "on-error", "greedy-detected"));

        var pattern = new ResolvedStep.BlockStep(null, List.of(fromA, timedFromB), Map.of());
        Result result = evaluator.evaluate(pattern, resolver, runner);

        assertTrue(result.isSuccess());
        assertEquals("greedy-detected", result.output().get("on-error.fallback"));
    }

    @Test
    void timedAbsenceNotDetected_eventArrives() throws Exception {
        ExecutionScope scope = new DefaultExecutionScope("test", new DefaultPrimitiveFactory());
        var evaluator = new StructuralStepEvaluator(conditionEvaluator, scope);

        OrcChannel<Object> events = scope.channel("events");

        // Send both A and B — no absence
        events.send(Map.of("type", "EXPANSION"));
        events.send(Map.of("type", "DEFENSE"));

        var fromA = new ResolvedStep.BlockStep(null, List.of(),
            Map.of("from", Map.of("channel", "events", "filter", "from.type == 'EXPANSION'")));
        var fromB = new ResolvedStep.BlockStep(null, List.of(),
            Map.of("from", Map.of("channel", "events", "filter", "from.type == 'DEFENSE'")));
        var timedFromB = new ResolvedStep.BlockStep(null, List.of(fromB),
            Map.of("timeout", "2s"));

        var pattern = new ResolvedStep.BlockStep(null, List.of(fromA, timedFromB), Map.of());
        Result result = evaluator.evaluate(pattern, resolver, runner);

        assertTrue(result.isSuccess());
        assertNull(result.output().get("on-error.fallback"));
    }
}
```

- [ ] **Step 2: Write delayed sequence test**

```java
@Test
void delayedSequence_delayThenTimeout() throws Exception {
    ExecutionScope scope = new DefaultExecutionScope("test",
        new DefaultPrimitiveFactory(SpeedMultiplier.of(10.0)));
    var evaluator = new StructuralStepEvaluator(conditionEvaluator, scope);
    var chain = new DecoratorChain(conditionEvaluator, SpeedMultiplier.of(10.0), scope);

    OrcChannel<Object> events = scope.channel("events");
    events.send(Map.of("type", "SCOUT"));

    var fromScout = new ResolvedStep.BlockStep(null, List.of(),
        Map.of("from", Map.of("channel", "events", "filter", "from.type == 'SCOUT'")));
    var delayStep = new ResolvedStep.BlockStep(null, List.of(),
        Map.of("delay", "1s"));
    var fromCounter = new ResolvedStep.BlockStep(null, List.of(),
        Map.of("from", Map.of("channel", "events", "filter", "from.type == 'COUNTER'")));
    var timedCounter = new ResolvedStep.BlockStep(null, List.of(fromCounter),
        Map.of("timeout", "500ms", "on-error", "unprepared"));

    var pattern = new ResolvedStep.BlockStep(null,
        List.of(fromScout, delayStep, timedCounter), Map.of());

    Result result = evaluator.evaluate(pattern, resolver, runner);
    assertTrue(result.isSuccess());
    assertEquals("unprepared", result.output().get("on-error.fallback"));
}
```

- [ ] **Step 3: Write periodic heartbeat test**

```java
@Test
void periodicHeartbeat_missingHeartbeatDetected() throws Exception {
    ExecutionScope scope = new DefaultExecutionScope("test",
        new DefaultPrimitiveFactory(SpeedMultiplier.of(20.0)));
    var evaluator = new StructuralStepEvaluator(conditionEvaluator, scope);

    OrcChannel<Object> heartbeats = scope.channel("heartbeats");

    var fromHeartbeat = new ResolvedStep.BlockStep(null, List.of(),
        Map.of("from", Map.of("channel", "heartbeats")));
    var timedHeartbeat = new ResolvedStep.BlockStep(null, List.of(fromHeartbeat),
        Map.of("timeout", "500ms", "on-error", "unresponsive"));

    Result result = evaluator.evaluate(timedHeartbeat, resolver, runner);

    assertTrue(result.isSuccess());
    assertEquals("unresponsive", result.output().get("on-error.fallback"));
}
```

- [ ] **Step 4: Run temporal pattern tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=TemporalPatternTest`
Expected: All 4 tests PASS

- [ ] **Step 5: Commit**

```bash
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/TemporalPatternTest.java
git commit -m "test(#604): temporal pattern integration tests — absence, delay, heartbeat

Verify timed absence (timeout fires = absence detected, event arrives = no
absence), delayed sequence with speedMultiplier, and periodic heartbeat
monitoring.

Refs #600"
```

---

### Task 6: Recursive composition integration test

**Files:**
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/RecursiveCompositionTest.java`

**Interfaces:**
- Consumes: All from Tasks 1-4
- Produces: Integration test proving `block:`, `race:`, `loop:`, `match:` nest arbitrarily

- [ ] **Step 1: Write recursive sub-pattern test: ((A then B) or (A then C))***

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.orchestration.*;
import io.casehub.yaml.plugin.api.Result;
import io.casehub.yaml.step.catalog.ResolvedStep;
import io.casehub.yaml.step.catalog.ResolvedMatchCase;
import io.casehub.yaml.core.step.MatchPattern;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

class RecursiveCompositionTest {

    @Test
    void recursivePattern_ABorAC_repeated() throws Exception {
        ExecutionScope scope = new DefaultExecutionScope("test", new DefaultPrimitiveFactory());
        var evaluator = new StructuralStepEvaluator(conditionEvaluator, scope);

        OrcChannel<Object> events = scope.channel("events");
        OrcChannel<Object> matched = scope.channel("matched");

        // Inject [A, B, A, C, A, B] then close
        for (String type : List.of("A", "B", "A", "C", "A", "B")) {
            events.send(Map.of("type", type));
        }
        events.close();

        // Build the pattern: loop continuous + block[from:A, match:from.type + from:events]
        // Step 1: from: { channel: events, filter: "from.type == 'A'" }
        var fromA = new ResolvedStep.BlockStep(null, List.of(),
            Map.of("from", Map.of("channel", "events", "filter", "from.type == 'A'")));

        // Step 2: match: from.type with from: { channel: events, filter: "from.type == 'B' or from.type == 'C'" }
        // Cases: B → publish AB, C → publish AC
        var publishAB = new ResolvedStep.BlockStep(null, List.of(),
            Map.of("publish", Map.of("channel", "matched", "data", "AB")));
        var publishAC = new ResolvedStep.BlockStep(null, List.of(),
            Map.of("publish", Map.of("channel", "matched", "data", "AC")));

        var caseB = new ResolvedMatchCase(
            new MatchPattern.ValuePattern("B"), null, List.of(publishAB));
        var caseC = new ResolvedMatchCase(
            new MatchPattern.ValuePattern("C"), null, List.of(publishAC));

        var matchStep = new ResolvedStep.MatchStep(null, "from.type",
            List.of(caseB, caseC),
            Map.of("from", Map.of("channel", "events",
                "filter", "from.type == 'B' or from.type == 'C'")));

        var block = new ResolvedStep.BlockStep(null, List.of(fromA, matchStep), Map.of());
        var loop = new ResolvedStep.BlockStep(null, List.of(block),
            Map.of("loop", 3));

        Result result = evaluator.evaluate(loop, resolver, runner);

        // Verify matched channel received [AB, AC, AB]
        assertEquals("AB", matched.receive(100, java.util.concurrent.TimeUnit.MILLISECONDS));
        assertEquals("AC", matched.receive(100, java.util.concurrent.TimeUnit.MILLISECONDS));
        assertEquals("AB", matched.receive(100, java.util.concurrent.TimeUnit.MILLISECONDS));
        assertTrue(matched.isEmpty());
    }

    @Test
    void raceWithIndependentChannels() throws Exception {
        ExecutionScope scope = new DefaultExecutionScope("test", new DefaultPrimitiveFactory());
        var evaluator = new StructuralStepEvaluator(conditionEvaluator, scope);

        OrcChannel<Object> mfaChannel = scope.channel("mfa");
        OrcChannel<Object> ssoChannel = scope.channel("sso");

        // SSO responds first
        Thread.ofVirtual().start(() -> {
            try {
                Thread.sleep(50);
                ssoChannel.send(Map.of("token", "sso-123"));
            } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        });

        var mfaBranch = new ResolvedStep.BlockStep(null, List.of(),
            Map.of("from", Map.of("channel", "mfa")));
        var ssoBranch = new ResolvedStep.BlockStep(null, List.of(),
            Map.of("from", Map.of("channel", "sso")));

        var race = new ResolvedStep.RaceStep(null, List.of(mfaBranch, ssoBranch), Map.of());
        Result result = evaluator.evaluate(race, resolver, runner);

        assertTrue(result.isSuccess());
    }
}
```

- [ ] **Step 2: Run recursive composition tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=RecursiveCompositionTest`
Expected: All 2 tests PASS

- [ ] **Step 3: Run full project build**

Run: `mvn --batch-mode install`
Expected: All modules compile and pass tests

- [ ] **Step 4: Commit**

```bash
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/RecursiveCompositionTest.java
git commit -m "test(#605): recursive composition — ((A then B) or (A then C))* + race with independent channels

Proves the event pattern grammar is regular-recursive: block/loop/match
nest arbitrarily. Sequential from: + match:/cases: for single-stream
alternation. Race for independent channels.

Refs #600"
```

---

## References

- [2026-10-13-event-sequence-patterns-design.md] — design spec this plan implements
- DecoratorChain.java:419-535 — current from: implementation
- StructuralStepEvaluator.java:213-290 — SelectStep early-termination pattern (reused for race)
- ResolvedStep.java — sealed hierarchy (permits clause)
- Walker.java:16-23 — RESERVED_KEYS, resolveOne() structural dispatch
- OrcChannel.java / DefaultOrcChannel.java — channel API
- ExecutionScope.java / DefaultExecutionScope.java — primitive registration
- PrimitiveFactory.java / DefaultPrimitiveFactory.java — factory pattern
- ConsumerHandleTest.java, DecoratorChainTest.java, StructuralStepEvaluatorTest.java — existing test files
- GitHub #600, #601, #602, #603, #604, #605 — epic and child issues
