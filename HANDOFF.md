# HANDOFF — casehub-platform

*Updated: 2026-07-24 — #195 PreferenceSchemaRegistry SPI + GET /preferences/schema (PR #200)*

**Date:** 2026-07-24
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Delivered `GET /preferences/schema` endpoint (#195) — type metadata so the blocks-ui preferences editor can render typed inputs. Three-layer SPI following the `EventTypeRegistry` pattern: SPI in platform-api, `@DefaultBean` no-op in platform, `InMemoryPreferenceSchemaRegistry` in preferences-editor.

Breaking change: `Preference` gains `toSerializedValue()` (marker → behavioral interface). All implementations migrated in-repo. Engine cross-repo fix filed as casehubio/engine#776 (two one-line additions).

Design review (4 rounds, 17 issues) caught five bugs before implementation: broken `toString()` serialization, silent `Boolean.parseBoolean()` corruption, missing integer/number type distinction, missing multiValue cardinality, untyped constraint vocabulary.

PR: casehubio/platform#200.

## Cross-Module

**Enabled** (we delivered, downstream work is ready):
- `casehub-engine` — engine#776: add `toSerializedValue()` to routing IntPreference/DoublePreference · XS · Low
- `casehub-engine` — engine#747-750: expression type migration to platform SPI · M · Med
- `casehub-blocks-ui` — blocks-ui#92: preferences editor UI component (now has schema endpoint) · L · Med
- `casehub-work` — work#315: migrate work-notifications to platform subscription engine · L · Med
- **Domain modules** — platform#197: register preference schemas via the SPI · varies

## What's Left

- MongoDB backend for subject view toolkit — not yet filed · M · Med
- platform#196: server-side preference validation using schema constraints
- platform#198: schema versioning
- platform#199: custom/composite preference types

## References

*Unchanged — `git show HEAD~1:HANDOFF.md`*
