# ICU MessageFormat 2.0 Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #963 — ICU MessageFormat 2.0 integration for multilingual template formatting
**Issue group:** #963

**Goal:** Add locale-aware message formatting (plurals, gender, ordinals) to the template registry's generation path via ICU4J MessageFormat 2.0, as an optional classpath-activated module.

**Architecture:** `MessageFormatResolver` SPI in `template-registry-api` with `CompiledMessage` opaque handle (compile at registration, format at generation). `IcuMessageFormatResolver` implementation in new `template-registry-mf2` module wrapping ICU4J 79.1. `TemplateDefinition` gains a nullable `messageFormat` field. `InMemoryTemplateRegistry.generate()` gains a fail-fast guard; `NlpTemplateRegistry.generate()` overrides with MF2 dispatch. MF2 is generation-only — matching unchanged.

**Tech Stack:** Java 21+, ICU4J 79.1 (`com.ibm.icu:icu4j`), JUnit 5, AssertJ. Existing: `template-registry-api`, `template-registry`, `template-registry-nlp-svo`, `template-registry-llm`.

## Global Constraints

- `template-registry-api` must remain zero external dependencies (yaml-core + Jackson only)
- MF2 syntax follows CLDR 47 stable spec — no `when` keyword, functions are `:string`, `:number`, `:integer`, `:date`, `:time`, `:datetime`
- ICU4J 79.1 MF2 API is at Draft status — the `MessageFormatResolver` SPI insulates the platform
- All coercion failures throw `IllegalArgumentException` — no partial results, no silent fallback
- `InMemoryTemplateRegistry` is a Declaration Primitive — constructor unchanged
- Commits reference #963

---

## Batch 1: SPI and type changes in template-registry-api

### Task 1: MessageFormatResolver SPI and schema types

**Files:**
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/MessageFormatResolver.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/MessageFormatSchema.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/SelectorInfo.java`
- Modify: `template-registry-api/src/main/java/io/casehub/template/registry/TemplateSchema.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/MessageFormatSchemaTest.java`

**Interfaces:**
- Produces: `MessageFormatResolver` (interface: `CompiledMessage compile(String, String)`, `String format(CompiledMessage, Map<String, String>)`, `MessageFormatSchema extractSchema(String)`), `MessageFormatSchema` (record: `pattern`, `selectors`, `variantKeys`), `SelectorInfo` (record: `variableName`, `function`), `TemplateSchema` with 6-arg constructor (adds nullable `messageFormatSchema`)

- [ ] **Step 1: Write tests for MessageFormatSchema and SelectorInfo records**

```java
package io.casehub.template.registry;

import org.junit.jupiter.api.Test;
import java.util.List;
import static org.assertj.core.api.Assertions.*;

class MessageFormatSchemaTest {

    @Test
    void selectorInfoRequiresNonNull() {
        assertThatThrownBy(() -> new SelectorInfo(null, "integer"))
            .isInstanceOf(NullPointerException.class);
        assertThatThrownBy(() -> new SelectorInfo("count", null))
            .isInstanceOf(NullPointerException.class);
    }

    @Test
    void selectorInfoCreation() {
        var info = new SelectorInfo("count", "integer");
        assertThat(info.variableName()).isEqualTo("count");
        assertThat(info.function()).isEqualTo("integer");
    }

    @Test
    void messageFormatSchemaRequiresPattern() {
        assertThatThrownBy(() -> new MessageFormatSchema(null, List.of(), List.of()))
            .isInstanceOf(NullPointerException.class);
    }

    @Test
    void messageFormatSchemaDefensiveCopy() {
        var selectors = new java.util.ArrayList<>(List.of(new SelectorInfo("count", "integer")));
        var variants = new java.util.ArrayList<>(List.of("1", "*"));
        var schema = new MessageFormatSchema(".match {$count :integer}", selectors, variants);
        selectors.clear();
        variants.clear();
        assertThat(schema.selectors()).hasSize(1);
        assertThat(schema.variantKeys()).hasSize(2);
    }

