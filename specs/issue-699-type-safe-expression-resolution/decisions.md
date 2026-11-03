# Decisions — #699 Type-Safe Expression Resolution

## D1: Resolution architecture

**Choice:** TypeAwareParamResolver — new class in yaml-step-runtime
**Alternatives:**
- In-place in CatalogStepRunner — minimal change but mixes step-running with resolution, not reusable
- StepRunner SPI change — larger API change, breaks existing StepRunner implementations
**Rationale:** Type-aware resolution is a distinct concern from step running. Extracting it makes it independently testable and reusable by StructuralStepEvaluator (for `when:` conditions) and YamlTestExecutor.
**Trade-offs:** One more class in the chain. Needs a mechanism to access VariableResolver scope data for expression context building.
**Sources:** CatalogStepRunner.java:22-34, StructuralStepEvaluator.java:104-120
**Exploration:** quick
**Status:** captured

## D1a: Scope — full expression evaluation

**Choice:** EXPRESSION params route to ExpressionEngine, not VariableResolver
**Alternatives:**
- Variable reference only (auto-wrap with ${}) — simpler but doesn't eliminate AssertThatPlugin boilerplate
- Variable ref now, expression later — incremental but requires two design passes
**Rationale:** Matches the ParameterType name and eliminates per-plugin expression evaluation boilerplate. AssertThatPlugin.resolveSubject() is proof this belongs in the resolution layer.
**Trade-offs:** Requires ExpressionEngineRegistry in ServiceRegistry at runtime for EXPRESSION params.
**Sources:** AssertThatPlugin.java:61-93
**Exploration:** quick
**Status:** captured

## D1b: Resolution precedence

**Choice:** EXPRESSION params always go to expression engine, never VariableResolver
**Alternatives:**
- VariableResolver first, ExpressionEngine fallback — more forgiving but two paths makes debugging harder
- Both paths merged — complex, unclear semantics
**Rationale:** Clean separation. STRING uses VariableResolver, EXPRESSION uses ExpressionEngine. No ambiguity about which path produced the result.
**Trade-offs:** No automatic variable reference shorthand in EXPRESSION params — everything goes through the expression engine.
**Depends on:** D1a (scope)
**Exploration:** quick
**Status:** captured

## D1c: Expression context from VariableResolver scopes

**Choice:** Expression context built from VariableResolver's registered scopes
**Alternatives:**
- Explicit context parameter from caller — more API surface, divergence risk
- ServiceRegistry lookup — pushes context wiring to each integration point
**Rationale:** Same data that ${...} resolution sees, exposed as expression variables. results.output.risk in an expression resolves the same way ${results.output.risk} would in a string.
**Exploration:** quick
**Status:** captured

## D1d: Backward compatibility for ${} in EXPRESSION fields

**Choice:** Accept and strip ${} wrapping in EXPRESSION fields
**Alternatives:**
- Reject ${} in EXPRESSION fields — forces immediate migration
- Pass through unchanged — expression engine may or may not handle ${}
**Rationale:** Existing playbooks continue to work without migration. No breaking change.
**Trade-offs:** Two syntax forms for the same thing. Could log deprecation warning.
**Exploration:** quick
**Status:** captured

## D1e: _subject declaration in Definition

**Choice:** Plugins declare `_subject` as an EXPRESSION input in Definition.inputs()
**Alternatives:**
- Infer _subject type from context — magic, fragile for multi-input plugins
- Keep _subject as STRING — limits the feature's benefit
**Rationale:** Consistent — all type-aware resolution goes through declared inputs. AssertThatPlugin.definition() adds `.input("_subject", ParameterType.EXPRESSION, true)`.
**Trade-offs:** Existing plugins that don't declare _subject won't get expression resolution for their primary value.
**Sources:** Walker.java:176 (_subject synthetic key), AssertThatPlugin.java:19-25 (definition builder)
**Exploration:** quick
**Status:** captured

## D1f: ExpressionContext.EXPRESSION for engine selection

**Choice:** New ExpressionContext.EXPRESSION constant in platform-api
**Alternatives:**
- Use ExpressionContext.CONDITION always — semantically wrong for transform expressions
- Configurable per parameter — adds API surface to zero-dep yaml-plugin-api
**Rationale:** Plugins that need a specific engine override via Definition metadata. Default is good enough for most cases.
**Trade-offs:** Expression engine must be registered as default for the new EXPRESSION context.
**Sources:** ExpressionContext enum in platform-api
**Exploration:** quick
**Status:** captured

