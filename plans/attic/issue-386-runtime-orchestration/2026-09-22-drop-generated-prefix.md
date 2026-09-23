# Drop Generated Prefix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #387 — chore: drop Generated prefix and platform.rest.generated package from APT output
**Issue group:** #387, #388, #389

**Goal:** Generate REST resources and GraphQL resolvers with clean class names
(`AclResource`, not `GeneratedAclResource`) in SPI-derived packages
(`io.casehub.platform.rest.acl`, not `io.casehub.platform.rest.generated`).

**Architecture:** Add a `deriveOutputPackage` method that replaces the `.api`
segment in the SPI's package with `.rest`/`.graphql`, with APT compiler arg
override. Drop the `Generated` prefix from class names. Apply the same rule
to `graphql-spring-generator`.

**Tech Stack:** Java APT (annotation processing), compile-testing, JavaPoet
(spring generator only)

## Global Constraints

- graphql-generator APT must remain minimal-dependency (no JavaPoet, no generator-common)
- The derivation logic is ~10 lines — duplicated in both modules rather than shared
- All test SPIs are in package `test` → derived REST package is `test.rest`, GraphQL is `test.graphql`

---

## Batch 1: APT naming and package derivation

### Task 1: Add deriveOutputPackage and restPackage/graphqlPackage options

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java`
- Modify: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java`

**Interfaces:**
- Produces: `static String deriveOutputPackage(String spiPackage, String channel)` — used by Tasks 2 and 3
- Produces: `static String spiPackage(DomainOperations ops)` — extracts package from first operation's declaring class

- [ ] **Step 1: Write unit tests for deriveOutputPackage**

Add to `GraphQLResolverProcessorTest.java`:

```java
@Test
void deriveOutputPackage_replacesApiMiddle() {
    assertThat(GraphQLResolverProcessor.deriveOutputPackage(
            "io.casehub.platform.api.acl", "rest"))
            .isEqualTo("io.casehub.platform.rest.acl");
}

@Test
void deriveOutputPackage_replacesApiEnd() {
    assertThat(GraphQLResolverProcessor.deriveOutputPackage(
            "io.casehub.chat.api", "rest"))
            .isEqualTo("io.casehub.chat.rest");
}

@Test
void deriveOutputPackage_appendsWhenNoApi() {
    assertThat(GraphQLResolverProcessor.deriveOutputPackage(
            "io.casehub.something", "rest"))
            .isEqualTo("io.casehub.something.rest");
}

@Test
void deriveOutputPackage_graphqlChannel() {
    assertThat(GraphQLResolverProcessor.deriveOutputPackage(
            "io.casehub.platform.api.acl", "graphql"))
            .isEqualTo("io.casehub.platform.graphql.acl");
}

@Test
void deriveOutputPackage_singleSegment() {
    assertThat(GraphQLResolverProcessor.deriveOutputPackage(
            "test", "rest"))
            .isEqualTo("test.rest");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl graphql-generator test -Dtest=GraphQLResolverProcessorTest#deriveOutputPackage* --batch-mode -q`
Expected: compilation error — `deriveOutputPackage` does not exist

- [ ] **Step 3: Implement deriveOutputPackage and spiPackage**

Add to `GraphQLResolverProcessor.java` (after `toPascalCase`):

```java
static String deriveOutputPackage(String spiPackage, String channel) {
    int apiIdx = spiPackage.indexOf(".api.");
    if (apiIdx >= 0) {
        return spiPackage.substring(0, apiIdx) + "." + channel
               + spiPackage.substring(apiIdx + 4);
    }
    if (spiPackage.endsWith(".api")) {
        return spiPackage.substring(0, spiPackage.length() - 4) + "." + channel;
    }
    return spiPackage + "." + channel;
}

private static String spiPackage(DomainOperations ops) {
    String fqcn = ops.operations.get(0).declaringClassFqcn();
    int lastDot = fqcn.lastIndexOf('.');
    return lastDot > 0 ? fqcn.substring(0, lastDot) : "";
}
```

