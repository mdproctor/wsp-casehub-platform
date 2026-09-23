# Design Journal — issue-213-spring-boot-deployment

## 2026-09-23 — Session 1: Design + review + plan + begin execution

**Scope:** casehubio/ledger#213 — Spring Boot deployment for ledger (core extraction + auto-configuration)

### Design phase
- Audited ledger repo: 10 modules, 55+ POJOs already in ledger-core, Panache purge complete
- 6 design decisions captured (scope, config, API pattern, extraction depth, JPA sharing, execution strategy)
- Wrote 614-line design spec covering 8 new modules, 25+ service extractions, 7 execution steps
- Standard 3-dimension design review: coherence (3 rounds), structure (3 rounds), robustness (3 rounds) — 50 issues found, 40 verified, spec extensively updated. $41.59.
- Key findings: repo SPI relocation needed, orm.xml mapped-superclass pattern for JPA-free api bases, signing modules consolidated to one Spring module, transaction boundary strategy, enricher priority() method

### Plan phase
- 1076-line implementation plan: 7 batches, 16 tasks
- Bottom-up: jpa-common → config records → service extraction → Spring modules → signing → integration test

### Execution (partial — Task 1 ~70%)
- Created api-level base POJOs (ActorTrustScoreBase, TrustScoreSnapshotBase) with orm.xml mapped-superclass entries
- Moved 4 SPI interfaces to api (CrossTenantLedgerEntryRepository, ActorTrustScoreRepository, TrustScoreSnapshotRepository, LedgerMerkleFrontierRepository)
- Renamed alpha/beta → alphaValue/betaValue for naming convention alignment
- Discovered: JOINED hierarchy entities can't get api-level bases — 3 SPIs stay in runtime→jpa-common
- Hit import cascade: blanket text replacement corrupted class names (GE-20260923-1d03d4)
- WIP committed: 50 files changed

### Remaining for next session
- Fix remaining import mismatches in JPA/InMemory implementations and test files
- Complete Task 1 (Step 3: findAllDetached, Step 4: countByActorId, Step 5: NoOp moves)
- Continue to Task 2 (jpa-common module creation) and beyond
