# HANDOFF — casehub-platform

**Date:** 2026-06-01
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Completed work-end on issue-35-47-51-small-batch: #35 (reactive storeAll), #47 (SCIM pagination with configurable member-page-size), #51 (erase contract test verified). Branch hygiene: 14+ project branches stamped, two abandoned workspace branches closed, worktree-agent branch stamped via commit-tree. CLAUDE.md synced. Blog published. Two garden entries submitted.

## Immediate Next Step

Identify which repo contains WorkBroker and ExclusionPolicy — `casehub-work` does not exist in casehubio org. Check casehub-engine or casehub-ledger. File issue there, then `/work`.

## Cross-Module

**We're blocking:**
- Unknown repo — WorkBroker and ExclusionPolicy call `membersOf()` expecting `Set<String>`. Next session: identify correct repo before filing issue. · S · Low

## What's Left

- Hook install pending on 5 repos: `casehub/aml`, `casehub/clinical`, `hortora/garden`, `casehub/drafthouse`, `casehub-poc` · XS · Low
- parent#130 filed — `docs/PLATFORM.md` + `docs/repos/casehub-platform.md` need memory-sqlite added · XS · Low
- Workspace epic branches past deletion dates: `epic-platform-api`, `epic-platform-testing`, `epic-quarkus-alignment`, `epic-platform-config` — kept by user choice

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #49 | CDI emission investigation — Options A/B/C + storeAll batch | M | Med | Needs devtown/clinical/aml app feedback first |
| #39 | CDI priority revisit when `memory-mem0/` arrives | S | Med | Blocks on #33 |
| #33 | Mem0 adapter — builds against updated SPI | L | Med | |
| #34 | Graphiti adapter — builds against updated SPI | L | Med | |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Parked |

## References

- Blog: `blog/2026-06-01-mdp01-five-closes-one-gotcha.md`
- Garden: GE-20260531-c7f95a (git checkout silent failure in loop), GE-20260601-8c9e4b (commit-tree for locked worktree branch)
- Prior blog: `blog/2026-05-31-mdp01-durable-memory-no-server.md`
