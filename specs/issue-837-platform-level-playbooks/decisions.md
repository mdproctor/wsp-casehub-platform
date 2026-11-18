## D1: Content taxonomy and directory structure

**Choice:** Top-level `tutorials/` and `examples/` as peers. `tutorials/` holds progressive and deep-dive teaching material. `examples/` holds use-case demonstrations organized by medium: `examples/playbooks/` (playbook use cases + capability matrix) and `examples/java/` (Java SDK use cases + capability matrix). The capability matrix cross-references tutorials. Current `playbooks/` module content moves to `examples/playbooks/`. `docs/examples/` content relocates into `examples/`. Use cases can mirror across playbooks and java.

**Alternatives:**
- Everything under `examples/` (tutorials nested inside) — cross-referencing direction feels odd when examples point inward to their own children
- Keep `playbooks/` as-is — mixes learning content taxonomy with module naming

**Rationale:** Tutorials are the "textbook chapters" (teach concepts). Examples are the "lab exercises" (demonstrate concepts applied). Examples cross-reference into tutorials. As siblings, the references flow naturally.

**Trade-offs:** Two top-level directories for learning content instead of one. Worth it for clean cross-referencing.

**Sources:** Existing `playbooks/` structure, `docs/examples/`, pages repo `tutorials/`, direction doc (parent#540)

**Exploration:** quick

**Status:** captured

## D2: Capability scoping for platform levels

**Choice:** Platform levels use only capabilities from the platform repo — step types, decorators, flow control, coordination primitives, orchestration, agent sessions. No domain modules (ledger, engine, work items, cases). Each repo writes its own levels for its own capabilities.

**Alternatives:**
- Cross-repo levels that build a full application — creates coupling between repos and breaks independent level progression

**Rationale:** Each repo owns its conformance suite. Platform levels prove the platform executor works. Engine levels (separate repo) prove engine capabilities on top.

**Trade-offs:** Early levels may feel abstract without domain context, but that's the point — platform is the foundation.

**Sources:** Issue #837 body (depends on prior platform work steps), user clarification

**Exploration:** quick

**Status:** captured

## D3: Scenario threading approach

**Choice:** Use-case examples (data-pipeline, api-integration, case-processing) with a capability matrix. Each use case naturally exercises multiple capabilities. Together they cover the full surface. The matrix cross-references which capabilities and tutorial levels each example demonstrates. Use all three proposed scenarios rather than forcing one through all levels.

**Alternatives:**
- Single scenario throughout — some capabilities feel forced into the narrative
- Numbered levels with one concept each — ends up mirroring reference categories without adding value

**Rationale:** Same model as Java examples: folder of use cases + capability matrix. The matrix makes it clear what levels/capabilities are demonstrated by each use case. Realistic examples that happen to demonstrate capabilities.

**Trade-offs:** No single linear progression — reader navigates via matrix. This is the intended design.

**Sources:** User direction, Java examples convention

**Exploration:** quick

**Status:** captured

## D4: Tutorial naming convention

**Choice:** Leveled tutorials use numbered prefix + category name: `01-basic-steps/`, `02-captures/`, `03-flow-control/`, etc. Number provides ordering, name provides discoverability. Each tutorial directory is a grouping (e.g., `tutorials/platform-playbooks/01-basic-steps/`).

**Alternatives:**
- Unnumbered directories with ordering in a manifest file — discoverable but ordering isn't visible in filesystem
- Pure numeric directories — ordering visible but meaningless names

**Rationale:** Filesystem ordering matches learning order. A reader can `ls` the directory and see the progression. The name tells them what they'll learn without opening files.

**Trade-offs:** Renaming or reordering levels requires renumbering directories. Acceptable for content that stabilises quickly.

**Sources:** Common convention in framework tutorials (Rust book, Django tutorial)

**Exploration:** quick

**Status:** captured