Add `"restPackage"` and `"graphqlPackage"` to `getSupportedOptions()`:

```java
@Override
public Set<String> getSupportedOptions() {
    return Set.of("generateGraphQL", "generateRest", "domainFilter",
                   "restPackage", "graphqlPackage");
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl graphql-generator test -Dtest=GraphQLResolverProcessorTest#deriveOutputPackage* --batch-mode -q`
Expected: all 5 new tests pass

- [ ] **Step 5: Commit**

```bash
git add graphql-generator/
git commit -m "feat(#387): add deriveOutputPackage and restPackage/graphqlPackage options

Refs #387

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: Wire derivation into generator output and update integration tests

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java`
- Modify: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java`

**Interfaces:**
- Consumes: `deriveOutputPackage(String, String)` and `spiPackage(DomainOperations)` from Task 1

- [ ] **Step 1: Update generateResolverSource — drop Generated prefix, use derived package**

In `generateResolverSource` (line 694), change:

```java
// Before:
String className = "Generated" + toPascalCase(domain) + "Resolver";
// ...
String packageName = "io.casehub.platform.graphql.generated";

// After:
String className = toPascalCase(domain) + "Resolver";
// ...
String graphqlPkgOverride = processingEnv.getOptions().get("graphqlPackage");
String packageName = graphqlPkgOverride != null
    ? graphqlPkgOverride
    : deriveOutputPackage(spiPackage(ops), "graphql");
```

- [ ] **Step 2: Update generateRestResourceSource — drop Generated prefix, use derived package**

In `generateRestResourceSource` (line 788), change:

```java
// Before:
String className = "Generated" + toPascalCase(domain) + "Resource";
// ...
String packageName = "io.casehub.platform.rest.generated";

// After:
String className = toPascalCase(domain) + "Resource";
// ...
String restPkgOverride = processingEnv.getOptions().get("restPackage");
String packageName = restPkgOverride != null
    ? restPkgOverride
    : deriveOutputPackage(spiPackage(ops), "rest");
