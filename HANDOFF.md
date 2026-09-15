# HANDOFF — casehub-platform

## Last Session

Continued #480 (Pattern 2 qhorus migration). Fixed all ledger-core extraction import breakage across qhorus — 19 files changed, compliance-report tests replaced and passing (146/146).

**#480: Ledger-core import fix — executed.**

The ledger repo (branch `issue-478-spring-modules`) extracted types from `io.casehub.ledger.runtime.service` and `io.casehub.ledger.runtime.privacy` to `ledger-core` packages. Qhorus had stale imports across 4 modules:

- `TrustGateService` → `io.casehub.ledger.core.trust`
- `ComplianceReport`, `DecisionRecord` → `io.casehub.ledger.core.compliance`
- `ContentSanitiser` → `io.casehub.ledger.core.privacy`
- `AttestationRecordedEvent` → `io.casehub.ledger.core.model`
- `LedgerMerkleTree` → `io.casehub.ledger.core.merkle`
- `LedgerMerkleFrontier` → `io.casehub.ledger.api.model` (from runtime.model)

Types that stayed in `io.casehub.ledger.runtime.service`: `LedgerVerificationService`, `LedgerComplianceReportService`, `LedgerMerklePublisher`.

Replaced `ComplianceQueryResolverTest` and `ComplianceMutationResolverTest` (referenced deleted resolver classes) with `ComplianceServiceTest` — tests the Pattern 2 `ComplianceService` directly with constructor injection and domain types.

Qhorus commit (on branch `issue-440-panache-purge`):
- `d39f995c` — fix imports for ledger-core extraction (19 files, 145 insertions, 175 deletions)

**Pre-existing issue:** runtime module Quarkus extension descriptor fails due to Panache deployment dependency mismatch (from the Panache purge work on this branch). Not caused by #480 import fixes.

## Immediate Next Step

#480 is now complete — all compilation errors fixed, tests passing. Advance to #481 (Pattern 2 neocortex) via `work next`.

## Queue State

| # | Issue | Scale | Complexity | Status |
|---|-------|-------|------------|--------|
| 0 | parent#478 | L | High | Done |
| 1 | parent#479 | XS | Low | Done |
| 2 | parent#483 | M | Med | Done |
| 3 | parent#480 | M | Med | Active — import fix complete, tests green |
| 4 | parent#481 | S | Low | Pending — Pattern 2 neocortex |
| 5 | parent#482 | S | Low | Pending — Wire graphql-spring-gen |

## Key Facts

- Platform branch `issue-478-spring-deployment-completion` — unchanged this session.
- Qhorus branch `issue-440-panache-purge` — 6 commits total from #480 work (5 prior + 1 this session).
- Ledger installed from branch `issue-478-spring-modules` (api, ledger-core, annotations, runtime) to local Maven repo.
- `runtime-core` and `compliance-report` compile and test clean.
- `runtime` compiles at source level but fails at Quarkus extension descriptor step (pre-existing Panache purge issue).

## References

- `specs/issue-478-spring-deployment-completion/2026-09-15-pattern2-qhorus-design.md`
- `specs/issue-478-spring-deployment-completion/pattern2-qhorus-decisions.md`
- casehubio/parent#478, #480
- Memory: `project_pattern2_migration.md`
