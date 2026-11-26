# Adaptive Semantic Variation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #971 — adaptive semantic variation
**Issue group:** #971, #967 (replaceOrRegister — subsumed)

**Goal:** Add three-tier semantic variation matching to the template registry — LLM-seeded variations at registration time, NLP structural matching on all patterns, and runtime adaptive LLM fallback that learns new phrasings.

**Architecture:** SPIs (`VariationSeeder`, `AdaptiveFallbackMatcher`, `CollisionDetector`) in `template-registry-api` (zero-dep). LLM implementations in new `template-registry-llm` module (depends on `template-registry` + `langchain4j-core`). `AdaptiveTemplateRegistry` extends `NlpTemplateRegistry` with tier 3 adaptive fallback, classification cache, and learned variation registration via CAS retry.

**Tech Stack:** Java 21, LangChain4j 1.19.0 (ChatModel structured output), OpenNLP (existing), JUnit 5, AssertJ

## Global Constraints

- `template-registry-api` must remain zero-dependency — no LangChain4j, no OpenNLP, no Quarkus
- `template-registry` dependency profile unchanged — no new dependencies added
- All new SPIs take a `language` parameter for i18n hooks (English-only now)
- `TemplateNamespace` language field defaults to `"en"` — backward-compatible two-arg constructor
- Every commit references #971

---

## Batch 1: SPI Foundation (template-registry-api)

### Task 1: replaceOrRegister and matchStructural on UnifiedTemplateRegistry

**Files:**
- Modify: `template-registry-api/src/main/java/io/casehub/template/registry/UnifiedTemplateRegistry.java`
- Modify: `template-registry-api/src/main/java/io/casehub/template/registry/InMemoryTemplateRegistry.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/InMemoryTemplateRegistryTest.java`

**Interfaces:**
- Produces: `UnifiedTemplateRegistry.replaceOrRegister(TemplateNamespace)`, `UnifiedTemplateRegistry.matchStructural(String)`, `InMemoryTemplateRegistry.currentSnapshot()`, `InMemoryTemplateRegistry.compareAndSetSnapshot(Snapshot, Snapshot)`

- [ ] **Step 1: Write failing test for replaceOrRegister**

```java
@Test
void replaceOrRegister_replacesExistingNamespace() {
    var ns1 = new TemplateNamespace("ns",
        Map.of("t1", TemplateDefinition.builder("t1").pattern("hello ${name}").build()));
    registry.register(ns1);

    var ns2 = new TemplateNamespace("ns",
        Map.of("t1", TemplateDefinition.builder("t1").pattern("hi ${name}").build()));
    registry.replaceOrRegister(ns2);

    var result = registry.match("ns", "hi world");
    assertThat(result).isInstanceOf(TemplateMatch.Matched.class);
    var matched = (TemplateMatch.Matched) result;
    assertThat(matched.fields()).containsEntry("name", "world");

    // Old pattern no longer matches
    var old = registry.match("ns", "hello world");
    assertThat(old).isInstanceOf(TemplateMatch.Unmatched.class);
}

@Test
void replaceOrRegister_registersNewNamespace() {
    var ns = new TemplateNamespace("ns",
        Map.of("t1", TemplateDefinition.builder("t1").pattern("hello ${name}").build()));
    registry.replaceOrRegister(ns);

    var result = registry.match("ns", "hello world");
    assertThat(result).isInstanceOf(TemplateMatch.Matched.class);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl template-registry-api test -Dtest=InMemoryTemplateRegistryTest#replaceOrRegister_replacesExistingNamespace -Dtest=InMemoryTemplateRegistryTest#replaceOrRegister_registersNewNamespace --batch-mode`
Expected: compilation error — `replaceOrRegister` not defined

- [ ] **Step 3: Add replaceOrRegister default method to UnifiedTemplateRegistry and matchStructural**

Add to `UnifiedTemplateRegistry.java`:
```java
default void replaceOrRegister(TemplateNamespace namespace) {
    deregister(namespace.name());
    register(namespace);
}

default TemplateMatch matchStructural(String input) {
    return match(input);
}
```

Override in `InMemoryTemplateRegistry.java` with single-CAS implementation:
```java
@Override
public void replaceOrRegister(TemplateNamespace namespace) {
    Objects.requireNonNull(namespace, "namespace");
    while (true) {
        Snapshot current = snapshot.get();
        Snapshot next = current.withoutNamespace(namespace.name())
                               .withNamespace(namespace);
        if (snapshot.compareAndSet(current, next)) {
            return;
        }
    }
}
```

