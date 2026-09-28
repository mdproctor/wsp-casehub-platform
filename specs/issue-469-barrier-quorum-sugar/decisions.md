## D1: Step name propagation through ResolvedStep

**Choice:** Add `name` field to the sealed interface
**Alternatives:**
- Wrapper record (`NamedStep`) — breaks pattern match in dispatchStep, adds unwrap ceremony
- Side-channel map — fragile pairing, has to be threaded through evaluator separately
**Rationale:** The sealed hierarchy is the natural home for step metadata. A default-null `name()` method on the interface means existing callers are unaffected. Step name duplicate validation in StepWalker comes almost free since we're already extracting the name.
**Trade-offs:** All 8 record variants gain a `name` parameter (nullable). Minor signature change but no behavioral change for existing code.
**Sources:** yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java, yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepWalker.java:80-81
**Exploration:** quick
**Status:** captured

## D2: Barrier/quorum as structural step types

**Choice:** New ResolvedStep variants (BarrierStep + QuorumStep)
**Alternatives:**
- Decorator-style — semantically wrong; barrier/quorum are coordination points, not step modifiers. A barrier with no body is valid.
- Generic LatchStep — fewer types but worse YAML readability; barrier and quorum have different failure semantics (barrier: failure counts toward countdown; quorum: failure does NOT count toward threshold)
**Rationale:** Barrier and quorum are distinct coordination concepts matching the pattern of block/parallel/select as first-class structural step types. StepWalker validation is specific per type. The YAML reads naturally.
**Trade-offs:** Two new sealed permits + two new evaluator methods. Modest code growth but clear separation.
**Sources:** issue-386 §2.2 Latch spec, yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java
**Exploration:** quick
**Status:** captured

## D3: Result ObjectVariableSource registration

**Choice:** Evaluator registers on first evaluate() call
**Alternatives:**
- Caller registers before evaluation — pushes ceremony onto every caller, risks forgetting
- ScenarioScope registers it — wrong dependency direction (yaml-core shouldn't know VariableResolver API shape)
**Rationale:** The evaluator is the natural integration point — holds both the scope (which owns the result store) and receives the resolver (which needs the prefix). Lazy registration means no-scope evaluation works unchanged.
**Trade-offs:** The evaluator gains registration responsibility. Slightly more coupling but the evaluator already couples scope and resolver.
**Sources:** yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java:38-45, yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java:48
**Exploration:** quick
**Status:** captured
