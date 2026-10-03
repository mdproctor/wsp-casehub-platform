# HANDOFF — casehub-platform

## Last Session

Completed pages#466 (Single-source YAML scenarios for tutorials and showcase gallery).

**What was built (3 commits on pages repo, 4 on platform workspace):**

1. `42769b38` — Extract 48 scenario YAML files from 8 showcase companion scripts
   - Created `scenarios/` directory with 8 category subdirectories
   - 48 `.scenario.yaml` files extracted from inline JS string arrays
   - Created `scripts/generate-scenario-manifest.js` + `scripts/validate-scenarios.js`
   - Generated `scenarios/manifest.json` (48 entries, 8 categories)

2. `9cca7597` — Migrate 4 showcase scripts to load YAML from shared scenario files
   - Flow Control, Coordination, Composition, Data Delivery scripts modified
   - Inline YAML replaced with async `fetch()` from `scenarios/manifest.json`
   - Custom UI preserved (queue-state dots, trigger panels, injection views)
   - 474 deletions, 181 insertions — net -293 lines of inline YAML

3. `7d8e1ae6` — Add scenario-ref support to tutorial host
   - Added `scenarioRef?: string` to `TutorialSection` interface
   - Parser passes through `scenario-ref` from YAML sections
   - Tutorial host fetches referenced `.scenario.yaml`, displays code viewer + Run button
   - Test added and passing (14/14 tutorial host tests green)

**Scope adjustment:** Plan originally called for one generic companion script
replacing all 8. Investigation found only 4 scripts use `parseScenario()`;
the other 4 use `createStepRunner` with pre-built step objects (YAML is
display-only). Adjusted to per-script migration for the 4 parseScenario
scripts, keeping all custom UI logic.

**Test results:** 14 tutorial host tests green. Showcase scripts untestable
in CI (require browser runtime with Pages bundle).

## Immediate Next Step

pages#466 is complete. Queue advanced to platform#424.

Next queue items:
1. **casehubio/platform#424** — Generated typed event dispatch Layer 3
2. **casehubio/platform#487** — Separate parsed structure from catalog
3. **casehubio/platform#502** — Epic YAML cross-repo parity
4. **casehub-pages#502** — Epic YAML playbook ops
5. **casehub-pages#508** — Complete type unification
6. **casehub-pages#514** — Delete remaining Format A types

## Key Design Decisions

- **D27-D31** in `specs/epic-502-yaml-parity/decisions.md`
- **Shared directory** (`scenarios/`) at repo root, not alongside samples
- **Existing meta format** reused (ScriptMeta) — no new format
- **Tutorial inline steps stay** — scenario-ref is additive, not a replacement
- **4 of 8 scripts migrated** — the 4 createStepRunner scripts (Coordination
  Primitives, Concurrency Patterns, Step Workflows, Invoke Bindings) still
  embed display-only YAML. They could be migrated later but the ROI is lower.

## Slot Repos

Slot 210:
- `slots/210/pages` — 3 new commits on `epic-502-yaml-parity` (pages#466)
- `slots/210/platform` — no new commits this session
- `slots/210/engine` — no new commits
- `slots/210/work` — no new commits

## References

- `.plan` — queue at position 26/32, platform#424 active
- Design spec: `specs/epic-502-yaml-parity/2026-10-03-single-source-scenarios-design.md`
- Implementation plan: `plans/2026-10-03-single-source-scenarios.md`
- Decisions D27-D31: `specs/epic-502-yaml-parity/decisions.md`
- Issue closed: casehub-pages#466
