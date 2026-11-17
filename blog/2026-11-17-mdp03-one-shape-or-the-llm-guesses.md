---
title: "One Shape, or the LLM Guesses"
date: 2026-11-17
entry_type: note
subtype: diary
author: mdp
projects: [casehub-platform]
tags: [playbook, canonical-form, language-design, consistency, yaml, llm-authoring]
series: casehub-platform
---

# One Shape, or the LLM Guesses

A DSL with two valid file shapes and mixed key casing is a DSL that works fine for humans and fails quietly for machines. Humans see `forEach` and `for-each` and understand they're the same thing. An LLM generating a playbook picks one, and if the validator only accepts the other, the error message says "unknown key" — which is true and useless.

We had exactly this problem. The playbook corpus had two file shapes: a three-document YAML format (header, metadata, bare step list) used by most files, and a single-document format with an explicit `steps:` key used by the agent-interaction patterns. Both worked because the parser normalised bare lists into `steps:` internally. Both were valid. Neither was canonical.

The key case story was worse. Every compound keyword in the decorator namespace was kebab-case — `on-error`, `on-success`, `on-failure` — except `forEach`, which was camelCase. One outlier in a namespace of thirty keywords. The kind of thing you don't notice until you're writing a schema that has to be unambiguous.

## The guard keyword that the guide invented

The language guide documented `if` as the guard decorator — the keyword that conditionally skips a step. The code used `when`. These are different operations. `when: "${order.valid}"` is a decorator that skips a single step. `if: "${order.valid}"` with `then:` and `else:` is structural branching over step lists. The guide conflated them, which meant an LLM reading the guide would generate `if: true` to conditionally skip a step, and the runtime would interpret it as a structural branch with no `then:` clause and throw.

The fix was to reconcile the guide against the code — not the other way around. The code had the right distinction. The guide had a shortcut that was fine when only humans read it.

