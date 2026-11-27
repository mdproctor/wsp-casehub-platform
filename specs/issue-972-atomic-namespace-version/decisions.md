# Decisions — #972 Atomic Namespace Version Safety

## D1: Mismatch policy

**Choice:** Match against dispatch-time version — the agent fulfilled the contract it was given
**Alternatives:**
- Advisory not hard failure — match current, produce advisory on failure. Defers decision downstream.
- Dual match — try current first, fall back to dispatch-time. Ambiguous which result to trust.
**Rationale:** The commitment was opened under a specific corpus version. The agent conformed to that version's templates. Rejecting a valid DONE because the vocabulary changed mid-flight is an infrastructure failure, not an agent failure.
**Trade-offs:** Requires the registry to retain previous versions. Slightly more memory per namespace.
**Sources:** casehubio/qhorus#543 adversarial review, InMemoryTemplateRegistry.java
**Exploration:** quick
**Status:** captured

## D2: Version identifier type

**Choice:** Monotonic long, incremented by the registry on each replaceOrRegister
**Alternatives:**
- Content hash (SHA-256) — deterministic but not ordered, can't tell which is newer
- Both (monotonic + hash) — covers all use cases but more complex than needed
**Rationale:** Simple, ordered, comparable. Easy to store in commitment metadata. Ordering lets the registry know which direction the version moved.
**Trade-offs:** Requires a counter in the registry (not content-addressable). Two identical namespaces registered sequentially get different versions.
**Sources:** TemplateNamespace.java (no version field currently)
**Exploration:** quick
**Status:** captured

## D3: Retention strategy

**Choice:** Registry retains N previous versions per namespace (bounded ring in the Snapshot)
**Alternatives:**
- Commitment stores full snapshot — larger commitment state, zero registry complexity
- External VersionedNamespaceStore SPI — more flexible but adds an SPI boundary
**Rationale:** The Snapshot CAS pattern already provides atomicity. Embedding the ring inside the Snapshot means current + history stay consistent in a single CAS swap. No separate data structure to coordinate.
**Trade-offs:** Bounded memory — commitments older than N versions back can't resolve. Default N=3 covers typical deployment cadence.
**Sources:** InMemoryTemplateRegistry.Snapshot (CAS pattern), issue description
**Exploration:** quick
**Depends on:** D2 (version identifier used as ring key)
**Status:** captured

## D4: Version in match result

**Choice:** Add version to TemplateMatch.Matched so callers can record it
**Alternatives:**
- Version stays internal — callers obtain version separately
**Rationale:** The match result is the natural place to surface version. Callers (qhorus commitment opening) need the version at match time to store in commitment metadata. Also exposed as `_tmatch.version` in playbook variable scope.
**Trade-offs:** Breaking change to TemplateMatch.Matched record (new field). All pattern matches on Matched need updating.
**Sources:** TemplateMatch.java, StructuralStepEvaluator.java:376-419
**Exploration:** quick
**Depends on:** D2 (version identifier type)
**Status:** captured

## D5: History location

**Choice:** Version ring embedded in the atomic Snapshot
**Alternatives:**
- Separate ConcurrentMap for history — simpler per-structure but requires coordination between two independent stores
**Rationale:** Atomic consistency comes free from the existing Snapshot CAS pattern. No separate data structure needed.
**Trade-offs:** Snapshot becomes slightly larger (holds ring per namespace). Acceptable given bounded ring size.
**Sources:** InMemoryTemplateRegistry.Snapshot inner class
**Exploration:** quick
**Depends on:** D3 (retention strategy)
**Status:** captured
