## D1: Module placement and naming

**Choice:** New module `yaml-core/` in the platform repo, artifact `casehub-platform-yaml-core`, parent `casehub-platform-parent`
**Alternatives:**
- Standalone repo (`casehubio/yaml-core`, artifact `casehub-yaml-core`, parent `casehub-parent`) — clean J2CL isolation but adds build-order and CI overhead for a small module
- Platform module with spec's name (`casehub-yaml-core` breaking `casehub-platform-*` convention) — signals cross-cutting intent but inconsistent naming
**Rationale:** Platform already hosts zero-dep utility code (expression/, graphql/). J2CL constraint is a coding discipline, not an architectural boundary. Follows existing naming convention. No new repo/CI needed.
**Trade-offs:** Platform repo grows by one module. J2CL constraints must be documented and enforced by tests rather than build isolation.
**Sources:** platform/pom.xml (module listing, naming convention), spec §Module Structure, CLAUDE.md §Modules (expression/ precedent)
**Exploration:** quick
**Status:** captured

## D2: DSL composability model

**Choice:** Toolbox approach — primitives are independent utilities, domains compose them in their own compilation pipelines
**Alternatives:**
- Explicit dialect (YamlDialect/YamlCapabilities declaring active primitives) — prevents half-supported features but over-engineers the initial extraction
**Rationale:** The primitives are naturally decoupled at the Java API level (ForEachExpander doesn't force you to use CsvParser). Each domain's compiler cherry-picks what it needs. A dialect layer can be added later if multiple domains show a common validation pattern.
**Trade-offs:** No generic "is this feature supported?" check. Domains own their own validation of which YAML constructs they accept.
**Sources:** ForEachExpander.java (adapter pattern decouples domain types), spec §What This Module Does NOT Include (compilation orchestration stays in domains)
**Exploration:** quick
**Status:** captured

## D3: YAML schema composability

**Choice:** JSON Schema fragment files — each primitive ships a reusable schema fragment that domains compose via `$ref`
**Alternatives:**
- Document vocabulary only — simpler but no reusable schema artifacts
- Programmatic schema model (Java SchemaContribution interface) — flexible but heavier, potential J2CL conflict
**Rationale:** JSON Schema is standard, enables IDE validation and documentation generation, pure resource files with no runtime cost. Fragments are composable via `$ref` and `allOf`. Domains build their full YAML schema by referencing the primitives they support.
**Trade-offs:** Schema fragments must be maintained alongside Java code. Schema changes lag behind code changes if not tested.
**Sources:** YAML vocabulary analysis (forEach/when/iterations/data surface constructs)
**Exploration:** quick
**Depends on:** D2 (toolbox — schema fragments are the declaration-side complement)
**Status:** captured

## D4: CSV data source — in scope

**Choice:** Include CSV typed data source (Primitive 4) in the initial implementation
**Alternatives:**
- Defer to follow-up — keeps first PR focused on porting existing code only
**Rationale:** Integration with VariableResolver (eachRowContext) and ForEach is designed. Doing it now avoids a second round of VariableResolver API changes. Pure Java, no extra deps.
**Trade-offs:** First PR is larger. CSV is new untested functionality (no existing production code to port).
**Sources:** spec §Primitive 4
**Exploration:** quick
**Status:** captured

## Spec corrections (from source code analysis)

These are not alternatives-explored decisions — they're corrections to the parent spec based on reading the actual source code.

### C1: ForEachAdapter is NOT @FunctionalInterface
The spec marks it `@FunctionalInterface` but it has 4 abstract methods. Remove the annotation.

### C2: VariableResolver drops dual resolve/resolveTemplate API
The existing code has two modes: `resolveString` (throws on match/fault) and `resolveTemplateString` (passes through non-var prefixes). The spec's `deferredPrefixes` replaces both — domains create resolvers with the right deferred config for each context. No separate template methods needed.

### C3: VariableSource null contract and chain compositor
`VariableSource.resolve()` returns `null` for "not found." Add `static VariableSource chain(VariableSource... sources)` to the interface for composing ordered fallback chains.

### C4: ForEachExpander uses static methods
Existing code is all static. No state to hold. Generic type goes on the method: `static <E> ExpansionResult<E> expand(...)`.

### C5: CsvParser — single parse method
`parseFile()` adds nothing over `parse()`. One method: `static CsvDataSource parse(String name, String csvContent)`.

### C6: Add resolve(Object) polymorphic dispatch
Exists in the current VariableResolver, missing from the spec. Convenience method that dispatches to resolveString/resolveMap/resolveList based on runtime type.
