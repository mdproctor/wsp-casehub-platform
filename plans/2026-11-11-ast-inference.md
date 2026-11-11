# AST-Based Plugin Call Chain Inference — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #798 — Infer plugin call chain from method body AST
**Issue group:** #798

**Goal:** Extend the graphql-generator APT to read connector method bodies via `com.sun.source.util.TreePathScanner`, inferring the SPI call chain directly from the code so that `@GeneratePlugin(capability, spi, accessor, spiMethod)` become fallbacks rather than requirements.

**Architecture:** A new `infer` package in `graphql-generator` containing `MethodBodyInferrer` (entry point), `CallChainScanner` (TreePathScanner subclass), `InferredCallChain` (result record), `InferenceFailure` (enum), and `MethodCallInfo` (chain element record). The scanner walks the method body in a single pass, recognizing connector patterns (service.platform() routing, requireCapability() detection, return-chain extraction, static default detection). Results merge into the existing `generatePluginSource()` method with annotation-explicit values taking precedence over inference.

**Tech Stack:** Java 21+, javac Compiler Tree API (`com.sun.source.util`), Jandex, JUnit 5, AssertJ, `javax.tools.JavaCompiler` (for compile-testing)

## Global Constraints

- `graphql-generator` is a Maven plugin with `maven-plugin` packaging — no Quarkus runtime
- `com.sun.source.*` types require `jdk.compiler` module — javac-only, not ECJ-compatible
- AST inference applies to Tier 2 (connector classes) only — Tier 1 (interfaces) unchanged
- `@GeneratePlugin` explicit attributes always override inference (D8 precedence model)
- All existing tests must continue to pass — no behavioral changes to Tier 1 or non-plugin generation
- No `quarkus:build` goal in graphql-generator

---

## Batch 1: Core AST Walker

### Task 1: InferenceFailure enum, InferredCallChain record, MethodCallInfo record

**Files:**
- Create: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/infer/InferenceFailure.java`
- Create: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/infer/InferredCallChain.java`
- Create: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/infer/MethodCallInfo.java`
- Test: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/infer/InferredCallChainTest.java`

**Interfaces:**
- Produces: `InferenceFailure` enum with 7 values (`NO_METHOD_BODY`, `VAR_TYPED_SPI`, `MULTIPLE_RETURNS`, `CAPABILITY_MISMATCH`, `INCOMPLETE_CAPABILITY_CHAIN`, `NO_SPI_VARIABLE`, `UNRECOGNIZED_PATTERN`); `InferredCallChain` record with `isComplete()` method; `MethodCallInfo` record with `argNames()` method

- [ ] **Step 1: Write tests for InferredCallChain.isComplete()**

```java
package io.casehub.platform.graphql.generator.infer;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class InferredCallChainTest {

    @Test
    void complete_with_spi_and_target_method() {
        var chain = new InferredCallChain(
                "io.casehub.connectors.bank.spi.BankPlatform", "platform",
                "io.casehub.connectors.bank.spi.AccountInformation", "accountInformation",
                List.of("userId()"), "balance", List.of("accountId"),
                Map.of(), "balance", null);
        assertThat(chain.isComplete()).isTrue();
    }

    @Test
    void incomplete_without_spi_type() {
        var chain = new InferredCallChain(
                null, null, null, null, null,
                "balance", List.of("accountId"),
                Map.of(), null, null);
        assertThat(chain.isComplete()).isFalse();
    }

    @Test
    void incomplete_without_target_method() {
        var chain = new InferredCallChain(
                "io.casehub.connectors.bank.spi.BankPlatform", "platform",
                null, null, null, null, null,
                Map.of(), null, null);
        assertThat(chain.isComplete()).isFalse();
    }

    @Test
    void incomplete_with_capability_but_no_accessor() {
        var chain = new InferredCallChain(
                "io.casehub.connectors.bank.spi.BankPlatform", "platform",
                "io.casehub.connectors.bank.spi.AccountInformation", null,
                null, "balance", List.of("accountId"),
                Map.of(), null, null);
        assertThat(chain.isComplete()).isFalse();
    }

    @Test
    void incomplete_with_failure_reason() {
        var chain = new InferredCallChain(
                "io.casehub.connectors.bank.spi.BankPlatform", "platform",
                null, null, null, "balance", List.of("accountId"),
                Map.of(), null, InferenceFailure.VAR_TYPED_SPI);
        assertThat(chain.isComplete()).isFalse();
    }

    @Test
    void complete_without_capability_routing() {
        var chain = new InferredCallChain(
                "io.casehub.connectors.bank.spi.BankPlatform", "platform",
                null, null, null, "balance", List.of("accountId"),
                Map.of(), null, null);
        assertThat(chain.isComplete()).isTrue();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=InferredCallChainTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — classes don't exist yet

- [ ] **Step 3: Create the three source files**

`InferenceFailure.java`:
```java
package io.casehub.platform.graphql.generator.infer;

