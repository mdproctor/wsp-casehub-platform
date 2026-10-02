# HANDOFF — casehub-platform

## Last Session

Completed pages#359, designed pages#390 (spec under review).

**pages#359 — Spotlight targeting for table rows (DONE).**
Added `aria-label` to PagesDataTable rows from `getRowKey`, public
`scrollToRow(predicate)` API, and `scroll-to-row` scenario command
with key/column+value/index lookup modes. 4 commits on pages repo:
`c2716ad9` (aria-label), `97b2aa53` (scrollToRow), `89b7a519`
(step definition), `87ce53ac` (command executor). All tests pass
(297 table, 19 executor). Issue closed.

**pages#390 — Scenario format refinements (DESIGNED, not implemented).**
Deep first-principles analysis led to a scope expansion: instead of
refining the bespoke Java parser, delete both parsers (ScenarioParser
Format A + HierarchicalParser) and write a single ScenarioEnvelopeParser
that delegates step resolution to the standard Walker/plugin catalog.

Key decisions (D18-D26 in decisions.md):
- Compact step syntax (action-name-as-key) is canonical — same as
  engine `do:` blocks and TS Walker
- Three plugin categories: AriaStep, ScenarioStep, ScenarioStructure
- All step types use yaml-plugin-api
- Speed default: omitted = no delay (opt-in pacing)
- REST/GraphQL become standard step plugins
- `target` naming resolves naturally (flat ARIA fields + decorator)
- `do:` replaces `steps:` in scenario YAML

Spec at `specs/epic-502-yaml-parity/2026-10-02-scenario-format-refinements-design.md`.
Standard design review was launched but timed out — needs re-running.

## Immediate Next Step

1. Re-run the design review for pages#390 spec (timed out)
2. After review passes, invoke writing-plans for pages#390
3. Implementation is substantial: delete 6 Java files, write envelope
   parser, adapt dispatchers as plugins, migrate YAML files, TS changes

## Parked

- **Playbook naming unification** — rename steps/scenarios/playbook to
  "playbook" consistently across all repos. Deferred to after the YAML
  parity epic completes. See `specs/epic-502-yaml-parity/parking-lot.md`.

## Slot Repos

Slot 210:
- `slots/210/platform` — no new commits this session (design work in workspace)
- `slots/210/pages` — 4 new commits on `epic-502-yaml-parity` (pages#359)
- `slots/210/engine` — no new commits
- `slots/210/work` — no new commits

## References

- `.plan` — queue at position 24/31, active issue pages#390
- pages#359 spec: `specs/epic-502-yaml-parity/2026-10-02-spotlight-table-rows-design.md`
- pages#359 plan: `plans/2026-10-02-spotlight-table-rows.md`
- pages#390 spec: `specs/epic-502-yaml-parity/2026-10-02-scenario-format-refinements-design.md`
- Decisions D18-D26: `specs/epic-502-yaml-parity/decisions.md`
- Parking lot: `specs/epic-502-yaml-parity/parking-lot.md`
