# Positional Discrimination Trie Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #964 — perf: positional discrimination trie for template candidate selection
**Issue group:** #964

**Goal:** Add a structurally-aware trie that narrows NLP template candidates from O(T×P) bag-of-words scan to O(depth) positional lookup when namespace template counts exceed a configurable threshold.

**Architecture:** `DiscriminationTrie` indexes template patterns by their structural element sequence (literal lemmas + wildcard nodes for variables). `NlpTemplateRegistry.matchInNamespace()` checks per-namespace pattern count and routes to trie walk or existing bag-of-words affinity loop. Trie is per-namespace, immutable after construction, rebuilt on register/deregister.

**Tech Stack:** Pure Java, `java.util.concurrent.ConcurrentHashMap` for per-namespace trie storage, JUnit 5 / AssertJ.

## Global Constraints

- `template-registry` module only — no external dependencies
- Thread safety via immutable trie + ConcurrentHashMap — never `synchronized`
- Existing bag-of-words path unchanged for small registries
- Uses `StructuralMatcher.Element` data already computed by `NlpTemplateCompiler`

---

## Batch 1: Core trie data structure

### Task 1: DiscriminationTrie with build and walk

**Files:**
- Create: `template-registry/src/main/java/io/casehub/template/registry/nlp/DiscriminationTrie.java`
- Test: `template-registry/src/test/java/io/casehub/template/registry/nlp/DiscriminationTrieTest.java`

**Interfaces:**
- Consumes: `StructuralMatcher.Element` (kind, lemma, variableName, optional), `ElementKind` enum, `AnnotatedToken.lemma()`, `NlpTemplateCompiler.CompiledNlpTemplate` (matchers → elements())
- Produces: `DiscriminationTrie.build(compiledTemplates, namespaceName)` → `DiscriminationTrie`, `DiscriminationTrie.walk(inputTokens)` → `List<PatternRef>`, `PatternRef(templateName, patternIndex)`

- [ ] **Step 1: Write failing tests for trie construction and walk**

Create `DiscriminationTrieTest.java`:

