# HANDOFF — casehub-platform

## Last Session

Completed 3 issues in one session, completing the epic-502-yaml-parity queue (35/35).

### platform#510 — Playbook naming unification (Phase 1)

**Platform (3 commits):**
- `16542d02` — PlaybookFrontMatter/PlaybookDocument/PlaybookSchemas in yaml-core + PlaybookParser in yaml-step-runtime + ScenarioParser refactored
- `2de1e7e4` — PlaybookSchemaRegistry SPI, PlaybookCapabilities, MapPlaybookSchemaRegistry with client/server built-ins
- `19f58cd3` — playbook.schema.json (Draft 2020-12)

**Pages (2 commits):**
- `17e9b28e` — TS PlaybookFrontMatter types + parsePlaybookFrontMatter()
- `0783d1ac` — TS PlaybookSchemaRegistry + PLAYBOOK_CAPABILITIES

### casehub-pages#518 — TS front matter parser + scenario migration

**Pages (2 commits):**
- `4ae7d38b` — Multi-doc YAML + playbook front matter in scenario parser (parseScenario + parseScenarioDocument)
- `fa70134a` — Migrated 48 scenario YAML files to playbook front matter format

### casehub-pages#519 — Annotate spec docs

**Pages (1 commit):**
- `1a8d53d9` — "(renamed to X)" annotations on historical spec docs

## Phase 2 — Future iterations

File migration is iterative. As new YAML files are written without playbook headers, run `scan-unmigrated-yaml.sh` to detect and migrate them:
```
./scripts/scan-unmigrated-yaml.sh /path/to/pages /path/to/aml /path/to/clinical
```

Repos NOT yet migrated:
- **aml** — 6 scenario YAML files (not in slot)
- **clinical** — 1 scenario YAML file (not in slot)
- **pages backend** — ~19 Java-parsed scenario files (ScenarioEnvelopeParser needs multi-doc support first)

Stale terminology to search for: "casehub yaml", "step script", "step-script".

## Epic Status

**epic-502-yaml-parity: COMPLETE (35/35)**. All batches landed. Deferred items in .plan are informational.

## Slot Repos

Slot 210:
- `slots/210/platform` — 7 commits on `epic-502-yaml-parity`
- `slots/210/pages` — 10 commits on `epic-502-yaml-parity`
- `slots/210/engine` — no new commits
- `slots/210/work` — no new commits

## References

- `.plan` — queue complete (35/35)
- Scan script: `wsp-casehub-platform/scripts/scan-unmigrated-yaml.sh`
