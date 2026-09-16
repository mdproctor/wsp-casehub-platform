# HANDOFF — casehub-platform

## Last Session

Completed #481 (Pattern 2 neocortex), #482 (graphql-spring-gen wiring), #487 (spring-generator Clock fix). Filed follow-up epic #488 with 4 child issues, plus DX audit #489.

### #481: Pattern 2 neocortex — done

CognitionResolver → CognitionApi SPI interface + CognitionService impl in cognitive-observability. APT generates GeneratedCognitionResolver. 50 tests pass. Interface stays in cognitive-observability (not cognitive-api) because return types depend on mindmap-core.

Neocortex commit: `9543188a` on branch `issue-478-spring-modules`.

### #482: Wire graphql-spring-gen — done (partial)

- **Qhorus** — `runtime-spring/pom.xml`: graphql-spring-generator plugin added pointing at `../api`. spring-graphql, spring-webmvc, jakarta.validation-api deps added. 8 Spring classes generated (4 GraphQL + 4 REST controllers). Commit `39b85496` on branch `issue-440-panache-purge`.
- **Neocortex** — new `cognitive-observability-spring` module created. 2 Spring classes generated. Commit `cd807229` on branch `issue-478-spring-modules`.
- Engine/work blocked on their Pattern 2 migrations (#484, #485).

### #487: spring-generator Clock fix — done

Two fixes in platform spring-generator (commit `8c30ffe3`):
1. JandexProducerScanner: skip `java.*` return types (abstract JDK types can't be new'd)
2. AutoConfigurationWriter: don't fall back to skipped descriptor type for anchor

Qhorus runtime-spring now compiles clean: 35 beans + 8 controllers.

### Filed issues

- **#488** — Spring follow-up epic (parent of #484, #485, #486, #487)
- **#489** — DX audit: CaseHub agent/tool DX vs Embabel — covers both Quarkus and Spring

## Immediate Next Step

#486 (cognitive-observability core extraction) is active. Extract CognitionService to a -core POJO with `List<T>` instead of CDI `Instance<T>`, enabling the spring-generator to produce a Spring bean.

## Queue State

| # | Issue | Scale | Complexity | Status |
|---|-------|-------|------------|--------|
| 0 | parent#478 | L | High | Done |
| 1 | parent#479 | XS | Low | Done |
| 2 | parent#483 | M | Med | Done |
| 3 | parent#480 | M | Med | Done |
| 4 | parent#481 | S | Low | Done |
| 5 | parent#482 | S | Low | Done |
| 6 | parent#487 | XS | Low | Done |
| 7 | parent#486 | S | Med | Active — next session |
| 8 | parent#484 | S | Low | Pending — blocked on engine#1095 |
| 9 | parent#485 | S | Low | Pending — blocked on work#400 |

## Key Facts

- Platform branch `issue-478-spring-deployment-completion` — 1 commit this session (spring-generator fix).
- Qhorus branch `issue-440-panache-purge` — 1 commit this session (graphql-spring-gen wiring).
- Neocortex branch `issue-478-spring-modules` — 2 commits this session (Pattern 2 migration + observability-spring module).
- spring-generator installed to local Maven repo with both fixes.
- cognitive-observability and cognitive-observability-spring installed to local Maven repo.
- Embabel DX audit filed as #489 — covers Quarkus (source of truth) and Spring (generated).