```java
package io.casehub.template.registry.nlp;

import io.casehub.template.registry.AnnotatedToken;
import io.casehub.template.registry.NlpTokenizer;
import io.casehub.template.registry.TemplateDefinition;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class DiscriminationTrieTest {

    private final OpenNlpTokenizer tokenizer = new OpenNlpTokenizer();

    @Test
    void singleLiteralPattern_matchesExactInput() {
        // Template "Cancel ${item}" → trie path: LITERAL(cancel) → WILDCARD → leaf
        var trie = buildTrie(Map.of(
            "cancel-order", def("cancel-order", "Cancel ${item}")));

        var results = trie.walk(tokenizer.tokenize("Cancel my subscription"));
        assertThat(results).hasSize(1);
        assertThat(results.get(0).templateName()).isEqualTo("cancel-order");
        assertThat(results.get(0).patternIndex()).isEqualTo(0);
    }

    @Test
    void singleLiteralPattern_noMatchForDifferentInput() {
        var trie = buildTrie(Map.of(
            "cancel-order", def("cancel-order", "Cancel ${item}")));

        var results = trie.walk(tokenizer.tokenize("Submit the report"));
        assertThat(results).isEmpty();
    }

    @Test
    void twoTemplates_discriminatesOnFirstLiteral() {
        var trie = buildTrie(Map.of(
            "cancel-order", def("cancel-order", "Cancel ${item}"),
            "submit-report", def("submit-report", "Submit ${item}")));

        var cancelResults = trie.walk(tokenizer.tokenize("Cancel my subscription"));
        assertThat(cancelResults).hasSize(1);
        assertThat(cancelResults.get(0).templateName()).isEqualTo("cancel-order");

        var submitResults = trie.walk(tokenizer.tokenize("Submit the report"));
        assertThat(submitResults).hasSize(1);
        assertThat(submitResults.get(0).templateName()).isEqualTo("submit-report");
    }

    @Test
    void multiLiteralPattern_matchesPositionally() {
        // "Cancel ${item} now" → LITERAL(cancel) → WILDCARD → LITERAL(now) → leaf
        var trie = buildTrie(Map.of(
            "cancel-now", def("cancel-now", "Cancel ${item} now")));

        var withNow = trie.walk(tokenizer.tokenize("Cancel my subscription now"));
        assertThat(withNow).hasSize(1);

        var withoutNow = trie.walk(tokenizer.tokenize("Cancel my subscription"));
        assertThat(withoutNow).isEmpty();
    }

    @Test
    void leadingVariable_usesWildcardRoot() {
        // "${action} the ${target}" → WILDCARD → LITERAL(the) → WILDCARD → leaf
        var trie = buildTrie(Map.of(
            "action", def("action", "${action} the ${target}")));

        var results = trie.walk(tokenizer.tokenize("Handle the report"));
        assertThat(results).hasSize(1);
        assertThat(results.get(0).templateName()).isEqualTo("action");
    }

    @Test
    void sharedPrefix_branchesCorrectly() {
        // Both start with "Cancel" but diverge at second literal
        var trie = buildTrie(Map.of(
            "cancel-now", def("cancel-now", "Cancel ${item} now"),
            "cancel-later", def("cancel-later", "Cancel ${item} later")));

        var nowResults = trie.walk(tokenizer.tokenize("Cancel my order now"));
        assertThat(nowResults).extracting(DiscriminationTrie.PatternRef::templateName)
            .containsExactly("cancel-now");

        var laterResults = trie.walk(tokenizer.tokenize("Cancel my order later"));
        assertThat(laterResults).extracting(DiscriminationTrie.PatternRef::templateName)
            .containsExactly("cancel-later");
    }

    @Test
    void multiplePatterns_sameTemplate() {
        // Template with two patterns
        var trie = buildTrie(Map.of(
            "greeting", new TemplateDefinition("greeting",
                List.of("Hello ${name}", "Hi ${name}"), Map.of())));

        var helloResults = trie.walk(tokenizer.tokenize("Hello world"));
        assertThat(helloResults).hasSize(1);
        assertThat(helloResults.get(0).patternIndex()).isEqualTo(0);

        var hiResults = trie.walk(tokenizer.tokenize("Hi world"));
        assertThat(hiResults).hasSize(1);
        assertThat(hiResults.get(0).patternIndex()).isEqualTo(1);
    }

    @Test
    void emptyTrie_returnsEmpty() {
        var trie = buildTrie(Map.of());
        var results = trie.walk(tokenizer.tokenize("anything"));
        assertThat(results).isEmpty();
    }

    @Test
    void wildcardScanAhead_findsLiteralAfterMultipleTokens() {
        // "${action} the ${target} at ${location} promptly"
        // WILDCARD → LITERAL(the) → WILDCARD → LITERAL(at) → WILDCARD → LITERAL(promptly) → leaf
        var trie = buildTrie(Map.of(
            "action", def("action", "${action} the ${target} at ${location} promptly")));

        var results = trie.walk(tokenizer.tokenize("Handle the quarterly report at headquarters promptly"));
        assertThat(results).hasSize(1);
    }

    private DiscriminationTrie buildTrie(Map<String, TemplateDefinition> templates) {
        Map<String, NlpTemplateCompiler.CompiledNlpTemplate> compiled = new LinkedHashMap<>();
        for (var entry : templates.entrySet()) {
            compiled.put("ns:" + entry.getKey(),
                NlpTemplateCompiler.compile(entry.getValue(), tokenizer));
        }
        return DiscriminationTrie.build(compiled, "ns");
    }

    private TemplateDefinition def(String name, String pattern) {
        return new TemplateDefinition(name, List.of(pattern), Map.of());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl template-registry -Dtest=DiscriminationTrieTest`
Expected: FAIL — class does not exist

- [ ] **Step 3: Implement DiscriminationTrie**

Create `DiscriminationTrie.java` using `ide_create_file`:

