# HANDOFF — casehub-platform

**Last worked:** #911, #912 done on stacked branches. #920 done on separate branch. 4 follow-up issues filed (#917–#920).
**Branch:** `issue-920-resolve-playbook-cross-root` (from main). Stacked branches `issue-911-credential-contract-tests` → `issue-912-credential-grace-cleanup` also pending landing.
**Queue:** #914 is next after landing

## Session summary

Three-issue session — two credential lifecycle issues (S/Low) and one connectors-blocking playbook fix (S/Med).

**#911 (S/Low) — test:** `AbstractStaticCredentialStoreTest` contract test base in `testing/` module. 25 tests covering all 7 `StaticCredentialStore` SPI methods. Key design: credential values not asserted after `find()`/`findAll()` because JPA hashes and returns null — `lookup()` used for roundtrip verification. Subclasses: `InMemoryStaticCredentialStoreTest` + `JpaStaticCredentialStoreContractTest`.

**#912 (S/Low) — feat:** `CredentialRetentionPurge @Scheduled` in `authn-social-jpa`. Two purge jobs with separate staggered cron keys: revoked purge at 03:00 (365d), grace purge at 03:30 (30d past expiry). 5 tests.

**#920 (S/Med) — fix:** `resolvePlaybook()` cross-root classpath scanning. Two changes: (1) search by full resource path instead of iterating root directories, (2) handle jar: URLs via `FileSystems` for playbooks in dependency JARs. Unblocks connectors.

**Blog:** "The Contract Your Hash Can't Keep" — contract testing for hash-vs-plaintext SPIs + credential lifecycle completion.

**Filed:** #917 (Spring retention purge, XS/Low), #918 (WorkerCredentialStore contract tests, S/Low), #919 (Spring StaticCredentialStore test, XS/Low).

## Branches to land

1. `issue-911-credential-contract-tests` — stacked on main
2. `issue-912-credential-grace-cleanup` — stacked on #911
3. `issue-920-resolve-playbook-cross-root` — independent, from main

## Attention for next session

1. **Three branches need landing** — #911 and #912 are stacked (land in order). #920 is independent.
2. **Connectors unblocked** — #920 installed to local .m2. Connectors can pick up the SNAPSHOT.
3. **#913 is next non-trivial work** — Spring parity for mcp-server (S/Med), topic change from credential lifecycle.