    @Test
    void messageFormatSchemaNullListsDefaultToEmpty() {
        var schema = new MessageFormatSchema(".match {$count :integer}", null, null);
        assertThat(schema.selectors()).isEmpty();
        assertThat(schema.variantKeys()).isEmpty();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl template-registry-api -Dtest=MessageFormatSchemaTest -DfailIfNoTests=false`
Expected: FAIL — classes do not exist yet

- [ ] **Step 3: Implement SelectorInfo record**

```java
package io.casehub.template.registry;

import java.util.Objects;

public record SelectorInfo(
    String variableName,
    String function
) {
    public SelectorInfo {
        Objects.requireNonNull(variableName, "variableName");
        Objects.requireNonNull(function, "function");
    }
}
```

- [ ] **Step 4: Implement MessageFormatSchema record**

```java
package io.casehub.template.registry;

import java.util.List;
import java.util.Objects;

public record MessageFormatSchema(
    String pattern,
    List<SelectorInfo> selectors,
    List<String> variantKeys
) {
    public MessageFormatSchema {
        Objects.requireNonNull(pattern, "pattern");
        selectors = selectors != null ? List.copyOf(selectors) : List.of();
        variantKeys = variantKeys != null ? List.copyOf(variantKeys) : List.of();
    }
}
```

- [ ] **Step 5: Implement MessageFormatResolver interface**

```java
package io.casehub.template.registry;

import java.util.Map;

public interface MessageFormatResolver {

    interface CompiledMessage {}

    CompiledMessage compile(String pattern, String languageTag);

    String format(CompiledMessage compiledMessage, Map<String, String> values);

    MessageFormatSchema extractSchema(String pattern);
}
```

- [ ] **Step 6: Add 6-arg constructor to TemplateSchema**

Add a backward-compatible 6-arg constructor with `messageFormatSchema` as the new last parameter. Keep the existing 5-arg constructor delegating with `null`. Use `ide_insert_member` to add:

```java
public TemplateSchema(String namespace, String templateName,
                       List<String> patterns,
                       Map<String, VariableConstraint> variables,
                       List<StructuralSummary> structuralSummaries,
                       MessageFormatSchema messageFormatSchema) {
    // ... existing validation for first 5 fields ...
    this.messageFormatSchema = messageFormatSchema;
}
```

The existing 5-arg compact constructor becomes a convenience delegating to the 6-arg with `messageFormatSchema = null`.

- [ ] **Step 7: Run all tests to verify no regressions**

Run: `mvn --batch-mode test -pl template-registry-api`
Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
git add template-registry-api/src/main/java/io/casehub/template/registry/MessageFormatResolver.java template-registry-api/src/main/java/io/casehub/template/registry/MessageFormatSchema.java template-registry-api/src/main/java/io/casehub/template/registry/SelectorInfo.java template-registry-api/src/main/java/io/casehub/template/registry/TemplateSchema.java template-registry-api/src/test/java/io/casehub/template/registry/MessageFormatSchemaTest.java
git commit -m "feat(#963): add MessageFormatResolver SPI, MessageFormatSchema, SelectorInfo, TemplateSchema 6-arg ctor"
```

### Task 2: TemplateDefinition messageFormat field and InMemoryTemplateRegistry fail-fast guard

**Files:**
- Modify: `template-registry-api/src/main/java/io/casehub/template/registry/TemplateDefinition.java`
- Modify: `template-registry-api/src/main/java/io/casehub/template/registry/InMemoryTemplateRegistry.java`
- Modify: `template-registry-llm/src/main/java/io/casehub/template/registry/llm/AdaptiveTemplateRegistry.java:570`
- Modify: `template-registry-llm/src/main/java/io/casehub/template/registry/llm/VariationSeedingService.java:63`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/TemplateDefinitionTest.java` (new test for messageFormat field)
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/InMemoryTemplateRegistryTest.java` (add fail-fast test)

**Interfaces:**
- Consumes: `MessageFormatResolver` (from Task 1)
- Produces: `TemplateDefinition` with nullable `messageFormat` field, `Builder.messageFormat(String)`, fail-fast `generate()` in `InMemoryTemplateRegistry` for MF2 templates

- [ ] **Step 1: Write failing test for TemplateDefinition messageFormat field**

Add to existing test class or create new:

```java
@Test
void messageFormatFieldNullByDefault() {
    var def = TemplateDefinition.builder("test")
        .pattern("hello ${name}")
        .build();
    assertThat(def.messageFormat()).isNull();
}

@Test
void messageFormatFieldSetViaBuilder() {
    var def = TemplateDefinition.builder("test")
        .pattern("${count} items")
        .messageFormat(".match {$count :integer}\n1 {{{$count} item}}\n* {{{$count} items}}")
        .build();
    assertThat(def.messageFormat()).startsWith(".match");
}

@Test
void threeArgConstructorSetsMessageFormatNull() {
    var def = new TemplateDefinition("test", List.of("hello ${name}"), Map.of());
    assertThat(def.messageFormat()).isNull();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl template-registry-api -Dtest=TemplateDefinitionTest`
Expected: FAIL — `messageFormat()` method does not exist

- [ ] **Step 3: Add messageFormat field to TemplateDefinition record**

Change the record declaration to add the fourth field. Add a 3-arg convenience constructor delegating with `null`. Add `messageFormat(String)` to Builder. Use `ide_replace_member` on the record.

The record becomes:
```java
public record TemplateDefinition(
    String name,
    List<String> patterns,
    Map<String, VariableConstraint> variables,
    String messageFormat
) {
    public TemplateDefinition(String name, List<String> patterns,
                               Map<String, VariableConstraint> variables) {
        this(name, patterns, variables, null);
    }

    public TemplateDefinition {
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(patterns, "patterns");
        if (patterns.isEmpty()) {
            throw new IllegalArgumentException(
                "Template must have at least one pattern");
        }
        patterns = List.copyOf(patterns);
        variables = variables != null
            ? Collections.unmodifiableMap(new LinkedHashMap<>(variables))
            : Map.of();
    }
    // Builder gains: public Builder messageFormat(String mf) { this.messageFormat = mf; return this; }
}
```

- [ ] **Step 4: Fix direct constructor calls that break**

Two production files use the 3-arg record constructor directly:

**`AdaptiveTemplateRegistry.java:570`** — change to carry forward messageFormat:
```java
new TemplateDefinition(def.name(), expanded, def.variables(), def.messageFormat());
```

**`VariationSeedingService.java:63`** — change to carry forward messageFormat:
```java
new TemplateDefinition(def.name(), allPatterns, def.variables(), def.messageFormat());
```

Also fix Builder's `build()` method to pass `messageFormat`:
```java
public TemplateDefinition build() {
    return new TemplateDefinition(name, patterns, variables, messageFormat);
}
```

- [ ] **Step 5: Write failing test for InMemoryTemplateRegistry fail-fast guard**

Add to `InMemoryTemplateRegistryTest`:

```java
@Test
void generateThrowsForMf2TemplateWithoutResolver() {
    var def = TemplateDefinition.builder("item-count")
        .pattern("${count} items")
        .messageFormat(".match {$count :integer}\n1 {{{$count} item}}\n* {{{$count} items}}")
        .build();
    var ns = new TemplateNamespace("ns", Map.of("item-count", def));
    registry.register(ns);
    assertThatThrownBy(() -> registry.generate("ns", "item-count",
            Map.of("count", "5")))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageContaining("messageFormat")
        .hasMessageContaining("MessageFormatResolver");
}
```

- [ ] **Step 6: Add fail-fast guard in InMemoryTemplateRegistry.generate()**

In `InMemoryTemplateRegistry.generate()`, before the `TemplateGenerator.generate()` call:

```java
if (def.messageFormat() != null) {
    throw new IllegalStateException(
        "Template '" + templateName + "' in namespace '" + namespaceName
        + "' declares messageFormat but InMemoryTemplateRegistry does not "
        + "support MF2 generation. Use NlpTemplateRegistry with a "
        + "MessageFormatResolver.");
}
```

- [ ] **Step 7: Run all tests across affected modules**

Run: `mvn --batch-mode test -pl template-registry-api,template-registry,template-registry-llm,template-registry-nlp-svo`
Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
git add template-registry-api/src/main/java/io/casehub/template/registry/TemplateDefinition.java template-registry-api/src/main/java/io/casehub/template/registry/InMemoryTemplateRegistry.java template-registry-llm/src/main/java/io/casehub/template/registry/llm/AdaptiveTemplateRegistry.java template-registry-llm/src/main/java/io/casehub/template/registry/llm/VariationSeedingService.java template-registry-api/src/test/java/io/casehub/template/registry/TemplateDefinitionTest.java template-registry-api/src/test/java/io/casehub/template/registry/InMemoryTemplateRegistryTest.java
git commit -m "feat(#963): add messageFormat field to TemplateDefinition, fail-fast guard in InMemoryTemplateRegistry"
```

---

## Batch 2: NlpTemplateRegistry MF2 dispatch and CDI wiring

### Task 3: NlpTemplateRegistry MF2 generation dispatch

**Files:**
- Modify: `template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateRegistry.java`
- Modify: `template-registry-llm/src/main/java/io/casehub/template/registry/llm/AdaptiveTemplateRegistry.java` (constructor chain)
- Test: `template-registry/src/test/java/io/casehub/template/registry/nlp/NlpTemplateRegistryTest.java`

**Interfaces:**
- Consumes: `MessageFormatResolver` (from Task 1), `TemplateDefinition.messageFormat()` (from Task 2)
- Produces: `NlpTemplateRegistry` 5-arg constructor with nullable `MessageFormatResolver`, `generate()` override dispatching to MF2, `buildSchema()` override populating `messageFormatSchema`

- [ ] **Step 1: Write failing test for MF2 generation via NlpTemplateRegistry**

Create a stub `MessageFormatResolver` for testing:

```java
private static final MessageFormatResolver STUB_RESOLVER = new MessageFormatResolver() {
    record StubCompiled(String pattern, String lang) implements CompiledMessage {}

    @Override
    public CompiledMessage compile(String pattern, String languageTag) {
        return new StubCompiled(pattern, languageTag);
    }

    @Override
    public String format(CompiledMessage compiled, Map<String, String> values) {
        // Simple stub: just returns "MF2:" + count value for testing dispatch
        String count = values.getOrDefault("count", "?");
        return "MF2:" + count;
    }

    @Override
    public MessageFormatSchema extractSchema(String pattern) {
        return new MessageFormatSchema(pattern,
            List.of(new SelectorInfo("count", "integer")),
            List.of("1", "*"));
    }
};
```

Test:
```java
@Test
void generateDelegatesToMf2ResolverWhenMessageFormatPresent() {
    var registry = new NlpTemplateRegistry(tokenizerFactory, familyRegistry,
        strategies, 0.5, STUB_RESOLVER);

    var def = TemplateDefinition.builder("item-count")
        .pattern("${count} items have been ${action}")
        .messageFormat(".match {$count :integer}\n1 {{{$count} item}}\n* {{{$count} items}}")
        .build();
    var ns = new TemplateNamespace("test", Map.of("item-count", def));
    registry.register(ns);

    String result = registry.generate("test", "item-count",
        Map.of("count", "5", "action", "approved"));
    assertThat(result).isEqualTo("MF2:5");
}

@Test
void generateUsesSlotFillWhenNoMessageFormat() {
    var registry = new NlpTemplateRegistry(tokenizerFactory, familyRegistry,
        strategies, 0.5, STUB_RESOLVER);

    var def = TemplateDefinition.builder("vote")
        .pattern("I ${decision} this ${subject}")
        .build();
    var ns = new TemplateNamespace("test", Map.of("vote", def));
    registry.register(ns);

    String result = registry.generate("test", "vote",
        Map.of("decision", "approve", "subject", "architecture"));
    assertThat(result).isEqualTo("I approve this architecture");
}

@Test
void generateThrowsForMf2TemplateWithoutResolver() {
    var registry = new NlpTemplateRegistry(tokenizerFactory, familyRegistry,
        strategies, 0.5, null);

    var def = TemplateDefinition.builder("item-count")
        .pattern("${count} items")
        .messageFormat(".match {$count :integer}\n1 {{{$count} item}}\n* {{{$count} items}}")
        .build();
    var ns = new TemplateNamespace("test", Map.of("item-count", def));

    assertThatThrownBy(() -> registry.register(ns))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageContaining("MessageFormatResolver");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl template-registry -Dtest=NlpTemplateRegistryTest`
Expected: FAIL — 5-arg constructor does not exist

- [ ] **Step 3: Implement NlpTemplateRegistry changes**

Add to `NlpTemplateRegistry`:

1. **New field:** `private final MessageFormatResolver messageFormatResolver;`

2. **New 5-arg constructor:**
```java
public NlpTemplateRegistry(NlpTokenizerFactory tokenizerFactory,
                             LanguageFamilyRegistry familyRegistry,
                             Map<String, MatchingStrategy> strategies,
                             double scoreThreshold,
                             MessageFormatResolver resolver) {
    super();
    this.tokenizerFactory = Objects.requireNonNull(tokenizerFactory);
    this.familyRegistry = Objects.requireNonNull(familyRegistry);
    this.strategies = Map.copyOf(strategies);
    this.scoreThreshold = scoreThreshold;
    this.messageFormatResolver = resolver;
}
```

Existing 4-arg constructor delegates: `this(tokenizerFactory, familyRegistry, strategies, scoreThreshold, null);`

3. **Modified `buildNamespaceState()`:** After strategy index building, compile MF2 patterns:
```java
Map<String, MessageFormatResolver.CompiledMessage> compiledMf2 = new LinkedHashMap<>();
for (TemplateDefinition def : namespace.templates().values()) {
    if (def.messageFormat() != null) {
        if (messageFormatResolver == null) {
            throw new IllegalStateException(
                "Template '" + def.name() + "' in namespace '"
                + namespace.name() + "' declares messageFormat but no "
                + "MessageFormatResolver is configured. "
                + "Add template-registry-mf2 to the classpath.");
        }
        compiledMf2.put(def.name(),
            messageFormatResolver.compile(def.messageFormat(), lang));
    }
}
```

4. **Modified `NamespaceState`:** Add `Map<String, MessageFormatResolver.CompiledMessage> compiledMf2` field.

5. **Override `generate()`:**
```java
@Override
public String generate(String namespaceName, String templateName,
                        Map<String, String> values) {
    NamespaceState state = namespaceStates.get(namespaceName);
    if (state != null && state.compiledMf2().containsKey(templateName)) {
        return messageFormatResolver.format(
            state.compiledMf2().get(templateName), values);
    }
    return super.generate(namespaceName, templateName, values);
}
```

6. **Override `buildSchema()`:**
```java
@Override
protected TemplateSchema buildSchema(String namespaceName,
                                      TemplateDefinition def) {
    NamespaceState state = namespaceStates.get(namespaceName);
    List<TemplateSchema.StructuralSummary> summaries = state != null
        ? state.strategy().structuralSummaries(state.index(), def.name())
        : List.of();

    MessageFormatSchema mfSchema = null;
    if (def.messageFormat() != null && messageFormatResolver != null) {
        mfSchema = messageFormatResolver.extractSchema(def.messageFormat());
    }

    return new TemplateSchema(namespaceName, def.name(),
        def.patterns(), def.variables(), summaries, mfSchema);
}
```

- [ ] **Step 4: Update AdaptiveTemplateRegistry constructor chain**

Both constructors gain `MessageFormatResolver resolver` parameter. The convenience 7-arg delegates with `resolver = null`. The full constructor forwards to `super`:

```java
public AdaptiveTemplateRegistry(NlpTokenizerFactory tokenizerFactory,
                                LanguageFamilyRegistry familyRegistry,
                                Map<String, MatchingStrategy> strategies,
                                double scoreThreshold,
                                AdaptiveFallbackMatcher fallbackMatcher,
                                double confidenceThreshold,
                                ClassificationCache classificationCache) {
    this(tokenizerFactory, familyRegistry, strategies, scoreThreshold,
         fallbackMatcher, confidenceThreshold, classificationCache, null, 0.5, null);
}

public AdaptiveTemplateRegistry(NlpTokenizerFactory tokenizerFactory,
                                LanguageFamilyRegistry familyRegistry,
                                Map<String, MatchingStrategy> strategies,
                                double scoreThreshold,
                                AdaptiveFallbackMatcher fallbackMatcher,
                                double confidenceThreshold,
                                ClassificationCache classificationCache,
                                EmbeddingModel embeddingModel,
                                double embeddingSimilarityThreshold,
                                MessageFormatResolver resolver) {
    super(tokenizerFactory, familyRegistry, strategies, scoreThreshold, resolver);
    // ... existing field assignments ...
}
```

- [ ] **Step 5: Run all tests across affected modules**

Run: `mvn --batch-mode test -pl template-registry-api,template-registry,template-registry-llm,template-registry-nlp-svo`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateRegistry.java template-registry-llm/src/main/java/io/casehub/template/registry/llm/AdaptiveTemplateRegistry.java template-registry/src/test/java/io/casehub/template/registry/nlp/NlpTemplateRegistryTest.java
git commit -m "feat(#963): NlpTemplateRegistry MF2 dispatch — compile at register, format at generate"
```

---

## Batch 3: ICU4J implementation module

### Task 4: template-registry-mf2 module with IcuMessageFormatResolver

**Files:**
- Create: `template-registry-mf2/pom.xml`
- Create: `template-registry-mf2/src/main/java/io/casehub/template/registry/mf2/IcuMessageFormatResolver.java`
- Create: `template-registry-mf2/src/main/java/io/casehub/template/registry/mf2/Mf2TypeCoercer.java`
- Create: `template-registry-mf2/src/main/java/io/casehub/template/registry/mf2/Mf2SchemaExtractor.java`
- Modify: `pom.xml` (parent — add module)
- Test: `template-registry-mf2/src/test/java/io/casehub/template/registry/mf2/IcuMessageFormatResolverTest.java`

**Interfaces:**
- Consumes: `MessageFormatResolver`, `CompiledMessage`, `MessageFormatSchema`, `SelectorInfo` (from Task 1)
- Produces: `IcuMessageFormatResolver` (implements `MessageFormatResolver`), CDI `@ApplicationScoped` bean

- [ ] **Step 1: Create module pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
         https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.4-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-template-registry-mf2</artifactId>
    <name>CaseHub Platform — Template Registry MF2</name>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-template-registry-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>com.ibm.icu</groupId>
            <artifactId>icu4j</artifactId>
            <version>79.1</version>
        </dependency>

        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
</project>
```

Add `<module>template-registry-mf2</module>` to the parent `pom.xml`.

- [ ] **Step 2: Write failing tests for IcuMessageFormatResolver**

```java
package io.casehub.template.registry.mf2;

import io.casehub.template.registry.MessageFormatResolver;
import io.casehub.template.registry.MessageFormatSchema;
import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class IcuMessageFormatResolverTest {

    private final IcuMessageFormatResolver resolver = new IcuMessageFormatResolver();

    @Test
    void compileParsesValidPattern() {
        var compiled = resolver.compile(
            ".match {$count :integer}\n1 {{{$count} item}}\n* {{{$count} items}}",
            "en");
        assertThat(compiled).isNotNull();
    }

    @Test
    void compileThrowsOnInvalidPattern() {
        assertThatThrownBy(() -> resolver.compile("{{invalid {{nested", "en"))
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void compileThrowsOnInvalidLanguageTag() {
        assertThatThrownBy(() -> resolver.compile("{Hello}", "zzz-invalid"))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("Invalid BCP 47");
    }

    @Test
    void formatPluralEnglishSingular() {
        var compiled = resolver.compile(
            ".match {$count :integer}\n1 {{{$count} item}}\n* {{{$count} items}}",
            "en");
        String result = resolver.format(compiled, Map.of("count", "1"));
        assertThat(result).isEqualTo("1 item");
    }

    @Test
    void formatPluralEnglishPlural() {
        var compiled = resolver.compile(
            ".match {$count :integer}\n1 {{{$count} item}}\n* {{{$count} items}}",
            "en");
        String result = resolver.format(compiled, Map.of("count", "5"));
        assertThat(result).isEqualTo("5 items");
    }

    @Test
    void formatGenderSelection() {
        var compiled = resolver.compile(
            ".match {$gender :string}\nmasculine {{He joined}}\nfeminine {{She joined}}\n* {{They joined}}",
            "en");
        assertThat(resolver.format(compiled, Map.of("gender", "masculine")))
            .isEqualTo("He joined");
        assertThat(resolver.format(compiled, Map.of("gender", "feminine")))
            .isEqualTo("She joined");
        assertThat(resolver.format(compiled, Map.of("gender", "other")))
            .isEqualTo("They joined");
    }

    @Test
    void formatSimpleMessage() {
        var compiled = resolver.compile("{Hello, {$name}!}", "en");
        String result = resolver.format(compiled, Map.of("name", "World"));
        assertThat(result).isEqualTo("Hello, World!");
    }

    @Test
    void formatThrowsOnCoercionFailure() {
        var compiled = resolver.compile(
            ".match {$count :integer}\n1 {{one}}\n* {{many}}",
            "en");
        assertThatThrownBy(() -> resolver.format(compiled, Map.of("count", "abc")))
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void extractSchemaReturnsSelectors() {
        var schema = resolver.extractSchema(
            ".match {$count :integer}\n1 {{{$count} item}}\n* {{{$count} items}}");
        assertThat(schema).isNotNull();
        assertThat(schema.pattern()).contains(".match");
        assertThat(schema.selectors()).isNotEmpty();
        assertThat(schema.variantKeys()).contains("1", "*");
    }

    @Test
    void formatFrenchPlural() {
        var compiled = resolver.compile(
            ".match {$count :integer}\n1 {{{$count} élément}}\n* {{{$count} éléments}}",
            "fr");
        assertThat(resolver.format(compiled, Map.of("count", "1")))
            .isEqualTo("1 élément");
        assertThat(resolver.format(compiled, Map.of("count", "5")))
            .isEqualTo("5 éléments");
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl template-registry-mf2`
Expected: FAIL — class does not exist

- [ ] **Step 4: Implement IcuMessageFormatResolver**

```java
package io.casehub.template.registry.mf2;

import com.ibm.icu.message2.MessageFormatter;
import io.casehub.template.registry.MessageFormatResolver;
import io.casehub.template.registry.MessageFormatSchema;

import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;

public class IcuMessageFormatResolver implements MessageFormatResolver {

    private record IcuCompiledMessage(
        MessageFormatter formatter,
        String pattern,
        String languageTag
    ) implements CompiledMessage {}

    @Override
    public CompiledMessage compile(String pattern, String languageTag) {
        Objects.requireNonNull(pattern, "pattern");
        Objects.requireNonNull(languageTag, "languageTag");

        Locale locale = Locale.forLanguageTag(languageTag);
        if (locale.getLanguage().isEmpty()) {
            throw new IllegalArgumentException(
                "Invalid BCP 47 language tag: '" + languageTag + "'");
        }

        try {
            MessageFormatter formatter = MessageFormatter.builder()
                .setPattern(pattern)
                .setLocale(locale)
                .build();
            return new IcuCompiledMessage(formatter, pattern, languageTag);
        } catch (Exception e) {
            throw new IllegalArgumentException(
                "Invalid MF2 pattern: " + e.getMessage(), e);
        }
    }

    @Override
    public String format(CompiledMessage compiledMessage,
                          Map<String, String> values) {
        Objects.requireNonNull(compiledMessage, "compiledMessage");
        Objects.requireNonNull(values, "values");

        IcuCompiledMessage compiled = (IcuCompiledMessage) compiledMessage;
        Map<String, Object> typedValues = Mf2TypeCoercer.coerce(values);
        return compiled.formatter().formatToString(typedValues);
    }

    @Override
    public MessageFormatSchema extractSchema(String pattern) {
        Objects.requireNonNull(pattern, "pattern");
        return Mf2SchemaExtractor.extract(pattern);
    }
}
```

- [ ] **Step 5: Implement Mf2TypeCoercer**

```java
package io.casehub.template.registry.mf2;

import java.util.LinkedHashMap;
import java.util.Map;

final class Mf2TypeCoercer {

    private Mf2TypeCoercer() {}

    static Map<String, Object> coerce(Map<String, String> values) {
        Map<String, Object> result = new LinkedHashMap<>();
        for (var entry : values.entrySet()) {
            result.put(entry.getKey(), coerceValue(entry.getKey(), entry.getValue()));
        }
        return result;
    }

    private static Object coerceValue(String name, String value) {
        if (value == null) return null;
        // Try numeric coercion first — MF2 :integer and :number functions
        // accept numeric values directly. If the value looks numeric, coerce.
        // Otherwise pass as String — :string function and untyped variables
        // accept strings.
        try {
            if (value.contains(".")) {
                return Double.parseDouble(value);
            }
            return Long.parseLong(value);
        } catch (NumberFormatException e) {
            return value;
        }
    }
}
```

Note: The coercion strategy is pragmatic — numeric strings become numbers (for `:integer`/`:number` selectors), everything else stays as strings (for `:string` selectors). ICU4J's `MessageFormatter` handles type dispatch internally based on the function annotation in the pattern. If a pattern declares `.match {$count :integer}` but receives a non-numeric string, ICU4J itself will produce a formatting error — the resolver wraps this as `IllegalArgumentException`.

- [ ] **Step 6: Implement Mf2SchemaExtractor**

```java
package io.casehub.template.registry.mf2;

import io.casehub.template.registry.MessageFormatSchema;
import io.casehub.template.registry.SelectorInfo;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class Mf2SchemaExtractor {

    private static final Pattern MATCH_SELECTOR = Pattern.compile(
        "\\.match\\s+\\{\\$([a-zA-Z_][a-zA-Z0-9_]*)\\s+:([a-zA-Z]+)");
    private static final Pattern VARIANT_KEY = Pattern.compile(
        "(?m)^\\s*([^{\\s]+)\\s+\\{\\{");

    private Mf2SchemaExtractor() {}

    static MessageFormatSchema extract(String pattern) {
        List<SelectorInfo> selectors = new ArrayList<>();
        Matcher matcherSel = MATCH_SELECTOR.matcher(pattern);
        while (matcherSel.find()) {
            selectors.add(new SelectorInfo(matcherSel.group(1), matcherSel.group(2)));
        }

        List<String> variantKeys = new ArrayList<>();
        Matcher matcherVar = VARIANT_KEY.matcher(pattern);
        while (matcherVar.find()) {
            String key = matcherVar.group(1);
            if (!key.startsWith(".")) {
                variantKeys.add(key);
            }
        }

        return new MessageFormatSchema(pattern, selectors, variantKeys);
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl template-registry-mf2`
Expected: ALL PASS. If any ICU4J API surprises (Draft API differences), adjust the implementation.

- [ ] **Step 8: Run full module suite to verify no regressions**

Run: `mvn --batch-mode test -pl template-registry-api,template-registry,template-registry-nlp-svo,template-registry-llm,template-registry-mf2`
Expected: ALL PASS

- [ ] **Step 9: Commit**

```bash
git add template-registry-mf2/ pom.xml
git commit -m "feat(#963): template-registry-mf2 module with IcuMessageFormatResolver wrapping ICU4J 79.1"
```

---

## Batch 4: Integration test

### Task 5: End-to-end MF2 generation integration test

**Files:**
- Create: `template-registry-mf2/src/test/java/io/casehub/template/registry/mf2/Mf2IntegrationTest.java`

**Interfaces:**
- Consumes: `NlpTemplateRegistry` (from Task 3), `IcuMessageFormatResolver` (from Task 4), `SvoMatchingStrategy` + `OpenNlpTokenizerFactory` (existing from template-registry-nlp-svo)

This test requires both `template-registry-nlp-svo` and `template-registry-mf2` on the test classpath to verify the full pipeline: register MF2 templates → match input → generate locale-aware output.

- [ ] **Step 1: Add test-scoped dependency on template-registry-nlp-svo in template-registry-mf2 pom**

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-template-registry-nlp-svo</artifactId>
    <version>${project.version}</version>
    <scope>test</scope>
</dependency>
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-template-registry</artifactId>
    <version>${project.version}</version>
    <scope>test</scope>
</dependency>
```

- [ ] **Step 2: Write integration test**

```java
package io.casehub.template.registry.mf2;

import io.casehub.template.registry.*;
import io.casehub.template.registry.nlp.NlpTemplateRegistry;
import io.casehub.template.registry.nlp.svo.OpenNlpTokenizerFactory;
import io.casehub.template.registry.nlp.svo.SvoMatchingStrategy;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class Mf2IntegrationTest {

    private NlpTemplateRegistry registry;

    @BeforeEach
    void setUp() {
        var tokenizerFactory = new OpenNlpTokenizerFactory();
        var familyRegistry = new LanguageFamilyRegistry();
        familyRegistry.register("en", "svo");
        familyRegistry.register("fr", "svo");

        var svoStrategy = new SvoMatchingStrategy();
        var strategies = Map.of("svo", (MatchingStrategy) svoStrategy);
        var resolver = new IcuMessageFormatResolver();

        registry = new NlpTemplateRegistry(tokenizerFactory, familyRegistry,
            strategies, 0.5, resolver);
    }

    @Test
    void matchThenGeneratePluralEnglish() {
        var def = TemplateDefinition.builder("item-count")
            .pattern("${count} items have been ${action}")
            .messageFormat(".match {$count :integer}\n1 {{{$count} item has been {$action}}}\n* {{{$count} items have been {$action}}}")
            .build();
        var ns = new TemplateNamespace("protocol:work", Map.of("item-count", def));
        registry.register(ns);

        // Matching uses regex pattern
        var match = (TemplateMatch.Matched) registry.match("protocol:work",
            "5 items have been approved");
        assertThat(match.fields()).containsEntry("count", "5");
        assertThat(match.fields()).containsEntry("action", "approved");

        // Generation uses MF2 — plural-aware
        String singular = registry.generate("protocol:work", "item-count",
            Map.of("count", "1", "action", "approved"));
        assertThat(singular).isEqualTo("1 item has been approved");

        String plural = registry.generate("protocol:work", "item-count",
            Map.of("count", "5", "action", "approved"));
        assertThat(plural).isEqualTo("5 items have been approved");
    }

    @Test
    void slotFillTemplateUnaffectedByMf2Module() {
        var def = TemplateDefinition.builder("vote")
            .pattern("I ${decision} this ${subject}")
            .build();
        var ns = new TemplateNamespace("protocol:review", Map.of("vote", def));
        registry.register(ns);

        String generated = registry.generate("protocol:review", "vote",
            Map.of("decision", "approve", "subject", "design"));
        assertThat(generated).isEqualTo("I approve this design");
    }

    @Test
    void schemaIncludesMf2Metadata() {
        var def = TemplateDefinition.builder("item-count")
            .pattern("${count} items")
            .messageFormat(".match {$count :integer}\n1 {{{$count} item}}\n* {{{$count} items}}")
            .build();
        var ns = new TemplateNamespace("test", Map.of("item-count", def));
        registry.register(ns);

        var schema = registry.schema("test", "item-count");
        assertThat(schema).isPresent();
        assertThat(schema.get().messageFormatSchema()).isNotNull();
        assertThat(schema.get().messageFormatSchema().selectors())
            .extracting(SelectorInfo::variableName)
            .contains("count");
    }

    @Test
    void frenchPluralFormatting() {
        var def = TemplateDefinition.builder("element-count")
            .pattern("${count} éléments")
            .messageFormat(".match {$count :integer}\n1 {{{$count} élément}}\n* {{{$count} éléments}}")
            .build();
        var ns = new TemplateNamespace("test", Map.of("element-count", def), "fr");
        registry.register(ns);

        assertThat(registry.generate("test", "element-count", Map.of("count", "1")))
            .isEqualTo("1 élément");
        assertThat(registry.generate("test", "element-count", Map.of("count", "3")))
            .isEqualTo("3 éléments");
    }
}
```

- [ ] **Step 3: Run integration tests**

Run: `mvn --batch-mode test -pl template-registry-mf2 -Dtest=Mf2IntegrationTest`
Expected: ALL PASS

- [ ] **Step 4: Run full build to verify everything compiles and passes**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git add template-registry-mf2/
git commit -m "test(#963): end-to-end MF2 integration test — plural English, French, schema metadata"
```

## References

- [docs/specs/issue-963-icu-messageformat-2/2026-11-27-icu-messageformat-2-design.md] — design spec this plan implements
- [template-registry-api/src/main/java/io/casehub/template/registry/TemplateDefinition.java] — record being extended
- [template-registry-api/src/main/java/io/casehub/template/registry/InMemoryTemplateRegistry.java:255-274] — generate() method receiving fail-fast guard
- [template-registry-api/src/main/java/io/casehub/template/registry/TemplateGenerator.java] — existing slot-fill generation
- [template-registry-api/src/main/java/io/casehub/template/registry/TemplateSchema.java] — schema record being extended
- [template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateRegistry.java] — NLP registry receiving MF2 dispatch
- [template-registry-llm/src/main/java/io/casehub/template/registry/llm/AdaptiveTemplateRegistry.java:63-83] — constructor chain update
- [template-registry-llm/src/main/java/io/casehub/template/registry/llm/VariationSeedingService.java:63] — TemplateDefinition reconstruction
- [template-registry-nlp-svo/pom.xml] — module structure reference
- [GitHub #963] — focal issue
- [GitHub #959] — unified template registry (prerequisite)
- [GitHub #965] — multi-language NLP tokenizers (MatchingStrategy SPI reference)
- [GitHub #1013] — CDI producer wiring (prerequisite for production CDI activation)
