# Decisions — Issue #798: AST-based plugin call chain inference

## D1: Inference scope

**Choice:** Tiered scope. Primary: core call chain inference — SPI type, routing parameter, capability class, capability accessor, accessor arguments, target method, target method arguments, and requireCapability detection. These directly replace the `@GeneratePlugin(capability, spi, accessor, spiMethod)` annotation attributes. Secondary (deferred until primary ships and implementation evidence exists): static default value inference (see D5), complex parameter construction pattern detection.
**Alternatives:**
- Full richer inference in one pass — core + defaults + parameter construction + conditional logic. Maximally ambitious but commits to patterns with no false-positive data
- Core call chain only — covers annotation reduction but misses default values that make YAML richer
**Rationale:** The issue's stated goal is annotation surface reduction. The "What to infer" table defines the primary scope — every item there directly eliminates a `@GeneratePlugin` attribute. The "Richer YAML from richer inference" items (default values, parameter construction, conditional logic) are enhancement opportunities that depend on implementation evidence: false-positive rates, actual connector pattern diversity, and YAML authoring scenarios. Shipping primary scope first provides the evidence base for secondary scope decisions. Conditional logic detection is dropped from scope entirely — it produces metadata that no current consumer uses.
**Trade-offs:** Secondary scope may never ship if primary inference proves sufficient. This is acceptable — if core inference eliminates the annotation burden, the richness features are nice-to-have, not essential.
**Sources:** Issue #798 "What to infer" table (primary), "Richer YAML from richer inference" section (secondary), ConnectorBankApi.java, ConnectorVoiceApi.java
**Exploration:** quick
**Status:** revised (R1-03 — tiered scope replaces monolithic "full richer inference")

## D2: Non-standard connector pattern handling

**Choice:** Handle voice-style patterns (helper-method routing, option-record construction, multi-service injection) in addition to the standard bank-style pattern. The scanner handles variable assignments by maintaining a `Map<Name, TypeTree>` of variable declarations encountered during the single-pass walk. When visiting a `VariableTree`, the scanner records the variable name and its declared type (from `VariableTree.getType()`). When visiting a `MethodInvocationTree` on a tracked variable, the scanner resolves the receiver's declared type from the map — no `getTypeMirror()` call needed for explicitly-typed local variables.
**Alternatives:**
- Standard patterns only, voice falls back to @GeneratePlugin — simpler AST walker, covers ~85% of methods but requires annotation fallback for voice/complex connectors
**Rationale:** Connectors show the ideal surface for what we need to generate. Excluding voice-style patterns forces annotation boilerplate on a significant fraction of methods. Voice-style patterns are structurally different from bank-style but equally recognizable from the AST — they use a finite set of AST shapes (variable declaration + method chain, constructor invocation + chained call). The term "non-standard" means "structurally different from the majority bank-style pattern," not "irregular" or "unpredictable."
**Trade-offs:** More pattern recognition cases in the scanner. Prerequisite: a complete survey of all 13 connector platform SPIs must confirm that the pattern catalog (bank-style, voice-style) is exhaustive before implementation.
**Sources:** ConnectorVoiceApi.java (resolveVoice helper, SynthesisOptions construction), ConnectorBankApi.java (standard pattern)
**Exploration:** quick
**Status:** revised (R1-04 — clarified mechanism, terminology, prerequisite survey)

## D3: AST inference fallback behavior

**Choice:** Fall back to @GeneratePlugin annotation when AST inference fails. No per-method diagnostic for individual fallbacks. Instead: (1) Structured processing summary — a single NOTE diagnostic at the end of the APT round: "AST inference: N/M methods inferred, K fell back to @GeneratePlugin: [method list]." One summary message is visible even in verbose build output; scattered per-method NOTEs are not. (2) Source comment in every generated plugin indicating the resolution path: `// resolved via: AST inference` or `// resolved via: @GeneratePlugin annotation`. When both are absent, skip with WARNING.
**Alternatives:**
- Per-method NOTE diagnostic — too granular, invisible in Maven build summary
- WARNING per fallback — overly alarmist for intentional @GeneratePlugin usage
- Compile ERROR — strict but forces developer action on every unrecognized pattern, even benign ones
**Rationale:** Graceful degradation. AST inference is the happy path; @GeneratePlugin attributes become fallbacks for methods where inference fails. The processing summary gives visibility without noise. The source comment makes debugging straightforward — when a generated plugin has incorrect behavior, the developer can immediately see which resolution path produced it without reading build logs.
**Trade-offs:** Summary message is still a NOTE (not a WARNING), so it appears in verbose output only. But a single line with counts is more visible than scattered diagnostics.
**Sources:** Issue #798 spec ("Fall back to annotation-based metadata when the AST pattern doesn't match"), Maven diagnostic visibility behavior
**Exploration:** quick
**Status:** revised (R1-06 — processing summary replaces per-method NOTE; source comment added)

## D4: Complex parameter handling

