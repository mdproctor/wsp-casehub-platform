# HANDOFF — casehub-platform

## Last Session (2026-09-08/09)

Designed and began implementing dual-framework core extraction (casehubio/parent#469, casehubio/platform#276). Produced a validated design spec (7 decisions, 3-round adversarial review, industry-validated against BootUI pattern) and an 8-batch implementation plan. Completed Batches 1-2: infrastructure + platform-view reference extraction.

## Current State

**Branch:** `issue-469-dual-framework-core-extraction`
**Plan state:** active
**Batch progress:** Batches 1-4 complete. Batch 5 (Agent Stack) next.

## The Extraction Pattern

Every CDI-coupled module splits into three Maven artifacts:

```
module-core/     ← pure Java: POJOs, constructor injection, zero annotations
module/          ← EXISTING artifact name kept: CDI producers, observers, @Scheduled
module-spring/   ← NEW: Spring Boot auto-config (80%+ auto-generated from Quarkus)
```

### Key Design Decisions (D1-D8)

| # | Decision | Detail |
|---|----------|--------|
| D1 | Full platform extraction | All CDI-coupled modules, not just platform-view |
| D2 | Naming: module-core / module / module-spring | Existing Quarkus names preserved — zero consumer breakage |
| D3 | Events: A+C hybrid | A = pure I/O cores with Consumer<T> callbacks. C = framework-specific implementations sharing utility logic (subscriptions, streams, mcp) |
| D4 | Zero Quarkus consumer disruption | Consumers keep same artifact names; core comes transitively |
| D5 | Direct CDI→Spring pattern mapping | @DefaultBean→@ConditionalOnMissingBean, @Alternative→@Primary, Instance<T>→ObjectProvider<T>, @Observes→@EventListener |
| D6 | Three-tier testing | Core: pure JUnit 5. Quarkus: @QuarkusTest. Spring: @SpringBootTest + new spring-testing module |
| D7 | Spring Boot 3.x | Jakarta namespace compatible with Quarkus 3.x. BOM managed in casehub-parent |
| D8 | Spring auto-generation | spring-generator Maven plugin generates @AutoConfiguration from Quarkus @Produces via Jandex scan. Drift verification fails the build |

### Module Classification

| Category | Count | What happens |
|----------|-------|-------------|
| N (already neutral) | 12 | No change — platform-api, yaml-core, agent-api, datasource-alpha, graphql, callback-api, graphql-generator, callback-generator, schema-generator, yaml-jackson, yaml-codegen, ts-core |
| A (core extraction) | ~47 | Split into -core + keep Quarkus + add -spring (generated) |
| C (framework-specific) | ~11 | Shared utility + parallel framework implementations — subscriptions, streams-*, mcp, oidc, credentials-quarkus, testing, graphql-client, callback-client, agent-gate |

### CDI Pattern Mapping (for all repos)

| CDI Pattern | Core Module | Quarkus Module | Spring Module |
|---|---|---|---|
| @DefaultBean no-op | POJO in core | @Produces @DefaultBean | @Bean @ConditionalOnMissingBean |
| @ApplicationScoped | Constructor-injected POJO | @Produces @ApplicationScoped | @Bean via @AutoConfiguration |
| @Alternative @Priority(N) | POJO | @Produces @Alternative @Priority(N) | @Bean @Primary + @AutoConfigureOrder |
| @Decorator @Priority(N) | POJO with delegate constructor param | @Decorator @Delegate @Any | @Bean @Primary wrapping delegate |
| @Inject Instance\<T\> | Constructor param: List\<T\> or Optional\<T\> | Collected from Instance\<T\> | Collected from ObjectProvider\<T\> |
| @Observes / @ObservesAsync | Method called by framework adapter | CDI observer delegates to core | @EventListener delegates to core |
| @Scheduled | Method called by framework adapter | @Scheduled delegates to core | @Scheduled delegates to core |
| @ConfigProperty | Constructor param | @ConfigProperty injected, passed to ctor | @Value / @ConfigurationProperties |
| PanacheEntityBase | Stays in -jpa module | PanacheEntityBase | Spring Data JPA |
| Event.fire() / fireAsync() | Consumer\<T\> callback | CDI Event\<T\> at construction | ApplicationEventPublisher |

### Extraction Steps (per module — mechanical)

1. Create `module-core/pom.xml` — depends on platform-api only, no framework deps
2. Move business logic classes → remove CDI annotations, convert field injection to constructor injection
3. Move pure logic tests to core (they already use `new Class()` — just need constructor params)
4. Update existing module → add `@Produces` methods in a `quarkus/` subpackage, depend on core
5. Create `module-spring/pom.xml` — use spring-generator plugin pointing at Quarkus module
6. Write Spring auto-config test with `ApplicationContextRunner` + mock SPI beans
7. Run `mvn verify` — tests + drift verification
8. Commit

### Garden Entries Consulted

- GE-20260615-c234fc — @DefaultBean silently ignored without quarkus-arc (root constraint)
- GE-20260522-adb5cd — moving beans to library JARs breaks CDI discovery
- GE-20260604-81a6a6 — @DefaultBean @Unremovable for cross-module injection
- GE-20260627-51e402 — @Alternative suppresses ALL @DefaultBean beans
- GE-20260513-4f26a7 — @DefaultBean + @ApplicationScoped displacement pattern
- GE-20260605-373190 — @ObservesAsync + @RequestScoped incompatibility
- GE-20260531-e1ce47 — CDI @Observes vs @ObservesAsync separate channels
- GE-20260423-daef97 — fire() vs fireAsync() delivery split
- GE-20260517-a6d608 — @DefaultBean + @ConfigProperty pattern
- GE-20260515-99cf39 — Config-driven @Produces @DefaultBean

### Industry Validation

Pattern matches BootUI (github.com/jdubois/boot-ui) — real-world dual Quarkus/Spring project. Same three-tier split, same native-events approach, same SPI pattern. Also validated by hexagonal architecture projects (SvenWoltmann, dustinsand, fuinorg).

## What's Been Built (Batches 1-2)

### New Modules Created

| Module | Purpose | Tests |
|--------|---------|-------|
| spring-testing/ | SpringFixedCurrentPrincipal + SpringTestConfig | 5 |
| spring-generator/ | Maven plugin: Jandex scan → @AutoConfiguration + drift verification | 7 |
| platform-view-core/ | SubjectViewEvaluator + SubjectViewOrchestrator POJOs | 31 |
| platform-view-spring/ | Generated @AutoConfiguration (2 beans, drift verified) | 3 |
| platform-core/ | 32 NoOp POJOs for all platform-api SPIs | compile ✅ |
| platform-spring/ | Generated @AutoConfiguration (32 beans, 30 generated + 2 manual) | drift ✅ |
| governance-core/ | PolicyEnforcer + DefaultPolicyEnforcer + exceptions | compile ✅ |
| expression-core/ | DefaultExpressionEngineRegistry + MVEL/JQ/JEXL engines | compile ✅ |
| identity-core/ | 15 POJOs: DID resolvers, VC validator, SCIM lookup, composites | 78 ✅ |

### Modified Modules

| Module | Change |
|--------|--------|
| pom.xml (parent) | Spring Boot BOM, 11 new module declarations |
| platform-view/ | Source to core, ViewBeans @Produces, depends on core |
| platform/ | 32 NoOps deleted, DefaultBeans @Produces, depends on core |
| governance/ | 6 files to core, GovernanceBeans @Produces, depends on core |
| expression/ | 5 files to core, ExpressionBeans @Produces, depends on core |
| identity/ | 15 files to core, IdentityBeans @Produces (CDI qualifiers preserved), depends on core |

### Commit History (11 commits)

```
5c2ffe9c feat(#276): extract identity-core — DID resolvers, VC validation, SCIM lookup as POJOs
29d43f9a feat(#276): extract expression-core — MVEL, JQ, JEXL engines as POJOs
6f062efe feat(#276): extract governance-core — PolicyEnforcer + retry logic as POJO
c500c083 feat(#276): add platform-spring — generated auto-config for 32 default beans
ff1d10ab feat(#276): replace platform/ NoOps with @Produces @DefaultBean producers
96490c60 feat(#276): create platform-core with 32 NoOp POJO defaults
a5c896ce feat(#276): add platform-view-spring — first generated auto-configuration
89766d08 feat(#276): add CDI producers to platform-view Quarkus module
e96f4c9f feat(#276): extract platform-view-core — pure Java view logic
f52e10a0 feat(#276): create spring-generator Maven plugin
2e3bdee4 feat(#276): add Spring Boot BOM and spring-testing scaffold
```

**Total: 124+ tests green across 12 new modules. Zero consumer breakage.**

## Immediate Next Step

**Batch 5: Agent Stack** — 6 agent backends (claude, openai, codex, gemini, gemini-cli, langchain4j) + router + gate + runtime. Each backend follows the same pattern: remove @ApplicationScoped, convert to constructor injection, @Produces in existing module. Special patterns: agent-router uses Instance<AgentBackend> → core takes List<AgentBackend>. agent-gate uses @Decorator → core wraps delegate via constructor. agent-langchain4j has @DefaultBean @Priority(10) ChatModel.

**IntelliJ workspace note:** The slot at `/Users/mdproctor/claude/casehub/slots/181/platform` was opened as a workspace module. Use `project_path=/Users/mdproctor/claude/casehub/slots/181/platform` for `ide_create_file` calls. The main repo at `/Users/mdproctor/claude/casehub/platform` is a DIFFERENT directory on `main` branch — do not write to it.

## Remaining Batches

| Batch | Content | Estimated Scale |
|-------|---------|----------------|
| ~~3~~ | ~~Platform defaults (NoOp POJOs)~~ | ~~M~~ DONE |
| ~~4~~ | ~~Leaf services (expression, identity, governance)~~ | ~~M~~ DONE |
| 5 | Agent stack (6 backends + router + gate + langchain4j) | L |
| 6 | Notification pipeline (stores + dispatch) | L |
| 7 | Data infrastructure (datasource, endpoints, memory, acl, callback, scim) | L |
| 8 | Category C modules (subscriptions, streams, mcp) | L |

## References

- Spec: `specs/issue-469-dual-framework-core-extraction/2026-09-07-dual-framework-core-extraction-design.md`
- Decisions: `specs/issue-469-dual-framework-core-extraction/decisions.md` (D1-D8)
- Plan: `plans/2026-09-07-dual-framework-core-extraction.md`
- BootUI reference: https://github.com/jdubois/boot-ui/blob/main/docs/QUARKUS-SUPPORT.md
