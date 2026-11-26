# Match Playbook Step — Template Registry Integration with Type-Safe Variable Flow

**Issue:** #970
**Date:** 2026-11-26
**Epic:** #943 (Message Extraction Pipeline)

## Purpose

Extend the `match` playbook step with a template mode that connects the unified template registry to playbook execution. Takes channel input, matches against a registered namespace, dispatches to handlers by template name, and flows extracted fields as typed scoped variables into downstream steps. Compile-time validation ensures variable references are correct against declared template schemas.

This builds on:
- #959 — unified template registry (types, SPI, matching infrastructure)
- #969 — YAML corpus format (template namespace declarations with variable metadata)

## Architecture

The `match` step gains a **template mode** alongside its existing value mode. Mode is detected by YAML structure:

- **Value mode** (unchanged): `match: ${expr}` (scalar value) with `cases:` sibling — `MatchPattern`-based dispatch
- **Template mode** (new): `match:` with a Map value containing `input:`, `namespace:`, `on:`, `unmatched:` — registry-backed matching with typed variable flow. Mode is detected by `matchValue instanceof Map` with `namespace` key present.

### YAML Syntax

```yaml
steps:
  - await:
      channel: review-channel
      as: response

  - match:
      input: ${response.text}
      namespace: protocol:review
      on:
        vote:
          - invoke: recordVote
            args:
              voter: ${response.sender}
              decision: ${vote.decision}    # enum — compiler knows allowed values
              subject: ${vote.subject}       # string
              rationale: ${vote.rationale}   # optional — compiler warns without null check
          - signal: vote-recorded
            data:
              decision: ${vote.decision}
        escalate:
          - invoke: routeEscalation
            args:
              target: ${escalate.target}
              reason: ${escalate.reason}
          - signal: escalation-raised
      unmatched:
        - invoke: passThrough
```

**Keys:**
- `input:` — expression resolving to the text to match (required)
- `namespace:` — registered template namespace name (required)
- `on:` — map of template name → handler step list (required, at least one entry)
- `unmatched:` — fallback handler step list (optional)

### Module Changes

| Module | Change | New Dependencies |
|--------|--------|------------------|
| `yaml-core` | `VariableConstraint` gets `metadata` field + `MetadataKeys` constants | None |
| `playbook-compiler` | `MatchCompiler` extended for template mode; new `TemplateSchemaResolver` SPI | → `template-registry-api` (for `TemplateSchema` in resolver return type) |
| `yaml-step-runtime` | Walker updated for template mode parsing; `StructuralStepEvaluator` extended for template dispatch; `ResolvedStep.MatchStep` extended; `TemplateMatchSpec` added | → `template-registry-api` (for `UnifiedTemplateRegistry` in evaluator) |
| `template-registry-api` | No changes required | — |

**Dependency justification:** `template-registry-api` is a lightweight API module with only `yaml-core` and Jackson dependencies — no heavy transitive costs. The coupling is architecturally necessary: the compiler must validate against template schemas, and the runtime must invoke template matching. Both are fundamental to the feature, not optional integration points.

## Type Changes

### VariableConstraint — metadata extension (yaml-core)

Add a `metadata` field to the sealed interface and both record implementations. Backward compatible via factory methods.

