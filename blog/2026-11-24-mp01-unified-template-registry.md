---
layout: post
title: "Two Stacks, One Registry"
date: 2026-11-24
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [nlp, templates, protocols, architecture]
series: issue-959-unified-template-registry
---

# Two Stacks, One Registry

The template matching infrastructure in casehub-platform had a problem I should have spotted earlier. We had two parallel implementations of the same concept — one in the protocol stack (yaml-core → coordination-core → yaml-step-runtime) and one in the extraction stack (message-extraction-api → message-extraction) — with no code dependency between them.

Both compile `${var}` templates to regex. Both extract variable bindings from input text. Both have constraint validation. Both have a `VariableConstraint` sealed interface with identical `StringConstraint` and `EnumConstraint` records. The extraction stack added NLP structural matching via OpenNLP (tense, plurals, lemmatisation). The protocol stack had an NLP SPI (`NlpProtocolMatcher`) with zero implementations — the bridge to the extraction stack was never built.

Worse: each playbook creates its own isolated `ProtocolEvaluator`. Templates compile per-playbook. Keyword caches duplicate. There is no cross-playbook composition. The lifecycle is the problem, not the matching algorithm.

## What "unified" means here

The unified template registry (#959) replaces both stacks with two new modules: `template-registry-api` (zero external deps, depends on yaml-core for the canonical `VariableConstraint`) and `template-registry` (OpenNLP, structural matching, CDI wiring).

Templates are registered under namespaces — `protocol:review`, `playbook:onboarding`, `runtime:alerts` — so different sources don't collide. The registry does two-tier matching: regex first (always available, in the API module), NLP structural fallback (when the impl module is on the classpath). This follows the platform's opt-in extension pattern — NLP activates by classpath presence, not by configuration.

The interesting design tension was between what's ideal and what's premature. I wanted a discrimination tree indexed by lemmatised literals — O(template depth) lookup instead of O(n) linear scan. Claude pushed back during the decision review: the existing keyword affinity filtering in `TemplateKeywords` already provides discrimination, and upgrading it to operate on lemmatised tokens (so "approved" and "approve" reduce to the same lemma) gives morphological discrimination with no new data structures. The positional trie is a future optimisation for when template counts exceed ~100 per registry. For realistic near-term volumes (10–50 templates per protocol), lemmatised keyword filtering is sufficient.

Similarly, I wanted NLP-driven generation — verb conjugation, determiner agreement, the works. The review caught this as premature: English morphological rules are irregular, the effort is substantial, and no concrete consumer requires subject-dependent generation yet. Template slot-filling is sufficient for governed communications where templates are authored with grammar in mind. The template IS the grammatically correct surface form; variables slot into positions where any value produces correct grammar.

## What was built

We built the `template-registry-api` module — the foundation layer. Core types: `TemplateDefinition` (name, patterns, variable constraints), `TemplateNamespace` (groups templates by source), `TemplateMatch` (sealed: `Matched` with score, `NearMiss` with rephrase suggestion, `Unmatched`), `TemplateSchema` (published sentence schema for LLM governance), and the `UnifiedTemplateRegistry` SPI.

The regex tier is complete: `RegexTemplateCompiler` ports the compilation logic from `TemplateExtractor`, `TemplateGenerator` handles bidirectional slot-filling (extract fields from prose, generate prose from fields), and `InMemoryTemplateRegistry` provides the full SPI implementation with immutable-snapshot concurrency via `AtomicReference` CAS.

```java
// Register a protocol's templates
registry.register(new TemplateNamespace("protocol:review", templates));

// Match input against registered templates
TemplateMatch result = registry.match("protocol:review", input);
// → Matched(namespace="protocol:review", templateName="vote",
//     fields={decision: "approve", subject: "architecture"}, score=1.0)

// Generate the canonical surface form from extracted fields
String surface = registry.generate("protocol:review", "vote",
    Map.of("decision", "approve", "subject", "architecture"));
// → "I approve this architecture"
```

The bidirectional roundtrip — extract then generate, verify semantic equivalence — works. That's the contract protocols need: the template tells the LLM "say it this way", the platform extracts fields mechanically, and the same template regenerates the expected surface form.

The NLP tier (Batch 2) and platform integration (Batch 3) are next. The NLP tier migrates `OpenNlpTokenizer` and `StructuralMatcher` from message-extraction, adds lemmatised keyword filtering, and builds the two-tier `NlpTemplateRegistry`. Platform integration adds the `@DefaultBean` NoOp, the `@McpDomain` schema endpoint, and the full integration test suite — which is the real acceptance criterion for this work.
