# Infer Plugin Call Chain from Method Body AST

**Issue:** casehubio/platform#798
**Date:** 2026-11-11
**Status:** Design
**Depends on:** casehubio/platform#795 (plugin generation from @PlatformQuery/@PlatformMutation)

## Summary

Extend `GraphQLResolverProcessor`'s Tier 2 plugin generation to read connector method bodies via the javac Compiler Tree API (`com.sun.source.util.TreePathScanner`). The AST walker infers the SPI call chain — SPI type, routing parameter, capability class, capability accessor, accessor arguments, target method, and target method arguments — directly from the code. This eliminates the need for `@GeneratePlugin(capability, spi, accessor, spiMethod)` attributes on most connector methods, reducing those attributes to fallbacks for methods where inference fails.

## Scope

### Primary (this issue)

The seven items from the issue's "What to infer" table:

| What | How | Replaces |
|------|-----|----------|
| SPI type (`BankPlatform`) | `service.platform(x)` return type | Inferred from `@Inject` field, or `@GeneratePlugin(spi = ...)` |
| Routing parameter (`platform`) | Argument to `platform()` call | Matched by name against service method |
| Capability class (`AccountInformation`) | `requireCapability()` second arg, or accessor return type | `@GeneratePlugin(capability = ...)` |
| Capability accessor (`accountInformation`) | Method call on the SPI-typed variable | `@GeneratePlugin(accessor = ...)` |
| Accessor arguments (`userId()`) | Arguments to the accessor call | Introspected from Jandex |
| Target method (`balance`) | Final method call in the chain | `@GeneratePlugin(spiMethod = ...)` |
| Target method arguments | Arguments to the target call | Matched against method parameters |

Plus: `requireCapability()` detection as an alternative way to identify the capability class and validate the method name.

Plus: static default value inference — literal values (`50`, `"wav"`, `false`) from `x != null ? x : literal` patterns, propagated to the plugin's compact constructor or `@DefaultValue`.

### Deferred (until primary ships)

- Dynamic default value inference — runtime-computed expressions (`Instant.now()`) are NOT inferred
- Complex parameter construction pattern detection — `new PageRequest(cursor, size)` is visible to the walker but not acted on in primary scope
- Conditional logic detection — dropped from scope entirely

### Out of scope

- Tier 1 (interface delegation) — no method body to read
- `@GeneratePlugin` shape attributes (`name`, `absorb`, `subject`, `optionalParams`, `exclude`) — always annotation-driven
- Changes to `@PlatformQuery` or `@PlatformMutation`

## Connector Method Patterns

A survey of all 13 connector platform SPIs in the connectors repo reveals two structural families. Both are recognizable from the AST.

### Pattern A — Standard routing (majority)

```java
@PlatformQuery("Get current balance for a bank account")
public AccountBalance balance(
        @QueryParam("platform") String platform,
        @PathParam String accountId) {
    BankPlatform p = bankService.platform(platform);
    requireCapability(p, AccountInformation.class, "balance");
    return p.accountInformation(userId()).balance(accountId);
}
```

AST shape:
1. `VariableTree`: `BankPlatform p = bankService.platform(platform)` — declares SPI-typed local variable, identifies routing parameter
2. `ExpressionStatementTree`: `requireCapability(p, AccountInformation.class, "balance")` — capability class is second argument (class literal)
3. `ReturnTree`: `p.accountInformation(userId()).balance(accountId)` — method chain on SPI variable: accessor → target method

Used by: Bank, Commerce, Health, Travel, Document, Contacts, Location, Project, Chat (standard service pattern with `service.platform(routingParam)`).

### Pattern B — Helper-method routing (voice-style)

```java
@PlatformMutation("Synthesise text to speech audio")
public VoiceSynthesisResult speak(
        @QueryParam("text") String text,
        @QueryParam("voice") String voice,
        @QueryParam("language") String language,
        @QueryParam("audioFormat") @DefaultValue("wav") String audioFormat,
        @QueryParam("includePhonemes") @DefaultValue("false") boolean includePhonemes) {
    ResolvedVoice resolved = resolveVoice(voice, language);
    VoicePlatform platform = resolved.platform();
    requireCapability(platform, TextToSpeech.class, "speak");
    var options = new SynthesisOptions(...);
    var result = platform.textToSpeech().synthesise(text, options);
    ...
}
```

AST shape:
1. `VariableTree` chain: helper method result → `.platform()` call → SPI-typed variable
2. `ExpressionStatementTree`: `requireCapability(platform, TextToSpeech.class, "speak")` — same pattern as A
3. Method chain on SPI variable: `platform.textToSpeech().synthesise(text, options)` — accessor → target method
4. Constructor invocation: `new SynthesisOptions(...)` — complex parameter construction (visible, not acted on in primary scope)

