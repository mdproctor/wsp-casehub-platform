# HANDOFF — casehub-platform

## Last Session

Batch 4 (generator plugin wiring), Batch 5 (mcp-spring runtime), and Batch 7 (blocks push) of casehubio/parent#478 (Spring deployment completion). Also integrated @ContextParam (platform#311) via rebase and discovered a major architectural concern about @McpDomain patterns.

**1. Batch 4: Targeted Generator Plugin Wiring.**

- **Multi-module Jandex scanning.** Enhanced `AbstractGeneratorMojo` to support `<quarkusModules>` list alongside `<quarkusModule>`. Uses `CompositeIndex` to combine indexes. All scanners widened from `Index` to `IndexView`. 15 files across 5 generator modules.
- **graphql-spring-generator wired in platform-spring.** Scans 3 modules (platform-api, preferences-editor-core, callback-api) — generates 20 Spring classes from 10 @McpDomain interfaces (10 GraphQL + 10 REST controllers). Two bugs fixed: `ResponseEntity.ok()` spurious `.build()`, verify normalization for hyphenated domain names.
- **spring-generator added to 5 consumer modules.** qhorus/runtime-spring, neocortex (mindmap-spring, rag-spring, memory-spring), connectors/connectors-spring. Each committed on their respective branches.
- **rest-spring-generator deferred.** Resolves itself via Pattern 2 migration — graphql-spring-generator covers both GraphQL and REST when consumer repos define @McpDomain SPI interfaces.
- **llm-config @McpDomain deferred.** Module has CDI deps, no -core equivalent.

**2. @McpDomain Pattern 1 vs Pattern 2 — architectural finding.**

Consumer repos (engine, work, qhorus, neocortex) all use @McpDomain on resolver **classes** (Pattern 1). Only platform uses it on SPI **interfaces** (Pattern 2). The `McpDomainJandexScanner` only processes interfaces (line 41 `isInterface()` filter), so graphql-spring-generator can't generate for consumer repos. A briefing was delivered to the session doing Quarkus REST/GraphQL/MCP generation — they confirmed their approach (engine#1095 done, work#400 designed) is Pattern 2, arriving at the same end state via full generation.

**3. @ContextParam integration.** Rebased branch onto platform#311 commits (b41adef2, 6506aaf4) from original repo main. Clean merge — no conflicts. Both our generator changes and @ContextParam changes touch `SpringDomainRestControllerWriter` but in different sections.

**4. Batch 5: mcp-spring Runtime Module.**

New module `mcp-spring` with Spring AI 2.0 integration:
- `SpringModelScanner` — discovers beans implementing @McpDomain interfaces, builds DomainModels, populates DomainModelRegistry
- `SpringOperationDispatcher` — reflective dispatch with @ContextParam resolution via CurrentPrincipal
- `CaseHubToolCallbackProvider` — registers `casehub_model` (catalog), `casehub_action` (unified dispatch), and per-operation tools via Spring AI `ToolCallbackProvider`
- `McpSpringAutoConfiguration` — eager scan, auto-configured
- Spring AI BOM 2.0.0 added to parent dependencyManagement
- 4 passing tests

**5. Batch 7: Blocks Push.**

Squashed 10 WIP commits to 1 clean commit, rebased onto 7 new origin/main commits. Fixed two core extraction issues during rebase: `SocialAvatarCognition` constructor (CDI field injection → constructor injection POJO) and missing jandex-maven-plugin on blocks module. Pushed to origin/main.

## Immediate Next Step

Batch 6: callback-spring module. CDI `@Decorator` → Spring `@Bean @Primary`. Study the `callback-generator` APT output to understand the wrapping pattern, then implement `CallbackDecoratorAutoConfiguration` for Spring.

## Remaining Batches

| Batch | What | Status |
|-------|------|--------|
| 1. Platform Panache Purge | 11 entities + 3 stores + 6 poms | Done + tested |
| 2. Consumer Panache Porting | ledger, work, qhorus | Done (squashed, ready to merge) |
| 3. Missing -spring Modules | work, ledger, eidos | Done |
| 4. Generator Plugin Wiring | graphql-gen + spring-gen to repos | Done (rest-gen deferred — resolves via Pattern 2) |
| 5. mcp-spring Runtime | SpringModelScanner + ToolCallbackProvider | Done |
| 6. callback-spring | @Decorator → @Bean @Primary | Next |
| 7. Blocks Push | Core extraction to origin/main | Done |

## Key Facts

- Platform branch `issue-478-spring-deployment-completion` has 8 commits ahead of origin/main (rebased onto @ContextParam).
- Spring AI BOM 2.0.0 in platform parent pom.
- Consumer repo branches: work `issue-478-spring-modules`, qhorus `issue-440-panache-purge`, ledger `issue-478-spring-modules`, eidos `issue-478-spring-modules`, neocortex `issue-478-spring-modules`, connectors `issue-478-spring-modules`.
- Pattern 2 migration in progress: engine#1095 done, work#400 designed. Once landed, wire graphql-spring-generator in each repo's -spring module.
- Blocks pushed to origin/main with core extraction + spring modules.

## Garden Entries Consulted

GE-20260420-7d28fa, GE-0138, GE-20260914-248827

## References

- `specs/spring-deployment-completion/2026-09-15-spring-deployment-completion-design.md`
- `specs/spring-deployment-completion/decisions.md` (4 decisions)
- `plans/2026-09-15-spring-deployment-completion.md` (11 tasks, 7 batches)
- casehubio/parent#478 — tracking issue
- casehubio/platform#311 — @ContextParam
- Memory: `project_pattern2_migration.md` — Pattern 2 migration tracking
