# Decisions — #828 WS-1: Canonical runner + finish inert features

## D1: Inert features — implement or remove

**Choice:** Implement both on-error and transform
**Alternatives:**
- Implement on-error only, remove transform — transform lacks a clear use case
- Remove both — re-add when there's a real need and a spec
**Rationale:** Both features are declared in the decorator chain and documented. Implementing them completes the language surface. Transform via expression engine (JQ/MVEL) has a clear contract: apply a transformation to the step result.
**Trade-offs:** Additional implementation work and test surface for transform. Must define a clear contract for what transform does (apply an expression to the result map).
**Sources:** DecoratorChain.java:308-317 (transform no-op), DecoratorChain.java:180-204 (on-error), P34, P35
**Exploration:** quick
**Status:** captured

## D2: Condition fix — injection and Norway problem

**Choice:** ExpressionEngine + strict Truthiness
**Alternatives:**
- ExpressionEngine + keep broad Truthiness — fixes injection but not Norway
- ExpressionEngine + remove Truthiness entirely — breaks playbooks using literal true/false without an engine
**Rationale:** Conditions route through ExpressionEngineRegistry (MVEL default for CONDITION context). Variables bound as data, never substituted into expression text. Truthiness fast-path stays but accepts only literal `true`/`false` — no yes/no/on/off/y/n/1/0. This fixes both the injection vulnerability and the Norway problem while maintaining backward compat for simple boolean conditions.
**Trade-offs:** Playbooks using `when: "yes"` or `when: "1"` will break. This is intentional — pre-release platform, breaking changes cost nothing.
**Sources:** ConditionEvaluator.java, Truthiness.java, P33, LD-4
**Exploration:** quick
**Status:** captured

## D3: Runner location

**Choice:** Move PlaybookRunnerCore to yaml-step-runtime
**Alternatives:**
- Move to playbook-runner module — keeps yaml-step-runtime pure but adds simulation deps to playbook-runner
- New playbook-core module — clean separation but adds a module to a 241-module project for one class
**Rationale:** PlaybookRunnerCore already depends on Walker, CatalogStepRunner, StructuralStepEvaluator which live in yaml-step-runtime. Natural home — it's the runtime that evaluates steps. yaml-test-core becomes a thin test adapter. Simulation dependency handled via constructor injection (optional).
**Trade-offs:** yaml-step-runtime gains a dependency on simulation-api (for SimulationRuntime), but only via constructor injection — no compile-time coupling if simulation isn't present. Module expansion (imports) stays as an optional pluggable interface.
**Sources:** PlaybookRunnerCore.java, PlaybookBeans.java, P32
**Exploration:** quick
**Status:** captured

## D4: Capture scope fix

**Choice:** Evaluator propagates captures from nested steps
**Alternatives:**
- Move capture handling into DecoratorChain — more uniform but changes capture semantics
**Rationale:** StructuralStepEvaluator collects captures from nested steps and merges them into the result. Captures are hierarchical — a capture inside a parallel branch is scoped to the branch name. This matches how the runner uses captures: as a named map of step outputs.
**Trade-offs:** Requires propagating capture information through Result, which means Result needs to carry capture data or the evaluator needs a side-channel (like StepResultStore).
**Sources:** PlaybookRunnerCore.java:130-153, StructuralStepEvaluator.java, P36
**Exploration:** quick
**Status:** captured