Used by: Voice (helper-method routing), potentially future connectors with non-standard service lookup.

**Limitation — non-trivial return transformation:** Voice `speak()` does not return the SPI result directly — it Base64-encodes audio, extracts fields from `ResolvedVoice`, and constructs a `VoiceSynthesisResult` DTO. Methods with non-trivial return value transformation cannot be auto-generated because the transformation logic is opaque to the generator. These methods fall back to `@GeneratePlugin` annotation or remain hand-written plugins.

The AST walker detects this: when the return expression is not a method invocation chain on the SPI variable (e.g., it's a constructor call or a local variable), inference marks the method as "non-direct return" and falls back.

### Pattern C — Direct registry (no SPI routing)

```java
@PlatformQuery("List available voices")
public List<VoiceDescriptor> listVoices(...) {
    var query = new VoiceQuery(vendor, gender, accent, null, language, style, cap, null);
    return voiceRegistry.query(query);
}
```

No SPI type, no capability routing, no `service.platform()` call. AST inference produces no `InferredCallChain` (no SPI variable detected). These methods fall back to the existing Jandex-based SPI resolution from #795. If that also fails, they skip with WARNING. Pattern C methods are typically utility/discovery methods that don't map to the connector SPI pattern.

### Locally-constructed target method arguments

When the SPI method's target call includes locally-constructed arguments (e.g., `new SynthesisOptions(...)` or `new PageRequest(cursor, size)`), the AST walker records the argument as a local variable reference, not a method parameter name. The generator handles this by mapping to the SPI method's parameter type via Jandex:

1. The AST walker extracts the target method name and argument names (including local variables)
2. The generator looks up the target method's parameter types on the capability interface via Jandex
3. For arguments that are local variables (not method params), the generator uses the SPI method's declared parameter type as the plugin field type
4. The plugin field is the complex type (e.g., `@Optional SynthesisOptions options`) — consistent with D4

This handles the `synthesise(text, options)` case: `text` maps to a plugin field from the API method params; `options` maps to a `SynthesisOptions` plugin field from the SPI method's parameter type. The YAML user provides the `SynthesisOptions` structure directly.

## AST Walker Architecture

### Entry point

In `GraphQLResolverProcessor.generatePluginSource()`, after resolving `PluginMeta` from annotations, attempt AST inference for Tier 2 connector class methods:

```java
InferredCallChain inferred = null;
if (!ops.isInterface && treesAvailable) {
    ExecutableElement methodElement = findMethodElement(op);
    if (methodElement != null) {
        inferred = MethodBodyInferrer.infer(trees, methodElement, jandexIndex);
    }
}
```

### Precedence model (D8)

1. `@GeneratePlugin` present with **explicit** call-chain values → annotation overrides inference
2. `@GeneratePlugin` absent or call-chain attributes at defaults → AST inference runs
3. AST inference succeeds → use inferred values
4. AST inference fails → fall back to annotation values; if no annotation, skip with WARNING

Shape attributes (`name`, `absorb`, `subject`, `optionalParams`, `exclude`) are always taken from `@GeneratePlugin` when present, regardless of inference.

### MethodBodyInferrer

A new class in `graphql-generator`:

```
io.casehub.platform.graphql.generator.infer.MethodBodyInferrer
io.casehub.platform.graphql.generator.infer.CallChainScanner
io.casehub.platform.graphql.generator.infer.InferredCallChain
```

**`MethodBodyInferrer`** is the public entry point:

```java
public final class MethodBodyInferrer {

    public static InferredCallChain infer(Trees trees,
                                           ExecutableElement method,
                                           IndexView jandexIndex) {
        MethodTree methodTree = trees.getTree(method);
        if (methodTree == null || methodTree.getBody() == null) {
            return null;
        }
        TreePath methodPath = trees.getPath(method);
        CallChainScanner scanner = new CallChainScanner(jandexIndex);
        scanner.scan(methodPath, null);
        return scanner.result();
    }
}
```

### CallChainScanner

A `TreePathScanner<Void, Void>` subclass that walks the method body in a single pass. Maintains state:

```java
class CallChainScanner extends TreePathScanner<Void, Void> {

    private final IndexView jandexIndex;

    // Variable tracking (D2): variable name → declared type name
    private final Map<Name, String> variableTypes = new HashMap<>();

    // Inferred data — populated during traversal
    private String spiTypeFqcn;
    private String routingParamName;
    private String capabilityFqcn;        // from requireCapability() or accessor return type
    private String capabilityAccessor;
    private List<String> accessorArgs;
    private String targetMethod;
    private List<String> targetArgs;
    private Map<String, String> staticDefaults;  // paramName → literal value
    private String requireCapabilityMethodName;   // from requireCapability() third arg
}
```

#### Recognition rules

**Rule 1 — Variable declaration with `service.platform(x)` call:**

```java
@Override
public Void visitVariable(VariableTree node, Void p) {
    // Record variable name → declared type
    String typeName = node.getType().toString();
    variableTypes.put(node.getName(), typeName);

    // Check if initializer is service.platform(arg)
    if (node.getInitializer() instanceof MethodInvocationTree inv) {
        if (methodName(inv).equals("platform") && inv.getArguments().size() == 1) {
            spiTypeFqcn = typeName;  // declared type IS the SPI type
            routingParamName = inv.getArguments().get(0).toString();
        }
    }
    return super.visitVariable(node, p);
}
```

**Rule 2 — Variable declaration with chained `.platform()` call (voice-style):**

```java
// Handles: VoicePlatform platform = resolved.platform();
// When the initializer is a method call ending in .platform()
// on a previously-tracked variable
if (node.getInitializer() instanceof MethodInvocationTree inv) {
    if (methodName(inv).equals("platform") && inv.getArguments().isEmpty()) {
        spiTypeFqcn = typeName;
    }
}
```

**Rule 3 — `requireCapability()` call:**

```java
@Override
public Void visitExpressionStatement(ExpressionStatementTree node, Void p) {
    if (node.getExpression() instanceof MethodInvocationTree inv) {
        if (methodName(inv).equals("requireCapability")) {
            List<? extends ExpressionTree> args = inv.getArguments();
            if (args.size() >= 2) {
                // Second arg is the capability class literal
                ExpressionTree capArg = args.get(1);
                if (capArg instanceof MemberSelectTree ms
                        && ms.getIdentifier().contentEquals("class")) {
                    capabilityFqcn = ms.getExpression().toString();
                }
                // Third arg (if present) is the method name string
                if (args.size() >= 3 && args.get(2) instanceof LiteralTree lit) {
                    requireCapabilityMethodName = lit.getValue().toString();
                }
            }
        }
    }
    return super.visitExpressionStatement(node, p);
}
```

**Rule 4 — Return statement with method chain:**

```java
@Override
public Void visitReturn(ReturnTree node, Void p) {
    ExpressionTree expr = node.getExpression();
    // Walk the method chain: p.accountInformation(userId()).balance(accountId)
    // This is a nested MethodInvocationTree structure
    List<MethodCallInfo> chain = flattenMethodChain(expr);
    // chain = [{receiver: p, method: accountInformation, args: [userId()]},
    //          {method: balance, args: [accountId]}]

    if (chain.size() >= 2) {
        MethodCallInfo first = chain.get(0);
        // Verify first call is on the SPI-typed variable
        if (variableTypes.containsKey(first.receiverName)
                && variableTypes.get(first.receiverName).equals(spiTypeFqcn)) {
            capabilityAccessor = first.methodName;
            accessorArgs = first.argNames();
            MethodCallInfo last = chain.get(chain.size() - 1);
            targetMethod = last.methodName;
            targetArgs = last.argNames();
        }
    } else if (chain.size() == 1) {
        // Direct method call on SPI variable (no capability routing)
        MethodCallInfo call = chain.get(0);
        if (variableTypes.containsKey(call.receiverName)) {
            targetMethod = call.methodName;
            targetArgs = call.argNames();
        }
    }
    return super.visitReturn(node, p);
}
```

**Rule 5 — Static default value detection:**

```java
@Override
public Void visitVariable(VariableTree node, Void p) {
    // ... existing type tracking ...

    // Detect: int size = pageSize != null ? pageSize : 50;
    if (node.getInitializer() instanceof ConditionalExpressionTree ternary) {
        // Check pattern: paramName != null ? paramName : literal
        if (ternary.getFalseExpression() instanceof LiteralTree lit) {
            String paramName = extractParamName(ternary.getCondition(),
                                                 ternary.getTrueExpression());
            if (paramName != null) {
                staticDefaults.put(paramName, lit.getValue().toString());
            }
        }
    }
    return super.visitVariable(node, p);
}
```

### InferredCallChain

The result record produced by the scanner:

```java
public record InferredCallChain(
    String spiTypeFqcn,
    String routingParamName,
    String capabilityFqcn,
    String capabilityAccessor,
    List<String> accessorArgs,
    String targetMethod,
    List<String> targetArgs,
    Map<String, String> staticDefaults,
    String requireCapabilityMethodName
) {
    public boolean isComplete() {
        return spiTypeFqcn != null && targetMethod != null;
    }
}
```

### Integration with generatePluginSource()

The inferred data merges with the existing generation logic:

```java
// After resolving PluginMeta from annotation
PluginMeta meta = resolvePluginMeta(op);
InferredCallChain inferred = null;

if (!ops.isInterface && treesAvailable) {
    inferred = MethodBodyInferrer.infer(trees, methodElement, jandexIndex);
}

// Merge: annotation explicit values take precedence over inference
String effectiveSpiType = !meta.spiFqcn.isEmpty() ? meta.spiFqcn
        : (inferred != null ? inferred.spiTypeFqcn() : resolvedSpiTypeFqcn);

String effectiveCapability = !meta.capabilityFqcn.isEmpty() ? meta.capabilityFqcn
        : (inferred != null ? inferred.capabilityFqcn() : null);

String effectiveAccessor = !meta.accessor.isEmpty() ? meta.accessor
        : (inferred != null ? inferred.capabilityAccessor() : null);

String effectiveSpiMethod = !meta.spiMethod.isEmpty() ? meta.spiMethod
        : (inferred != null ? inferred.targetMethod() : op.methodName());

String effectiveRoutingParam = inferred != null ? inferred.routingParamName()
        : routingParamName;
```

### Processing summary diagnostic (D3)

At the end of `generatePluginSource()`, emit a single summary:

```java
processingEnv.getMessager().printMessage(Diagnostic.Kind.NOTE,
    "AST inference: " + inferredCount + "/" + totalCount
    + " methods inferred, " + fallbackCount
    + " fell back to @GeneratePlugin: " + fallbackMethods);
```

Each generated plugin includes a source comment:

```java
out.println("// GENERATED by GraphQLResolverProcessor — do not edit");
out.println("// resolved via: " + (usedInference ? "AST inference" : "@GeneratePlugin annotation"));
```

## jdk.compiler Module Dependency (D9)

The `Trees` API and `TreePathScanner` are in the `jdk.compiler` module. This is a supported, exported API — not internal javac implementation.

### Dependency setup

`graphql-generator/pom.xml` needs no explicit dependency for `jdk.compiler` — annotation processors run inside the compiler and have automatic access to `com.sun.source.*` types. However, the module-info or compiler args may need:

```xml
<compilerArgs>
    <arg>--add-modules</arg>
    <arg>jdk.compiler</arg>
</compilerArgs>
```

This is only needed if `graphql-generator` itself is compiled as a module. Since it's a classpath-based Maven build, no additional configuration is expected.

### Graceful unavailability

If `Trees.instance(processingEnv)` throws or returns null (non-javac compiler), set `treesAvailable = false` and all methods fall back to annotation-based resolution:

```java
Trees trees;
boolean treesAvailable;
try {
    trees = Trees.instance(processingEnv);
    treesAvailable = true;
} catch (Exception e) {
    trees = null;
    treesAvailable = false;
    processingEnv.getMessager().printMessage(Diagnostic.Kind.NOTE,
        "AST inference unavailable (non-javac compiler?) — using annotation-based resolution");
}
```

### Constraint

This creates a compile-time dependency on javac. Alternative compilers (ECJ/Eclipse JDT) do not provide the Trees API. The platform uses Maven + javac exclusively; ECJ compatibility is not a requirement.

## Annotation Surface After Inference

### Before (current — all attributes required for Tier 2)

```java
@PlatformQuery("Get current balance for a bank account")
@GeneratePlugin(capability = AccountInformation.class,
                absorb = true, subject = "accountId")
public AccountBalance balance(
        @QueryParam("platform") String platform,
        @PathParam String accountId) {
    BankPlatform p = bankService.platform(platform);
    requireCapability(p, AccountInformation.class, "balance");
    return p.accountInformation(userId()).balance(accountId);
}
```

### After (inference eliminates call-chain attributes)

```java
@PlatformQuery("Get current balance for a bank account")
@GeneratePlugin(absorb = true, subject = "accountId")
public AccountBalance balance(
        @QueryParam("platform") String platform,
        @PathParam String accountId) {
    BankPlatform p = bankService.platform(platform);
    requireCapability(p, AccountInformation.class, "balance");
    return p.accountInformation(userId()).balance(accountId);
}
```

For methods with no shape overrides, `@GeneratePlugin` can be omitted entirely:

```java
@PlatformQuery("List bank accounts on a platform")
public List<AccountInfo> listAccounts(@QueryParam("platform") String platform) {
    BankPlatform p = bankService.platform(platform);
    requireCapability(p, AccountInformation.class, "listAccounts");
    return p.accountInformation(userId()).listAccounts();
}
```

## Testing Strategy (D7)

### 1. AST walker unit tests — `graphql-generator/src/test/`

Test the `CallChainScanner` in isolation with synthetic method bodies compiled via `javax.tools.JavaCompiler`. Test source files contain realistic connector-style implementations.

**Test cases:**

- **Pattern A — standard routing:** `service.platform(x)` → `requireCapability` → `p.accessor(args).method(args)`. Assert `InferredCallChain` contains correct SPI type, routing param, capability, accessor, target method.
- **Pattern A — no capability routing:** Direct `p.method(args)` call without accessor. Assert no capability accessor, target method inferred correctly.
- **Pattern A — multiple accessor arguments:** `p.accountInformation(userId()).listTransactions(accountId, from, to, pageRequest)`. Assert accessor args and target args both populated.
- **Pattern B — helper-method routing:** `resolved.platform()` chain. Assert SPI type inferred from declared type.
- **requireCapability detection:** Assert capability class and method name extracted from the call.
- **Static default detection:** `pageSize != null ? pageSize : 50`. Assert `staticDefaults` map contains `{"pageSize": "50"}`.
- **Annotation override:** When `@GeneratePlugin(capability = X.class)` has explicit values, assert those take precedence over inferred values.

### 2. False-positive / false-negative tests

Test sources with intentionally unsupported patterns:

- **`var`-typed SPI variable:** `var p = bankService.platform(platform)` — no declared type in AST. Assert inference returns null.
- **Complex control flow:** if/else branching around SPI calls. Assert inference returns null (falls back).
- **Lambda body:** SPI call inside a lambda. Assert not inferred.
- **Try-catch wrapping:** SPI call inside try block. Assert still inferred (try-catch doesn't change the call chain).
- **Multiple return statements:** Assert inference uses first return or returns null.
- **No return statement (void method):** Assert target method extracted from the last method invocation expression statement.

### 3. Integration with compile-testing

Extend the existing `PluginGenerationTest` with connector-style source files that have method bodies. Verify generated plugin source contains correct delegate call chain matching the inferred pattern.

## File Changes

| File | Change |
|------|--------|
| `graphql-generator/src/main/java/.../infer/MethodBodyInferrer.java` | **NEW** — public entry point |
| `graphql-generator/src/main/java/.../infer/CallChainScanner.java` | **NEW** — TreePathScanner subclass |
| `graphql-generator/src/main/java/.../infer/InferredCallChain.java` | **NEW** — result record |
| `graphql-generator/src/main/java/.../GraphQLResolverProcessor.java` | **MODIFY** — integrate inference into generatePluginSource(), add processing summary |
| `graphql-generator/pom.xml` | **MODIFY** — add `--add-modules jdk.compiler` if needed |
| `graphql-generator/src/test/java/.../infer/CallChainScannerTest.java` | **NEW** — AST walker unit tests |
| `graphql-generator/src/test/java/.../infer/FalsePositiveTest.java` | **NEW** — false-positive/negative tests |
| `graphql-generator/src/test/java/.../PluginGenerationTest.java` | **MODIFY** — add compile-testing with method bodies |
| `graphql-generator/src/test/resources/infer/*.java` | **NEW** — test source files with connector-style methods |

## Prerequisites

1. **Issue #795 must be complete** — AST inference extends Tier 2 plugin generation, which is introduced by #795.
2. **Connector pattern survey** — all 13 connector platform SPIs must be surveyed to confirm the pattern catalog (A, B, C) is exhaustive. This survey should happen during implementation, before finalizing the pattern recognition rules.

## References

- `graphql-generator/src/main/java/.../GraphQLResolverProcessor.java:1766-2045` — current Tier 2 plugin generation
- `graphql-generator/src/main/java/.../GraphQLResolverProcessor.java:2066-2098` — current PluginMeta resolution
- `mcp-api/src/main/java/.../GeneratePlugin.java` — annotation definition
- `connectors/graphql/src/main/java/.../ConnectorBankApi.java` — Pattern A reference
- `connectors/graphql/src/main/java/.../ConnectorVoiceApi.java` — Pattern B reference
- `com.sun.source.util.TreePathScanner` javadoc — walker base class
- `com.sun.source.util.Trees` javadoc — entry point for compiler tree access
- Issue #795 design spec — `specs/issue-795-generate-plugin-from-platformquery/2026-11-11-plugin-generation-design.md`
- Issue #798 — tracking issue
- decisions.md — D1-D9 design decisions with rationale
