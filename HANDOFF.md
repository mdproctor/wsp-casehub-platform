# HANDOFF — casehub-platform

## Last Session

Two major workstreams this session under casehubio/parent#478 (Spring deployment completion):

**1. Generator infrastructure improvements.** Extracted shared MCP domain scan model to generator-common — `McpDomainJandexScanner`, `ResolvedOperation`, `ResolvedParam`, `DomainScanResult`, `OperationType`, `GeneratorUtils`. This gives both APT and Maven plugin generators a single scan model. Then rewrote graphql-spring-generator for full annotation parity with the Quarkus graphql-generator: @PlatformStream→@SubscriptionMapping+SseEmitter, @RestName, @RestStatus, @PaginatedResponse, @RolesAllowed pass-through, @PathParam→@PathVariable with null→404, mutations→201, kebab-case paths, isSimpleType routing. 14 tests covering all features.

**2. Platform Panache purge (Batch 1 complete).** Stripped `extends PanacheEntityBase` from 11 entity files across 6 -jpa modules. Ported all Panache API calls in 3 store files (JpaAccessControlProvider: 20+ calls including find/delete/count/findById/persist; JpaPreferenceStore: find/list/delete/persist; JpaMemoryStore: 2x persist). Removed `quarkus-hibernate-orm-panache` dependency from all 6 pom files, replaced with direct `quarkus-hibernate-orm`. All modules compile.

Also pushed generator modules + new annotation commits to shared local platform repo (`/Users/mdproctor/claude/casehub/platform`) so other slots can access them.

## Immediate Next Step

Continue with plan Batch 2: Consumer Panache porting — ledger (2 files), work (~21 files), qhorus (~22 files). Issues already filed: ledger#208, work#401, qhorus#440. Same porting pattern established in Batch 1.

## Remaining Batches

| Batch | What | Status |
|-------|------|--------|
| 1. Platform Panache Purge | 11 entities + 3 stores + 6 poms | Done |
| 2. Consumer Panache Porting | ledger (2), work (21), qhorus (22) | Next |
| 3. Missing -spring Modules | work, ledger, eidos | Pending |
| 4. Generator Plugin Wiring | rest/graphql gen to 5 repos | Pending |
| 5. mcp-spring Runtime | SpringModelScanner + registrar | Pending |
| 6. callback-spring | @Decorator → @Bean @Primary | Pending |
| 7. Blocks Push | 10 commits to origin/main | Pending |

## Key Facts

- Blocks repo has 10 unpushed core extraction commits on local main (rebased onto origin/main). Push needed.
- Platform Panache tests NOT run yet — compilation verified only. Tests need running before considering Batch 1 truly validated.
- graphql-generator APT processor NOT yet retrofitted to use shared types (works correctly, lower priority than Spring generators).
- origin/main may have new commits from other sessions — rebase before continuing.

## Garden Entries Consulted

GE-20260420-7d28fa, GE-0138, GE-20260914-248827

## References

- `specs/spring-deployment-completion/2026-09-15-spring-deployment-completion-design.md`
- `specs/spring-deployment-completion/decisions.md` (4 decisions)
- `plans/2026-09-15-spring-deployment-completion.md` (11 tasks, 7 batches)
- casehubio/parent#478 — tracking issue