**Choice:** Complex fields passed through as single plugin fields (e.g., PageRequest as @Optional field). JSON Schema handles the record's field structure for the YAML surface.
**Alternatives:**
- Individual fields — plugin exposes cursor + pageSize separately and constructs PageRequest internally. Flatter YAML surface but generator must synthesize constructor calls.
**Rationale:** Consistent with issue #795 design: "Complex method parameters (records, POJOs) are passed as whole plugin record fields — the generator does NOT decompose them." The AST inference detects `new PageRequest(cursor, size)` and maps the SPI method's parameter types. Whether decomposition improves YAML DX is a user-scenario question that belongs in #795's scope — #798 gains visibility into construction patterns but D4 consciously does not act on it until #795 evaluates the YAML surface with concrete scenarios.
**Trade-offs:** Nested YAML surface for pagination parameters. But JSON Schema expansion makes this ergonomic.
**Sources:** Issue #795 design spec §Result Handling, ConnectorBankApi.listTransactions
**Exploration:** quick
**Status:** captured

## D5: Default value inference

**Choice:** Static defaults (literal values: integers, strings, booleans, enum constants) captured and propagated to the plugin's compact constructor or `@DefaultValue`. Dynamic defaults (runtime-computed expressions like `Instant.now().minusSeconds(2592000)`) are NOT inferred — they are connector implementation details, not part of the SPI contract.
**Alternatives:**
- Record dynamic defaults as metadata/comments in generated code — carries semantic information but risks staleness (the comment says "default: 30 days ago" but the connector changed six months later; no mechanism to detect this)
- Don't infer any defaults — loses static default information that is genuinely useful for YAML ergonomics
**Rationale:** The plugin consumer's contract is with the SPI, not the connector's default-value logic. Static defaults are constant values that are part of the method's contract — they don't change without a source edit. Dynamic defaults are implementation details that: (1) can't be executed at plugin construction time, (2) have no defined consumer (generated Java comments aren't consumed by tooling), and (3) risk active misleading through staleness. The SPI method's parameter nullability already signals optionality. Stale metadata is worse than no metadata.
**Sources:** ConnectorBankApi.listTransactions (`from != null ? from : Instant.now().minusSeconds(2592000)` — the 30-day window is implementation detail, not SPI contract)
**Exploration:** quick
**Status:** revised (R1-07 — dynamic defaults dropped; static defaults retained)

## D6: AST walker architecture

