## D1: Content taxonomy and directory structure

**Choice:** Top-level `tutorials/` and `examples/` as peers in each repo. `tutorials/` holds progressive and deep-dive teaching material. `examples/` holds use-case demonstrations: `examples/playbooks/` (playbook use cases + capability matrix) and `examples/java/` (Java SDK use cases + capability matrix). Capability matrix cross-references tutorials. Current `playbooks/` module content moves to `examples/playbooks/`. `docs/examples/` content relocates into `examples/`. Pages repo already has `tutorials/` with this convention.

**Alternatives:**
- Everything under `examples/` — works for aggregation but tutorials are conceptually peers, not children
- Keep `playbooks/` as-is — mixes learning content taxonomy with module naming

**Rationale:** Tutorials teach concepts. Examples demonstrate concepts applied. As siblings, cross-references flow naturally.

**Trade-offs:** Two top-level directories for learning content. Worth it for clean cross-referencing.

**Sources:** Existing `playbooks/` structure, pages repo `tutorials/`, direction doc (parent#540)

**Exploration:** quick

**Status:** captured

## D2: Capability scoping — hybrid contribution model

**Choice:** Each repo contributes levels using only its own capabilities (self-contained, no cross-repo dependencies). Platform levels use platform capabilities + simulation framework for domain stubs. Cross-cutting examples that need multiple repos live standalone in casehub-examples (like helpdesk). casehub/examples submodules all contributing repos and builds a unified navigation/explorer across them.

**Alternatives:**
- All levels in one repo — coupling, single point of failure
- Levels only in casehub-examples — repos lose ownership of their conformance suites

**Rationale:** Repos own their conformance suite (LD-1). Cross-cutting examples that compose multiple repos are a separate concern, owned by the aggregator. Platform simulation framework stubs domain context where needed.

**Trade-offs:** Platform levels use simulated domain context rather than real domain modules. Keeps them self-contained.

**Sources:** Issue #837, casehub/examples aggregator architecture, helpdesk prototype

**Exploration:** quick

**Status:** captured

## D3: Use-case examples with capability matrix

**Choice:** Use-case examples (data-pipeline, api-integration, case-processing) under `examples/playbooks/` with a capability matrix. Each use case exercises multiple capabilities. Matrix cross-references which capabilities and tutorial levels each example demonstrates. Same model as Java examples: folder of use cases + matrix. Use cases can mirror across playbooks and java.

**Alternatives:**
- Isolated single-pattern reference examples — already exist as the current `playbooks/` categories; use cases add realistic context
- Numbered levels as examples — mirrors reference categories without adding value

**Rationale:** Realistic examples that happen to demonstrate capabilities. The matrix is the navigation.

**Trade-offs:** No single linear progression in examples — reader navigates via matrix. Tutorials provide the linear progression.

**Sources:** User direction, Java examples convention

**Exploration:** quick

**Status:** captured

## D4: Tutorial naming convention

**Choice:** Leveled tutorials use numbered prefix + category name: `01-basic-steps/`, `02-captures/`, `03-flow-control/`, etc. Number provides ordering, name provides discoverability. Grouped under a tutorial track (e.g., `tutorials/platform-playbooks/01-basic-steps/`).

**Alternatives:**
- Unnumbered with manifest — ordering not visible in filesystem
- Pure numeric — meaningless names

**Rationale:** Filesystem ordering matches learning order. Consistent with pages repo convention.

**Trade-offs:** Renumbering on reorder. Acceptable for content that stabilises quickly.

**Sources:** Pages repo `tutorials/` convention, common framework pattern

**Exploration:** quick

**Status:** captured

## D5: Platform also hosts yaml-composition tutorial

**Choice:** Platform repo includes a `tutorials/yaml-composition/` tutorial track alongside `tutorials/platform-playbooks/`. yaml-core is a platform module — the canonical composition language tutorial belongs with its runtime.

**Alternatives:**
- yaml-composition only in pages — but yaml-core is a platform module
- Single shared tutorial referenced from both — complex cross-repo dependency

**Rationale:** The composition language is platform infrastructure. Platform teaches it in the playbook context. Pages teaches it in the page-building context.

**Trade-offs:** Two tutorials covering overlapping yaml-core content. Acceptable because application context differs.

**Sources:** yaml-core module ownership, pages `tutorials/yaml-composition/`

**Exploration:** quick

**Status:** captured

## D6: Server-side level execution model

**Choice:** Level playbooks execute server-side. The user experience is: show the YAML, execute server-side, show results back. Platform levels are tested headlessly via `.test.yaml` conformance tests. The TS browser runtime in pages is scoped to teaching the playbook language (composition, syntax) — not orchestration. Real orchestration (agents, coordination, REST calls) is always server-side.

**Alternatives:**
- All levels in browser via TS runtime — only works for language-level features, not orchestration
- Separate browser levels and server levels — fragments the progression

**Rationale:** The browser runtime teaches language mechanics. Server execution teaches real orchestration. These are different capability tiers, naturally split between pages (browser) and platform (server).

**Trade-offs:** Server-side levels don't have interactive browser visualization. The "show YAML + show results" pattern (like helpdesk) provides the experience.

**Sources:** Pages TS playbook runtime scoping, helpdesk example pattern

**Exploration:** quick

**Status:** captured
