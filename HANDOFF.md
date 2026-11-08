# HANDOFF — casehub-platform

## Last Session

Completed #746 — MCP tool for runtime simulation phase inspection (S/Low). Landed as 54875f7b. Added `type()`/`reset()` to `CorpusSelector` SPI, selector inspection methods to `SimulationRuntime`, and `CorpusSelectorService @McpDomain("corpus-selectors")` in event-simulation with list/status/advance/reset operations. Also added `initializeSelectors()` called at startup so selectors are discoverable without prior `strategyFor()` calls.

## Immediate Next Step

Pick next from queue — #747 (per-phase corpus-files, XS/Low) or #725 (CLI --dry-run discovery, S/Low) are smallest. #745 (CDI event observer wiring, M/Med) and #748 (profile-level corpus-selection, M/Med) are larger.

## References

- `.queue` — 6 remaining issues
- `specs/issue-746-mcp-simulation-phase-inspection/` — design spec and decisions
- `plans/2026-11-08-mcp-simulation-phase-inspection.md` — implementation plan