**Choice:** Single-pass `com.sun.source.util.TreePathScanner` that walks the method body in one pass, collecting all inference data into an `InferredCallChain` record. `TreePathScanner` maintains the ancestor chain during traversal, providing parent context at zero additional cost over `TreeScanner` (it extends `TreeScanner`, wrapping each `scan()` with path construction). The scanner maintains variable-tracking state (see D2) — "single-pass" means one traversal of the tree, not stateless traversal.
**Alternatives:**
- Multi-pass analysis with type resolution — more robust type handling via Trees.getTypeMirror(), but significantly more complex and getTypeMirror() can be unreliable across compilation rounds
- Pattern-matching DSL — maximally extensible declarative patterns, but heavy upfront investment for a pattern language nobody else will use
- TreeScanner (no path) — lighter, but lacks ancestor context needed for future extension (e.g., detecting whether a call is inside an if-block)
**Rationale:** Connector method bodies follow a finite set of recognizable AST shapes. Bank-style methods use direct SPI method chaining; voice-style methods use variable assignment + chained calls. Both are structurally recognizable from the AST without multi-pass type resolution, because connector code uses explicitly-typed local variables (the declared type is available from `VariableTree.getType()`). `TreePathScanner` is preferred over `TreeScanner` because it provides `getCurrentPath()` at zero cost — future extensions (conditional logic detection, if it's ever needed) require parent context. Prerequisite: a complete survey of all 13 connector platform SPI patterns must validate that the recognized pattern catalog is exhaustive.
**Trade-offs:** Less robust type resolution than multi-pass. If a connector uses `var` for SPI-typed variables, the declared type is not in the AST and the scanner cannot infer it — such methods fall back to `@GeneratePlugin`. This is acceptable given the annotation-fallback mechanism (D3) and the current connector convention of explicit type declarations.
**Sources:** ConnectorBankApi.java, ConnectorVoiceApi.java, ConnectorCommerceApi.java (observed patterns — Commerce pattern analysis is a prerequisite before finalizing the pattern catalog), `com.sun.source.util.TreePathScanner` javadoc, `com.sun.source.util.TreeScanner` javadoc
**Exploration:** quick
**Status:** revised (R1-04, R1-05, R1-11 — TreePathScanner replaces TreeScanner; clarified "finite recognizable shapes" vs "regular"; Commerce analysis prerequisite noted)

## D7: Testing strategy for AST inference

**Choice:** Three-level testing strategy:
1. **AST walker unit tests** — test the `TreePathScanner` subclass in isolation with synthetic method bodies. Test source files must contain **realistic method implementations** (not just signatures) because the Trees API needs method bodies to walk. Each recognized pattern (bank-style, voice-style) gets a test source file. Tests assert the content of the `InferredCallChain` record — which SPI type, which capability, which accessor, which target method, which arguments were extracted. This is the primary regression defense.
2. **False-positive/false-negative detection** — dedicated test sources with intentionally unsupported patterns (methods with complex control flow, recursive calls, lambda bodies, try-catch wrapping). Assert that inference returns empty/fails gracefully and fallback to `@GeneratePlugin` activates.
3. **Integration with existing compile-testing** — the #795 spec's `javax.tools.JavaCompiler` compile-test infrastructure already validates generated plugin source. #798 extends it: test sources include connector-style methods WITH method bodies, and tests verify the generated plugin's delegate call matches the expected SPI call chain (not just that it compiles).
**Alternatives:**
- Compile-testing only (no AST walker unit tests) — verifies the end-to-end output but doesn't isolate AST inference bugs from code generation bugs
- Runtime testing only (YAML step execution) — too late in the feedback loop; AST inference bugs should be caught at compile time
**Rationale:** AST walker bugs produce generated code that compiles but calls the wrong SPI methods. Compilation success is necessary but not sufficient — the tests must verify semantic correctness of the inferred call chain. Isolating AST walker tests from code generation tests gives precise failure localization.
**Sources:** Issue #795 spec §Testing Strategy, `javax.tools.JavaCompiler` compile-testing, `GraphQLResolverProcessorTest.java`
**Exploration:** quick (surfaced by reviewer)
**Status:** captured

## D8: Inference trigger and precedence model

**Choice:** AST inference runs on Tier 2 connector class methods only (methods on `@McpDomain`-annotated classes, not interfaces). Tier 1 interface methods have no method body in the APT compilation unit — inference is not applicable. Precedence model:
1. If `@GeneratePlugin` is present with **explicit** values (non-default `capability`, `spi`, `accessor`, or `spiMethod`), those attributes override AST inference for the fields they specify. Shape attributes (`name`, `absorb`, `subject`, `optionalParams`, `exclude`) are always taken from `@GeneratePlugin` when present.
2. If `@GeneratePlugin` is absent or its call-chain attributes are at defaults (`capability = void.class`, `spi = void.class`, `accessor = ""`, `spiMethod = ""`), AST inference runs.
3. If AST inference succeeds, use inferred values.
4. If AST inference fails (unrecognized pattern, `var`-typed variables, complex control flow), fall back to `@GeneratePlugin` attribute values. If no `@GeneratePlugin` annotation exists, skip with WARNING.
**Alternatives:**
- Always run inference, ignore @GeneratePlugin call-chain attributes entirely — simpler but removes the escape hatch for methods where inference produces wrong results
- Always run inference, use it to validate @GeneratePlugin attributes — catches annotation/code drift but adds complexity for marginal benefit
**Rationale:** `@GeneratePlugin` attributes are the escape hatch. When present with explicit values, they represent developer intent to override inference — perhaps because the method has an unusual pattern or because inference was known to produce wrong results. This model is consistent with #798's goal: "The `capability`, `spi`, `accessor`, and `spiMethod` attributes become fallbacks for methods where inference fails — not the default path."
**Sources:** Issue #798 body ("Fall back to annotation-based metadata when the AST pattern doesn't match"), #795 spec §SPI type resolution
**Exploration:** quick (surfaced by reviewer)
**Status:** captured

## D9: jdk.compiler module dependency constraint

**Choice:** Explicitly acknowledge that `Trees.instance(processingEnv)` and `TreePathScanner` create a dependency on the `jdk.compiler` module, constraining the APT to javac-based compilation. This is a supported API (exported from `jdk.compiler`, not `com.sun.tools.javac.internal`), but compiler-specific: alternative compilers (ECJ used by Eclipse JDT) do not provide it.
**Alternatives:**
- Avoid Trees API entirely — use only Jandex + annotation-based inference. Compiler-agnostic but cannot read method bodies.
- Abstract the AST access behind an SPI with javac and ECJ implementations — over-engineering for a platform that uses Maven + javac exclusively.
**Rationale:** This platform uses Maven + javac exclusively (§2 Constraints in ARC42STORIES.MD: "Java 21 on Java 26 JVM"). ECJ compatibility is not a requirement. The fallback mechanism (D3) covers any future scenario where the APT runs under a non-javac compiler — `Trees.instance()` will return null or throw, and all methods fall back to `@GeneratePlugin` annotation-based resolution. The constraint should be documented so that any future build system change is aware of the dependency.
**Sources:** `jdk.compiler` module exports (`com.sun.source.util` package), ARC42STORIES.MD §2 Constraints, `Trees.instance()` javadoc
**Exploration:** quick (surfaced by reviewer)
**Status:** captured
