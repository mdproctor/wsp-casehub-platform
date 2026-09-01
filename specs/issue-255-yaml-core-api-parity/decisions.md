## D1: sourceFor(prefix) + withChainedScope() on VariableResolver

**Choice:** Add both: `VariableSource sourceFor(String prefix)` (primitive — returns registered source or null) and `VariableResolver withChainedScope(String prefix, VariableSource source)` (convenience — chains new source ahead of existing).
**Alternatives:**
- sourceFor only — caller reassembles chain manually; more general but verbose for the overwhelmingly common module-scope-layering case
- withChainedScope only — captures the intent but doesn't expose the raw source for less common patterns
**Rationale:** `withChainedScope("var", moduleScope::get)` captures the actual intent (layer a source ahead of the existing one) rather than exposing an accessor and requiring the caller to reassemble. `sourceFor` is the primitive for less common patterns. Dual API follows the precedent of `validate()` + `validateOrThrow()` from D4/#252.
**Trade-offs:** Two methods where one would suffice. Acceptable — the convenience makes the common case a one-liner.
**Sources:** casehubio/platform#255 §1, casehubio/casehub-desiredstate#128, R1-03 decision review
**Exploration:** quick
**Status:** revised (R1-03 — withChainedScope is more intent-revealing than sourceFor alone)

## D2: IterationValueExpander callback on ForEachExpander

**Choice:** Add `@FunctionalInterface IterationValueExpander` with `List<String> expand(String resolvedValue, String groupContext)`. New overload of `expand()` accepts it. Called after variable resolution on each iteration value — consumer can parse JSON arrays or other formats. Default: single-element list (current behaviour).
**Alternatives:**
- Build JSON parsing into yaml-core — violates zero-dep constraint
- Let consumer pre-process IterationGroups before calling expand — works but duplicates the variable resolution step
**Rationale:** Desiredstate's local expander handles `${config.zones}` → `["us-east","eu-west"]` by detecting JSON array syntax and parsing with Jackson. yaml-core can't add Jackson. The callback lets the consumer provide the parsing without yaml-core knowing about JSON.
**Trade-offs:** One more parameter on expand(). Mitigated by keeping the existing overload as a convenience (null resolver = current behaviour).
**Sources:** casehubio/platform#255 §2, desiredstate ForEachExpander.resolveGroupValues()
**Exploration:** quick
**Status:** captured

## D3: SectionDeserializer + typed rewriter — conversion during expansion

**Choice:** Consumer registers per-section `SectionDeserializer<T>` callbacks that run during expansion, converting raw `Map<String, Object>` entries to typed domain objects before the rewriter runs. `SectionContentRewriter` receives typed objects. `ExpandedModule` provides typed accessor `<T> Map<String, T> section(String name)` that hides the unchecked cast.
**Alternatives:**
- Accept the gap (convert after expansion) — rewriter operates on raw maps, fragile field access via `((Map) entry).get("dependsOn")`, breaks silently on field renames
- Single SectionProcessor combining conversion + rewriting — fewer types but merges two distinct concerns, harder to test independently
- Full generic parameterization `YamlModule<S>` — over-complicates API for multi-consumer use, type parameter propagates through every utility, Jackson TypeReference boilerplate at every parse site
**Rationale:** The rewriter needs typed access — `node.dependsOn()` vs `((Map) entry).get("dependsOn")`. Consumer controls both callbacks (deserializer + rewriter) so the Object storage is safe. Typed accessor on ExpandedModule (`expanded.section("nodes")`) gives clean access — one safe accessor beats scattered casts. Matches the ForEachAdapter pattern: consumer-provided callbacks for domain-specific work, framework handles generic orchestration.
**Trade-offs:** Values stored as Object references internally. The cast in `section()` is unchecked but safe — the consumer registered the deserializer that produced those objects. Without the accessor, every access point becomes a manual cast.
**Sources:** casehubio/platform#255 (issue creator's update on type safety regression), D3 from #252 decisions (generic sections model), desiredstate YamlModule.java (typed fields in local version)
**Exploration:** deep-analysis
**Pipeline timing (R1-01):** Deserialization IS compatible with unresolved variables for domain types that use `Map<String, Object>` or `String` for variable-carrying fields. Desiredstate's `YamlNode` uses `Map<String, Object> spec` — `${var.apiEndpoint}` survives as a string value. Jackson deserializes it fine. This holds for any consumer whose typed records carry variable content in Object-typed fields.
**Boundary shift (R1-02):** Acknowledged. #252 said "section content interpretation stays in the consumer." This decision deliberately shifts that boundary: yaml-core now orchestrates consumer-delegated transformation via callbacks. The boundary is "yaml-core doesn't know the types" (still true — it calls opaque callbacks), not "yaml-core never touches values" (no longer true).
**Depends on:** D3 from #252 (generic sections model — this decision extends the original choice with consumer-delegated typed access)
**Status:** captured (R1-01 resolved, R1-02 acknowledged as deliberate)

## D4: SectionContentRewriter receives typed objects

**Choice:** `SectionContentRewriter` signature changes to receive the deserialized (typed) value instead of raw `Map<String, Object>`. The rewriter runs AFTER deserialization but BEFORE the entry is stored in the result. Consumer casts internally (they know the type from their deserializer registration).
**Alternatives:**
- Rewriter receives raw maps (original #255 proposal) — fragile, verbose, breaks silently on schema changes
**Rationale:** The whole point of D3's SectionDeserializer is to give the rewriter typed access. If the rewriter still receives Object, the deserializer's benefit is limited to the final access pattern. Running deserializer → rewriter → store gives the rewriter typed domain objects with compile-time field access.
**Trade-offs:** Rewriter must cast its `Object entryValue` parameter to the domain type. This is a single cast at the top of the rewriter, not scattered casts per field access. Acceptable.
**Sources:** casehubio/platform#255 §3, desiredstate ModuleExpander (operates on typed YamlNode for dependency rewriting)
**Exploration:** quick
**Depends on:** D3 (SectionDeserializer provides typed objects to the rewriter)
**Status:** captured