```

- [ ] **Step 3: Remove .generated. check from enforceNoHandWrittenRest**

Delete line 169:

```java
if (name.contains(".generated.")) continue;
```

Generated classes have `@McpDomain`, so the `hasMcpDomain` check (line 176) handles them.

- [ ] **Step 4: Update all integration test assertions**

All test SPIs are in package `test`. The derived packages become:
- REST: `test.rest.<Domain>Resource`
- GraphQL: `test.graphql.<Domain>Resolver`

Update each test's `compilation.generatedSourceFile(...)` and `assertThat(content).contains("class ...")` calls:

| Test method | Old generated file | New generated file |
|---|---|---|
| `restNameOverridesQueryParamName` | `io.casehub.platform.rest.generated.GeneratedPagesResource` | `test.rest.PagesResource` |
| `rolesAllowedPassesThroughToRest` | `io.casehub.platform.rest.generated.GeneratedAdminResource` | `test.rest.AdminResource` |
| `mutationEndpointReturns200` | `io.casehub.platform.rest.generated.GeneratedItemsResource` | `test.rest.ItemsResource` |
| `roundEnvScanDiscoversLocalInterface` (REST) | `io.casehub.platform.rest.generated.GeneratedSampleResource` | `test.rest.SampleResource` |
| `roundEnvScanDiscoversLocalInterface` (content) | `class GeneratedSampleResource` | `class SampleResource` |
| `roundEnvScanDiscoversLocalInterface` (GraphQL) | `io.casehub.platform.graphql.generated.GeneratedSampleResolver` | `test.graphql.SampleResolver` |
| `domainFilterExcludesNonMatchingDomains` (alpha REST) | `...GeneratedAlphaResource` | `test.rest.AlphaResource` |
| `domainFilterExcludesNonMatchingDomains` (beta REST) | `...GeneratedBetaResource` | `test.rest.BetaResource` |
| `domainFilterExcludesNonMatchingDomains` (alpha GQL) | `...GeneratedAlphaResolver` | `test.graphql.AlphaResolver` |
| `generateGraphQLFalseSuppressesResolvers` (GQL) | `...GeneratedGammaResolver` | `test.graphql.GammaResolver` |
| `generateGraphQLFalseSuppressesResolvers` (REST) | `...GeneratedGammaResource` | `test.rest.GammaResource` |
| `hyphenatedDomainProducesValidClassName` (file) | `...GeneratedDeliveryChannelsResource` | `test.rest.DeliveryChannelsResource` |
| `hyphenatedDomainProducesValidClassName` (content) | `class GeneratedDeliveryChannelsResource` | `class DeliveryChannelsResource` |
| `streamingRestProducesSseEndpoint` | `...GeneratedEventsResource` | `test.rest.EventsResource` |
| `streamingGraphqlProducesSubscription` | `...GeneratedSubsResolver` | `test.graphql.SubsResolver` |
| `nonStreamingRestHasMethodLevelVirtualThread` | `...GeneratedPlainResource` | `test.rest.PlainResource` |
| `paginatedResponseAddsXTotalCountHeader` | `...GeneratedListsResource` | `test.rest.ListsResource` |
| `classBasedDomainGeneratesRestResource` (REST) | `...GeneratedStatusResource` | `test.rest.StatusResource` |
| `classBasedDomainGeneratesRestResource` (GQL) | `...GeneratedStatusResolver` | `test.graphql.StatusResolver` |
| `classWithoutScopeEmitsWarning` | `...GeneratedUnscopedResource` | `test.rest.UnscopedResource` |
| `classBasedDomainWithContextParam` | `...GeneratedTenantItemsResource` | `test.rest.TenantItemsResource` |

- [ ] **Step 5: Add new tests for APT override and edge cases**

```java
@Test
void restPackageOverrideTakesPrecedence() throws Exception {
    var spi = com.google.testing.compile.JavaFileObjects.forSourceString(
            "test.OverrideApi",
            """
            package test;
            import io.casehub.platform.api.mcp.*;

            @McpDomain("override")
            public interface OverrideApi {
                @PlatformQuery("Get data") String getData();
            }
            """);

    var compilation = com.google.testing.compile.Compiler.javac()
            .withProcessors(new GraphQLResolverProcessor())
            .withOptions("-AdomainFilter=override", "-AgenerateGraphQL=false",
                         "-ArestPackage=custom.pkg")
            .compile(spi);

    assertThat(compilation.generatedSourceFile(
            "custom.pkg.OverrideResource")).isPresent();
}

@Test
void graphqlPackageOverrideTakesPrecedence() throws Exception {
    var spi = com.google.testing.compile.JavaFileObjects.forSourceString(
            "test.GqlOverrideApi",
            """
            package test;
            import io.casehub.platform.api.mcp.*;

            @McpDomain("gql-override")
            public interface GqlOverrideApi {
                @PlatformQuery("Get data") String getData();
            }
            """);

    var compilation = com.google.testing.compile.Compiler.javac()
            .withProcessors(new GraphQLResolverProcessor())
            .withOptions("-AdomainFilter=gql-override", "-AgenerateRest=false",
                         "-AgraphqlPackage=custom.gql")
            .compile(spi);

    assertThat(compilation.generatedSourceFile(
            "custom.gql.GqlOverrideResolver")).isPresent();
}

@Test
void apiSubpackageDerivation() throws Exception {
    var spi = com.google.testing.compile.JavaFileObjects.forSourceString(
            "com.example.api.billing.InvoiceApi",
            """
            package com.example.api.billing;
            import io.casehub.platform.api.mcp.*;

            @McpDomain("invoices")
            public interface InvoiceApi {
                @PlatformQuery("List invoices") java.util.List<String> list();
            }
            """);

    var compilation = com.google.testing.compile.Compiler.javac()
            .withProcessors(new GraphQLResolverProcessor())
            .withOptions("-AdomainFilter=invoices", "-AgenerateGraphQL=false")
            .compile(spi);

    assertThat(compilation.generatedSourceFile(
            "com.example.rest.billing.InvoicesResource")).isPresent();
}
```

- [ ] **Step 6: Run full test suite**

Run: `mvn -pl graphql-generator test --batch-mode -q`
Expected: all tests pass (21 updated + 3 new)

- [ ] **Step 7: Commit**

```bash
git add graphql-generator/
git commit -m "feat(#387): drop Generated prefix and use SPI-derived packages