```java
package io.casehub.template.registry.nlp;

import io.casehub.template.registry.AnnotatedToken;
import io.casehub.template.registry.ElementKind;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public final class DiscriminationTrie {

    public record PatternRef(String templateName, int patternIndex) {}

    static final class TrieNode {
        final Map<String, TrieNode> literalChildren;
        final TrieNode wildcardChild;
        final List<PatternRef> leaves;

        TrieNode(Map<String, TrieNode> literalChildren, TrieNode wildcardChild,
                 List<PatternRef> leaves) {
            this.literalChildren = Map.copyOf(literalChildren);
            this.wildcardChild = wildcardChild;
            this.leaves = List.copyOf(leaves);
        }
    }

    private final TrieNode root;

    private DiscriminationTrie(TrieNode root) {
        this.root = root;
    }

    public static DiscriminationTrie build(
            Map<String, NlpTemplateCompiler.CompiledNlpTemplate> compiledTemplates,
            String namespaceName) {
        MutableNode mutableRoot = new MutableNode();

        for (var entry : compiledTemplates.entrySet()) {
            String key = entry.getKey();
            String templateName = key.substring(namespaceName.length() + 1);
            NlpTemplateCompiler.CompiledNlpTemplate compiled = entry.getValue();

            for (int i = 0; i < compiled.matchers().size(); i++) {
                List<StructuralMatcher.Element> elements = compiled.matchers().get(i).elements();
                MutableNode current = mutableRoot;

                for (StructuralMatcher.Element elem : elements) {
                    if (elem.kind() == ElementKind.LITERAL) {
                        current = current.literalChildren.computeIfAbsent(
                            elem.lemma().toLowerCase(), k -> new MutableNode());
                    } else {
                        if (current.wildcardChild == null) {
                            current.wildcardChild = new MutableNode();
                        }
                        current = current.wildcardChild;
                    }
                }
                current.leaves.add(new PatternRef(templateName, i));
            }
        }

        return new DiscriminationTrie(mutableRoot.freeze());
    }

    public List<PatternRef> walk(List<AnnotatedToken> inputTokens) {
        List<PatternRef> results = new ArrayList<>();
        walkRecursive(root, inputTokens, 0, results);
        return results;
    }

    private void walkRecursive(TrieNode node, List<AnnotatedToken> tokens,
                                int tokenIndex, List<PatternRef> results) {
        results.addAll(node.leaves);

        if (tokenIndex >= tokens.size()) return;

        String lemma = tokens.get(tokenIndex).lemma().toLowerCase();

        TrieNode literalChild = node.literalChildren.get(lemma);
        if (literalChild != null) {
            walkRecursive(literalChild, tokens, tokenIndex + 1, results);
        }

        if (node.wildcardChild != null) {
            for (int t = tokenIndex; t < tokens.size(); t++) {
                String scanLemma = tokens.get(t).lemma().toLowerCase();
                TrieNode nextLiteral = node.wildcardChild.literalChildren.get(scanLemma);
                if (nextLiteral != null) {
                    walkRecursive(nextLiteral, tokens, t + 1, results);
                }
            }
            if (node.wildcardChild.leaves.size() > 0) {
                results.addAll(node.wildcardChild.leaves);
            }
        }
    }

    private static final class MutableNode {
        final Map<String, MutableNode> literalChildren = new HashMap<>();
        MutableNode wildcardChild;
        final List<PatternRef> leaves = new ArrayList<>();

        TrieNode freeze() {
            Map<String, TrieNode> frozenLiterals = new HashMap<>();
            literalChildren.forEach((k, v) -> frozenLiterals.put(k, v.freeze()));
            return new TrieNode(
                frozenLiterals,
                wildcardChild != null ? wildcardChild.freeze() : null,
                leaves);
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl template-registry -Dtest=DiscriminationTrieTest`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add template-registry/src/main/java/io/casehub/template/registry/nlp/DiscriminationTrie.java template-registry/src/test/java/io/casehub/template/registry/nlp/DiscriminationTrieTest.java
git commit -m "feat(#964): DiscriminationTrie with positional build and scan-ahead walk Refs #964"
```

## Batch 2: NlpTemplateRegistry integration

### Task 2: Wire trie into NlpTemplateRegistry with threshold activation

**Files:**
- Modify: `template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateRegistry.java`
- Test: `template-registry/src/test/java/io/casehub/template/registry/nlp/TrieActivationTest.java` (new)

**Interfaces:**
- Consumes: `DiscriminationTrie.build(compiledTemplates, namespaceName)`, `DiscriminationTrie.walk(inputTokens)` → `List<PatternRef>`, `StructuralMatcher.match(inputTokens, variables)`, `CompiledNlpTemplate.matchers()`, `CompiledNlpTemplate.keywordSets()`
- Produces: `NlpTemplateRegistry` with trie-based candidate selection above threshold. New constructor parameter `trieActivationThreshold` (default 100). Protected accessor `trieActivationThreshold()`.

- [ ] **Step 1: Write failing tests for threshold activation**

Create `TrieActivationTest.java`:

```java
package io.casehub.template.registry.nlp;