## D2: Expression context source

**Choice:** Export from VariableResolver via `buildExpressionContext()` — backed by concrete maps stored via `withObjectScope(String, Map)` overload
**Alternatives:**
- Lazy proxy maps backed by ObjectVariableSource — fails because MVEL.getTypeMap() iterates the map at compile time; empty entrySet() breaks compilation
- Caller-provided context — no VariableResolver changes but context can diverge from resolver scopes
- Unified ResolutionContext — guarantees consistency but requires refactoring every VariableResolver call site
**Rationale:** Single source of truth. Callers migrate from `withObjectScope("results", map::get)` to `withObjectScope("results", map)` — the resolver stores the backing map and returns it from buildExpressionContext(). MVEL gets concrete, iterable maps for type introspection. Stays within yaml-core's zero-dep constraint.
**Trade-offs:** Small change to yaml-core's public API. Scopes registered via the functional `withObjectScope(String, ObjectVariableSource)` overload are NOT available in expression context (those callers need to migrate to the Map overload).
**Depends on:** D1 (TypeAwareParamResolver needs an expression context)
**Sources:** VariableResolver.java:15-17, MvelExpressionEngine.java:25 (MVEL.getTypeMap iteration)
**Exploration:** quick
**Status:** revised (lazy map approach disproven by MVEL type introspection requirement)

## D3: Plugin EXPRESSION field declaration

**Choice:** `@Expression` annotation in yaml-plugin-api on record fields
**Alternatives:**
- Expression marker type — stronger Java typing but adds API surface and wrapping
- Attribute on @Required/@Optional — reuses existing annotations but overloads their meaning
**Rationale:** Clean, explicit, no ambiguity. Java type stays String. Plugin processor maps @Expression to ParameterType.EXPRESSION in generated schema and Definition. Consistent with existing @Required/@Optional annotation pattern.
**Trade-offs:** New annotation in zero-dep yaml-plugin-api. Plugin processor must recognize it.
**Sources:** Plugin.java, SchemaEmitter.java:56-68 (Java type to JSON Schema mapping)
**Exploration:** quick
**Status:** captured

## D4: ExpressionEngineRegistry unavailable

**Choice:** Fail fast with IllegalStateException
**Rationale:** If a plugin declares EXPRESSION params but no ExpressionEngineRegistry is in ServiceRegistry, that's a configuration error. Silent fallback to string resolution would produce wrong results. Clear error message guides the fix.
**Trade-offs:** Strict — tests must provide an ExpressionEngineRegistry or not use EXPRESSION-typed plugins.
**Exploration:** quick
**Status:** captured

## D5: JSON Schema representation of EXPRESSION

**Choice:** `"type": "string", "format": "expression"` in generated JSON Schema
**Rationale:** EXPRESSION values are strings in YAML. The `format` annotation signals to tooling (editors, validators) that the value is an expression, not arbitrary text. Standard JSON Schema convention for annotating string subtypes.
**Trade-offs:** The `format` keyword is advisory in JSON Schema — validators may or may not enforce it.
**Depends on:** D3 (@Expression annotation drives schema generation)
**Sources:** SchemaEmitter.java:29-31 (property emission)
**Exploration:** quick
**Status:** captured Expression context source

**Choice:** Export from VariableResolver via `buildExpressionContext()` method
**Alternatives:**
- Caller-provided context — no VariableResolver changes but context can diverge from resolver scopes
- Unified ResolutionContext — guarantees consistency but requires refactoring every VariableResolver call site
**Rationale:** Single source of truth. The resolver knows its own scopes — asking it to export them as a Map<String, Object> for expression engine consumption is natural. Returns lazy proxy maps backed by ObjectVariableSources, no eager enumeration. Stays within yaml-core's zero-dep constraint (returns plain Map).
**Trade-offs:** Small change to yaml-core's public API. ObjectVariableSource-backed proxy maps need on-demand resolution (lazy get, no size/iterator).
**Depends on:** D1 (TypeAwareParamResolver needs an expression context)
**Sources:** VariableResolver.java:15-17 (prefixSources, objectPrefixSources fields)
**Exploration:** quick
**Status:** captured
