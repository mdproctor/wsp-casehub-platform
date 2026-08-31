## D1: ExpansionResult returns Map<String, E> instead of List<E>

**Choice:** Replace `List<E> elements` with `LinkedHashMap<String, E> elements` in `ExpansionResult`
**Alternatives:**
- Both fields (`List<E>` + `Map<String, E> elementsById`) — non-breaking but redundant data structures
- Wrapper record (`List<ExpandedElement<E>>`) — explicit but adds a type and forces unwrapping
**Rationale:** The expander already computes the stampedId for every element — it's passed to `adapter.stamp()`. Dropping it from the result was the bug. `LinkedHashMap<String, E>` is the natural return type — ordered, keyed, no wrapper. Callers that just need iteration use `.values()`.
**Trade-offs:** Breaking change — existing callers of `result.elements()` must update from `List` to `Map`. Only one caller exists (the test suite in yaml-core itself), so migration cost is zero within the module.
**Sources:** casehubio/platform#253, ForEachExpander.java (stampedId already computed at line 104), casehubio/casehub-desiredstate#128 (migration identified the regression)
**Exploration:** quick
**Status:** captured
