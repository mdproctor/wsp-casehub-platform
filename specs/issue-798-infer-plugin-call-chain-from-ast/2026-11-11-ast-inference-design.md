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

- Dynamic default value inference (#799) — runtime-computed expressions (`Instant.now()`) are NOT inferred
- Complex parameter construction pattern detection (#800) — `new PageRequest(cursor, size)` is visible to the walker but not acted on in primary scope
- Conditional logic detection (#801) — dropped from scope entirely

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

**`findMethodElement(op)`** bridges from `ResolvedOperation` to `ExecutableElement` using the same `TypeElement` lookup pattern as the existing `resolvePluginMeta`:

```java
private ExecutableElement findMethodElement(ResolvedOperation op) {
    TypeElement te = processingEnv.getElementUtils().getTypeElement(op.declaringClassFqcn());
    if (te == null) return null; // Jandex-sourced domain — no source in current round
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

**Constraint:** For Jandex-sourced domains (connector classes loaded from dependency JARs rather than compiled in the current round), `getTypeElement()` returns a type with no source, so `Trees.getTree()` on the returned `ExecutableElement` yields null. The entry point naturally short-circuits: `MethodBodyInferrer.infer()` returns null when `trees.getTree(method)` is null, and the method falls back to annotation-based resolution. AST inference only works for `RoundEnvironment`-sourced methods.

### Known limitations

1. **`var`-typed SPI variables** — when the SPI variable uses `var` instead of an explicit type (`var p = bankService.platform(platform)`), the declared type is not available in the AST (`node.getType().toString()` returns `"var"`). The scanner cannot infer the SPI type and falls back to annotation-based resolution. This is acceptable given the current connector convention of explicit type declarations.

2. **Non-direct return transformation** — methods that transform the SPI result before returning (e.g., Voice `speak()` which Base64-encodes audio and constructs a DTO) cannot have their call chain fully inferred. The scanner detects this: when the return expression is not a method invocation chain on the SPI variable, inference marks the method as not directly returnable and falls back.

3. **Methods not in current compilation round** — AST inference only works for `RoundEnvironment`-sourced methods (classes compiled in the current APT round). Jandex-only classes from dependency JARs have no source tree available.

4. **Indirect return via local variable** — inference requires the SPI method chain to appear directly in the return expression (`return p.accessor().method(args)`) or as an expression statement (Rule 6 for void methods). If the SPI call is assigned to a local variable and the variable is returned (`var result = p.accessor().method(args); return result;`), the return expression is an `IdentifierTree`, not a method chain, and the target method is not extracted. Such methods fall back to annotation-based resolution.

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

The scanner constructor takes the `TreePath` to extract the `CompilationUnitTree` for import resolution (see Type Resolution above).

### CallChainScanner

A `TreePathScanner<Void, Void>` subclass that walks the method body in a single pass. Maintains state:

```java
class CallChainScanner extends TreePathScanner<Void, Void> {

    private final IndexView jandexIndex;
    private final Map<String, String> importMap; // simple name → FQCN from imports

    // Variable tracking (D2): variable name → declared type FQCN
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

    // Multi-return detection
    private int returnCount;

    // Failure tracking
    private InferenceFailure failureReason;
}
```

#### Type resolution — simple names to FQCNs

The scanner resolves simple type names (from `node.getType().toString()`) to fully-qualified class names using two strategies:

1. **Import resolution** — on construction, the scanner extracts the `CompilationUnitTree` from the `TreePath` and builds an `importMap` from `import` declarations. For `import io.casehub.connectors.bank.spi.BankPlatform;`, the map contains `{"BankPlatform" → "io.casehub.connectors.bank.spi.BankPlatform"}`. Wildcard imports (e.g., `import io.casehub.connectors.bank.spi.*;`) are noted but not expanded.

2. **Jandex fallback** — when a simple name is not found in the import map (wildcard import or same-package type), the scanner searches the Jandex index for classes matching the simple name. If exactly one match is found, that FQN is used. If zero or multiple matches are found, inference fails for that type (the `jandexIndex` constructor parameter serves this purpose).

```java
private String resolveTypeName(String simpleName) {
    if (simpleName.contains(".")) return simpleName; // already qualified
    String fromImports = importMap.get(simpleName);
    if (fromImports != null) return fromImports;
    // Jandex fallback for wildcard/same-package imports
    List<ClassInfo> candidates = jandexIndex.getKnownClasses().stream()
            .filter(ci -> ci.simpleName().equals(simpleName))
            .toList();
    return candidates.size() == 1 ? candidates.get(0).name().toString() : simpleName;
}
```

This resolves both `spiTypeFqcn` (from Rule 1) and `capabilityFqcn` (from Rule 3) to proper FQCNs, ensuring correct comparison with Jandex-resolved values in the integration code.

#### Scope guards — skipping nested scopes

Lambda expressions and anonymous class bodies introduce nested scopes with their own return statements, variable declarations, and method invocations. These are irrelevant to the enclosing method's call chain and must not interfere with inference. The scanner skips these subtrees entirely:

```java
@Override
public Void visitLambdaExpression(LambdaExpressionTree node, Void p) {
    return null; // do not recurse into lambda body
}

@Override
public Void visitNewClass(NewClassTree node, Void p) {
    if (node.getClassBody() != null) {
        return null; // do not recurse into anonymous class body
    }
    return super.visitNewClass(node, p);
}
```

This prevents false-positive `MULTIPLE_RETURNS` from lambda returns (e.g., `stream().filter(a -> { return a.isActive(); })`), and also prevents lambda-scoped variable declarations from polluting the `variableTypes` map (e.g., a lambda-local `var p = ...` would shadow the outer SPI variable).

#### Recognition rules

**Rule 1 — Variable declaration with `service.platform(x)` call:**

```java
@Override
public Void visitVariable(VariableTree node, Void p) {
    // Record variable name → resolved FQCN
    String typeName = node.getType().toString();
    if ("var".equals(typeName)) {
        // var-typed — cannot resolve type from AST
        // Only fail inference if this is the SPI variable (service.platform() pattern)
        if (node.getInitializer() instanceof MethodInvocationTree inv
                && methodName(inv).equals("platform")) {
            failureReason = InferenceFailure.VAR_TYPED_SPI;
        }
        // Don't add to variableTypes — type is unknown
        return super.visitVariable(node, p);
    }
    String resolvedType = resolveTypeName(typeName);
    variableTypes.put(node.getName(), resolvedType);

    // Check if initializer is service.platform(arg)
    if (node.getInitializer() instanceof MethodInvocationTree inv) {
        if (methodName(inv).equals("platform") && inv.getArguments().size() == 1) {
            spiTypeFqcn = resolvedType;  // resolved FQCN of the SPI type
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
        spiTypeFqcn = resolvedType;
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
                    capabilityFqcn = resolveTypeName(ms.getExpression().toString());
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
    returnCount++;
    if (returnCount > 1) {
        // Multiple returns → ambiguous control flow, fail inference
        spiTypeFqcn = null;
        capabilityAccessor = null;
        targetMethod = null;
        targetArgs = null;
        failureReason = InferenceFailure.MULTIPLE_RETURNS;
        return super.visitReturn(node, p);
    }

    ExpressionTree expr = node.getExpression();
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

**`MethodCallInfo`** — a record representing one link in a flattened method chain:

```java
record MethodCallInfo(Name receiverName, String methodName, List<String> args) {
    List<String> argNames() {
        return args;
    }
}
```

**`flattenMethodChain(expr)`** — recursively unwraps nested `MethodInvocationTree` into a flat list, outermost receiver first:

```java
private List<MethodCallInfo> flattenMethodChain(ExpressionTree expr) {
    List<MethodCallInfo> chain = new ArrayList<>();
    flattenMethodChainRecursive(expr, chain);
    return chain;
}

private void flattenMethodChainRecursive(ExpressionTree expr, List<MethodCallInfo> chain) {
    if (!(expr instanceof MethodInvocationTree inv)) return;

    ExpressionTree methodSelect = inv.getMethodSelect();
    List<String> args = inv.getArguments().stream()
            .map(ExpressionTree::toString)
            .toList();

    if (methodSelect instanceof MemberSelectTree ms) {
        // Recurse into the receiver: a.b().c() → unwrap a.b() first
        flattenMethodChainRecursive(ms.getExpression(), chain);
        Name receiverName = (chain.isEmpty() && ms.getExpression() instanceof IdentifierTree id)
                ? id.getName() : null;
        chain.add(new MethodCallInfo(receiverName, ms.getIdentifier().toString(), args));
    }
}
```

For `p.accountInformation(userId()).balance(accountId)`, the AST is:
```
MethodInvocationTree("balance", args=[accountId],
    receiver=MethodInvocationTree("accountInformation", args=[userId()],
        receiver=IdentifierTree("p")))
```

`flattenMethodChain` produces: `[{receiver: p, method: accountInformation, args: [userId()]}, {receiver: null, method: balance, args: [accountId]}]`.

Note: argument expressions like `userId()` are method invocations, not identifiers. `ExpressionTree.toString()` renders them as source-level text (e.g., `"userId()"`). These are matched by name against the connector method's `@QueryParam`/`@PathParam` parameters — the generator already handles this mapping in the existing Tier 2 code.

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

**`extractParamName(condition, trueExpr)`** — validates the `x != null ? x : literal` pattern and returns the parameter name, or null if the pattern doesn't match:

```java
private String extractParamName(ExpressionTree condition, ExpressionTree trueExpr) {
    // Condition must be: paramName != null
    if (!(condition instanceof BinaryTree binary)) return null;
    if (binary.getKind() != Tree.Kind.NOT_EQUAL_TO) return null;
    ExpressionTree left = binary.getLeftOperand();
    ExpressionTree right = binary.getRightOperand();
    // One operand must be null literal
    boolean leftIsNull = right instanceof LiteralTree lit && lit.getValue() == null;
    boolean rightIsNull = left instanceof LiteralTree lit2 && lit2.getValue() == null;
    if (!leftIsNull && !rightIsNull) return null;
    // Non-null operand is the parameter name
    ExpressionTree paramExpr = leftIsNull ? left : right;
    if (!(paramExpr instanceof IdentifierTree paramId)) return null;
    // True expression must be the same identifier
    if (!(trueExpr instanceof IdentifierTree trueId)) return null;
    if (!paramId.getName().contentEquals(trueId.getName())) return null;
    return paramId.getName().toString();
}
```

**Rule 6 — Void method expression statement with SPI method chain:**

For `@PlatformMutation` methods with void return type (e.g., delete operations), the SPI call is an expression statement rather than a return statement. Rule 6 extends `visitExpressionStatement` to extract the call chain from SPI method invocations:

```java
// In visitExpressionStatement, after Rule 3 (requireCapability check):
if (node.getExpression() instanceof MethodInvocationTree inv) {
    List<MethodCallInfo> chain = flattenMethodChain(inv);
    if (chain.size() >= 2) {
        MethodCallInfo first = chain.get(0);
        if (first.receiverName != null
                && variableTypes.containsKey(first.receiverName)
                && variableTypes.get(first.receiverName).equals(spiTypeFqcn)) {
            // Only set if not already set by a return statement (Rule 4 takes precedence)
            if (targetMethod == null) {
                capabilityAccessor = first.methodName;
                accessorArgs = first.argNames();
                MethodCallInfo last = chain.get(chain.size() - 1);
                targetMethod = last.methodName;
                targetArgs = last.argNames();
            }
        }
    } else if (chain.size() == 1) {
        MethodCallInfo call = chain.get(0);
        if (call.receiverName != null
                && variableTypes.containsKey(call.receiverName)
                && targetMethod == null) {
            targetMethod = call.methodName;
            targetArgs = call.argNames();
        }
    }
}
```

Rule 4 (return statement) takes precedence: if both a return statement and an expression statement contain SPI method chains, the return-based inference wins. For void methods with no return statement, Rule 6 is the only source of the target method.

### InferenceFailure

An enum capturing why inference failed, used by the processing summary for diagnostic reporting:

```java
public enum InferenceFailure {
    NO_METHOD_BODY,              // method not in current compilation unit
    VAR_TYPED_SPI,               // SPI variable uses var — no type in AST
    MULTIPLE_RETURNS,            // multiple return statements — ambiguous control flow
    CAPABILITY_MISMATCH,         // requireCapability method name ≠ target method name
    INCOMPLETE_CAPABILITY_CHAIN, // capability detected but accessor not found in return chain
    NO_SPI_VARIABLE,             // no service.platform() call found (Pattern C)
    UNRECOGNIZED_PATTERN         // AST shape doesn't match any known pattern
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
    String requireCapabilityMethodName,
    InferenceFailure failureReason
) {
    public boolean isComplete() {
        if (spiTypeFqcn == null || targetMethod == null) return false;
        // If capability was detected (via requireCapability), accessor must also be present
        if (capabilityFqcn != null && capabilityAccessor == null) return false;
        return failureReason == null;
    }
}
```

The scanner's `result()` method performs cross-validation before returning:

```java
InferredCallChain result() {
    // Cross-validate requireCapability method name against inferred target method
    if (requireCapabilityMethodName != null && targetMethod != null
            && !requireCapabilityMethodName.equals(targetMethod)) {
        failureReason = InferenceFailure.CAPABILITY_MISMATCH;
    }
    // Detect Pattern C — no SPI variable found
    if (spiTypeFqcn == null && failureReason == null) {
        failureReason = InferenceFailure.NO_SPI_VARIABLE;
    }
    // Detect incomplete capability chain — capability found but accessor missing
    if (capabilityFqcn != null && capabilityAccessor == null && failureReason == null) {
        failureReason = InferenceFailure.INCOMPLETE_CAPABILITY_CHAIN;
    }
    // Detect incomplete pattern — have SPI type but no target method
    if (spiTypeFqcn != null && targetMethod == null && failureReason == null) {
        failureReason = InferenceFailure.UNRECOGNIZED_PATTERN;
    }
    return new InferredCallChain(spiTypeFqcn, routingParamName,
            capabilityFqcn, capabilityAccessor, accessorArgs,
            targetMethod, targetArgs, staticDefaults,
            requireCapabilityMethodName, failureReason);
}
```

### Integration with generatePluginSource()

The inferred data merges with the existing generation logic. The key change: the existing capability routing condition `if (!meta.capabilityFqcn.isEmpty())` changes to use effective values, so AST-inferred capabilities flow into accessor introspection and delegate call construction.

```java
// After resolving PluginMeta from annotation
PluginMeta meta = resolvePluginMeta(op);
InferredCallChain inferred = null;

if (!ops.isInterface && treesAvailable) {
    ExecutableElement methodElement = findMethodElement(op);
    if (methodElement != null) {
        inferred = MethodBodyInferrer.infer(trees, methodElement, jandexIndex);
    }

    // Accumulate failure reason for processing summary
    if (inferred != null && !inferred.isComplete()) {
        failureReasons.merge(inferred.failureReason(), 1, Integer::sum);
        fallbackMethods.add(op.methodName());
        inferred = null; // treat incomplete inference as failure
    }
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

The existing capability routing block (line 1870 in current code) changes from:

```java
// BEFORE: only fires when annotation has explicit capability
if (!meta.capabilityFqcn.isEmpty()) {
    capabilityAccessor = !meta.accessor.isEmpty() ? meta.accessor : decapitalize(capSimple);
    // ... accessor introspection via Jandex ...
}
if (!meta.spiMethod.isEmpty()) {
    spiMethodName = meta.spiMethod;
}
```

to:

```java
// AFTER: fires when capability is known from annotation OR inference
if (effectiveCapability != null && !effectiveCapability.isEmpty()) {
    String capSimple = effectiveCapability.contains(".")
            ? effectiveCapability.substring(effectiveCapability.lastIndexOf('.') + 1)
            : effectiveCapability;
    capabilityAccessor = effectiveAccessor != null && !effectiveAccessor.isEmpty()
            ? effectiveAccessor : decapitalize(capSimple);
    // ... accessor introspection via Jandex (unchanged) ...
}
spiMethodName = effectiveSpiMethod;
```

This ensures AST-inferred capability values reach the accessor introspection and delegate call construction, not just the merge variables.

### Processing summary diagnostic (D3)

Summary counters are **processor-level instance fields**, accumulated across all domains during the domain loop in `process()`. The summary is emitted **once**, after the domain loop completes — not per-domain:

```java
// Processor-level fields
private int inferredCount;
private int totalPluginCount;
private final Map<InferenceFailure, Integer> failureReasons = new EnumMap<>(InferenceFailure.class);
private final List<String> fallbackMethods = new ArrayList<>();

// In process(), after the domain loop:
if (generatePlugins && totalPluginCount > 0) {
    int fallbackCount = fallbackMethods.size();
    StringBuilder summary = new StringBuilder();
    summary.append("AST inference: ").append(inferredCount).append("/")
           .append(totalPluginCount).append(" methods inferred");
    if (fallbackCount > 0) {
        summary.append(", ").append(fallbackCount).append(" fell back (");
        failureReasons.forEach((reason, count) ->
                summary.append(count).append(" ").append(reason.name().toLowerCase()).append(", "));
        summary.setLength(summary.length() - 2); // trim trailing ", "
        summary.append("): ").append(fallbackMethods);
    }
    processingEnv.getMessager().printMessage(Diagnostic.Kind.NOTE, summary.toString());
}
```

This gives a single, project-wide view: `"AST inference: 47/60 methods inferred, 13 fell back (5 no_spi_variable, 3 var_typed_spi, 2 multiple_returns, 3 unrecognized_pattern): [method list]"`.

Each generated plugin includes a source comment indicating the resolution path. `usedInference` is derived from the completeness check: after the merge code nulls out incomplete inference (line 528), `inferred != null` means inference succeeded and was used:

```java
boolean usedInference = (inferred != null);
// ... later, in the source generation:
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

### Initialization and lifecycle

`trees` and `treesAvailable` are **instance fields** on `GraphQLResolverProcessor`. Initialization happens **once**, at the beginning of `process()`, before the domain loop — after `loadCombinedIndex()` and before `scanHandWrittenPluginNames()`:

```java
// Instance fields
private Trees trees;
private boolean treesAvailable;

// In process(), after loadCombinedIndex():
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

Since `processed = true` (line 95) ensures the processor fires exactly once, this initialization runs exactly once per compilation round. The `trees` instance is then passed to `MethodBodyInferrer.infer()` inside `generatePluginSource()` during the domain loop.

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
- **Multiple return statements:** Assert inference returns null with `failureReason = MULTIPLE_RETURNS`.
- **No return statement (void method):** Assert target method extracted from the SPI method invocation expression statement via Rule 6.
- **Lambda with explicit return:** `stream().filter(a -> { return a.isActive(); })` in method body does NOT trigger `MULTIPLE_RETURNS`.

### 3. Integration with compile-testing

Extend the existing `PluginGenerationTest` with connector-style source files that have method bodies. Verify generated plugin source contains correct delegate call chain matching the inferred pattern.

## File Changes

| File | Change |
|------|--------|
| `graphql-generator/src/main/java/.../infer/MethodBodyInferrer.java` | **NEW** — public entry point |
| `graphql-generator/src/main/java/.../infer/CallChainScanner.java` | **NEW** — TreePathScanner subclass |
| `graphql-generator/src/main/java/.../infer/InferredCallChain.java` | **NEW** — result record |
| `graphql-generator/src/main/java/.../infer/InferenceFailure.java` | **NEW** — failure reason enum |
| `graphql-generator/src/main/java/.../infer/MethodCallInfo.java` | **NEW** — method chain element record |
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