import io.casehub.template.registry.TemplateDefinition;
import io.casehub.template.registry.TemplateMatch;
import io.casehub.template.registry.TemplateNamespace;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class TrieActivationTest {

    private final OpenNlpTokenizer tokenizer = new OpenNlpTokenizer();

    @Test
    void belowThreshold_usesAffinityLoop_matchesCorrectly() {
        // 3 templates, threshold 100 → bag-of-words
        var registry = new NlpTemplateRegistry(tokenizer, 0.3, 0.5, 100);
        registry.register(buildNamespace("test-ns", 3));

        TemplateMatch result = registry.match("test-ns", "Cancel my order");
        assertThat(result).isInstanceOf(TemplateMatch.Matched.class);
        var matched = (TemplateMatch.Matched) result;
        assertThat(matched.templateName()).isEqualTo("cancel");
    }

    @Test
    void aboveThreshold_usesTrieWalk_matchesCorrectly() {
        // 3 templates with threshold 2 → trie activates
        var registry = new NlpTemplateRegistry(tokenizer, 0.3, 0.5, 2);
        registry.register(buildNamespace("test-ns", 3));

        TemplateMatch result = registry.match("test-ns", "Cancel my order");
        assertThat(result).isInstanceOf(TemplateMatch.Matched.class);
        var matched = (TemplateMatch.Matched) result;
        assertThat(matched.templateName()).isEqualTo("cancel");
    }

    @Test
    void trieAndAffinity_produceSameResults() {
        var templates = buildNamespace("test-ns", 5);
        var inputs = List.of(
            "Cancel my order",
            "Submit the report",
            "Review the document",
            "The weather is nice today"
        );

        // Below threshold (bag-of-words)
        var affinityRegistry = new NlpTemplateRegistry(tokenizer, 0.3, 0.5, 100);
        affinityRegistry.register(templates);

        // Above threshold (trie)
        var trieRegistry = new NlpTemplateRegistry(tokenizer, 0.3, 0.5, 2);
        trieRegistry.register(templates);

        for (String input : inputs) {
            TemplateMatch affinityResult = affinityRegistry.match("test-ns", input);
            TemplateMatch trieResult = trieRegistry.match("test-ns", input);

            if (affinityResult instanceof TemplateMatch.Matched am) {
                assertThat(trieResult).isInstanceOf(TemplateMatch.Matched.class);
                var tm = (TemplateMatch.Matched) trieResult;
                assertThat(tm.templateName()).isEqualTo(am.templateName());
            } else {
                assertThat(trieResult).isNotInstanceOf(TemplateMatch.Matched.class);
            }
        }
    }

    @Test
    void deregister_clearsTrie() {
        var registry = new NlpTemplateRegistry(tokenizer, 0.3, 0.5, 2);
        registry.register(buildNamespace("test-ns", 3));

        TemplateMatch before = registry.match("test-ns", "Cancel my order");
        assertThat(before).isInstanceOf(TemplateMatch.Matched.class);

        registry.deregister("test-ns");

        TemplateMatch after = registry.match("Cancel my order");
        assertThat(after).isInstanceOf(TemplateMatch.Unmatched.class);
    }

    @Test
    void replaceOrRegister_rebuildsTrie() {
        var registry = new NlpTemplateRegistry(tokenizer, 0.3, 0.5, 2);
        registry.register(buildNamespace("test-ns", 3));

        // Replace with different templates
        var newTemplates = new LinkedHashMap<String, TemplateDefinition>();
        newTemplates.put("hello", new TemplateDefinition("hello",
            List.of("Hello ${name}"), Map.of()));
        newTemplates.put("goodbye", new TemplateDefinition("goodbye",
            List.of("Goodbye ${name}"), Map.of()));
        newTemplates.put("thanks", new TemplateDefinition("thanks",
            List.of("Thank ${name}"), Map.of()));
        registry.replaceOrRegister(new TemplateNamespace("test-ns", newTemplates, "en"));

        // Old template shouldn't match
        TemplateMatch oldResult = registry.match("test-ns", "Cancel my order");
        assertThat(oldResult).isNotInstanceOf(TemplateMatch.Matched.class);

        // New template should match
        TemplateMatch newResult = registry.match("test-ns", "Hello world");
        assertThat(newResult).isInstanceOf(TemplateMatch.Matched.class);
    }

    private TemplateNamespace buildNamespace(String name, int count) {
        var templates = new LinkedHashMap<String, TemplateDefinition>();
        if (count >= 1) templates.put("cancel", new TemplateDefinition("cancel",
            List.of("Cancel ${item}"), Map.of()));
        if (count >= 2) templates.put("submit", new TemplateDefinition("submit",
            List.of("Submit ${item}"), Map.of()));
        if (count >= 3) templates.put("review", new TemplateDefinition("review",
            List.of("Review ${item}"), Map.of()));
        if (count >= 4) templates.put("approve", new TemplateDefinition("approve",
            List.of("Approve ${item}"), Map.of()));
        if (count >= 5) templates.put("reject", new TemplateDefinition("reject",
            List.of("Reject ${item}"), Map.of()));
        return new TemplateNamespace(name, templates, "en");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl template-registry -Dtest=TrieActivationTest`
Expected: FAIL — constructor does not accept 4 args

- [ ] **Step 3: Add trie fields and constructor to NlpTemplateRegistry**

Add new field and constructor overload. The existing 2-arg and 3-arg constructors delegate with default threshold 100:

```java
private static final int DEFAULT_TRIE_THRESHOLD = 100;

private final int trieActivationThreshold;
private final ConcurrentMap<String, DiscriminationTrie> namespaceTries = new ConcurrentHashMap<>();
```

New constructor:
```java
public NlpTemplateRegistry(NlpTokenizer tokenizer, double affinityThreshold,
                            double scoreThreshold, int trieActivationThreshold) {
    super(tokenizer);
    this.tokenizer = tokenizer;
    this.affinityThreshold = affinityThreshold;
    this.scoreThreshold = scoreThreshold;
    this.trieActivationThreshold = trieActivationThreshold;
}
```

Existing 3-arg constructor delegates: `this(tokenizer, affinityThreshold, scoreThreshold, DEFAULT_TRIE_THRESHOLD);`

Add protected accessor: `protected int trieActivationThreshold() { return trieActivationThreshold; }`

- [ ] **Step 4: Update lifecycle methods to manage trie**

In `register()`, after NLP compilation, check total pattern count and build trie if above threshold:

```java
@Override
public void register(TemplateNamespace namespace) {
    super.register(namespace);
    // existing NLP compilation code...
    rebuildTrieIfNeeded(namespace.name());
}

private void rebuildTrieIfNeeded(String namespaceName) {
    Map<String, NlpTemplateCompiler.CompiledNlpTemplate> nsCompiled = new LinkedHashMap<>();
    String prefix = namespaceName + ":";
    for (var entry : nlpCompiled.entrySet()) {
        if (entry.getKey().startsWith(prefix)) {
            nsCompiled.put(entry.getKey(), entry.getValue());
        }
    }
    int totalPatterns = nsCompiled.values().stream()
        .mapToInt(c -> c.matchers().size()).sum();
    if (totalPatterns >= trieActivationThreshold) {
        namespaceTries.put(namespaceName, DiscriminationTrie.build(nsCompiled, namespaceName));
    } else {
        namespaceTries.remove(namespaceName);
    }
}
```

In `deregister()`, remove trie: `namespaceTries.remove(namespaceName);`

In `replaceOrRegister()` / `recompileNlp()`, rebuild trie after recompilation.

- [ ] **Step 5: Add trie path to matchInNamespace**

Add strategy branch at the top of `matchInNamespace()`, after the regex check:

```java
DiscriminationTrie trie = namespaceTries.get(namespaceName);
if (trie != null) {
    return matchViaTrie(namespaceName, ns, inputTokens, trie);
}
// ... existing bag-of-words loop unchanged
```

Implement `matchViaTrie()`:

```java
private TemplateMatch matchViaTrie(String namespaceName, TemplateNamespace ns,
                                    List<AnnotatedToken> inputTokens,
                                    DiscriminationTrie trie) {
    List<DiscriminationTrie.PatternRef> candidates = trie.walk(inputTokens);
    TemplateMatch.Matched bestMatch = null;
    String nearMissTemplate = null;
    String nearMissPattern = null;
    double nearMissScore = 0.0;

    for (DiscriminationTrie.PatternRef ref : candidates) {
        TemplateDefinition def = ns.templates().get(ref.templateName());
        if (def == null) continue;
        String key = namespaceName + ":" + ref.templateName();
        NlpTemplateCompiler.CompiledNlpTemplate compiled = nlpCompiled.get(key);
        if (compiled == null) continue;

        StructuralMatcher matcher = compiled.matchers().get(ref.patternIndex());
        var result = matcher.match(inputTokens, def.variables());
        if (result.isPresent() && result.get().score() > scoreThreshold) {
            if (bestMatch == null || result.get().score() > bestMatch.score()) {
                bestMatch = new TemplateMatch.Matched(
                    namespaceName, ref.templateName(), ref.patternIndex(),
                    result.get().fields(), result.get().score(), ns.version());
            }
        } else if (result.isPresent() && result.get().score() > nearMissScore) {
            nearMissScore = result.get().score();
            nearMissTemplate = ref.templateName();
            nearMissPattern = def.patterns().get(ref.patternIndex());
        }
    }

    if (bestMatch != null) return bestMatch;
    if (nearMissTemplate != null) {
        return new TemplateMatch.NearMiss(
            namespaceName, String.join(" ", inputTokens.stream()
                .map(AnnotatedToken::surface).toList()),
            nearMissTemplate,
            TemplateFormatHelper.formatSuggestion(nearMissPattern));
    }
    return new TemplateMatch.Unmatched(
        String.join(" ", inputTokens.stream()
            .map(AnnotatedToken::surface).toList()));
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl template-registry -Dtest=TrieActivationTest`
Expected: PASS

- [ ] **Step 7: Run full module tests for regression**

Run: `mvn --batch-mode test -pl template-registry`
Expected: PASS — all existing tests still pass (they use the default threshold of 100, so bag-of-words path is unchanged)

- [ ] **Step 8: Commit**

```bash
git add template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateRegistry.java template-registry/src/test/java/io/casehub/template/registry/nlp/TrieActivationTest.java
git commit -m "feat(#964): wire DiscriminationTrie into NlpTemplateRegistry with threshold activation Refs #964"
```

## Batch 3: Correctness equivalence and downstream compatibility

### Task 3: Downstream module compatibility and full build verification

**Files:**
- Test: `template-registry-llm/src/test/java/io/casehub/template/registry/llm/TrieCompatibilityTest.java` (new)

**Interfaces:**
- Consumes: `NlpTemplateRegistry` with trie activation, `AdaptiveTemplateRegistry` constructor (inherits trie behavior via super)

- [ ] **Step 1: Write tests verifying AdaptiveTemplateRegistry works with trie**

Create `TrieCompatibilityTest.java`:

```java
package io.casehub.template.registry.llm;

import io.casehub.template.registry.ClassificationResult;
import io.casehub.template.registry.TemplateDefinition;
import io.casehub.template.registry.TemplateMatch;
import io.casehub.template.registry.TemplateNamespace;
import io.casehub.template.registry.nlp.OpenNlpTokenizer;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class TrieCompatibilityTest {

    private final OpenNlpTokenizer tokenizer = new OpenNlpTokenizer();

    @Test
    void adaptiveRegistry_inheritsTrieBehavior() {
        // AdaptiveTemplateRegistry extends NlpTemplateRegistry
        // With low threshold, trie should activate and match correctly
        var registry = new AdaptiveTemplateRegistry(tokenizer,
            (input, candidates, language) -> new ClassificationResult.Unmatched(),
            0.8, new ClassificationCache(Duration.ofMinutes(5), Duration.ofMinutes(1), 100));

        var templates = new LinkedHashMap<String, TemplateDefinition>();
        templates.put("cancel", new TemplateDefinition("cancel",
            List.of("Cancel ${item}"), Map.of()));
        templates.put("submit", new TemplateDefinition("submit",
            List.of("Submit ${item}"), Map.of()));
        registry.register(new TemplateNamespace("test-ns", templates, "en"));

        TemplateMatch result = registry.match("test-ns", "Cancel my order");
        assertThat(result).isInstanceOf(TemplateMatch.Matched.class);
        assertThat(((TemplateMatch.Matched) result).templateName()).isEqualTo("cancel");
    }

    @Test
    void adaptiveRegistry_llmFallbackStillWorks() {
        var registry = new AdaptiveTemplateRegistry(tokenizer,
            (input, candidates, language) -> new ClassificationResult.Matched(
                "cancel", Map.of("item", "subscription"),
                "Cancel my ${item}", 0.95),
            0.8, new ClassificationCache(Duration.ofMinutes(5), Duration.ofMinutes(1), 100));

        var templates = new LinkedHashMap<String, TemplateDefinition>();
        templates.put("cancel", new TemplateDefinition("cancel",
            List.of("Cancel ${item}"), Map.of()));
        registry.register(new TemplateNamespace("test-ns", templates, "en"));

        // Input that won't match structurally but LLM can classify
        TemplateMatch result = registry.match("test-ns", "I want to stop my subscription");
        assertThat(result).isInstanceOf(TemplateMatch.Matched.class);
    }
}
```

- [ ] **Step 2: Run tests**

Run: `mvn --batch-mode test -pl template-registry-llm -Dtest=TrieCompatibilityTest`
Expected: PASS

- [ ] **Step 3: Run full build across all affected modules**

Run: `mvn --batch-mode install -pl template-registry-api,template-registry,template-registry-llm -am`
Expected: BUILD SUCCESS — all tests pass

- [ ] **Step 4: Commit**

```bash
git add template-registry-llm/src/test/java/io/casehub/template/registry/llm/TrieCompatibilityTest.java
git commit -m "test(#964): trie compatibility tests for AdaptiveTemplateRegistry Refs #964"
```

## References

- [2026-11-27-positional-discrimination-trie-design.md] — design spec this plan implements
- NlpTemplateRegistry — `template-registry/src/main/java/.../nlp/NlpTemplateRegistry.java`
- StructuralMatcher — `template-registry/src/main/java/.../nlp/StructuralMatcher.java`
- NlpTemplateCompiler — `template-registry/src/main/java/.../nlp/NlpTemplateCompiler.java`
- LemmatisedKeywordFilter — `template-registry/src/main/java/.../nlp/LemmatisedKeywordFilter.java`
- AdaptiveTemplateRegistry — `template-registry-llm/src/main/java/.../llm/AdaptiveTemplateRegistry.java`
- GitHub #964 — focal issue
- GitHub #959 — unified template registry architecture
- GitHub #982 — embedding rescue tier (independent)
