# Decisions — Issue #798: AST-based plugin call chain inference

## D1: Inference scope

**Choice:** Full richer inference — core call chain plus requireCapability detection, default value inference, complex parameter construction, and conditional logic detection.
**Alternatives:**
- Core call chain only — simpler, covers ~80% of value but misses default values and parameter construction patterns that make YAML richer
- Core + requireCapability only — partial improvement, leaves default values and parameter construction for a follow-up
**Rationale:** Connectors are the reference implementation for what YAML plugins should look like. Maximum richness from the method body means the generated YAML surface should be as expressive as a hand-written plugin.
**Trade-offs:** More complex AST walker with more pattern recognition cases. More potential for false positives on edge-case patterns.
**Sources:** ConnectorBankApi.java (listTransactions defaults), ConnectorVoiceApi.java (option construction), issue #798 spec
**Exploration:** quick
**Status:** captured

## D2: Non-standard connector pattern handling

**Choice:** Handle voice-style patterns (helper-method routing, option-record construction, multi-service injection) in addition to the standard bank-style pattern.
**Alternatives:**
- Standard patterns only, voice falls back to @GeneratePlugin — simpler AST walker, covers ~85% of methods but requires annotation fallback for voice/complex connectors
**Rationale:** Connectors show the ideal surface for what we need to generate. Excluding voice-style patterns forces annotation boilerplate on a significant fraction of methods.
**Trade-offs:** More complex pattern recognition in the TreeScanner. Need to handle variable assignments through helper methods and multi-step routing chains.
**Sources:** ConnectorVoiceApi.java (resolveVoice helper, SynthesisOptions construction), ConnectorBankApi.java (standard pattern)
**Exploration:** quick
**Status:** captured

## D3: AST inference fallback behavior

**Choice:** Fall back to @GeneratePlugin annotation when AST inference fails. Emit NOTE diagnostic, check for annotation. If annotation present, use annotation-based resolution. If absent, skip with WARNING.
**Alternatives:**
- Always skip with WARNING — simpler but no recovery path for unrecognized patterns
- Emit compile ERROR — strict but forces developer action on every unrecognized pattern, even benign ones
**Rationale:** Graceful degradation. AST inference is the happy path; @GeneratePlugin attributes become fallbacks for methods where inference fails. No breaking change.
**Trade-offs:** Silent fallback could mask inference bugs — developer might not notice the AST walker failed and annotation took over. NOTE diagnostic mitigates this.
**Sources:** Issue #798 spec ("Fall back to annotation-based metadata when the AST pattern doesn't match")
**Exploration:** quick
**Status:** captured

## D4: Complex parameter handling

**Choice:** Complex fields passed through as single plugin fields (e.g., PageRequest as @Optional field). JSON Schema handles the record's field structure for the YAML surface.
**Alternatives:**
- Individual fields — plugin exposes cursor + pageSize separately and constructs PageRequest internally. Flatter YAML surface but generator must synthesize constructor calls.
**Rationale:** Consistent with issue #795 design: "Complex method parameters (records, POJOs) are passed as whole plugin record fields — the generator does NOT decompose them." The AST inference detects `new PageRequest(cursor, size)` and maps the SPI method's parameter types.
**Trade-offs:** Nested YAML surface for pagination parameters. But JSON Schema expansion makes this ergonomic.
**Sources:** Issue #795 design spec §Result Handling, ConnectorBankApi.listTransactions
**Exploration:** quick
**Status:** captured

## D5: Default value inference

**Choice:** Static defaults captured as literal values in the generated plugin. Dynamic defaults (runtime-computed expressions like `Instant.now()`) recorded as metadata/comments in the generated plugin but not executed.
**Alternatives:**
- Static defaults only — simpler, but dynamic defaults are invisible to the plugin consumer
**Rationale:** Dynamic defaults carry semantic information even if they can't be executed at plugin construction time. Recording them as metadata helps plugin consumers understand what the connector does when a param is absent.
**Trade-offs:** Metadata comments add noise to generated code. Dynamic defaults in metadata may become stale if the connector changes. But the alternative is losing the information entirely.
**Sources:** ConnectorBankApi.listTransactions (`from != null ? from : Instant.now().minusSeconds(2592000)`)
**Exploration:** quick
**Status:** captured

## D6: AST walker architecture

**Choice:** Single-pass TreeScanner that walks the method body in one pass, collecting all inference data into an InferredCallChain record.
**Alternatives:**
- Multi-pass analysis with type resolution — more robust type handling via Trees.getTypeMirror(), but significantly more complex and getTypeMirror() can be unreliable across compilation rounds
- Pattern-matching DSL — maximally extensible declarative patterns, but heavy upfront investment for a pattern language nobody else will use
**Rationale:** Connector patterns are regular and finite. A single TreeScanner pass handles all observed patterns without multi-pass complexity. Voice-style patterns add recognition cases to the same scanner without changing the architecture.
**Trade-offs:** Less robust type resolution than multi-pass. If new connector patterns emerge that require full type context, the scanner would need refactoring. But the patterns are knowable and bounded.
**Sources:** ConnectorBankApi.java, ConnectorVoiceApi.java, ConnectorCommerceApi.java (observed patterns), com.sun.source.util.TreeScanner javadoc
**Exploration:** quick
**Status:** captured