Add protected snapshot access methods to `InMemoryTemplateRegistry`:
```java
protected Snapshot currentSnapshot() {
    return snapshot.get();
}

protected boolean compareAndSetSnapshot(Snapshot expected, Snapshot next) {
    return snapshot.compareAndSet(expected, next);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -pl template-registry-api test --batch-mode`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add template-registry-api/
git commit -m "feat(#971): add replaceOrRegister and matchStructural to UnifiedTemplateRegistry

Implements #967. Single-CAS atomic namespace replacement with no gap
where namespace is absent. matchStructural provides structural-only
matching for collision detection. Protected snapshot accessors for
subclass CAS operations.

Refs #971"
```

### Task 2: TemplateNamespace language field, new API types, and CollisionDetector

**Files:**
- Modify: `template-registry-api/src/main/java/io/casehub/template/registry/TemplateNamespace.java`
- Modify: `template-registry-api/src/main/java/io/casehub/template/registry/CandidateOutcome.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/VariationSeeder.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/AdaptiveFallbackMatcher.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/ClassificationResult.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/TemplateCandidate.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/CollisionDetector.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/TemplateNamespaceTest.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/ClassificationResultTest.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/TemplateCandidateTest.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/CollisionDetectorTest.java`

**Interfaces:**
- Consumes: `UnifiedTemplateRegistry.matchStructural(String)` from Task 1
- Produces: `VariationSeeder.seed(TemplateDefinition, String)`, `AdaptiveFallbackMatcher.classify(String, List<TemplateCandidate>, String)`, `ClassificationResult.Matched(templateName, fields, suggestedVariation, confidence)`, `ClassificationResult.Unmatched()`, `TemplateCandidate.from(TemplateDefinition)`, `CollisionDetector.detect(List<String>, Map<String,VariableConstraint>, String, String, UnifiedTemplateRegistry)`, `TemplateNamespace(name, templates, language)`

- [ ] **Step 1: Write failing tests for TemplateNamespace language field**

```java
@Test
void twoArgConstructor_defaultsToEnglish() {
    var ns = new TemplateNamespace("ns", Map.of("t",
        TemplateDefinition.builder("t").pattern("hello").build()));
    assertThat(ns.language()).isEqualTo("en");
}

@Test
void threeArgConstructor_acceptsLanguage() {
    var ns = new TemplateNamespace("ns", Map.of("t",
        TemplateDefinition.builder("t").pattern("hello").build()), "de");
    assertThat(ns.language()).isEqualTo("de");
}

