## D1: Content taxonomy and directory structure

**Choice:** Rename `playbooks/` module to `examples/` with three sections: `tutorials/` (progressive levels), `reference/` (pattern lookup by capability, current playbook categories), `java/` (Java SDK examples with capability matrix). Deep-dive tutorials (like yaml-composition) also live under `tutorials/`. `docs/examples/` content relocates into `examples/`.

**Alternatives:**
- Keep `playbooks/` as-is, add `levels/` inside — mixes two navigation intents (learning vs lookup) in one flat directory
- Separate top-level `tutorials/` and `examples/` directories — fragments learning content across two roots

**Rationale:** "Examples" is the umbrella for everything you run to learn. The subdirectory tells you the learning mode: progressive (tutorials), lookup (reference), or code (java). File extensions (`.playbook.yaml`, `.java`) indicate the medium.

**Trade-offs:** Renaming `playbooks/` to `examples/` is a module rename that touches pom.xml, CI, and any imports. Worth it for a coherent taxonomy.

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

**Choice:** Use multiple connected scenarios across levels rather than forcing one scenario through all levels. The story arc evolves (e.g., build a data pipeline → monitor the services it calls → alert when things go wrong). Each phase naturally fits the capabilities being taught at that stage.

**Alternatives:**
- Single scenario throughout — some capabilities feel forced into the narrative
- Independent unrelated scenarios per level — no learning continuity

**Rationale:** "Why not all 3? Do one then the other." — each scenario phase naturally exercises the capabilities at its complexity tier. The connected arc provides continuity without forcing fit.

**Trade-offs:** Slightly harder for a reader to track than a single scenario, but each phase builds on the world the previous one established.

**Sources:** User direction, direction doc threading requirement

**Exploration:** quick

**Status:** captured
