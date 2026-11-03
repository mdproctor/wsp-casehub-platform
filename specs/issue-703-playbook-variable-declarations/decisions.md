# Decisions — #703 Playbook Variable Declarations

## D1: Type scope — scalars + domain types

**Choice:** Support all four ValueType scalars (STRING, INTEGER, BOOLEAN, NUMBER) plus arbitrary domain type names as opaque labels
**Alternatives:**
- Scalars only — simpler but defers domain type syntax, creating two incompatible migration paths later
**Rationale:** Domain types like `AgentSessionConfig` are declared as metadata strings. Values stay as `Map<String,Object>`. Actual deserialization deferred to #699.
**Trade-offs:** TypedName must be extended beyond ValueType to accept arbitrary strings. No compile-time type checking on domain types until #699.
**Sources:** TypedName.java, ValueType.java, issue #699
**Exploration:** quick
**Status:** captured

## D2: Document placement — content map

**Choice:** `vars:` and `params:` are top-level keys in the content map alongside `steps`, `orchestration`, `pools`
**Alternatives:**
- Front matter / doc 2 split — separates public interface from internal state but adds parsing complexity
**Rationale:** Consistent with how `orchestration` and `pools` are already handled. Single content map, single parsing path.
**Trade-offs:** No structural separation between public interface (params) and internal state (vars) at the document level.
**Sources:** PlaybookCompiler.java:86-123, PlaybookParser.java
**Exploration:** quick
**Status:** captured

## D3: Domain type resolution — opaque labels

**Choice:** Domain type strings stored as metadata only. Map values stay as `Map<String,Object>`. No classpath resolution or deserialization.
**Alternatives:**
- Classpath-resolved — Jackson deserialization at parse time. Breaks yaml-core zero-dep constraint.
- Registry-resolved — TypeRegistry SPI maps names to deserializers. More infrastructure upfront.
**Rationale:** Keeps yaml-core zero-dep and J2CL-safe. Deserialization is a separate concern for #699.
**Trade-offs:** No runtime type safety on domain-typed variables until #699 provides it.
**Sources:** yaml-core zero-dep rule (CLAUDE.md), issue #699
**Exploration:** quick
**Status:** captured

## D4: Constraint model — reuse YamlModuleParameter

**Choice:** Reuse `YamlModuleParameter` directly for constraint declarations in `params:` long form
**Alternatives:**
- New PlaybookParameter type — tailored for playbooks but duplicates constraint logic
**Rationale:** Same record, same `ParameterValidator`, same Builder. Single source of truth for constraint validation across modules and playbooks.
**Trade-offs:** Playbooks inherit module constraint vocabulary even if some constraints (like ARRAY type) may not apply to playbook params initially.
**Sources:** YamlModuleParameter.java, ParameterValidator.java
**Exploration:** quick
**Status:** captured

## D5: Variable references — prefix-based

**Choice:** `${var.name}` for vars, `${params.name}` for params. Existing prefix-based VariableResolver contract unchanged.
**Alternatives:**
- Bare references `${name}` — simpler author syntax but requires VariableResolver changes and risks shadowing
- Both prefix + shorthand — convenience with safety but adds complexity
**Rationale:** Consistent with existing contract. VariableResolver already throws on bare references. No changes needed to the resolver.
**Trade-offs:** Authors must always use prefixes, which is slightly more verbose than `${name}`.
**Sources:** VariableResolver.java:208-214 (lookupVariable throws on bare refs)
**Exploration:** quick
**Status:** captured

## D6: Integration point — PlaybookCompiler-centric

**Choice:** `PlaybookCompiler.compile()` extracts `vars:` and `params:` from the content map, produces a `PlaybookVariableContext` bundled into `CompilationResult`
**Alternatives:**
- PlaybookDocument-level parsing — couples yaml-core's thin document to module subsystem concerns
- Separate pre-processing pass — creates mandatory pre-step every consumer must know about
**Rationale:** Follows established pattern (orchestration, pools already parsed here). Compiler owns its input format. Variable context flows naturally through CompilationResult.
**Trade-offs:** Variable parsing is coupled to the compiler rather than being reusable independently, but this matches the existing architecture.
**Sources:** PlaybookCompiler.java:86-123 (compile method pattern)
**Exploration:** quick
**Status:** captured

## D7: TypedName extension — nullable scalarType with typeName

**Choice:** Extend `TypedName` to hold `String typeName` and nullable `ValueType scalarType`. When `typeName` matches a `ValueType`, `scalarType` is populated. For domain types like `AgentSessionConfig`, `scalarType` is null and `typeName` carries the opaque label.
**Alternatives:**
- New PlaybookTypedName separate from TypedName — leaves TypedName as CSV-only but duplicates parsing logic
- Subclass/variant of TypedName — breaks the record pattern
**Rationale:** TypedName is the natural place for `name:type` parsing. Extending it is backward-compatible — existing callers that use `.type()` (now `.scalarType()`) can continue to work. CsvParser already enforces scalars-only at its call site.
**Trade-offs:** TypedName becomes a broader concept than its original CSV-header scope. Callers that assume non-null `scalarType` need updating (but there are very few — CsvParser and TypedVariables).
**Sources:** TypedName.java, CsvParser.java
**Exploration:** quick
**Status:** captured

## D8: Domain-typed values — store as-is, no validation

**Choice:** Domain-typed variables store their values as-is with no shape validation. Map values stay as `Map<String,Object>`, scalar values also kept as-is. The type label is pure metadata.
**Alternatives:**
- Validate shape — domain types must have map values, scalars rejected. Provides early feedback but overly strict before deserialization exists.
**Rationale:** Without a type registry, there's no basis for shape validation. Deferred to #699 where deserialization and type checking are the explicit focus.
**Trade-offs:** Malformed domain-typed values won't be caught until runtime (or #699).
**Sources:** Issue #699
**Exploration:** quick
**Status:** captured

## D9: run-playbook param validation — validate at invocation

**Choice:** `RunPlaybookPlugin` parses the sub-playbook's `params:`, validates caller-provided `vars:` against them using `ParameterValidator`, fails fast on missing required params or type mismatches.
**Depends on:** D4 (reuse YamlModuleParameter), D6 (PlaybookCompiler-centric parsing)
**Alternatives:**
- No validation, best-effort — caller vars merged blindly, missing params resolve to null silently
- Defer to follow-up — run-playbook integration out of scope for #703
**Rationale:** Fail-fast validation gives playbook authors immediate feedback. The infrastructure (ParameterValidator) already exists. run-playbook is the primary consumer of params: — deferring it would leave params: untestable.
**Trade-offs:** RunPlaybookPlugin becomes aware of the variable declaration parsing, adding a dependency on the new parsing code.
**Sources:** RunPlaybookPlugin.java, ParameterValidator.java
**Exploration:** quick
**Status:** captured
