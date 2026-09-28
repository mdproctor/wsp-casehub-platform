# Block-level iteration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #432 — Block-level iteration: forEach and loop on YamlImport
**Issue group:** #429, #432, #433

**Goal:** Enable forEach and loop on module imports so blocks of nodes can be iterated without decorating each node individually.

**Architecture:** Phase 1 pre-expansion (`ImportExpander`) stamps out N copies of a forEach-annotated import with dash-composed aliases and resolved parameters. ModuleExpander and ForEachExpander run unchanged on the output. `loop` is model-only — carried on YamlImport, consumed by the orchestration runtime.

**Tech Stack:** Java 21, JUnit 5, AssertJ, zero external dependencies

## Global Constraints

- yaml-core must remain zero-dependency
- Dash (`-`) separator for stamped aliases (industry convention: dots for hierarchy, dashes for composition)
- Stamped aliases must not contain dots (reserved for module-to-node hierarchy)
- No changes to ModuleExpander or ForEachExpander

---

## Batch 1: Import iteration

### Task 1: YamlImport record — add forEach and loop fields

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlImport.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/module/YamlImportTest.java` (new)

**Interfaces:**
- Produces: `YamlImport(String module, String as, String when, Map<String, String> parameters, Object forEach, Object loop)`

- [ ] **Step 1: Write tests for the updated record**

Create `yaml-core/src/test/java/io/casehub/yaml/core/module/YamlImportTest.java`:

```java
package io.casehub.yaml.core.module;

