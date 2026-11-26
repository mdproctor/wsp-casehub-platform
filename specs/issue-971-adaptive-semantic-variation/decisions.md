## D1: Variation persistence strategy

**Choice:** In-memory only — variations stored in the registry's existing immutable snapshots, lost on restart
**Alternatives:**
- YAML corpus persistence (#969) — durable across restarts, but #969 isn't implemented yet and adds serialization scope
- Pluggable DataStore SPI — future-ready but SPI doesn't exist yet
**Rationale:** Keeps #971 focused on the semantic matching pipeline. The registry already uses immutable snapshots in memory; seeded/learned variations just add more patterns. Persistence is a separate concern.
**Trade-offs:** Variations lost on restart. LLM re-seeds on next startup (batch, cheap). Runtime-learned variations must be re-learned.
**Sources:** Issue #969, InMemoryTemplateRegistry snapshot model
**Exploration:** quick
**Status:** captured

## D2: Seeding integration with registration

**Choice:** Explicit seeder call before register — callers seed variations externally and add them as extra patterns to the TemplateDefinition before calling register()
**Alternatives:**
- Registry-integrated seeding — register() accepts/holds a VariationSeeder reference, triggers seeding internally. Tighter coupling, simpler for callers.
- Post-registration enrichment — register canonical first, then enrichWithVariations() adds seeded patterns. Two-step, allows async.
**Rationale:** Preserves the registry's zero-dep contract. The LLM concern stays at the boundary (caller/wiring layer), not inside the matching engine. The registry doesn't need to know whether patterns came from a human, YAML, or LLM — they're all just patterns.
**Trade-offs:** Callers must orchestrate seeding + collision checking + registration themselves. Slightly more wiring code.
**Depends on:** D1 (in-memory — no persistence layer to coordinate with)
**Sources:** UnifiedTemplateRegistry SPI, InMemoryTemplateRegistry.register(), template-registry-api zero-dep constraint
**Exploration:** quick
**Status:** captured

## D3: Learned variation mutation strategy

**Choice:** Atomic replace via deregister + re-register — the adaptive fallback builds a new TemplateNamespace including original patterns plus the learned variation, then atomically swaps via deregister(ns) + register(expandedNs)
**Alternatives:**
- New addVariation() method on the registry SPI — cleaner caller API but changes the SPI contract and needs a new snapshot operation
- Separate variation overlay — learned variations in a parallel structure, match checks main then overlay. No mutation of original namespace but adds query complexity
**Rationale:** Requires zero SPI changes. The existing deregister + register pair already provides atomic namespace replacement (#967). Learned variations are just patterns, same as seeded ones. The immutable-snapshot concurrency model means readers see either old or new state, never torn.
**Trade-offs:** Brief logical gap between deregister and register — but CAS retry handles contention. Rebuilds the entire namespace snapshot for each learned variation (acceptable: learning is rare, O(templates) not O(corpus)).
**Depends on:** D2 (variations are patterns — no distinction between seeded and learned in the registry)
**Sources:** InMemoryTemplateRegistry.Snapshot, issue #967 (atomic namespace replace)
**Exploration:** quick
**Status:** captured