Replace hardcoded 'Generated' prefix and '.generated.' packages with
clean class names in SPI-derived packages. Adds -ArestPackage and
-AgraphqlPackage APT options for explicit override.

Refs #387

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 2: graphql-spring-generator consistency

### Task 3: Update graphql-spring-generator to use SPI-derived packages

**Files:**
- Modify: `graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/GraphqlSpringGeneratorMojo.java:47`

**Interfaces:**
- Consumes: `DomainScanResult.sourceFqcn()` from generator-common — provides the SPI's fully qualified name

- [ ] **Step 1: Add deriveOutputPackage to the mojo**

Add the same derivation method (duplicated from APT — ~10 lines):

```java
static String deriveOutputPackage(String spiPackage, String channel) {
    int apiIdx = spiPackage.indexOf(".api.");
    if (apiIdx >= 0) {
        return spiPackage.substring(0, apiIdx) + "." + channel
               + spiPackage.substring(apiIdx + 4);
    }
    if (spiPackage.endsWith(".api")) {
        return spiPackage.substring(0, spiPackage.length() - 4) + "." + channel;
    }
    return spiPackage + "." + channel;
}

private static String spiPackage(DomainScanResult domain) {
    String fqcn = domain.sourceFqcn();
    int lastDot = fqcn.lastIndexOf('.');
    return lastDot > 0 ? fqcn.substring(0, lastDot) : "";
}
```

- [ ] **Step 2: Replace hardcoded targetPackage with derivation**

In `execute()` (line 47), change:

```java
// Before:
String targetPackage = "io.casehub.platform.graphql.spring.generated";

// After:
String graphqlTargetPackage = deriveOutputPackage(spiPackage(domain), "graphql") + ".spring";
String restTargetPackage = deriveOutputPackage(spiPackage(domain), "rest") + ".spring";
```

Update the generate calls:

```java
// Before:
JavaFile graphqlFile = graphqlWriter.generate(domain, targetPackage);
JavaFile restFile = restWriter.generate(domain, targetPackage);

// After:
JavaFile graphqlFile = graphqlWriter.generate(domain, graphqlTargetPackage);
JavaFile restFile = restWriter.generate(domain, restTargetPackage);
```

- [ ] **Step 3: Build and verify**

Run: `mvn -pl graphql-spring-generator install --batch-mode -q`
Expected: builds successfully

- [ ] **Step 4: Run full platform build**

Run: `mvn --batch-mode install`
Expected: clean build — all modules pass. Generated classes in platform modules
use new names and packages.

- [ ] **Step 5: Commit**

```bash
git add graphql-spring-generator/
git commit -m "feat(#387): derive graphql-spring-generator package from SPI

Replace hardcoded io.casehub.platform.graphql.spring.generated with
SPI-derived packages (e.g. io.casehub.platform.graphql.acl.spring).

Refs #387

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## References

- [2026-09-22-drop-generated-prefix-design.md] — design spec this plan implements
- [GraphQLResolverProcessor.java:694,702,788,796] — current class name and package templates
- [GraphQLResolverProcessor.java:169] — .generated. check in enforceNoHandWrittenRest
- [GraphqlSpringGeneratorMojo.java:47] — hardcoded spring generator package
- [DomainScanResult.java:8] — sourceFqcn field for SPI package derivation
- [GraphQLResolverProcessorTest.java:260-740] — 21 integration tests to update
- [GitHub #387] — focal issue
- [GitHub #388, #389] — consumer follow-ups (not implemented here)