import io.casehub.yaml.core.foreach.ForEachDirective;
import io.casehub.yaml.core.orchestration.LoopDirective;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class YamlImportTest {

    @Test
    void construct_with_forEach_and_loop() {
        var imp = new YamlImport("my-module", "region", null, Map.of(),
                "regions", Map.of("count", 3));
        assertThat(imp.forEach()).isEqualTo("regions");
        assertThat(imp.loop()).isNotNull();
    }

    @Test
    void construct_without_forEach_and_loop() {
        var imp = new YamlImport("my-module", "region", null, Map.of(), null, null);
        assertThat(imp.forEach()).isNull();
        assertThat(imp.loop()).isNull();
    }

    @Test
    void forEach_parses_via_ForEachDirective() {
        var imp = new YamlImport("mod", "region", null, Map.of(),
                Map.of("as", "r", "in", List.of("us", "eu")), null);
        ForEachDirective directive = ForEachDirective.parse(imp.forEach());
        assertThat(directive).isInstanceOf(ForEachDirective.InlineIteration.class);
    }

    @Test
    void loop_parses_via_LoopDirective() {
        var imp = new YamlImport("mod", "region", null, Map.of(),
                null, 5);
        LoopDirective directive = LoopDirective.parse(imp.loop());
        assertThat(directive).isInstanceOf(LoopDirective.Count.class);
        assertThat(((LoopDirective.Count) directive).count()).isEqualTo(5);
    }

    @Test
    void parameters_default_to_empty_map() {
        var imp = new YamlImport("mod", "x", null, null, null, null);
        assertThat(imp.parameters()).isEmpty();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=YamlImportTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — constructor has wrong parameter count

- [ ] **Step 3: Update YamlImport record**

Use `ide_replace_text_in_file` to update the record:

```java
package io.casehub.yaml.core.module;

import java.util.Map;

public record YamlImport(
        String module,
        String as,
        String when,
        Map<String, String> parameters,
        Object forEach,
        Object loop) {

    public YamlImport {
        if (parameters == null) { parameters = Map.of(); }
    }
}
```

- [ ] **Step 4: Fix existing callers**

Use `ide_find_references` on `YamlImport` constructor to find all call sites. Each `new YamlImport(module, as, when, params)` call needs two trailing `null` args: `new YamlImport(module, as, when, params, null, null)`. Check:
- `ModuleExpanderTest.java` — test fixtures creating YamlImport instances
- `ForEachExpanderTest.java` — test fixtures
- Any other test files

Use `ide_replace_text_in_file` to update each call site.

- [ ] **Step 5: Run tests**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=YamlImportTest,ModuleExpanderTest`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/module/YamlImport.java
git add yaml-core/src/test/java/io/casehub/yaml/core/module/
git commit -m "feat(#432): add forEach and loop fields to YamlImport

Refs #432

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: ImportExpander — Phase 1 pre-expansion

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/ImportExpander.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/module/ImportExpanderTest.java` (new)

**Interfaces:**
- Consumes: `YamlImport` with `forEach` field (Task 1), `ForEachDirective.parse()`, `VariableSource.forEachContext()`, `ObjectVariableSource.drillOnly()`, `IterationGroup`, `CsvDataSource`
- Produces: `ImportExpander.expand(List<YamlImport>, Map<String, IterationGroup>, Map<String, CsvDataSource>, VariableResolver) → List<YamlImport>`

- [ ] **Step 1: Write tests for list-based forEach expansion**

Create `yaml-core/src/test/java/io/casehub/yaml/core/module/ImportExpanderTest.java`:

```java
package io.casehub.yaml.core.module;

import io.casehub.yaml.core.data.CsvDataSource;
import io.casehub.yaml.core.data.CsvParser;
import io.casehub.yaml.core.foreach.ForEachDirective;
import io.casehub.yaml.core.foreach.IterationGroup;
import io.casehub.yaml.core.resolver.VariableResolver;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ImportExpanderTest {

    private final VariableResolver resolver = new VariableResolver(Map.of(), Set.of());

    @Test
    void inlineForEach_stampsImports() {
        var imp = new YamlImport("pipeline", "region", null,
                Map.of("ep", "${each.region}"),
                Map.of("as", "region", "in", List.of("us-east", "eu-west")),
                null);

        List<YamlImport> result = ImportExpander.expand(
                List.of(imp), Map.of(), Map.of(), resolver);

        assertThat(result).hasSize(2);
        assertThat(result.get(0).as()).isEqualTo("region-us-east");
        assertThat(result.get(0).parameters()).containsEntry("ep", "us-east");
        assertThat(result.get(0).forEach()).isNull();
        assertThat(result.get(1).as()).isEqualTo("region-eu-west");
        assertThat(result.get(1).parameters()).containsEntry("ep", "eu-west");
    }

    @Test
    void namedGroup_stampsImports() {
        var groups = Map.of("regions",
                new IterationGroup("region", List.of("us", "eu")));
        var imp = new YamlImport("pipeline", "region", null,
                Map.of("r", "${each.region}"),
                "regions", null);

        List<YamlImport> result = ImportExpander.expand(
                List.of(imp), groups, Map.of(), resolver);

        assertThat(result).hasSize(2);
        assertThat(result.get(0).as()).isEqualTo("region-us");
        assertThat(result.get(0).parameters()).containsEntry("r", "us");
        assertThat(result.get(1).as()).isEqualTo("region-eu");
    }

    @Test
    void csvDataSource_stampsWithTypedParams() {
        var csv = CsvParser.parse("envs",
                "name:STRING,port:INTEGER\nstaging,8080\nprod,443");
        var groups = Map.of("envs", new IterationGroup("env", List.of()));
        var imp = new YamlImport("pipeline", "env", null,
                Map.of("host", "${each.env.name}", "p", "${each.env.port}"),
                "envs", null);

        List<YamlImport> result = ImportExpander.expand(
                List.of(imp), groups, Map.of("envs", csv), resolver);

        assertThat(result).hasSize(2);
        assertThat(result.get(0).as()).isEqualTo("env-staging");
        assertThat(result.get(0).parameters()).containsEntry("host", "staging")
                                               .containsEntry("p", "8080");
        assertThat(result.get(1).as()).isEqualTo("env-prod");
        assertThat(result.get(1).parameters()).containsEntry("p", "443");
    }

    @Test
    void noForEach_passesThrough() {
        var imp = new YamlImport("mod", "alias", null,
                Map.of("k", "v"), null, null);

        List<YamlImport> result = ImportExpander.expand(
                List.of(imp), Map.of(), Map.of(), resolver);

        assertThat(result).hasSize(1);
        assertThat(result.get(0)).isSameAs(imp);
    }

    @Test
    void loop_preserved_on_stamped_imports() {
        var imp = new YamlImport("pipeline", "region", null,
                Map.of(), Map.of("as", "region", "in", List.of("us")),
                Map.of("count", 3));

        List<YamlImport> result = ImportExpander.expand(
                List.of(imp), Map.of(), Map.of(), resolver);

        assertThat(result).hasSize(1);
        assertThat(result.get(0).loop()).isEqualTo(Map.of("count", 3));
        assertThat(result.get(0).forEach()).isNull();
    }

    @Test
    void mixed_forEach_and_regular_imports() {
        var regular = new YamlImport("db", "database", null,
                Map.of(), null, null);
        var forEach = new YamlImport("svc", "region", null,
                Map.of("r", "${each.region}"),
                Map.of("as", "region", "in", List.of("us", "eu")),
                null);

        List<YamlImport> result = ImportExpander.expand(
                List.of(regular, forEach), Map.of(), Map.of(), resolver);

        assertThat(result).hasSize(3);
        assertThat(result.get(0).as()).isEqualTo("database");
        assertThat(result.get(1).as()).isEqualTo("region-us");
        assertThat(result.get(2).as()).isEqualTo("region-eu");
    }

    @Test
    void when_condition_filters_stamped_imports() {
        var imp = new YamlImport("pipeline", "region", "${each.region}",
                Map.of(),
                Map.of("as", "region", "in", List.of("true", "false")),
                null);

        List<YamlImport> result = ImportExpander.expand(
                List.of(imp), Map.of(), Map.of(), resolver);

        assertThat(result).hasSize(1);
        assertThat(result.get(0).as()).isEqualTo("region-true");
    }

    @Test
    void dotInValue_throws() {
        var imp = new YamlImport("pipeline", "region", null,
                Map.of(),
                Map.of("as", "region", "in", List.of("us.east")),
                null);

        assertThatThrownBy(() -> ImportExpander.expand(
                List.of(imp), Map.of(), Map.of(), resolver))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining(".")
                .hasMessageContaining("reserved");
    }

    @Test
    void duplicateStampedAlias_throws() {
        var imp = new YamlImport("pipeline", "region", null,
                Map.of(),
                Map.of("as", "region", "in", List.of("same", "same")),
                null);

        assertThatThrownBy(() -> ImportExpander.expand(
                List.of(imp), Map.of(), Map.of(), resolver))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("Duplicate");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ImportExpanderTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — ImportExpander doesn't exist

- [ ] **Step 3: Implement ImportExpander**

Create `yaml-core/src/main/java/io/casehub/yaml/core/module/ImportExpander.java`:

```java
package io.casehub.yaml.core.module;

import io.casehub.yaml.core.condition.Truthiness;
import io.casehub.yaml.core.data.CsvDataSource;
import io.casehub.yaml.core.foreach.ForEachDirective;
import io.casehub.yaml.core.foreach.IterationGroup;
import io.casehub.yaml.core.resolver.ObjectVariableSource;
import io.casehub.yaml.core.resolver.VariableResolver;
import io.casehub.yaml.core.resolver.VariableSource;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

public final class ImportExpander {

    private ImportExpander() {}

    public static List<YamlImport> expand(
            List<YamlImport> imports,
            Map<String, IterationGroup> iterationGroups,
            Map<String, CsvDataSource> dataSources,
            VariableResolver resolver) {

        List<YamlImport> result = new ArrayList<>();
        Set<String> seenAliases = new HashSet<>();

        for (YamlImport imp : imports) {
            if (imp.forEach() == null) {
                result.add(imp);
                seenAliases.add(imp.as());
                continue;
            }

            ForEachDirective directive = ForEachDirective.parse(imp.forEach());
            String as = resolveAs(directive, iterationGroups);

            if (directive instanceof ForEachDirective.GroupRef ref) {
                CsvDataSource csv = dataSources.get(ref.groupName());
                if (csv != null && !csv.rows().isEmpty()) {
                    expandCsv(imp, csv, as, resolver, result, seenAliases);
                } else {
                    IterationGroup group = iterationGroups.get(ref.groupName());
                    if (group == null) {
                        throw new IllegalArgumentException(
                                "Import '" + imp.as() + "' forEach references unknown group '"
                                + ref.groupName() + "'.");
                    }
                    expandList(imp, resolveValues(group.inAsList(), resolver), as, resolver, result, seenAliases);
                }
            } else if (directive instanceof ForEachDirective.InlineIteration inline) {
                expandList(imp, resolveValues(inline.in(), resolver), as, resolver, result, seenAliases);
            }
        }

        return List.copyOf(result);
    }

    private static void expandList(YamlImport imp, List<String> values, String as,
                                    VariableResolver resolver,
                                    List<YamlImport> result, Set<String> seenAliases) {
        for (String value : values) {
            validateValue(value, imp.as());
            String stampedAlias = imp.as() + "-" + value;
            validateUniqueAlias(stampedAlias, seenAliases);

            VariableResolver eachResolver = resolver.withScope("each",
                    VariableSource.forEachContext(Map.of(as, value), null));

            if (imp.when() != null) {
                String resolvedWhen = eachResolver.resolveString(imp.when(), stampedAlias);
                if (!Truthiness.isTruthy(resolvedWhen)) continue;
            }

            Map<String, String> resolvedParams = resolveParams(imp.parameters(), eachResolver, stampedAlias);
            result.add(new YamlImport(imp.module(), stampedAlias,
                    null, resolvedParams, null, imp.loop()));
        }
    }

    private static void expandCsv(YamlImport imp, CsvDataSource csv, String as,
                                    VariableResolver resolver,
                                    List<YamlImport> result, Set<String> seenAliases) {
        String firstCol = csv.columns().get(0).name();
        for (int i = 0; i < csv.rows().size(); i++) {
            Map<String, Object> row = csv.rows().get(i);
            String rowKey = String.valueOf(row.get(firstCol));
            validateValue(rowKey, imp.as());
            String stampedAlias = imp.as() + "-" + rowKey;
            validateUniqueAlias(stampedAlias, seenAliases);

            VariableResolver eachResolver = resolver.withScope("each",
                    VariableSource.forEachContext(
                            Map.of(as, rowKey, "index", String.valueOf(i)),
                            Map.of(as, row)))
                    .withObjectScope("each", ObjectVariableSource.drillOnly(
                            name -> name.equals(as) ? row : null));

            if (imp.when() != null) {
                String resolvedWhen = eachResolver.resolveString(imp.when(), stampedAlias);
                if (!Truthiness.isTruthy(resolvedWhen)) continue;
            }

            Map<String, String> resolvedParams = resolveParams(imp.parameters(), eachResolver, stampedAlias);
            result.add(new YamlImport(imp.module(), stampedAlias,
                    null, resolvedParams, null, imp.loop()));
        }
    }

    private static Map<String, String> resolveParams(Map<String, String> params,
                                                       VariableResolver resolver,
                                                       String context) {
        Map<String, String> resolved = new LinkedHashMap<>();
        for (Map.Entry<String, String> entry : params.entrySet()) {
            resolved.put(entry.getKey(),
                    resolver.resolveString(entry.getValue(), context));
        }
        return Map.copyOf(resolved);
    }

    private static List<String> resolveValues(List<?> in, VariableResolver resolver) {
        List<String> values = new ArrayList<>();
        for (Object item : in) {
            String s = item.toString();
            if (s.contains("${")) {
                s = resolver.resolveString(s, "forEach.import");
            }
            values.add(s);
        }
        return values;
    }

    private static String resolveAs(ForEachDirective directive,
                                     Map<String, IterationGroup> groups) {
        return switch (directive) {
            case ForEachDirective.GroupRef ref -> {
                if (ref.as() != null) yield ref.as();
                IterationGroup group = groups.get(ref.groupName());
                yield group != null ? group.as() : ref.groupName();
            }
            case ForEachDirective.InlineIteration inline -> inline.as();
        };
    }

    private static void validateValue(String value, String importAlias) {
        if (value.contains(".")) {
            throw new IllegalArgumentException(
                    "Import '" + importAlias + "' forEach value '" + value
                    + "' contains '.', which is reserved as the ID separator.");
        }
    }

    private static void validateUniqueAlias(String alias, Set<String> seen) {
        if (!seen.add(alias)) {
            throw new IllegalArgumentException(
                    "Duplicate stamped import alias '" + alias
                    + "'. forEach values must be unique.");
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ImportExpanderTest`
Expected: ALL PASS

- [ ] **Step 5: Run full yaml-core suite**

Run: `mvn --batch-mode test -pl yaml-core`
Expected: ALL PASS — no regressions

- [ ] **Step 6: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/module/ImportExpander.java
git add yaml-core/src/test/java/io/casehub/yaml/core/module/ImportExpanderTest.java
git commit -m "feat(#432): ImportExpander — block-level forEach on imports

Phase 1 pre-expansion stamps out N import copies per forEach directive.
Dash-composed aliases (region-us-east), resolved parameters, when-filtering,
CSV typed row support via ObjectVariableSource.drillOnly. Loop directives
preserved for runtime consumption.

Refs #432

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## References

- [2026-09-25-block-level-iteration-design.md] — design spec
- [yaml-core/module/YamlImport.java:1-14] — import record to extend
- [yaml-core/module/ModuleExpander.java:validateImports] — dot check constraint
- [yaml-core/foreach/ForEachExpander.java:170-344] — CSV forEach pattern to reuse
- [yaml-core/foreach/ForEachDirective.java:1-35] — directive parsing
- [yaml-core/orchestration/LoopDirective.java:1-47] — loop model
- [yaml-core/resolver/ObjectVariableSource.java] — drillOnly factory
- [GitHub #432] — focal issue
- [GitHub #429] — prerequisite (ValueType, typed resolution)