@Test
void nullLanguage_defaultsToEnglish() {
    var ns = new TemplateNamespace("ns", Map.of("t",
        TemplateDefinition.builder("t").pattern("hello").build()), null);
    assertThat(ns.language()).isEqualTo("en");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl template-registry-api test -Dtest=TemplateNamespaceTest --batch-mode`
Expected: compilation error — three-arg constructor not found

- [ ] **Step 3: Add language field to TemplateNamespace**

Modify `TemplateNamespace.java` to add `language` field with two-arg backward-compatible constructor per spec.

- [ ] **Step 4: Fix all callers of TemplateNamespace two-arg constructor**

The existing two-arg constructor delegates to three-arg — existing callers should continue to compile. Run full module test to confirm.

- [ ] **Step 5: Create SPI interfaces and types**

Create `VariationSeeder.java`, `AdaptiveFallbackMatcher.java`, `ClassificationResult.java`, `TemplateCandidate.java` per spec. Add `ADAPTIVE_MATCHED` to `CandidateOutcome` enum.

- [ ] **Step 6: Write tests for ClassificationResult, TemplateCandidate**

```java
// ClassificationResultTest
@Test
void matched_requiresNonNullFields() {
    assertThatThrownBy(() -> new ClassificationResult.Matched(
        "t1", null, "pattern", 0.9))
        .isInstanceOf(NullPointerException.class);
}

@Test
void matched_fieldsAreImmutable() {
    var fields = new HashMap<String, String>();
    fields.put("k", "v");
    var m = new ClassificationResult.Matched("t1", fields, "pattern", 0.9);
    assertThatThrownBy(() -> m.fields().put("k2", "v2"))
        .isInstanceOf(UnsupportedOperationException.class);
}

@Test
void confidence_rejectsBelowZero() {
    assertThatThrownBy(() -> new ClassificationResult.Matched(
        "t1", Map.of(), "pattern", -0.1))
        .isInstanceOf(IllegalArgumentException.class);
}

@Test
void confidence_rejectsAboveOne() {
    assertThatThrownBy(() -> new ClassificationResult.Matched(
        "t1", Map.of(), "pattern", 1.1))
        .isInstanceOf(IllegalArgumentException.class);
}

// TemplateCandidateTest
@Test
void fromDefinition_extractsFields() {
    var def = TemplateDefinition.builder("vote")
        .pattern("I ${decision} this ${subject}")
        .variable("decision", VariableConstraint.enumOf("approve", "reject"))
        .build();
    var candidate = TemplateCandidate.from(def);
    assertThat(candidate.templateName()).isEqualTo("vote");
    assertThat(candidate.patterns()).containsExactly("I ${decision} this ${subject}");
    assertThat(candidate.variables()).containsKey("decision");
}
```

- [ ] **Step 7: Write CollisionDetector and tests**

Create `CollisionDetector.java` per spec with `substituteTestValues` for enum constraints.

```java
// CollisionDetectorTest
@Test
void detect_findsCollisionWithOtherNamespace() {
    var ns1 = new TemplateNamespace("ns1", Map.of("t1",
        TemplateDefinition.builder("t1")
            .pattern("I ${action} this ${thing}")
            .variable("action", VariableConstraint.string())
            .variable("thing", VariableConstraint.string())
            .build()));
    registry.register(ns1);

    var collisions = CollisionDetector.detect(
        List.of("I ${action} this ${thing}"),
        Map.of("action", VariableConstraint.string(),
               "thing", VariableConstraint.string()),
        "ns2", "t2", registry);

    assertThat(collisions).hasSize(1);
    assertThat(collisions.get(0).collidingNamespace()).isEqualTo("ns1");
}

@Test
void detect_ignoresSelfMatch() {
    var ns = new TemplateNamespace("ns", Map.of("t1",
        TemplateDefinition.builder("t1")
            .pattern("I ${action} this ${thing}")
            .variable("action", VariableConstraint.string())
            .variable("thing", VariableConstraint.string())
            .build()));
    registry.register(ns);

    var collisions = CollisionDetector.detect(
        List.of("I ${action} this ${thing}"),
        Map.of("action", VariableConstraint.string(),
               "thing", VariableConstraint.string()),
        "ns", "t1", registry);

    assertThat(collisions).isEmpty();
}

@Test
void detect_usesEnumFirstValueForSubstitution() {
    var ns = new TemplateNamespace("ns", Map.of("vote",
        TemplateDefinition.builder("vote")
            .pattern("I ${decision} this ${subject}")
            .variable("decision", VariableConstraint.enumOf("approve", "reject"))
            .variable("subject", VariableConstraint.string())
            .build()));
    registry.register(ns);

    var collisions = CollisionDetector.detect(
        List.of("I ${decision} this ${subject}"),
        Map.of("decision", VariableConstraint.enumOf("approve", "reject"),
               "subject", VariableConstraint.string()),
        "ns2", "t2", registry);

    assertThat(collisions).hasSize(1);
}

@Test
void detect_usesMatchStructural() {
    // Verifies CollisionDetector calls matchStructural, not match
    // — prevents LLM calls during collision checking
}
```

- [ ] **Step 8: Run all template-registry-api tests**

Run: `mvn -pl template-registry-api test --batch-mode`
Expected: all PASS

- [ ] **Step 9: Commit**

```bash
git add template-registry-api/
git commit -m "feat(#971): add variation SPIs, CollisionDetector, and TemplateNamespace language field

VariationSeeder, AdaptiveFallbackMatcher, ClassificationResult,
TemplateCandidate, CollisionDetector — all zero-dep in template-registry-api.
TemplateNamespace gains backward-compatible language field (default: en).
CandidateOutcome.ADAPTIVE_MATCHED for trace output.

Refs #971"
```

## Batch 2: NLP Tier Update (template-registry)

### Task 3: NlpTemplateRegistry replaceOrRegister and recompileNlp

**Files:**
- Modify: `template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateRegistry.java`
- Test: `template-registry/src/test/java/io/casehub/template/registry/nlp/NlpTemplateRegistryTest.java`

**Interfaces:**
- Consumes: `InMemoryTemplateRegistry.replaceOrRegister(TemplateNamespace)` from Task 1
- Produces: `NlpTemplateRegistry.replaceOrRegister(TemplateNamespace)`, `NlpTemplateRegistry.recompileNlp(String, TemplateNamespace)` (protected)

- [ ] **Step 1: Write failing test for NlpTemplateRegistry.replaceOrRegister**

```java
@Test
void replaceOrRegister_updatesNlpCompiledCache() {
    var ns1 = new TemplateNamespace("ns", Map.of("t1",
        TemplateDefinition.builder("t1")
            .pattern("I ${decision} this ${subject}")
            .variable("decision", VariableConstraint.enumOf("approve", "reject"))
            .variable("subject", VariableConstraint.string())
            .build()));
    registry.register(ns1);

    // NLP should match inflected form
    var before = registry.match("ns", "I approved this design");
    assertThat(before).isInstanceOf(TemplateMatch.Matched.class);

    // Replace with different pattern
    var ns2 = new TemplateNamespace("ns", Map.of("t1",
        TemplateDefinition.builder("t1")
            .pattern("${subject} gets my ${decision}")
            .variable("decision", VariableConstraint.enumOf("approve", "reject"))
            .variable("subject", VariableConstraint.string())
            .build()));
    registry.replaceOrRegister(ns2);

    // Old NLP pattern should no longer match
    var afterOld = registry.match("ns", "I approved this design");
    assertThat(afterOld).isNotInstanceOf(TemplateMatch.Matched.class);

    // New NLP pattern should match
    var afterNew = registry.match("ns", "design gets my approve");
    assertThat(afterNew).isInstanceOf(TemplateMatch.Matched.class);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl template-registry test -Dtest=NlpTemplateRegistryTest#replaceOrRegister_updatesNlpCompiledCache --batch-mode`
Expected: FAIL — old NLP pattern still matches (nlpCompiled not cleared)

- [ ] **Step 3: Implement replaceOrRegister and recompileNlp**

```java
@Override
public void replaceOrRegister(TemplateNamespace namespace) {
    super.replaceOrRegister(namespace);
    recompileNlp(namespace.name(), namespace);
}

protected void recompileNlp(String namespaceName, TemplateNamespace namespace) {
    nlpCompiled.keySet().removeIf(k -> k.startsWith(namespaceName + ":"));
    for (TemplateDefinition def : namespace.templates().values()) {
        String key = namespaceName + ":" + def.name();
        nlpCompiled.put(key, NlpTemplateCompiler.compile(def, tokenizer));
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -pl template-registry test --batch-mode`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add template-registry/
git commit -m "feat(#971): NlpTemplateRegistry.replaceOrRegister with nlpCompiled cache sync

Override replaceOrRegister to clear and recompile NLP patterns.
Protected recompileNlp() helper for AdaptiveTemplateRegistry subclass.

Refs #971"
```

## Batch 3: template-registry-llm Module

### Task 4: Module scaffolding and ClassificationCache

**Files:**
- Create: `template-registry-llm/pom.xml`
- Create: `template-registry-llm/src/main/java/io/casehub/template/registry/llm/ClassificationCache.java`
- Test: `template-registry-llm/src/test/java/io/casehub/template/registry/llm/ClassificationCacheTest.java`
- Modify: `pom.xml` (parent — add module)

**Interfaces:**
- Produces: `ClassificationCache.CacheKey(namespace, input)`, `ClassificationCache.get(CacheKey)`, `ClassificationCache.putPositive(CacheKey, ClassificationResult.Matched)`, `ClassificationCache.putNegative(CacheKey)`, `ClassificationCache.invalidateNamespace(String)`

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

    <artifactId>casehub-platform-template-registry-llm</artifactId>
    <name>CaseHub Platform — Template Registry LLM</name>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-template-registry</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>dev.langchain4j</groupId>
            <artifactId>langchain4j-core</artifactId>
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

Add `<module>template-registry-llm</module>` after `template-registry` in parent pom.

- [ ] **Step 2: Write failing tests for ClassificationCache**

```java
@Test
void get_returnsNullForUnknownKey() {
    var cache = new ClassificationCache(Duration.ofMinutes(30),
        Duration.ofMinutes(5), 1000);
    var key = new ClassificationCache.CacheKey("ns", "input");
    assertThat(cache.get(key)).isNull();
}

@Test
void putPositive_thenGet_returnsCachedResult() {
    var cache = new ClassificationCache(Duration.ofMinutes(30),
        Duration.ofMinutes(5), 1000);
    var key = new ClassificationCache.CacheKey("ns", "I'm in favour of this design");
    var matched = new ClassificationResult.Matched(
        "vote", Map.of("decision", "approve", "subject", "design"),
        "I'm in favour of this ${subject}", 0.9);
    cache.putPositive(key, matched);

    var entry = cache.get(key);
    assertThat(entry).isNotNull();
    assertThat(entry.isPositive()).isTrue();
}

@Test
void putNegative_thenGet_returnsNegativeEntry() {
    var cache = new ClassificationCache(Duration.ofMinutes(30),
        Duration.ofMinutes(5), 1000);
    var key = new ClassificationCache.CacheKey("ns", "unrelated text");
    cache.putNegative(key);

    var entry = cache.get(key);
    assertThat(entry).isNotNull();
    assertThat(entry.isPositive()).isFalse();
}

@Test
void invalidateNamespace_clearsAllEntriesForNamespace() {
    var cache = new ClassificationCache(Duration.ofMinutes(30),
        Duration.ofMinutes(5), 1000);
    var key1 = new ClassificationCache.CacheKey("ns1", "input1");
    var key2 = new ClassificationCache.CacheKey("ns1", "input2");
    var key3 = new ClassificationCache.CacheKey("ns2", "input1");
    cache.putNegative(key1);
    cache.putNegative(key2);
    cache.putNegative(key3);

    cache.invalidateNamespace("ns1");

    assertThat(cache.get(key1)).isNull();
    assertThat(cache.get(key2)).isNull();
    assertThat(cache.get(key3)).isNotNull();
}

@Test
void negativeTtl_expiresEntry() throws InterruptedException {
    var cache = new ClassificationCache(Duration.ofMinutes(30),
        Duration.ofMillis(50), 1000);
    var key = new ClassificationCache.CacheKey("ns", "input");
    cache.putNegative(key);
    Thread.sleep(100);
    assertThat(cache.get(key)).isNull();
}
```

- [ ] **Step 3: Implement ClassificationCache**

ConcurrentHashMap-backed, TTL-based eviction on get, LRU eviction when max entries exceeded. `CacheKey` is a typed record. `Entry` holds either a `ClassificationResult.Matched` or null (negative), plus insertion timestamp.

- [ ] **Step 4: Run tests**

Run: `mvn -pl template-registry-llm test --batch-mode`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add template-registry-llm/ pom.xml
git commit -m "feat(#971): add template-registry-llm module with ClassificationCache

New module for LLM-backed template variation. ClassificationCache stores
positive and negative LLM classification results with configurable TTLs
and LRU eviction.

Refs #971"
```

### Task 5: AdaptiveTemplateRegistry

**Files:**
- Create: `template-registry-llm/src/main/java/io/casehub/template/registry/llm/AdaptiveTemplateRegistry.java`
- Test: `template-registry-llm/src/test/java/io/casehub/template/registry/llm/AdaptiveTemplateRegistryTest.java`

**Interfaces:**
- Consumes: `NlpTemplateRegistry` (superclass), `AdaptiveFallbackMatcher.classify()`, `CollisionDetector.detect()`, `ClassificationCache`, `InMemoryTemplateRegistry.currentSnapshot()`/`compareAndSetSnapshot()`
- Produces: `AdaptiveTemplateRegistry` — the tier 3 registry implementation

- [ ] **Step 1: Write failing test — adaptive fallback classifies unmatched input**

```java
@Test
void match_delegatesToAdaptiveFallbackOnUnmatched() {
    var stubFallback = new StubAdaptiveFallback(
        new ClassificationResult.Matched(
            "vote", Map.of("decision", "approve", "subject", "design"),
            "I'm in favour of this ${subject}", 0.95));

    var registry = new AdaptiveTemplateRegistry(
        tokenizer, stubFallback, 0.8, cache);

    var ns = new TemplateNamespace("protocol:review", Map.of("vote",
        TemplateDefinition.builder("vote")
            .pattern("I ${decision} this ${subject}")
            .variable("decision", VariableConstraint.enumOf("approve", "reject"))
            .variable("subject", VariableConstraint.string())
            .build()));
    registry.register(ns);

    var result = registry.match("protocol:review",
        "I'm in favour of this design");
    assertThat(result).isInstanceOf(TemplateMatch.Matched.class);
    var matched = (TemplateMatch.Matched) result;
    assertThat(matched.templateName()).isEqualTo("vote");
    assertThat(matched.fields()).containsEntry("decision", "approve");
    assertThat(matched.score()).isEqualTo(0.9);
}
```

- [ ] **Step 2: Write failing test — LLM unavailable degrades to Unmatched**

```java
@Test
void match_degradesToUnmatchedOnLlmFailure() {
    var failingFallback = (AdaptiveFallbackMatcher) (input, candidates, lang) -> {
        throw new RuntimeException("LLM unavailable");
    };

    var registry = new AdaptiveTemplateRegistry(
        tokenizer, failingFallback, 0.8, cache);
    registry.register(ns);

    var result = registry.match("protocol:review",
        "I'm in favour of this design");
    assertThat(result).isInstanceOf(TemplateMatch.Unmatched.class);
}
```

- [ ] **Step 3: Write failing test — classification cache prevents repeated LLM calls**

```java
@Test
void match_usesCacheOnSecondCall() {
    var countingFallback = new CountingAdaptiveFallback(
        new ClassificationResult.Matched(
            "vote", Map.of("decision", "approve", "subject", "design"),
            "I'm in favour of this ${subject}", 0.95));

    var registry = new AdaptiveTemplateRegistry(
        tokenizer, countingFallback, 0.8, cache);
    registry.register(ns);

    registry.match("protocol:review", "I'm in favour of this design");
    registry.match("protocol:review", "I'm in favour of this design");

    assertThat(countingFallback.callCount()).isEqualTo(1);
}
```

- [ ] **Step 4: Write failing test — learned variation matches structurally on next call**

```java
@Test
void learnedVariation_matchesStructurallyWithoutLlm() {
    var stubFallback = new StubAdaptiveFallback(
        new ClassificationResult.Matched(
            "vote", Map.of("decision", "approve", "subject", "design"),
            "This ${subject} gets my ${decision}", 0.95));

    var registry = new AdaptiveTemplateRegistry(
        tokenizer, stubFallback, 0.8, cache);
    registry.register(ns);

    // First call — triggers LLM, registers variation
    registry.match("protocol:review", "This design gets my approve");

    // Replace fallback with one that throws — proving structural match
    var noLlmRegistry = new AdaptiveTemplateRegistry(
        tokenizer, failingFallback, 0.8, new ClassificationCache(...));
    // Copy the registry state... (use replaceOrRegister with expanded ns)

    // Actually: just check the registry now has the variation
    var result = registry.match("protocol:review", "This architecture gets my reject");
    assertThat(result).isInstanceOf(TemplateMatch.Matched.class);
    assertThat(((TemplateMatch.Matched) result).score()).isEqualTo(1.0);
}
```

- [ ] **Step 5: Write failing test — confidence below threshold skips registration**

```java
@Test
void lowConfidence_returnsMatchButDoesNotRegisterVariation() {
    var stubFallback = new StubAdaptiveFallback(
        new ClassificationResult.Matched(
            "vote", Map.of("decision", "approve", "subject", "design"),
            "This ${subject} gets my ${decision}", 0.5)); // below 0.8 threshold

    var registry = new AdaptiveTemplateRegistry(
        tokenizer, stubFallback, 0.8, cache);
    registry.register(ns);

    var result = registry.match("protocol:review",
        "This design gets my approve");
    assertThat(result).isInstanceOf(TemplateMatch.Matched.class);

    // Variation should NOT be registered
    assertThat(registry.match("protocol:review",
        "This architecture gets my reject"))
        .isNotInstanceOf(TemplateMatch.Matched.class);
}
```

- [ ] **Step 6: Write failing test — matchStructural bypasses adaptive fallback**

```java
@Test
void matchStructural_doesNotTriggerAdaptiveFallback() {
    var countingFallback = new CountingAdaptiveFallback(
        new ClassificationResult.Matched(
            "vote", Map.of("decision", "approve", "subject", "design"),
            "pattern", 0.95));

    var registry = new AdaptiveTemplateRegistry(
        tokenizer, countingFallback, 0.8, cache);
    registry.register(ns);

    var result = registry.matchStructural("I'm in favour of this design");
    assertThat(result).isInstanceOf(TemplateMatch.Unmatched.class);
    assertThat(countingFallback.callCount()).isEqualTo(0);
}
```

- [ ] **Step 7: Implement AdaptiveTemplateRegistry**

Implement per spec: `match()` override with tier 3, `adaptiveFallback()` with cache check, `tryRegisterVariation()` with confidence threshold and collision guard, `registerLearnedVariation()` with CAS retry loop, `matchStructural()` override, `replaceOrRegister()` override with cache invalidation, `matchWithTrace()` override.

- [ ] **Step 8: Run all tests**

Run: `mvn -pl template-registry-llm test --batch-mode`
Expected: all PASS

- [ ] **Step 9: Commit**

```bash
git add template-registry-llm/
git commit -m "feat(#971): AdaptiveTemplateRegistry — tier 3 LLM adaptive fallback

Extends NlpTemplateRegistry with LLM classification fallback,
classification cache, confidence threshold, collision guard, and
learned variation registration via CAS retry.

Refs #971"
```

### Task 6: LLM implementations and VariationSeedingService

**Files:**
- Create: `template-registry-llm/src/main/java/io/casehub/template/registry/llm/LlmVariationSeeder.java`
- Create: `template-registry-llm/src/main/java/io/casehub/template/registry/llm/LlmAdaptiveFallback.java`
- Create: `template-registry-llm/src/main/java/io/casehub/template/registry/llm/VariationSeedingService.java`
- Test: `template-registry-llm/src/test/java/io/casehub/template/registry/llm/LlmVariationSeederTest.java`
- Test: `template-registry-llm/src/test/java/io/casehub/template/registry/llm/LlmAdaptiveFallbackTest.java`
- Test: `template-registry-llm/src/test/java/io/casehub/template/registry/llm/VariationSeedingServiceTest.java`

**Interfaces:**
- Consumes: `ChatModel` (LangChain4j), `VariationSeeder`, `AdaptiveFallbackMatcher`, `CollisionDetector`, `UnifiedTemplateRegistry`
- Produces: `LlmVariationSeeder`, `LlmAdaptiveFallback`, `VariationSeedingService.seedAndRegister(TemplateNamespace)`

- [ ] **Step 1: Write failing tests for LlmVariationSeeder**

Test with a stub ChatModel that returns predetermined JSON. Verify:
- Returned variations preserve all `${var}` placeholders
- Variations that drop a placeholder are filtered out
- Empty LLM response returns empty list

- [ ] **Step 2: Implement LlmVariationSeeder**

Build structured-output prompt per spec. Parse JSON response. Validate placeholder preservation.

- [ ] **Step 3: Write failing tests for LlmAdaptiveFallback**

Test with a stub ChatModel. Verify:
- Returns `ClassificationResult.Matched` with correct fields
- Returns `ClassificationResult.Unmatched` when LLM says no match
- Validates field values against variable constraints

- [ ] **Step 4: Implement LlmAdaptiveFallback**

Build classification prompt per spec. Parse structured output. Validate constraints.

- [ ] **Step 5: Write failing tests for VariationSeedingService**

```java
@Test
void seedAndRegister_expandsDefinitionWithVariations() {
    var stubSeeder = (VariationSeeder) (def, lang) ->
        List.of("This ${subject} gets my ${decision}");

    var service = new VariationSeedingService(stubSeeder, registry);
    var ns = new TemplateNamespace("ns", Map.of("vote",
        TemplateDefinition.builder("vote")
            .pattern("I ${decision} this ${subject}")
            .variable("decision", VariableConstraint.enumOf("approve", "reject"))
            .variable("subject", VariableConstraint.string())
            .build()));

    service.seedAndRegister(ns);

    // Seeded variation matches structurally
    var result = registry.match("ns", "This architecture gets my approve");
    assertThat(result).isInstanceOf(TemplateMatch.Matched.class);
}

@Test
void seedAndRegister_rejectsCollidingVariations() {
    // Register ns1 first
    registry.register(new TemplateNamespace("ns1", Map.of("t1",
        TemplateDefinition.builder("t1")
            .pattern("I ${action} this ${thing}")
            .variable("action", VariableConstraint.string())
            .variable("thing", VariableConstraint.string())
            .build())));

    // Seeder returns a variation that collides with ns1
    var stubSeeder = (VariationSeeder) (def, lang) ->
        List.of("I ${action} this ${thing}");

    var service = new VariationSeedingService(stubSeeder, registry);
    var ns2 = new TemplateNamespace("ns2", Map.of("t2",
        TemplateDefinition.builder("t2")
            .pattern("${thing} receives my ${action}")
            .variable("action", VariableConstraint.string())
            .variable("thing", VariableConstraint.string())
            .build()));

    // Should not throw — colliding variation filtered out
    service.seedAndRegister(ns2);

    // Only the canonical pattern registered, not the colliding variation
    assertThat(registry.schemas("ns2").get(0).patterns()).hasSize(1);
}
```

- [ ] **Step 6: Implement VariationSeedingService**

Per spec — seed, collision check, filter, build expanded namespace, register.

- [ ] **Step 7: Run all tests**

Run: `mvn -pl template-registry-llm test --batch-mode`
Expected: all PASS

- [ ] **Step 8: Commit**

```bash
git add template-registry-llm/
git commit -m "feat(#971): LLM implementations and VariationSeedingService

LlmVariationSeeder generates paraphrases via ChatModel structured output.
LlmAdaptiveFallback classifies unmatched input with field extraction.
VariationSeedingService orchestrates seed → collision check → register.

Refs #971"
```

## Batch 4: Integration Tests and ParaphraseCliff Update

### Task 7: Integration tests and ParaphraseCliff update

**Files:**
- Create: `template-registry-llm/src/test/java/io/casehub/template/registry/llm/AdaptiveRegistryIntegrationTest.java`
- Modify: `template-registry/src/test/java/io/casehub/template/registry/nlp/TemplateRegistryIntegrationTest.java`

**Interfaces:**
- Consumes: All types from Tasks 1–6

- [ ] **Step 1: Write integration test — seeded variation matches structural rearrangement**

Register a template with pre-seeded structural rearrangement. Assert regex/NLP match without LLM.

- [ ] **Step 2: Write integration test — adaptive fallback bridges ParaphraseCliff**

Configure `AdaptiveTemplateRegistry` with mock LLM. Assert "I'm in favour of this design" matches via tier 3 with `{decision: "approve", subject: "design"}`.

- [ ] **Step 3: Write integration test — learned variation matches without LLM on second occurrence**

First call triggers adaptive fallback for a structural paraphrase (preserves variables). Second call matches via regex/NLP — no LLM.

- [ ] **Step 4: Write integration test — NearMiss triggers adaptive fallback**

Input that produces NearMiss from tiers 1+2 triggers the adaptive fallback.

- [ ] **Step 5: Write integration test — collision guard rejects unsafe variations**

Adaptive fallback suggests a variation colliding with another namespace. Match returned but variation NOT registered.

- [ ] **Step 6: Update ParaphraseCliff tests**

Add test documenting that ParaphraseCliff is bridged by tier 3 adaptive fallback (not seeded variations). The existing `semanticEquivalentsDoNotMatch` test stays — it documents the tier 1+2 boundary. Add a companion test proving tier 3 handles them.

- [ ] **Step 7: Run full build**

Run: `mvn --batch-mode install`
Expected: all PASS

- [ ] **Step 8: Commit**

```bash
git add template-registry-llm/ template-registry/
git commit -m "feat(#971): integration tests and ParaphraseCliff tier 3 bridge

Proves three-tier matching pipeline: seeded variations for structural
rearrangements, NLP for inflection, adaptive LLM fallback for semantic
paraphrase. ParaphraseCliff bridged via tier 3.

Refs #971"
```

## References

- `specs/issue-971-adaptive-semantic-variation/2026-11-26-adaptive-semantic-variation-design.md` — design spec
- `specs/issue-971-adaptive-semantic-variation/decisions.md` — D1–D7
- `template-registry-api/src/main/java/io/casehub/template/registry/UnifiedTemplateRegistry.java:8` — registry SPI
- `template-registry-api/src/main/java/io/casehub/template/registry/InMemoryTemplateRegistry.java:14` — snapshot model
- `template-registry-api/src/main/java/io/casehub/template/registry/TemplateNamespace.java:8` — namespace record
- `template-registry-api/src/main/java/io/casehub/template/registry/CandidateOutcome.java:3` — outcome enum
- `template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateRegistry.java:24` — NLP registry
- `template-registry/src/test/java/io/casehub/template/registry/nlp/TemplateRegistryIntegrationTest.java:675` — ParaphraseCliff
- GitHub #971, #967, #979, #969
