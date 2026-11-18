## D1: Content taxonomy and directory structure

**Choice:** Top-level `tutorials/` and `examples/` as peers in each repo. `tutorials/` holds progressive and deep-dive teaching material (leveled playbooks, yaml-composition). `examples/` holds use-case demonstrations: `examples/playbooks/` (playbook use cases + capability matrix) and `examples/java/` (Java SDK use cases + capability matrix). Capability matrix cross-references tutorials. Current `playbooks/` module content moves to `examples/playbooks/`. `docs/examples/` content relocates into `examples/`. Pages repo already has `tutorials/` with this convention.

**Alternatives:**
- Everything under `examples/` — works for aggregation but tutorials are conceptually peers, not children
- Keep `playbooks/` as-is — mixes learning content taxonomy with module naming

**Rationale:** Tutorials teach concepts. Examples demonstrate concepts applied. As siblings, cross-references flow naturally. The `casehub/examples` aggregator syncs both (sync config updated).

**Trade-offs:** Two top-level directories for learning content. Worth it for clean cross-referencing.

**Sources:** Existing `playbooks/` structure, pages repo `tutorials/`, `casehub/examples` aggregator, direction doc (parent#540)

**Exploration:** quick

**Status:** captured

## D2: Capability scoping — each repo owns its content

**Choice:** Each repo owns tutorials and examples for its own capabilities. Platform levels use only platform capabilities (step types, decorators, flow control, coordination, agent sessions). Content ownership follows capability ownership. Pages renders content interactively after consuming it via the catalog — separation of concerns.

**Alternatives:**
- Cross-repo levels — coupling between repos
- All tutorials in pages — loses headless conformance testing at the platform level

**Rationale:** Each repo's tutorials are its conformance suite (LD-1). Platform tests headlessly. Pages adds interactive rendering. Build order supports this: pages is built after platform.

**Trade-offs:** Early platform levels feel abstract without UI. That's the point — platform proves the runtime; pages proves the experience.

**Sources:** Issue #837, user direction, build order (platform before pages)

**Exploration:** quick

**Status:** captured

## D3: Use-case examples with capability matrix

**Choice:** Use-case examples (data-pipeline, api-integration, case-processing) under `examples/playbooks/` with a capability matrix. Each use case exercises multiple capabilities. Matrix cross-references which capabilities and tutorial levels each example demonstrates. Same model as Java examples: folder of use cases + matrix. Use cases can mirror across playbooks and java.

**Alternatives:**
- Isolated single-pattern reference examples — already exist as the current `playbooks/` categories; use cases add realistic context
- Numbered levels as examples — mirrors reference categories without adding value

**Rationale:** Realistic examples that happen to demonstrate capabilities. The matrix is the navigation — "I want to learn about coordination" → "look at data-pipeline and api-integration."

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

**Choice:** Platform repo includes a `tutorials/yaml-composition/` tutorial track alongside `tutorials/platform-playbooks/`. yaml-core is a platform module — the canonical composition language tutorial belongs with its runtime. Pages has its own yaml-composition tutorial teaching composition in the page-building context.

**Alternatives:**
- yaml-composition only in pages — but yaml-core is a platform module
- Single shared tutorial referenced from both — complex cross-repo dependency

**Rationale:** The composition language is platform infrastructure. Platform teaches it in the playbook context. Pages teaches it in the page-building context. Same language, different application.

**Trade-offs:** Two tutorials covering overlapping yaml-core content. Acceptable because the application context differs meaningfully.

**Sources:** yaml-core module ownership, pages `tutorials/yaml-composition/`

**Exploration:** quick

**Status:** captured
