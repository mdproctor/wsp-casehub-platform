# HANDOFF — casehub-platform

## Status

**Branch:** epic-502-yaml-parity
**Epic:** platform#502 — YAML cross-repo parity
**State:** paused — queue 35/41 (6 new audit issues added this session)
**Active issue:** none (between issues)

## This Session

Completed platform#510 (playbook naming), pages#518 (TS parser + migration), pages#519 (spec annotations), pages#522 (TS non-map guard), pages#523 (closed — already done). Started platform#520 (Scenario→Playbook rename) — platform classes done, TS types done, Java backend classes remaining.

### Commits — platform repo (5 on `epic-502-yaml-parity`)

1. `16542d02` — PlaybookFrontMatter types + PlaybookParser
2. `2de1e7e4` — PlaybookSchemaRegistry and capability model
3. `19f58cd3` — playbook.schema.json
4. `aef69589` — Scenario→Playbook renames (PlaybookDefinition, CompiledPlaybook, PlaybookCompiler, PlaybookValidator)

### Commits — pages repo (7 on `epic-502-yaml-parity`)

1. `17e9b28e` — TS PlaybookFrontMatter types
2. `0783d1ac` — TS PlaybookSchemaRegistry
3. `4ae7d38b` — Multi-doc YAML + playbook front matter in parser
4. `fa70134a` — Migrated 48 scenario YAML files to playbook format
5. `1a8d53d9` — Spec doc annotations
6. `f32df019` — TS Scenario→Playbook renames (10 types/functions)
7. `8b7a1758` — TS non-map guard on second YAML document

## Remaining Issues

| # | Repo | Title | Scale | Blocked by |
|---|------|-------|-------|------------|
| pages#520 | casehub-pages | ScenarioEnvelopeParser multi-doc support | M | — |
| pages#521 | casehub-pages | Migrate 13 backend YAML files | S | #520 |
| platform#518 | platform | Platform spec doc annotations | S | — |
| platform#519 | platform | CaseHub YAML → Playbook YAML terminology sweep | M | — |
| platform#520 | platform | Scenario→Playbook rename epic (14 Java backend classes + directories) | L | — |

## Iterative Migration

YAML files are actively being written by others. Run `scan-unmigrated-yaml.sh` periodically:
```
./scripts/scan-unmigrated-yaml.sh /path/to/pages /path/to/aml /path/to/clinical
```

Unmigrated repos: aml (6 files), clinical (1 file), pages backend (13 files — blocked on #520).

## Slot Repos

Slot 210:
- `slots/210/platform` — epic-502-yaml-parity
- `slots/210/pages` — epic-502-yaml-parity
- `slots/210/engine` — no changes
- `slots/210/work` — no changes

## References

- `.plan` — queue at position 35/41
- Scan script: `wsp-casehub-platform/scripts/scan-unmigrated-yaml.sh`