public enum InferenceFailure {
    NO_METHOD_BODY,
    VAR_TYPED_SPI,
    MULTIPLE_RETURNS,
    CAPABILITY_MISMATCH,
    INCOMPLETE_CAPABILITY_CHAIN,
    NO_SPI_VARIABLE,
    UNRECOGNIZED_PATTERN
}
```

`InferredCallChain.java`:
```java
package io.casehub.platform.graphql.generator.infer;

import java.util.List;
import java.util.Map;

public record InferredCallChain(
    String spiTypeFqcn,
    String routingParamName,
    String capabilityFqcn,
    String capabilityAccessor,
    List<String> accessorArgs,
    String targetMethod,
    List<String> targetArgs,
    Map<String, String> staticDefaults,
    String requireCapabilityMethodName,
    InferenceFailure failureReason
) {
    public boolean isComplete() {
        if (spiTypeFqcn == null || targetMethod == null) return false;
        if (capabilityFqcn != null && capabilityAccessor == null) return false;
        return failureReason == null;
    }
}
```

`MethodCallInfo.java`:
```java
package io.casehub.platform.graphql.generator.infer;

import javax.lang.model.element.Name;
import java.util.List;

public record MethodCallInfo(Name receiverName, String methodName, List<String> args) {
    List<String> argNames() {
        return args;
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=InferredCallChainTest`
Expected: PASS — all 6 tests green

- [ ] **Step 5: Commit**

```bash
git add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/infer/
git add graphql-generator/src/test/java/io/casehub/platform/graphql/generator/infer/
git commit -m "feat(#798): add InferenceFailure, InferredCallChain, MethodCallInfo types"
```

### Task 2: CallChainScanner — core recognition rules

**Files:**
- Create: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/infer/CallChainScanner.java`
- Create: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/infer/MethodBodyInferrer.java`
- Create: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/infer/CallChainScannerTest.java`
- Create: `graphql-generator/src/test/resources/infer/StandardConnector.java`

**Interfaces:**
- Consumes: `InferenceFailure`, `InferredCallChain`, `MethodCallInfo` from Task 1
- Produces: `MethodBodyInferrer.infer(Trees, ExecutableElement, IndexView) → InferredCallChain`; `CallChainScanner` with Rules 1-4 (variable tracking, service.platform() detection, requireCapability() detection, return chain extraction)

- [ ] **Step 1: Create test source file for Pattern A**

Create `graphql-generator/src/test/resources/infer/StandardConnector.java`:
```java
package infer;

import java.util.List;

public class StandardConnector {

    private FakePlatformService service;

    public FakeResult simpleQuery(String platform, String accountId) {
        FakeSpiType p = service.platform(platform);
        return p.capability(userId()).targetMethod(accountId);
    }

    public FakeResult withRequireCapability(String platform, String accountId) {
        FakeSpiType p = service.platform(platform);
        requireCapability(p, FakeCapability.class, "targetMethod");
        return p.capability(userId()).targetMethod(accountId);
    }

    public List<FakeResult> noCapabilityRouting(String platform) {
        FakeSpiType p = service.platform(platform);
        return p.listAll();
    }

    public FakeResult multipleAccessorArgs(String platform, String accountId,
                                            String userId) {
        FakeSpiType p = service.platform(platform);
        return p.capability(userId, "extra").targetMethod(accountId);
    }

    private String userId() { return "user"; }
    private static void requireCapability(Object p, Class<?> cap, String op) {}
}

class FakePlatformService {
    FakeSpiType platform(String name) { return null; }
}

class FakeSpiType {
    FakeCapability capability(String... args) { return null; }
    List<FakeResult> listAll() { return null; }
}

class FakeCapability {
    FakeResult targetMethod(String arg) { return null; }
}

class FakeResult {}
```

- [ ] **Step 2: Write CallChainScanner tests**

```java
package io.casehub.platform.graphql.generator.infer;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import javax.lang.model.element.Element;
import javax.lang.model.element.ExecutableElement;
import javax.lang.model.element.TypeElement;
import javax.tools.JavaCompiler;
import javax.tools.JavaFileObject;
import javax.tools.StandardJavaFileManager;
import javax.tools.ToolProvider;
import com.sun.source.util.JavacTask;
import com.sun.source.util.Trees;
import java.io.File;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class CallChainScannerTest {

    private static Trees trees;
    private static TypeElement connectorType;

    @BeforeAll
    static void compileTestSource() throws Exception {
        JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
        StandardJavaFileManager fm = compiler.getStandardFileManager(null, null, null);
        File source = new File("src/test/resources/infer/StandardConnector.java");
        Iterable<? extends JavaFileObject> units = fm.getJavaFileObjects(source);
        JavacTask task = (JavacTask) compiler.getTask(null, fm, null,
                List.of("-proc:none"), null, units);
        task.parse();
        task.analyze();
        trees = Trees.instance(task);
        for (TypeElement te : task.analyze()) {
            // Javac returns compilation unit elements; walk to find StandardConnector
        }
        for (Element e : task.analyze()) {
            if (e instanceof TypeElement te && te.getSimpleName().contentEquals("StandardConnector")) {
                connectorType = te;
                break;
            }
        }
    }

    private ExecutableElement findMethod(String name) {
        for (Element e : connectorType.getEnclosedElements()) {
            if (e instanceof ExecutableElement exec
                    && exec.getSimpleName().contentEquals(name)) {
                return exec;
            }
        }
        throw new AssertionError("Method not found: " + name);
    }

    @Test
    void pattern_a_simple_query_infers_call_chain() {
        InferredCallChain result = MethodBodyInferrer.infer(trees, findMethod("simpleQuery"), null);
        assertThat(result.isComplete()).isTrue();
        assertThat(result.spiTypeFqcn()).endsWith("FakeSpiType");
        assertThat(result.routingParamName()).isEqualTo("platform");
        assertThat(result.capabilityAccessor()).isEqualTo("capability");
        assertThat(result.targetMethod()).isEqualTo("targetMethod");
        assertThat(result.targetArgs()).containsExactly("accountId");
    }

    @Test
    void require_capability_extracts_class_and_method() {
        InferredCallChain result = MethodBodyInferrer.infer(trees, findMethod("withRequireCapability"), null);
        assertThat(result.isComplete()).isTrue();
        assertThat(result.capabilityFqcn()).endsWith("FakeCapability");
        assertThat(result.requireCapabilityMethodName()).isEqualTo("targetMethod");
    }

    @Test
    void no_capability_routing_infers_direct_call() {
        InferredCallChain result = MethodBodyInferrer.infer(trees, findMethod("noCapabilityRouting"), null);
        assertThat(result.isComplete()).isTrue();
        assertThat(result.capabilityAccessor()).isNull();
        assertThat(result.targetMethod()).isEqualTo("listAll");
    }

    @Test
    void multiple_accessor_args_captured() {
        InferredCallChain result = MethodBodyInferrer.infer(trees, findMethod("multipleAccessorArgs"), null);
        assertThat(result.isComplete()).isTrue();
        assertThat(result.accessorArgs()).hasSize(2);
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=CallChainScannerTest`
Expected: FAIL — `CallChainScanner` and `MethodBodyInferrer` don't exist

- [ ] **Step 4: Implement CallChainScanner with Rules 1-4**

Create `CallChainScanner.java` implementing the full scanner as specified in the design spec:
- Constructor takes `IndexView jandexIndex` and `TreePath methodPath` (for import resolution)
- `visitVariable()` — Rules 1, 2 (variable tracking, SPI detection, voice-style `.platform()`)
- `visitExpressionStatement()` — Rule 3 (requireCapability detection)
- `visitReturn()` — Rule 4 (method chain extraction with multi-return detection)
- `visitLambdaExpression()` — scope guard (return null, don't recurse)
- `visitNewClass()` — scope guard (skip anonymous class bodies)
- `flattenMethodChain()` and `flattenMethodChainRecursive()` — chain unwrapping
- `resolveTypeName()` — import map + Jandex fallback
- `result()` — cross-validation (CAPABILITY_MISMATCH, NO_SPI_VARIABLE, INCOMPLETE_CAPABILITY_CHAIN, UNRECOGNIZED_PATTERN)

Create `MethodBodyInferrer.java`:
```java
package io.casehub.platform.graphql.generator.infer;

import com.sun.source.tree.MethodTree;
import com.sun.source.util.TreePath;
import com.sun.source.util.Trees;
import org.jboss.jandex.IndexView;
import javax.lang.model.element.ExecutableElement;

public final class MethodBodyInferrer {

    private MethodBodyInferrer() {}

    public static InferredCallChain infer(Trees trees,
                                           ExecutableElement method,
                                           IndexView jandexIndex) {
        MethodTree methodTree = trees.getTree(method);
        if (methodTree == null || methodTree.getBody() == null) {
            return new InferredCallChain(null, null, null, null, null,
                    null, null, null, null, InferenceFailure.NO_METHOD_BODY);
        }
        TreePath methodPath = trees.getPath(method);
        CallChainScanner scanner = new CallChainScanner(jandexIndex, methodPath);
        scanner.scan(methodPath, null);
        return scanner.result();
    }
}
```

See the spec §AST Walker Architecture for the complete `CallChainScanner` implementation with all recognition rules, scope guards, `resolveTypeName()`, `extractParamName()`, and `result()` cross-validation.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=CallChainScannerTest`
Expected: PASS — all 4 tests green

- [ ] **Step 6: Commit**

```bash
git add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/infer/
git add graphql-generator/src/test/java/io/casehub/platform/graphql/generator/infer/
git add graphql-generator/src/test/resources/infer/
git commit -m "feat(#798): add CallChainScanner with Rules 1-4 and MethodBodyInferrer entry point"
```

### Task 3: Rules 5-6 and false-positive tests

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/infer/CallChainScanner.java`
- Create: `graphql-generator/src/test/resources/infer/DefaultValueConnector.java`
- Create: `graphql-generator/src/test/resources/infer/VoidConnector.java`
- Create: `graphql-generator/src/test/resources/infer/FalsePositiveConnector.java`
- Create: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/infer/FalsePositiveTest.java`
- Modify: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/infer/CallChainScannerTest.java`

**Interfaces:**
- Consumes: `CallChainScanner` from Task 2
- Produces: Rule 5 (static default detection), Rule 6 (void method expression statement chain)

- [ ] **Step 1: Create test source files**

`DefaultValueConnector.java` — test source for Rule 5:
```java
package infer;

public class DefaultValueConnector {

    private FakePlatformService service;

    public FakeResult withStaticDefault(String platform, String accountId,
                                         Integer pageSize) {
        FakeSpiType p = service.platform(platform);
        int size = pageSize != null ? pageSize : 50;
        return p.capability(userId()).listItems(accountId, size);
    }

    public FakeResult withStringDefault(String platform, String format) {
        FakeSpiType p = service.platform(platform);
        String fmt = format != null ? format : "json";
        return p.capability(userId()).export(fmt);
    }

    private String userId() { return "user"; }
}
```

`VoidConnector.java` — test source for Rule 6:
```java
package infer;

public class VoidConnector {

    private FakePlatformService service;

    public void deleteItem(String platform, String itemId) {
        FakeSpiType p = service.platform(platform);
        requireCapability(p, FakeCapability.class, "deleteItem");
        p.capability(userId()).deleteItem(itemId);
    }

    private String userId() { return "user"; }
    private static void requireCapability(Object p, Class<?> cap, String op) {}
}
```

`FalsePositiveConnector.java` — test source for false-positive detection:
```java
package infer;

import java.util.List;

public class FalsePositiveConnector {

    private FakePlatformService service;

    public FakeResult varTypedSpi(String platform, String id) {
        var p = service.platform(platform);
        return p.capability(userId()).targetMethod(id);
    }

    public FakeResult multipleReturns(String platform, String id) {
        FakeSpiType p = service.platform(platform);
        if (id == null) {
            return p.capability(userId()).defaultMethod();
        }
        return p.capability(userId()).targetMethod(id);
    }

    public FakeResult lambdaReturn(String platform) {
        FakeSpiType p = service.platform(platform);
        List<String> items = List.of("a", "b");
        items.stream().filter(a -> { return a.length() > 1; }).toList();
        return p.listAll();
    }

    private String userId() { return "user"; }
}

class FakeCapability {
    FakeResult targetMethod(String arg) { return null; }
    FakeResult defaultMethod() { return null; }
    void deleteItem(String id) {}
    FakeResult export(String fmt) { return null; }
    FakeResult listItems(String id, int size) { return null; }
}
```

- [ ] **Step 2: Write tests for Rules 5, 6 and false-positive cases**

Add to `CallChainScannerTest`:
```java
@Test
void static_default_integer_detected() {
    InferredCallChain result = MethodBodyInferrer.infer(trees, findMethod("withStaticDefault"), null);
    assertThat(result.staticDefaults()).containsEntry("pageSize", "50");
}

@Test
void static_default_string_detected() {
    InferredCallChain result = MethodBodyInferrer.infer(trees, findMethod("withStringDefault"), null);
    assertThat(result.staticDefaults()).containsEntry("format", "json");
}

@Test
void void_method_target_extracted_via_rule_6() {
    InferredCallChain result = MethodBodyInferrer.infer(trees, findMethod("deleteItem"), null);
    assertThat(result.isComplete()).isTrue();
    assertThat(result.targetMethod()).isEqualTo("deleteItem");
    assertThat(result.capabilityAccessor()).isEqualTo("capability");
}
```

Create `FalsePositiveTest`:
```java
package io.casehub.platform.graphql.generator.infer;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class FalsePositiveTest {
    // Same @BeforeAll setup as CallChainScannerTest, compiling FalsePositiveConnector.java

    @Test
    void var_typed_spi_fails_inference() {
        InferredCallChain result = MethodBodyInferrer.infer(trees, findMethod("varTypedSpi"), null);
        assertThat(result.isComplete()).isFalse();
        assertThat(result.failureReason()).isEqualTo(InferenceFailure.VAR_TYPED_SPI);
    }

    @Test
    void multiple_returns_fails_inference() {
        InferredCallChain result = MethodBodyInferrer.infer(trees, findMethod("multipleReturns"), null);
        assertThat(result.isComplete()).isFalse();
        assertThat(result.failureReason()).isEqualTo(InferenceFailure.MULTIPLE_RETURNS);
    }

    @Test
    void lambda_return_does_not_trigger_multiple_returns() {
        InferredCallChain result = MethodBodyInferrer.infer(trees, findMethod("lambdaReturn"), null);
        assertThat(result.isComplete()).isTrue();
        assertThat(result.failureReason()).isNull();
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest="CallChainScannerTest,FalsePositiveTest"`
Expected: FAIL — Rules 5, 6 not implemented; test source files need compiling setup

- [ ] **Step 4: Implement Rule 5 (static defaults) and Rule 6 (void methods)**

Add Rule 5 (`extractParamName` and ternary detection in `visitVariable`) and Rule 6 (SPI method chain in `visitExpressionStatement` after requireCapability check, with `targetMethod == null` guard) to `CallChainScanner.java` as specified in the design spec §AST Walker Architecture.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest="CallChainScannerTest,FalsePositiveTest"`
Expected: PASS — all tests green

- [ ] **Step 6: Run all graphql-generator tests to verify no regressions**

Run: `mvn --batch-mode test -pl graphql-generator`
Expected: PASS — existing `PluginGenerationTest` and all other tests still green

- [ ] **Step 7: Commit**

```bash
git add graphql-generator/src/
git commit -m "feat(#798): add Rules 5-6 (static defaults, void methods) and false-positive tests"
```

## Batch 2: Processor Integration

### Task 4: Integrate AST inference into GraphQLResolverProcessor

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java`
- Modify: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/PluginGenerationTest.java`

**Interfaces:**
- Consumes: `MethodBodyInferrer.infer()`, `InferredCallChain`, `InferenceFailure` from Tasks 1-3
- Produces: Modified `generatePluginSource()` that attempts AST inference before annotation-based resolution; `findMethodElement()` bridge; processing summary diagnostic; `// resolved via:` source comment

- [ ] **Step 1: Write integration tests**

Add to `PluginGenerationTest.java`:
```java
@Test
void trees_initialized_when_available() {
    // Verify that Trees.instance() is attempted during process()
    // This is a structural test — the actual inference is tested in CallChainScannerTest
    var processor = new GraphQLResolverProcessor();
    assertThat(processor.getSupportedOptions()).contains("generatePlugins");
}
```

Note: Full compile-testing integration (connector source → generated plugin with inferred call chain) requires test fixture sources with `@McpDomain`, `@PlatformQuery`, and `@Inject` annotations. This is covered in Task 5.

- [ ] **Step 2: Add Trees initialization to process()**

In `GraphQLResolverProcessor.java`, add instance fields and initialization after `loadCombinedIndex()`:

```java
private Trees trees;
private boolean treesAvailable;
private int inferredCount;
private int totalPluginCount;
private final Map<InferenceFailure, Integer> failureReasons = new java.util.EnumMap<>(InferenceFailure.class);
private final List<String> fallbackMethods = new ArrayList<>();
```

Initialization (in `process()`, after `loadCombinedIndex()`):
```java
try {
    trees = Trees.instance(processingEnv);
    treesAvailable = true;
} catch (Exception e) {
    trees = null;
    treesAvailable = false;
    processingEnv.getMessager().printMessage(Diagnostic.Kind.NOTE,
        "AST inference unavailable — using annotation-based resolution");
}
```

- [ ] **Step 3: Add findMethodElement() bridge**

```java
private ExecutableElement findMethodElement(ResolvedOperation op) {
    TypeElement te = processingEnv.getElementUtils().getTypeElement(op.declaringClassFqcn());
    if (te == null) return null;
    int paramCount = op.params().size();
    for (Element enclosed : te.getEnclosedElements()) {
        if (enclosed.getSimpleName().toString().equals(op.methodName())
                && enclosed instanceof ExecutableElement exec
                && exec.getParameters().size() == paramCount) {
            return exec;
        }
    }
    return null;
}
```

- [ ] **Step 4: Integrate inference into generatePluginSource()**

In the per-operation loop inside `generatePluginSource()`, after `PluginMeta meta = resolvePluginMeta(op)`:

1. Attempt AST inference (spec §Integration with generatePluginSource())
2. Accumulate failure reasons for incomplete inference
3. Compute effective values with annotation precedence (D8)
4. Change capability routing block to use effective values
5. Add static default integration after `mapParamsToFields()`
6. Add `// resolved via:` source comment
7. Increment `totalPluginCount` and `inferredCount` counters

After the domain loop in `process()`, emit the processing summary diagnostic.

See spec §Integration with generatePluginSource() and §Processing summary diagnostic for exact code.

- [ ] **Step 5: Run all graphql-generator tests**

Run: `mvn --batch-mode test -pl graphql-generator`
Expected: PASS — all tests green (inference is a no-op when Trees produces null for Jandex-sourced types)

- [ ] **Step 6: Commit**

```bash
git add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java
git add graphql-generator/src/test/java/io/casehub/platform/graphql/generator/PluginGenerationTest.java
git commit -m "feat(#798): integrate AST inference into generatePluginSource with precedence model"
```

### Task 5: End-to-end compile-testing with connector-style sources

**Files:**
- Create: `graphql-generator/src/test/resources/infer/compile-test/ConnectorBankApiFixture.java`
- Modify: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/PluginGenerationTest.java`

**Interfaces:**
- Consumes: Integrated `generatePluginSource()` from Task 4
- Produces: End-to-end verification that connector source → AST inference → correct generated plugin

- [ ] **Step 1: Create connector-style compile-test fixture**

`ConnectorBankApiFixture.java` — a minimal connector class with `@McpDomain`, `@PlatformQuery`, `@Inject` field, and realistic method bodies. This fixture must include all types it references (inline or imported) since it's compiled standalone:

```java
package infer.compiletest;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformQuery;
import jakarta.inject.Inject;
import jakarta.ws.rs.QueryParam;

@McpDomain("connectors/test-bank")
public class ConnectorBankApiFixture {

    @Inject TestBankService bankService;

    @PlatformQuery("Get balance")
    public TestBalance balance(@QueryParam("platform") String platform,
                                String accountId) {
        TestSpi p = bankService.platform(platform);
        requireCapability(p, TestAccountInfo.class, "balance");
        return p.accountInfo(userId()).balance(accountId);
    }

    private String userId() { return "user"; }
    private static void requireCapability(Object p, Class<?> cap, String op) {}
}

class TestBankService {
    TestSpi platform(String name) { return null; }
}

class TestSpi {
    TestAccountInfo accountInfo(String userId) { return null; }
}

class TestAccountInfo {
    TestBalance balance(String accountId) { return null; }
}

class TestBalance {
    String amount() { return null; }
    String currency() { return null; }
}
```

- [ ] **Step 2: Write compile-test that verifies generated plugin source**

Add to `PluginGenerationTest.java` — a test that compiles `ConnectorBankApiFixture.java` with `generatePlugins=true` using `javax.tools.JavaCompiler`, then reads the generated plugin source and asserts it contains the expected delegate call chain:

```java
@Test
void ast_inference_generates_correct_delegate_call() throws Exception {
    // Compile ConnectorBankApiFixture with GraphQLResolverProcessor
    // Assert generated TestBankBalancePlugin contains:
    //   spi.accountInfo(userId).balance(accountId)
    // Assert source comment: "resolved via: AST inference"
}
```

The exact compile-testing setup follows the pattern used by other APT tests in the project — create a `JavaCompiler` task with the processor, compile the fixture source, and read the generated output from the Filer.

- [ ] **Step 3: Run test to verify it fails**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest="PluginGenerationTest#ast_inference_generates_correct_delegate_call"`
Expected: FAIL — fixture or assertion not wired

- [ ] **Step 4: Wire the compile-test**

Implement the compile-test using `javax.tools.JavaCompiler` with `GraphQLResolverProcessor` as the annotation processor, `generatePlugins=true` as a processor option. Read the generated source from the output directory and assert content.

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest="PluginGenerationTest#ast_inference_generates_correct_delegate_call"`
Expected: PASS

- [ ] **Step 6: Run full test suite**

Run: `mvn --batch-mode test -pl graphql-generator`
Expected: PASS — all tests green

- [ ] **Step 7: Run full project build**

Run: `mvn --batch-mode install -DskipTests=false`
Expected: BUILD SUCCESS — no regressions across the entire project

- [ ] **Step 8: Commit**

```bash
git add graphql-generator/src/test/
git commit -m "test(#798): add end-to-end compile-testing for AST-inferred plugin generation"
```

## References

- `specs/issue-798-infer-plugin-call-chain-from-ast/2026-11-11-ast-inference-design.md` — design spec this plan implements
- `specs/issue-798-infer-plugin-call-chain-from-ast/decisions.md` — D1-D9 design decisions
- `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java:1766-2045` — current Tier 2 plugin generation
- `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/PluginGenerationTest.java` — existing tests
- `connectors/graphql/src/main/java/io/casehub/connectors/graphql/ConnectorBankApi.java` — Pattern A reference
- `connectors/graphql/src/main/java/io/casehub/connectors/graphql/ConnectorVoiceApi.java` — Pattern B reference
- GitHub #798 — tracking issue
- GitHub #795 — prerequisite issue (plugin generation from @PlatformQuery)
