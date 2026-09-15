## D1: Approach for Spring REST parity of non-domain @Path resources

**Choice:** Core-extract business logic to -core POJOs + hand-write thin Spring @RestControllers. All 6 resources (5 non-trivial + EventTypeResource).
**Alternatives:**
- Hand-write Spring controllers directly — duplicates business logic, ongoing maintenance burden
- Improve rest-spring-generator — significant engineering effort, different issue scope (generator handles only single-delegate, no Response, no Instance<>, no @Context)
**Rationale:** Follows the established core extraction pattern used 34+ times across the platform. Creates shared business logic usable by both frameworks. Hand-written thin wrappers are trivial to maintain.
**Sources:** rest-spring-generator source (RestResourceScanner.java line 62-77 — single-delegate limitation), GE-20260910-fc414e (Consumer<T> callback pattern for Event<T>)
**Trade-offs:** More upfront work than hand-writing Spring controllers directly. But the extraction also improves the JAX-RS side — resources become thinner and more testable.
**Exploration:** quick
**Status:** captured
