# Handoff — Four-Tier Expression Escape Model (#411)

## What happened this session

Closed #425 (orchestration-core extraction — decided against, keep in yaml-core). Implemented #411 (four-tier expression escape model): brainstorming → design spec → 7 decisions (with light decision review) → implementation plan → 7 tasks across 3 batches → code review → squash → merge to main. 9 commits, 31 tests.

## Key decisions

- **D3 revised**: BeanInvoker SPI takes primitive params (String, Object...) — no yaml-core types cross into platform-api. Decision review caught the boundary violation.
- **D4 revised**: ActionRegistry + ActionHandle live in yaml-core (not platform-api) — ActionHandle.invoke(ScenarioScope) requires yaml-core type. Self-review caught this.
- **D5 dropped**: ComputeBlock compile bridge unnecessary — callers use `registry.compile(block.engine(), block.expression(), ...)` directly.
- **Security model**: InvocationPolicy SPI with fail-closed AllowListInvocationPolicy. First explicit invocation restriction in the expression layer.

## Pre-existing build failures

Two modules fail on main (pre-existing, not from #411):
- `platform-spring`: rest-spring-generator generates `DeliveryEngagementController` with type mismatch (`Map<String,String>` vs `Map<String,List<String>>`)
- `mcp`: `McpModelComprehensionIT` integration test fails (end-of-input JSON parse)

## Next action

Fix all failing tests — `work start` with a test-fix issue.
