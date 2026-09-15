# HANDOFF — casehub-platform

## Last Session

Executed #480 (Pattern 2 qhorus migration) — all 4 tasks complete. 5 commits to qhorus repo. Queue still at position 3/6 (#480 active).

**#480: Pattern 2 migration qhorus (M/Med) — executed.**

Migrated qhorus from Pattern 1 (@McpDomain on resolver classes) to Pattern 2 (@McpDomain on SPI interfaces). 4 SPI interfaces created in `api/`, 4 implementation beans in `graphql/` and `compliance-report/`, graphql-generator APT wired, 7 old resolvers deleted, 41 dead DTOs deleted, 6 tests rewritten.

Qhorus commits (on branch `issue-440-panache-purge`):
1. `65b2bbe9` — SPI supporting types + compliance model move (23 files) to api/
2. `2adcfb8c` — 4 SPI interfaces (ChannelsApi, MessagingApi, GovernanceApi, ComplianceApi)
3. `d57d8efa` — 4 implementation beans
4. `35474526` — APT wiring + resolver deletion + test updates
5. `9580e56b` — Dead DTO cleanup (41 deleted, 2 kept for ChannelsSubscriptionResolver)

**One incomplete item:** compliance-report tests (ComplianceQueryResolverTest, ComplianceMutationResolverTest) still reference deleted resolver classes. Blocked by pre-existing compilation errors in compliance-report from ledger dependency refactoring (TrustGateService, ComplianceReport, DecisionRecord missing from `io.casehub.ledger.runtime.service`). Fix pattern is identical to graphql test updates — replace resolver references with ComplianceService, update DTO types to domain types. Apply when the ledger dep compiles again.

## Immediate Next Step

The #480 execution is done for what can be verified. Either:
- Advance to #481 (Pattern 2 neocortex) via `work next`
- Or fix the compliance-report ledger dep first (pre-existing, not new from #480)

## Queue State

| # | Issue | Scale | Complexity | Status |
|---|-------|-------|------------|--------|
| 0 | parent#478 | L | High | Done |
| 1 | parent#479 | XS | Low | Done |
| 2 | parent#483 | M | Med | Done |
| 3 | parent#480 | M | Med | Active — executed, compliance tests blocked |
| 4 | parent#481 | S | Low | Pending — Pattern 2 neocortex |
| 5 | parent#482 | S | Low | Pending — Wire graphql-spring-gen |

## Key Facts

- Platform branch `issue-478-spring-deployment-completion` — unchanged this session (all work in qhorus repo).
- Qhorus branch `issue-440-panache-purge` — 5 new commits from this session.
- APT generates 6 files for graphql/: GeneratedChannelsResolver, GeneratedMessagingResolver, GeneratedGovernanceResolver + 3 REST resources. Verified with `mvn compile`.
- Compliance APT wired but cannot verify — pre-existing compilation errors block the entire compliance-report module.
- `ChannelsSubscriptionResolver` and `ChannelsModelEnricher` stay hand-written (by design). MessageType + PresenceType DTOs kept for subscription support.
- `ChannelQuery` name collision with `io.casehub.qhorus.api.store.query.ChannelQuery` — ChannelsService uses FQN for the SPI param type.
- `PropertyViolation` was also moved to api/ (discovered during execution — it was referenced by `PropertyResult` which moved with the compliance models).
- Plan file: `plans/2026-09-15-pattern2-qhorus-migration.md`

## Garden Entries Consulted

None this session — Pattern 2 migration pattern was already well-established from prior sessions.

## References

- `specs/issue-478-spring-deployment-completion/2026-09-15-pattern2-qhorus-design.md`
- `specs/issue-478-spring-deployment-completion/pattern2-qhorus-decisions.md` (5 decisions)
- `plans/2026-09-15-pattern2-qhorus-migration.md` — implementation plan
- casehubio/parent#478, #480 — tracking issues
- Memory: `project_pattern2_migration.md`
