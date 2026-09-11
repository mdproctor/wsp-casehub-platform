# HANDOFF — casehub-platform

## Last Session (2026-09-11)

**Branch:** `issue-286-model-registry-spi`
**Covers:** #286, #287
**State:** Batch 1 of 3 complete — SPIs landed, implementation next

### What happened

- **#280, #281, #282** — landed: ShorthandModule, yaml-codegen consolidation, drift-detection enforcer rule
- **#283** — landed: DisplayTermResolver SPI + NoOp @DefaultBean
- **#285** — filed epic (LLM model registry) with 7 child issues + eidos#172. Cross-repo audit confirmed no overlaps.
- **#286/#287** — brainstormed, designed (6 decisions, Standard review), planned (6 tasks), executed Batch 1 (SPIs in platform-api). 9 new types created and tested.

Also filed: neocortex#291 (ShorthandModule migration), qhorus#434 (capacity SPI adoption), eidos#171 (DisplayTermResolver bridge).

### Key decisions (this branch)

- `AgentSessionConfig.model` semantics expand from "backend key" to "model reference" — RoutingAgentProvider gains 3-step resolution (registry → key → fail-fast) with config rewriting
- `ModelDescriptor` has typed enum dimensions + `family` field (separates product lineage from vendor)
- `ModelSource.refresh()` is pull-based, full replacement — registry is a cache
- Existing MCP `ModelRegistry` renamed to `DomainModelRegistry` (Task 5)

### Resume point

**Batch 2:** Tasks 3-4 (InMemoryModelRegistry + SeedCatalogModelSource)
**Batch 3:** Tasks 5-6 (DomainModelRegistry rename + RoutingAgentProvider integration)

### References

- Plan: `plans/2026-09-11-model-registry-spi.md`
- Spec: `specs/issue-286-model-registry-spi/2026-09-11-model-registry-spi-design.md`
- Decisions: `specs/issue-286-model-registry-spi/decisions.md`
- Epic: casehubio/platform#285
