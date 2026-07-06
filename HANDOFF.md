# HANDOFF — casehub-platform

**Date:** 2026-07-06
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Full cross-repo BOM audit across all 24 build-chain repos. Found 41 library modules missing from casehub-parent BOM and 8 stale entries. Fixed the BOM, added `scripts/bom-audit.py` and weekly CI workflow (`bom-audit.yml`) for automated drift detection. Platform publish now dispatches to parent. Downstream CI: parent + platform + first tier (ledger, connectors, eidos, neocortex) all green. Work and qhorus have pre-existing test failures.

## Immediate Next Step

Fix the `work` repo's `WorkEventTypeTest.allExpectedValuesExist` — it's the first domino in the downstream chain. Enum mismatch from new notification/subscription event types. Everything below work (engine, devtown, aml, clinical, claudony) cascades from this.

## Cross-Module

**We're blocking:**
- `casehub-work` — `WorkEventTypeTest` needs updating for new notification/subscription event types · XS · Low
- `casehub-qhorus` — `ConcurrentAutoChannelTest` race condition (unrelated to platform) · S · Med

## What's Left

*Unchanged — retrieve with: `git show HEAD~1:HANDOFF.md`*

**Added:**
- Other child repos should add `parent` to their publish dispatch lists (gradual rollout) · XS · Low each

## What's Next

*Unchanged — retrieve with: `git show HEAD~1:HANDOFF.md`*

## References

| Type | Path |
|------|------|
| BOM audit script | `casehub-parent: scripts/bom-audit.py` |
| BOM audit CI | `casehub-parent: .github/workflows/bom-audit.yml` |
| Garden entry | `tools/GE-20260706-5a5d0c.md` (GitHub Packages API pagination) |
| Blog | `blog/2026-07-06-mdp02-bom-audit.md` |
