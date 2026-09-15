# HANDOFF — casehub-platform

## Last Session

Git hygiene and Batch 3 of casehubio/parent#478 (Spring deployment completion).

**1. Git hygiene.** Pushed workspace to origin (8 commits). Squashed WIP commits in work (3 → 1: `eec5771a`) and qhorus (8 → 1: `de57d7b1`). Both branches now have a single clean commit ready to merge.

**2. Spring generator fixes.** Two bugs found and fixed in `spring-generator`:

- **Abstract return types:** Producer methods returning abstract SPIs (e.g., `AgentGraphBackfill`) caused `new AbstractType()` in generated code. Fixed by changing producers in eidos and ledger to return concrete types (e.g., `NoOpAgentGraphBackfill`). CDI still resolves by supertypes — no behavior change.
- **`@ConfigMapping` parameter detection:** Scanner didn't detect Quarkus `@ConfigMapping` types as CDI dependencies, generating uncompilable Spring code referencing runtime-only types. Fixed: `JandexProducerScanner` now checks parameter types against `@ConfigMapping` annotation in Jandex. `SpringVerifyMojo` now excludes `requiresManualConfig()` descriptors from drift check.

**3. Batch 3: Created missing -spring modules.**

| Repo | Module | Branch | Types | Commit |
|------|--------|--------|:-----:|--------|
| eidos | eidos-spring | `issue-478-spring-modules` | 18/18 | `1c4cae8` |
| ledger | ledger-spring | `issue-478-spring-modules` | 7/7 | `c63aa6a` |
| work | work-spring | `issue-478-spring-modules` | 6/6 | `39c70e81` |

Each parent pom received: `spring-boot.version=4.1.0`, `version.io.casehub=0.2-SNAPSHOT`, `spring-boot-dependencies` BOM import, and the new module declaration.

IntelliJ was opened for eidos and ledger in slot 192 for the producer return type changes.

## Immediate Next Step

Batch 4: Targeted Generator Plugin Wiring. Audit each source module for `@Path`, `@McpDomain`, `@Tool` annotations using IntelliJ. Add `rest-spring-generator`, `graphql-spring-generator`, `mcp-spring-generator` plugins only where annotations exist. Also fix 3 repos with -spring modules but no `spring-generator` plugin: qhorus, neocortex, connectors.

## Remaining Batches

| Batch | What | Status |
|-------|------|--------|
| 1. Platform Panache Purge | 11 entities + 3 stores + 6 poms | Done + tested |
| 2. Consumer Panache Porting | ledger, work, qhorus | Done (squashed, ready to merge) |
| 3. Missing -spring Modules | work, ledger, eidos | Done |
| 4. Generator Plugin Wiring | rest/graphql gen to 5 repos | Next |
| 5. mcp-spring Runtime | SpringModelScanner + registrar | Pending |
| 6. callback-spring | @Decorator → @Bean @Primary | Pending |
| 7. Blocks Push | 10 commits to origin/main | Pending (needs squash first) |

## Key Facts

- Work and qhorus Panache branches are squashed single commits, not yet merged to main.
- Platform branch `issue-478-spring-deployment-completion` has 3 commits ahead of origin/main (Batch 1 Panache + test fix + generator fix).
- Eidos, ledger, work each have `issue-478-spring-modules` branches with 1 commit.
- Workspace pushed to origin.
- IntelliJ has eidos and ledger from slot 192 open (in addition to existing projects).

## Garden Entries Consulted

GE-20260420-7d28fa, GE-0138, GE-20260914-248827

## References

- `specs/spring-deployment-completion/2026-09-15-spring-deployment-completion-design.md`
- `specs/spring-deployment-completion/decisions.md` (4 decisions)
- `plans/2026-09-15-spring-deployment-completion.md` (11 tasks, 7 batches)
- casehubio/parent#478 — tracking issue
- casehubio/work#401 — work Panache purge issue
- casehubio/qhorus#440 — qhorus Panache purge issue
