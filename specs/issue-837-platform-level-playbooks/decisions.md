## D1: Content taxonomy — tutorials and examples as peers

**Choice:** Top-level `tutorials/` and `examples/` as peers in each repo. `tutorials/` holds progressive and deep-dive teaching material. `examples/` holds use-case demonstrations: `examples/playbooks/` (playbook use cases + capability matrix) and `examples/java/` (Java SDK examples + capability matrix). Capability matrix cross-references tutorials. Pages repo already has `tutorials/` with this convention.

**Rationale:** Tutorials teach concepts. Examples demonstrate concepts applied. As siblings, cross-references flow naturally.

**Status:** captured

## D2: Hybrid contribution model

**Choice:** Each repo contributes levels using only its own capabilities (self-contained). Cross-cutting examples that need multiple repos live standalone in casehub-examples. casehub/examples submodules all contributing repos and builds unified navigation/explorer.

**Rationale:** Repos own their conformance suite (LD-1). Cross-cutting composition owned by aggregator.

**Status:** captured

## D3: Use-case examples with capability matrix

**Choice:** Use-case examples with capability matrix. Same model as Java examples: folder of use cases + matrix cross-referencing capabilities and tutorial levels.

**Status:** captured

## D4: Tutorial naming convention

**Choice:** Leveled tutorials use numbered prefix + category name: `01-basic-steps/`, `02-captures/`, etc. Number provides ordering, name provides discoverability.

**Status:** captured

## D5: yaml-composition tutorial belongs with yaml-core

**Choice:** yaml-core is a platform module. The composition language tutorial belongs with its runtime. Pages has its own context-specific version for page-building.

**Status:** captured

## D6: Server-side level execution model

**Choice:** Level playbooks execute server-side. Show YAML, execute, show results. TS browser runtime in pages is scoped to teaching the playbook language (composition, syntax) — not orchestration.

**Status:** captured

## D7: No tutorials in platform repo

**Choice:** Platform is pure infrastructure — its capabilities are best taught where they're applied. No tutorials or progressive level playbooks in the platform repo. Platform concepts (steps, flow control, coordination, agents) are taught in downstream repos (engine, agency, connectors) and casehub-examples where domain context makes them meaningful.

**Alternatives:**
- Platform-hosted tutorials with simulated domain stubs — abstract, can't show UI, duplicates TS browser content
- yaml-composition tutorial in platform — needs interactive editor UI only pages provides
- Agent config examples without domain context — meaningless without eidos

**Rationale:** Every platform capability audit reached the same conclusion: the concept is best taught where it's consumed, not where it's implemented. Platform provides the runtime, SPIs, and reference docs. Teaching happens downstream.

**What platform DOES provide:**
- Format standard for levels (the spec that all repos follow)
- Reference playbook patterns (existing `playbooks/`, tested headlessly)
- Java examples and config examples (under `examples/`)
- Reference docs (SPI documentation, config guides)

**Sources:** Full platform capability audit, build order analysis, TS browser runtime scoping, helpdesk prototype in casehub-examples

**Exploration:** deep-analysis (iterative across multiple questions)

**Status:** captured
