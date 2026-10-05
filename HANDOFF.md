# HANDOFF — casehub-platform

## Last Session

Working on platform#510 (Playbook naming unification) — Phase 1 infrastructure complete.

**What was built:**

### Platform repo (3 commits on `epic-502-yaml-parity`)

1. `16542d02` — PlaybookFrontMatter types + PlaybookParser
   - `PlaybookFrontMatter`, `PlaybookDocument`, `PlaybookSchemas` records in yaml-core (zero-dep)
   - `PlaybookParser` in yaml-step-runtime — multi-doc YAML splitting, front matter extraction
   - `ScenarioParser.parseYaml()` refactored to delegate to PlaybookParser
   - Full backward compat for files without `playbook:` header

2. `2de1e7e4` — PlaybookSchemaRegistry and capability model
   - `PlaybookSchemaDescriptor` with capability sets
   - `PlaybookCapabilities` constants (shared, client-only, server-only)
   - `PlaybookSchemaRegistry` SPI + `MapPlaybookSchemaRegistry` implementation
   - Pre-registers `client` and `server` built-in schemas

3. `19f58cd3` — playbook.schema.json
   - JSON Schema (Draft 2020-12) for front matter validation

### Pages repo (2 commits on `epic-502-yaml-parity`)

1. `17e9b28e` — PlaybookFrontMatter types in TS yaml-core
   - `PlaybookFrontMatter`, `PlaybookDocument` interfaces
   - `parsePlaybookFrontMatter()`, `isBuiltInSchema()`, `isDomainSchema()`
   - Exported from `@casehubio/yaml-core`

2. `0783d1ac` — PlaybookSchemaRegistry in TS yaml-core
   - `PlaybookSchemaDescriptor`, `PLAYBOOK_CAPABILITIES`
   - `createPlaybookSchemaRegistry()`, `domainSchema()`

**Build verification:**
- Platform: 760 yaml-core tests + 341 yaml-step-runtime tests pass
- Pages: 30 playbook tests pass

## Phase 2 (not started)

File migration — rename `.yaml` → `.playbook.yaml` across repos, add front matter to existing files. Repos with YAML files: platform (test), casehub-pages (~17 files), aml (6 files), clinical (1 file). YAML is actively being edited by others — coordinate timing.

## Immediate Next Step

Continue platform#510 Phase 2, or advance to:
1. **casehub-pages#518** — TS front matter parser + scenario migration
2. **casehub-pages#519** — Annotate spec docs with new type names

## Slot Repos

Slot 210:
- `slots/210/platform` — 7 commits on `epic-502-yaml-parity` (prior + platform#510)
- `slots/210/pages` — 5 commits on `epic-502-yaml-parity` (prior + platform#510)
- `slots/210/engine` — no new commits
- `slots/210/work` — no new commits

## References

- `.plan` — queue at position 32/35, platform#510 active
- Design spec: `wsp-casehub-platform/specs/epic-502-yaml-parity/2026-10-04-type-unification-design.md`
- Implementation plan: `wsp-casehub-platform/plans/2026-10-04-type-unification.md`
- Decisions: D37-D39 in `specs/epic-502-yaml-parity/decisions.md`