## What canonical form actually looks like

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 760 340" style="max-width: 760px; font-family: 'JetBrains Mono', 'Fira Code', monospace;">
  <defs>
    <marker id="arrowhead" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#666"/>
    </marker>
  </defs>
  <!-- Before box -->
  <rect x="10" y="10" width="340" height="300" rx="6" fill="#f8f8f8" stroke="#ccc"/>
  <text x="180" y="35" text-anchor="middle" font-size="13" font-weight="bold" fill="#333">Before (3 shapes)</text>
  <!-- Shape A -->
  <rect x="25" y="50" width="310" height="75" rx="4" fill="#fff" stroke="#ddd"/>
  <text x="35" y="68" font-size="10" fill="#888">Shape A — 61 files</text>
  <text x="35" y="85" font-size="11" fill="#444">playbook: "1.0" / schema: client</text>
  <text x="35" y="100" font-size="11" fill="#444">--- meta: ... ---</text>
  <text x="35" y="115" font-size="11" fill="#c44">- click: "A"  (bare list, no steps:)</text>
  <!-- Shape B -->
  <rect x="25" y="135" width="310" height="60" rx="4" fill="#fff" stroke="#ddd"/>
  <text x="35" y="153" font-size="10" fill="#888">Shape B — 9 files</text>
  <text x="35" y="170" font-size="11" fill="#444"># comment, no header</text>
  <text x="35" y="185" font-size="11" fill="#c44">steps:  (no version, no meta)</text>
  <!-- Mixed keys -->
  <rect x="25" y="205" width="310" height="45" rx="4" fill="#fff" stroke="#ddd"/>
  <text x="35" y="223" font-size="10" fill="#888">Key case — mixed</text>
  <text x="35" y="240" font-size="11" fill="#c44">on-error  on-success  forEach  when</text>
  <!-- Guard confusion -->
  <rect x="25" y="260" width="310" height="40" rx="4" fill="#fff" stroke="#ddd"/>
  <text x="35" y="278" font-size="10" fill="#888">Guard keyword — guide says if, code uses when</text>
  <text x="35" y="293" font-size="11" fill="#c44">if: true  ← guard or structural branch?</text>

  <!-- Arrow -->
  <line x1="360" y1="160" x2="400" y2="160" stroke="#666" stroke-width="2" marker-end="url(#arrowhead)"/>

  <!-- After box -->
  <rect x="410" y="10" width="340" height="300" rx="6" fill="#f0f7f0" stroke="#8c8"/>
  <text x="580" y="35" text-anchor="middle" font-size="13" font-weight="bold" fill="#333">After (1 shape)</text>
  <!-- Canonical form -->
  <rect x="425" y="50" width="310" height="120" rx="4" fill="#fff" stroke="#bdb"/>
  <text x="435" y="68" font-size="10" fill="#888">Canonical — all files</text>
  <text x="435" y="85" font-size="11" fill="#2a2">playbook: "1.0"</text>
  <text x="435" y="100" font-size="11" fill="#2a2">schema: client</text>
  <text x="435" y="115" font-size="11" fill="#444">---</text>
  <text x="435" y="130" font-size="11" fill="#2a2">meta: { title, description, tags }</text>
  <text x="435" y="145" font-size="11" fill="#2a2">steps:</text>
  <text x="435" y="160" font-size="11" fill="#2a2">  - click: "A"</text>
  <!-- Kebab keys -->
  <rect x="425" y="180" width="310" height="45" rx="4" fill="#fff" stroke="#bdb"/>
  <text x="435" y="198" font-size="10" fill="#888">Key case — kebab-case throughout</text>
  <text x="435" y="215" font-size="11" fill="#2a2">on-error  on-success  for-each  when</text>
  <!-- Guard clear -->
  <rect x="425" y="235" width="310" height="65" rx="4" fill="#fff" stroke="#bdb"/>
  <text x="435" y="253" font-size="10" fill="#888">Guard vs branch — distinct keywords</text>
  <text x="435" y="270" font-size="11" fill="#2a2">when: true  ← guard (skip step)</text>
  <text x="435" y="287" font-size="11" fill="#2a2">if: / then: / else:  ← structural branch</text>
</svg>

Every playbook file now uses a two-document YAML format: front matter (version, schema) and content (metadata, steps). The parser already normalised bare lists internally — the canonical form makes the YAML match what the runtime expects.

The `forEach` → `for-each` rename touched the entire keyword namespace: Walker, StepKeywords, DecoratorChain, FusionPass, ForEachExpander, the JSON schema, and every playbook file. Java class names stay PascalCase — `ForEachExpander` is a Java convention, `for-each` is a YAML convention. The boundary between the two is the string literal.

## Why the schema lied, and why we caught it now

The JSON schema validation test had a quiet escape hatch: bare-list documents (the third YAML document in the old format) hit an `instanceof List` check and returned early. The validator never saw the step content. When we migrated to the two-document form, the step list moved into the content map under `steps:`, and the validator finally looked at it.

What it found: `log` was declared as `type: object` but used as a string shorthand throughout the corpus. `loop` was declared as `type: integer` but accepted strings and booleans for conditional loops. `when` and `if` were declared as `type: string` but accepted booleans for literal conditions. The schema was aspirational, not descriptive.

We fixed the schema to match the runtime. A schema that rejects valid playbooks is worse than no schema at all — it teaches authors to distrust validation.

## The LLM authoring constraint

This work is a prerequisite for LLM-generated playbooks. An LLM authoring a playbook from the guide needs exactly one valid form for each construct — no "both work, pick one". The guide is the prompt. If the guide says `if` and the code uses `when`, the LLM generates a valid-looking playbook that fails at runtime with an error that doesn't mention the real problem.

The canonical form eliminates an entire class of ambiguity. The schema validates what the runtime accepts. The guide describes what the code does. These three things are now the same thing, and that's the whole point.