**Duplicate in `message-extraction-api`:** A duplicate `io.casehub.extraction.VariableConstraint` exists in `message-extraction-api` (marked for removal in the #959 spec). This spec does NOT update the duplicate. The template-mode match flow exclusively uses `yaml-core`'s `VariableConstraint` throughout — from `TemplateSchema` (which references `yaml-core`'s version) through `TemplateMatchSpec.templateVariables` to compile-time validation. No code path in the template match pipeline touches the `message-extraction-api` version. Its removal is tracked by #959 and is not a blocking dependency.

```java
public sealed interface VariableConstraint {
    boolean required();
    Map<String, String> metadata();
    VariableConstraint optional();
    VariableConstraint withMetadata(Map<String, String> metadata);

    record StringConstraint(boolean required, Map<String, String> metadata)
            implements VariableConstraint {
        public StringConstraint {
            metadata = metadata != null
                ? Collections.unmodifiableMap(new LinkedHashMap<>(metadata))
                : Map.of();
        }
        public StringConstraint(boolean required) { this(required, Map.of()); }
        @Override public VariableConstraint optional() {
            return new StringConstraint(false, metadata);
        }
        @Override public VariableConstraint withMetadata(Map<String, String> metadata) {
            return new StringConstraint(required, metadata);
        }
    }

    record EnumConstraint(Set<String> values, boolean required,
                          Map<String, String> metadata)
            implements VariableConstraint {
        public EnumConstraint {
            Objects.requireNonNull(values, "values");
            if (values.isEmpty())
                throw new IllegalArgumentException("Enum constraint must have at least one value");
            values = Set.copyOf(values);
            metadata = metadata != null
                ? Collections.unmodifiableMap(new LinkedHashMap<>(metadata))
                : Map.of();
        }
        public EnumConstraint(Set<String> values, boolean required) {
            this(values, required, Map.of());
        }
        @Override public VariableConstraint optional() {
            return new EnumConstraint(values, false, metadata);
        }
        @Override public VariableConstraint withMetadata(Map<String, String> metadata) {
            return new EnumConstraint(values, required, metadata);
        }
    }

    static VariableConstraint string() { return new StringConstraint(true); }
    static VariableConstraint enumOf(String... values) {
        return new EnumConstraint(Set.of(values), true);
    }
}
```

### MetadataKeys — grammar constants (yaml-core)

```java
public final class MetadataKeys {
    public static final String PERSON = "person";       // "1st" | "2nd" | "3rd"
    public static final String NUMBER = "number";       // "singular" | "plural"
    public static final String PRONOUNS = "pronouns";   // "they/them" | "she/her" | "he/him"

    private MetadataKeys() {}
}
```

Defined in yaml-core alongside `VariableConstraint`. Known keys provide discoverability and prevent typo-based silent failures. Unknown keys are accepted for extensibility.

### TemplateMatchSpec — template-mode carrier (yaml-step-runtime)

Carries template-mode configuration within the Walker pipeline. Constructed by the Walker during template-mode resolution and attached to `ResolvedStep.MatchStep`. Lives in `yaml-step-runtime` alongside `ResolvedStep` — both the producer (Walker) and consumer (`StructuralStepEvaluator`) are in this module.

```java
public record TemplateMatchSpec(
    String namespace,
    String inputExpression,
    Map<String, List<ResolvedStep>> handlers,
    List<ResolvedStep> unmatchedHandler
) {
    public TemplateMatchSpec {
        Objects.requireNonNull(namespace, "namespace");
        Objects.requireNonNull(inputExpression, "inputExpression");
        handlers = Map.copyOf(handlers);
        unmatchedHandler = unmatchedHandler != null ? List.copyOf(unmatchedHandler) : List.of();
    }
}
```

`TemplateMatchSpec` carries only runtime-relevant data. Variable schemas (template name → variable name → constraint) are a compile-time concern — they live in `MatchCompiler`'s compilation context and are not carried in the runtime type. The evaluator dispatches to handlers based on template match results and does not validate extracted fields against schema constraints at runtime.

### TemplateSchemaResolver — compiler SPI (playbook-compiler)

```java
@FunctionalInterface
public interface TemplateSchemaResolver {
    List<TemplateSchema> resolve(String namespace);

    static TemplateSchemaResolver noOp() {
        return namespace -> List.of();
    }
}
```

Non-optional on `PlaybookCompiler`. Defaults to `noOp()` which returns empty for all namespaces — template-mode match steps that reference namespaces get "namespace not found" compile-time errors when no resolver is wired. This follows the platform NoOp pattern.

## Compiler Changes

### PlaybookCompiler

Add `TemplateSchemaResolver` as a constructor parameter with NoOp default. The existing no-arg constructor does 20+ `register()` calls — these move to the canonical three-arg constructor, and both shorter constructors delegate to it:

```java
private TemplateSchemaResolver schemaResolver;

public PlaybookCompiler() {
    this(null, TemplateSchemaResolver.noOp());
}

public PlaybookCompiler(PluginRegistry pluginRegistry) {
    this(pluginRegistry, TemplateSchemaResolver.noOp());
}

public PlaybookCompiler(PluginRegistry pluginRegistry,
                        TemplateSchemaResolver schemaResolver) {
    this.pluginRegistry = pluginRegistry;
    this.schemaResolver = Objects.requireNonNull(schemaResolver);
    register("log", (key, value, fullStep, ctx) -> { /* ... */ });
    register("block", new BlockCompiler());
    register("match", new MatchCompiler());
    // ... remaining 15+ register() calls ...
}

TemplateSchemaResolver schemaResolver() { return schemaResolver; }
```

The package-private `schemaResolver()` accessor is used by `MatchCompiler` via `CompilationContext` (see §MatchCompiler below).

The CDI caller (`PlaybookRunnerCore` or a Quarkus bean) wires the resolver to delegate to `UnifiedTemplateRegistry::schemas`.

### MatchCompiler — template mode

`MatchCompiler.compile()` detects template mode when `stepValue` is a `Map` containing `namespace`. The schema resolver is accessed via `CompilationContext`, which already holds a package-private `PlaybookCompiler` reference:

```java
@Override
public TaskItem compile(String stepKey, Object stepValue,
                        Map<String, Object> fullStep, CompilationContext ctx) {
    if (stepValue instanceof Map<?,?> config && config.containsKey("namespace")) {
        return compileTemplateMode(config, ctx);
    }
    return compileValueMode(stepKey, stepValue, fullStep, ctx);
}

private TaskItem compileTemplateMode(Map<?,?> config, CompilationContext ctx) {
    var resolver = ctx.compiler().schemaResolver();
    String namespace = String.valueOf(config.get("namespace"));
    List<TemplateSchema> schemas = resolver.resolve(namespace);
    // ... validation and compilation ...
}
```

**Wiring path:** `CompilationContext` already holds a `PlaybookCompiler compiler` field (package-private, same package). We add a package-private accessor `compiler()` to `CompilationContext` and `schemaResolver()` to `PlaybookCompiler`. Since `MatchCompiler` is in `io.casehub.platform.compiler` — the same package — it can access both. No new public API surface needed.

**`compileValueMode`** — existing `MatchCompiler` logic (unchanged).

**`compileTemplateMode`:**
1. Extract `input`, `namespace`, `on`, `unmatched` from config
2. Resolve namespace via `TemplateSchemaResolver` — emit ERROR if empty (namespace not found)
3. Validate `on:` handler keys against resolved template names — emit ERROR for unknown handlers
4. Walk each handler's step list, collect `${templateName.variable}` references
5. Validate references against template schemas:
   - Unknown variable → ERROR diagnostic
   - Optional variable used without null guard → WARNING diagnostic
   - Enum variable → note type info (available for downstream validation)
6. Compile to `SetTask` with `_stepType: "template-match"` and encoded metadata (namespace, input expression, handler map). The SWF `SwitchTask` can't express NLP matching — template dispatch happens at runtime.

### Compile-Time Variable Validation

**Pipeline scope:** This validation applies to the SWF compilation path (`MatchCompiler.compileTemplateMode()`). The Walker path (`Walker.resolve()` → `StructuralStepEvaluator.evaluate()`) skips validation — the Walker constructs `TemplateMatchSpec` without schema resolution and relies on runtime variable resolution errors (`UnresolvedVariableException`) for unknown references. This is consistent with the platform's existing bifurcation: the SWF path produces validated workflows; the Walker path is a lightweight execution engine.

The compiler scans handler step parameters for `${templateName.variableName}` patterns:

```java
private void validateTemplateReferences(String templateName,
        List<?> steps, Map<String, VariableConstraint> variables,
        CompilationContext ctx) {
    // Walk all string values in step parameters
    // Match ${templateName.variableName} pattern
    // Check variableName exists in template's variable declarations
    // Warn on optional variable usage without null guard
}
```

**Validation rules:**
- `${vote.decision}` where `decision` is declared → valid
- `${vote.nonexistent}` where `nonexistent` is not declared → ERROR
- `${vote.rationale}` where `rationale` is `required: false` → WARNING ("optional variable 'rationale' used without null check — may be null at runtime")
- `${escalate.target}` referenced inside `on: vote:` handler → ERROR (cross-handler reference — `escalate` variables are only available in the `escalate` handler)

**Cross-handler reference disambiguation:** When the compiler encounters `${X.Y}` in a handler block, it checks whether `X` is a template name in the same `on:` block. If `X` matches another template name, it is a cross-handler reference — ERROR, regardless of whether `X` also exists as an external scope (e.g., from a preceding `capture: X` step). Template names shadow external scopes within handler blocks. This is consistent with how the `match` scope in value mode shadows any external scope named `match`.

If the user needs an external scope that collides with a template name, they must rename the capture. This is by design — the alternative (silent disambiguation based on scope availability) would create confusing interactions where adding a new template to a namespace could change the meaning of existing handler code.

### Walker Changes (yaml-step-runtime)

Template mode is detected from `matchValue` itself — not from step-level companion keys. In the spec's YAML syntax, `namespace`, `on`, `input`, `unmatched` are NESTED inside the `match:` mapping value, not step-level siblings. The Walker's key iteration sets `hasMatch = true; matchValue = e.getValue()`, and for template mode `matchValue` is the entire Map `{input: ..., namespace: ..., on: {...}, unmatched: [...]}`. The template-mode keys never appear in the step-level iteration.

This matches how `MatchCompiler` already detects template mode: `stepValue instanceof Map config && config.containsKey("namespace")`. The Walker uses the same pattern — type-based dispatch on `matchValue`.

**1. Structural type assignment.** After setting `hasMatch` and `matchValue`, mode detection checks the type and content of `matchValue`:

```java
// Value mode: match + cases (existing)
if (hasMatch && companions.containsKey("cases")) {
    if (structuralType != null) {
        throw new IllegalArgumentException(...);
    }
    structuralType = "match";
}

// Template mode: match value is a Map containing "namespace"
if (hasMatch && matchValue instanceof Map<?,?> matchMap
        && matchMap.containsKey("namespace")) {
    if (structuralType != null) {
        throw new IllegalArgumentException(
            path + " → Step " + index + ": ambiguous — structural keyword '"
            + structuralType + "' and 'match' (template mode) both present");
    }
    structuralType = "match-template";
}

// Match requires either cases or a template-mode config map
if (hasMatch && !"match".equals(structuralType)
        && !"match-template".equals(structuralType)) {
    throw new IllegalArgumentException(
        path + " → Step " + index
        + ": 'match' requires either 'cases' or a template config "
        + "with 'namespace' + 'on'");
}
```

No new companion set is needed — template-mode keys live inside `matchValue` and are extracted directly from it during construction.

**2. Template-mode construction.** After the existing `if ("match".equals(structuralType))` block, add template-mode construction that extracts configuration from `matchValue`:

```java
if ("match-template".equals(structuralType)) {
    @SuppressWarnings("unchecked")
    var config = (Map<String, Object>) matchValue;

    // Validate required keys
    if (!config.containsKey("on")) {
        throw new IllegalArgumentException(
            stepPath + ": template-mode 'match' requires 'on:' handler map");
    }

    String inputExpr = config.containsKey("input")
        ? String.valueOf(config.get("input"))
        : null;
    if (inputExpr == null) {
        throw new IllegalArgumentException(
            stepPath + ": template-mode 'match' requires 'input:' expression");
    }
    String namespace = String.valueOf(config.get("namespace"));

    @SuppressWarnings("unchecked")
    var onHandlers = (Map<String, Object>) config.get("on");
    if (onHandlers.isEmpty()) {
        throw new IllegalArgumentException(
            stepPath + ": 'on:' must contain at least one handler");
    }
    Map<String, List<ResolvedStep>> resolvedHandlers = new LinkedHashMap<>();
    String childPrefix = stepKey + ".";

    for (var entry : onHandlers.entrySet()) {
        String templateName = entry.getKey();
        @SuppressWarnings("unchecked")
        var handlerSteps = (List<Map<String, Object>>) entry.getValue();
        resolvedHandlers.put(templateName,
            resolve(handlerSteps, registry, depth + 1,
                stepPath + " → on:" + templateName, seenNames,
                annotations, childPrefix, 0, collector,
                playbookFile, locations));
    }

    @SuppressWarnings("unchecked")
    var unmatchedRaw = (List<Map<String, Object>>) config.get("unmatched");
    List<ResolvedStep> unmatchedSteps = unmatchedRaw != null
        ? resolve(unmatchedRaw, registry, depth + 1,
            stepPath + " → unmatched", seenNames,
            annotations, childPrefix, 0, collector,
            playbookFile, locations)
        : List.of();

    var spec = new TemplateMatchSpec(
        namespace, inputExpr, resolvedHandlers, unmatchedSteps);

    return MatchStep.templateMode(stepName, spec, decorators);
}
```

**3. `withAnnotations()` and `withDecorators()` updates.** These copy-on-modify methods must dispatch by mode:

```java
case ResolvedStep.MatchStep s ->
    s.isTemplateMode()
        ? MatchStep.templateMode(s.name(), s.templateSpec(), s.decorators(), anns)
        : MatchStep.valueMode(s.name(), s.scrutinee(), s.cases(), s.decorators(), anns);
```

### ResolvedStep.MatchStep Extension

The record gains a `TemplateMatchSpec` field. Mode exclusivity is enforced via static factory methods that make it impossible to construct an invalid hybrid state:

```java
record MatchStep(
    String name,
    String scrutinee,                  // value mode (null in template mode)
    List<ResolvedMatchCase> cases,     // value mode (empty in template mode)
    TemplateMatchSpec templateSpec,    // template mode (null in value mode)
    Map<String, Object> decorators,
    List<Annotation> annotations) implements ResolvedStep {

    public MatchStep {
        cases       = cases != null ? List.copyOf(cases) : List.of();
        decorators  = Map.copyOf(decorators);
        annotations = annotations != null ? List.copyOf(annotations) : List.of();
    }

    public boolean isTemplateMode() { return templateSpec != null; }

    // --- Static factories enforce mode exclusivity ---

    static MatchStep valueMode(String name, String scrutinee,
            List<ResolvedMatchCase> cases, Map<String, Object> decorators) {
        Objects.requireNonNull(scrutinee, "scrutinee required for value mode");
        return new MatchStep(name, scrutinee, cases, null, decorators, List.of());
    }

    static MatchStep valueMode(String name, String scrutinee,
            List<ResolvedMatchCase> cases, Map<String, Object> decorators,
            List<Annotation> annotations) {
        Objects.requireNonNull(scrutinee, "scrutinee required for value mode");
        return new MatchStep(name, scrutinee, cases, null, decorators, annotations);
    }

    static MatchStep templateMode(String name, TemplateMatchSpec templateSpec,
            Map<String, Object> decorators) {
        Objects.requireNonNull(templateSpec, "templateSpec required for template mode");
        return new MatchStep(name, null, List.of(), templateSpec, decorators, List.of());
    }

    static MatchStep templateMode(String name, TemplateMatchSpec templateSpec,
            Map<String, Object> decorators, List<Annotation> annotations) {
        Objects.requireNonNull(templateSpec, "templateSpec required for template mode");
        return new MatchStep(name, null, List.of(), templateSpec, decorators, annotations);
    }
}
```

**Construction site migration:**
- `Walker.resolveOne()` value-mode: `MatchStep.valueMode(stepName, matchValue, cases, decorators)`
- `Walker.resolveOne()` template-mode: `MatchStep.templateMode(stepName, spec, decorators)`
- `Walker.withAnnotations()`: reconstruct via `isTemplateMode()` dispatch to the matching factory
- `Walker.withDecorators()`: same pattern
- All test sites use the 4-param value-mode constructor → `MatchStep.valueMode(...)` (mechanical)

## Runtime Changes

### StructuralStepEvaluator — template dispatch

`evaluateMatch()` detects template mode via `TemplateMatchSpec`:

```java
private Result evaluateMatch(ResolvedStep.MatchStep match,
                             StepContext ctx, StepRunner runner) {
    if (match.templateSpec() != null) {
        return evaluateTemplateMatch(match.templateSpec(), ctx, runner);
    }
    // existing value-mode logic unchanged
    Object scrutineeValue = ctx.resolver().resolve(match.scrutinee());
    // ...
}
```

**`evaluateTemplateMatch`:**

```java
private Result evaluateTemplateMatch(TemplateMatchSpec spec,
                                     StepContext ctx, StepRunner runner) {
    // 1. Resolve input expression
    Object inputValue = ctx.resolver().resolve(spec.inputExpression());
    String input = String.valueOf(inputValue);

    // 2. Match against namespace via registry
    TemplateMatch result = registry.match(spec.namespace(), input);

    // 3. Dispatch by match result
    if (result instanceof TemplateMatch.Matched matched) {
        List<ResolvedStep> handler = spec.handlers().get(matched.templateName());
        if (handler == null) {
            // Template matched but no handler declared — treat as unmatched
            return evaluateUnmatched(spec, input, null, ctx, runner);
        }

        // 4. Push extracted fields as scoped variables: ${templateName.field}
        VariableResolver enriched = ctx.resolver()
            .withObjectScope(matched.templateName(),
                name -> matched.fields().get(name));

        // 5. Push match context: ${_tmatch.namespace}, ${_tmatch.template}, ${_tmatch.score}
        enriched = enriched.withObjectScope("_tmatch", name ->
            switch (name) {
                case "namespace" -> matched.namespace();
                case "template" -> matched.templateName();
                case "score" -> String.valueOf(matched.score());
                default -> null;
            });

        StepContext handlerCtx = ctx.withResolver(enriched);
        return evaluateBlock(
            new ResolvedStep.BlockStep(null, handler, Map.of()),
            handlerCtx, runner);
    }

    if (result instanceof TemplateMatch.NearMiss nearMiss) {
        LOG.info("Template near-miss in namespace '" + spec.namespace()
            + "': input near '" + nearMiss.suggestedTemplate()
            + "', suggested format: " + nearMiss.suggestedFormat());
        return evaluateUnmatched(spec, input, nearMiss, ctx, runner);
    }

    // Unmatched
    return evaluateUnmatched(spec, input, null, ctx, runner);
}

private Result evaluateUnmatched(TemplateMatchSpec spec, String input,
                                  TemplateMatch.NearMiss nearMiss,
                                  StepContext ctx, StepRunner runner) {
    if (spec.unmatchedHandler().isEmpty()) {
        return Result.of(Map.of());
    }
    // Push _tmatch context with input + near-miss diagnostics
    VariableResolver enriched = ctx.resolver()
        .withObjectScope("_tmatch", name ->
            switch (name) {
                case "input" -> input;
                case "namespace" -> spec.namespace();
                case "nearMiss" -> nearMiss != null
                    ? nearMiss.suggestedTemplate() : null;
                case "suggestedFormat" -> nearMiss != null
                    ? nearMiss.suggestedFormat() : null;
                default -> null;
            });
    StepContext unmatchedCtx = ctx.withResolver(enriched);
    return evaluateBlock(
        new ResolvedStep.BlockStep(null, spec.unmatchedHandler(), Map.of()),
        unmatchedCtx, runner);
}
```

### preRegisterLatches — MatchStep recursion

`preRegisterLatches()` must recurse into MatchStep child step lists (both modes). Currently `MatchStep` falls into `default -> {}` with no recursion — a pre-existing gap for value-mode cases. Since this spec adds new nested step lists (template-mode handlers), it should fix both:

```java
case ResolvedStep.MatchStep m -> {
    if (m.isTemplateMode()) {
        for (var handler : m.templateSpec().handlers().values()) {
            preRegisterLatches(handler);
        }
        preRegisterLatches(m.templateSpec().unmatchedHandler());
    } else {
        for (var mc : m.cases()) {
            preRegisterLatches(mc.steps());
        }
    }
}
```

Without this, any `barrier` or `quorum` referencing a named step inside a template handler would deadlock — the latch is never pre-registered.

### Registry Access

`StructuralStepEvaluator` needs `UnifiedTemplateRegistry` for template dispatch. The private constructor's parameter list grows from 5 to 6:

```java
private final UnifiedTemplateRegistry templateRegistry;

public StructuralStepEvaluator(ConditionEvaluator conditionEvaluator) {
    this(conditionEvaluator, null);
}

public StructuralStepEvaluator(ConditionEvaluator conditionEvaluator,
                               ExecutionScope scope) {
    this(conditionEvaluator, scope, Map.of(), null, null, null);
}

public StructuralStepEvaluator(ConditionEvaluator conditionEvaluator,
                               ExecutionScope scope,
                               UnifiedTemplateRegistry templateRegistry) {
    this(conditionEvaluator, scope, Map.of(), null, null, templateRegistry);
}

private StructuralStepEvaluator(ConditionEvaluator conditionEvaluator,
        ExecutionScope scope, Map<String, Object> injectedBindings,
        StepExecutionListener listener, CaptureCollector captureCollector,
        UnifiedTemplateRegistry templateRegistry) {
    // ... existing init ...
    this.templateRegistry = templateRegistry != null
        ? templateRegistry : new NoOpUnifiedTemplateRegistry();
}
```

**Copy-on-modify methods** must thread the registry through — `withListener()`, `withCaptureCollector()`, and `withInjections()` all create new instances via the private constructor. Each passes `this.templateRegistry` through.

**Production wiring path:** `PlaybookRunnerCore.executeSteps()` constructs the evaluator directly (line 297), not via CDI:

```java
var evaluator = new StructuralStepEvaluator(conditionEvaluator, scope)
```

This becomes:

```java
var evaluator = new StructuralStepEvaluator(conditionEvaluator, scope, templateRegistry)
```

`PlaybookRunnerCore` gains a `UnifiedTemplateRegistry` constructor parameter. Callers that construct `PlaybookRunnerCore` (CDI-managed Quarkus beans) inject the registry via CDI. Existing constructors default to `null` (→ NoOp internally).

**Test sites** (20+ StructuralStepEvaluator constructions) continue using the existing 1-arg and 2-arg constructors, which default to NoOp — no updates needed unless testing template mode.

## Variable Scoping

### Template handler scope

Inside an `on:` handler block, extracted fields are available as `${templateName.variableName}`:

```yaml
on:
  vote:
    # Available: ${vote.decision}, ${vote.subject}, ${vote.rationale}
    - invoke: recordVote
      args:
        decision: ${vote.decision}
  escalate:
    # Available: ${escalate.target}, ${escalate.reason}
    # NOT available: ${vote.decision} — different handler scope
    - invoke: routeEscalation
```

Each handler's scope is isolated — `${vote.decision}` is only available in the `vote` handler, not in `escalate`. The compiler enforces this at compile time (D4 validation rules).

**Scope shadowing:** Template names shadow all scopes with the same prefix inside handler blocks, including built-in scopes (`error`, `result`, `params`, `var`, `module`, `events`). For example, a template named `error` would make `${error.message}` resolve to the template's extracted `message` field, not a try-catch error scope. This is consistent with how the `match` scope in value mode shadows external scopes, and with the cross-handler shadowing rule (§Compile-Time Variable Validation). Template names are defined in the template namespace (not authored per-playbook), making accidental collision unlikely.

### Match context scope

The `_tmatch` prefix provides match metadata in all handler blocks:

| Variable | Type | Available in |
|----------|------|-------------|
| `${_tmatch.namespace}` | String | matched + unmatched handlers |
| `${_tmatch.template}` | String | matched handlers only |
| `${_tmatch.score}` | String (numeric) | matched handlers only |
| `${_tmatch.input}` | String | unmatched handler only |
| `${_tmatch.nearMiss}` | String (nullable) | unmatched handler only — suggested template name |
| `${_tmatch.suggestedFormat}` | String (nullable) | unmatched handler only — rephrase suggestion |

The `_tmatch` prefix (not `_match`) avoids collision with the existing `match` scope used by value-mode matching via `ScopeUtils.pushScope(resolver, "match", value)`.

**Convention:** The underscore prefix establishes a platform convention for system-provided scopes — it distinguishes them from user-defined scopes and prevents accidental shadowing (users can't create `capture: _tmatch`). Future system scopes should follow this convention.

**RESERVED_CAPTURE_NAMES:** `_tmatch` must be added to `StepKeywords.RESERVED_CAPTURE_NAMES` to prevent `capture: _tmatch` from colliding with the system scope. The Walker's capture-name validation will reject it automatically.

## Metadata Propagation

### Flow: declaration → extraction → generation

1. **Declaration** (YAML corpus, #969): template variables carry metadata
   ```yaml
   variables:
     agent:
       type: string
       metadata:
         person: 3rd
         pronouns: they/them
   ```

2. **Compilation**: `TemplateSchemaResolver` returns `TemplateSchema` with `VariableConstraint` carrying metadata. Compiler validates references against schemas (SWF compilation path only — see §Compile-Time Variable Validation).

3. **Extraction** (match step runtime): registry matches input, extracts field values. The `_tmatch.namespace` and `_tmatch.template` context variables identify which template matched.

4. **Generation** (downstream step): a `generate` step producing templated output looks up the matched template's schema via the registry to retrieve metadata for grammar-aware generation:
   ```java
   // In generate step implementation:
   Optional<TemplateSchema> schema = registry.schema(
       resolver.resolve("_tmatch.namespace"),
       resolver.resolve("_tmatch.template"));
   if (schema.isPresent()) {
       Map<String, String> agentMeta =
           schema.get().variables().get("agent").metadata();
       String pronouns = agentMeta.get(MetadataKeys.PRONOUNS);
       // Use pronouns for grammar-correct generation
   }
   ```

### Compile-time metadata validation

The compiler can validate that generation steps referencing template variables have metadata available:
- If a `generate` step uses `${vote.agent}` and `agent` has `person: 3rd` metadata, the compiler knows grammar-aware generation is possible
- If `agent` has no metadata, the compiler can note that generation will use raw values without grammar adaptation

This is advisory (WARNING level), not blocking — generation without metadata produces grammatically neutral output.

## TemplateMatchingFilter Supersession

The new match template mode subsumes `TemplateMatchingFilter`'s functionality:

| TemplateMatchingFilter feature | Match template mode equivalent |
|-------------------------------|-------------------------------|
| `fromYaml()` parsing | `MatchCompiler` template mode + `TemplateSchemaResolver` |
| `ProtocolEvaluator` matching | `UnifiedTemplateRegistry.match(namespace, input)` |
| Constraint validation via `TemplateExtractor` | Registry handles constraint validation internally |
| Near-miss detection | `TemplateMatch.NearMiss` from registry |
| Rephrase suggestions | `NearMiss.suggestedFormat()` |
| `ServiceRegistry` registration | Direct registry injection via constructor |

`TemplateMatchingFilter` remains available during the transition period for existing playbooks using the `templates:` section. No new features will be added to it. Full removal is tracked by #961 (consumer migration).

## Scope

### In scope
- `VariableConstraint` metadata extension + `MetadataKeys` in yaml-core
- `TemplateSchemaResolver` SPI in playbook-compiler
- `MatchCompiler` template mode with compile-time variable validation
- Walker template mode parsing
- `ResolvedStep.MatchStep` extension with `TemplateMatchSpec`
- `StructuralStepEvaluator` template dispatch with scoped variable binding
- `_tmatch` context variables for metadata lookup
- Compile-time diagnostics: ERROR for invalid references, WARNING for optional variables
- Metadata propagation design (declaration → extraction → generation)

### Out of scope
- `generate` step implementation — this spec designs the metadata propagation *path*; the generation step that consumes metadata is a separate issue
- Consumer migration from `TemplateMatchingFilter` — tracked by #961
- POS-driven morphological generation — #962
- Multi-language template matching — #965
- PlaybookCompiler SWF compilation path — template match compiles to `SetTask` with runtime metadata; full SWF integration deferred to when the SWF runtime supports custom step types

## Thread Safety

All new types are immutable records. `TemplateMatchSpec`, `TemplateSchemaResolver`, and `MetadataKeys` have no mutable state. Runtime template matching delegates to `UnifiedTemplateRegistry` which uses immutable-snapshot concurrency (D9 from #959). Variable scoping creates new `VariableResolver` instances per handler invocation — no shared mutable state.

## References

- `playbook-compiler/src/main/java/io/casehub/platform/compiler/MatchCompiler.java` — existing value-mode compiler
- `playbook-compiler/src/main/java/io/casehub/platform/compiler/PlaybookCompiler.java` — compiler entry point, template parsing
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java:325` — existing `evaluateMatch()`
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java:104` — existing `MatchStep` record
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedMatchCase.java` — existing case record
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/TemplateMatchingFilter.java` — superseded by template mode
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableConstraint.java` — metadata extension target
- `yaml-core/src/main/java/io/casehub/yaml/core/step/MatchPattern.java` — value-mode patterns (unchanged)
- `template-registry-api/src/main/java/io/casehub/template/registry/UnifiedTemplateRegistry.java` — matching SPI
- `template-registry-api/src/main/java/io/casehub/template/registry/TemplateSchema.java` — schema type
- `template-registry-api/src/main/java/io/casehub/template/registry/TemplateMatch.java` — match result type
- Decisions: `specs/issue-970-match-step-type-safe-vars/decisions.md` (D1–D6)
- Issue #959 — unified template registry design spec
- Issue #969 — YAML corpus format
- Issue #961 — consumer migration (TemplateMatchingFilter removal)
- Issue #943 — parent epic
