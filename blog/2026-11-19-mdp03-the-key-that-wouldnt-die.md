---
title: "The Key That Wouldn't Die"
date: 2026-11-19
author: Mark Proctor
tags: [yaml, format-migration, linting, consistency]
---

We removed `steps:` from the playbook format months ago. The Walker rejects it. The PlaybookParser throws if you try. We wrote a lint. We migrated every `.playbook.yaml` file. Done.

Except it wasn't done.

## The Format That Forked

The problem with format migrations is that they only cover the files you remember. Playbooks went through `PlaybookParser`, which enforces the bare-list multi-document format. Test files went through `YamlTestDiscovery`, which nobody updated. Nine `.test.yaml` files still used top-level `steps:`. One multi-test file still used `tests[].steps`. Five more test fixtures in the test engine module. The `playbook-document.schema.json` still declared `steps:` as valid. And the parallel step type had its own map form with `steps:` inside it.

That's four separate locations where the deprecated format survived — each with its own parser path, its own schema, its own conventions. The lint caught one. The others were invisible to it.

## Why One Format Matters

The argument for a single format isn't aesthetic. It's that every divergence is a maintenance tax someone pays later. A new contributor reads a test file, sees `steps:`, copies the pattern into their playbook, and hits the lint. Now they're confused about which format is right. They look at the schema, which says both are valid. They look at a multi-test file, which uses a third variant. Three formats for the same concept, each correct in its own context.

The fix isn't complicated — multi-document YAML, bare list after `---`. The same pattern playbooks already use:

```yaml
name: My test
---
- click: A
- click: B
```

For multi-test files, the same pattern repeats — each test case is a metadata document followed by a bare step list:

```yaml
name: Test suite
simulate:
  agent:
    - prompt: "hello"
      response: "world"
---
name: First test
---
- run-playbook: my-playbook.yaml
  capture: output
- assertThat: output.succeeded
  equals: true
---
name: Second test
---
- click: A
- click: B
```

No `steps:` wrapper. No `tests:` wrapper. Each document is either metadata or a step list — the parser distinguishes by type.

## The Last Holdout

The parallel step had its own private use of `steps:` that nothing else knew about:

```yaml
# Old map form
- parallel:
    steps:
      - click: A
      - click: B
    advance-after: 1
    cancel-remaining: true
```

The `steps:` key here served a structural purpose — it separated the branch list from the policy keys (`advance-after`, `cancel-remaining`). But policy keys don't need to be inside the parallel value. They're step-level concerns — siblings, not children:

```yaml
# New form
- parallel:
    - click: A
    - click: B
  advance-after: 1
  cancel-remaining: true
```

This matches how every other decorator works in the language. `timeout`, `retry`, `when` — all sibling keys on the step map. The parallel policies were the exception, hidden inside a nested object nobody questioned because it worked.

## Linting Covers Every Level Now

The rejection points after the migration:

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 680 320" style="max-width: 680px; font-family: system-ui, -apple-system, sans-serif;">
  <defs>
    <marker id="arrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <path d="M0,0 L8,3 L0,6" fill="none" stroke="#374151" stroke-width="1.5"/>
    </marker>
  </defs>

  <!-- Background -->
  <rect width="680" height="320" fill="#fafaf9" rx="8"/>

  <!-- Title -->
  <text x="340" y="30" text-anchor="middle" font-size="14" font-weight="600" fill="#1f2937">steps: rejection points</text>

  <!-- Layer boxes -->
  <!-- PlaybookParser -->
  <rect x="40" y="55" width="180" height="50" rx="6" fill="#dbeafe" stroke="#93c5fd" stroke-width="1.5"/>
  <text x="130" y="75" text-anchor="middle" font-size="12" font-weight="500" fill="#1e40af">PlaybookParser</text>
  <text x="130" y="92" text-anchor="middle" font-size="10" fill="#3b82f6">.playbook.yaml top-level</text>

  <!-- YamlTestDiscovery -->
  <rect x="250" y="55" width="180" height="50" rx="6" fill="#dbeafe" stroke="#93c5fd" stroke-width="1.5"/>
  <text x="340" y="75" text-anchor="middle" font-size="12" font-weight="500" fill="#1e40af">YamlTestDiscovery</text>
  <text x="340" y="92" text-anchor="middle" font-size="10" fill="#3b82f6">.test.yaml top-level + tests:</text>

  <!-- Walker -->
  <rect x="460" y="55" width="180" height="50" rx="6" fill="#dbeafe" stroke="#93c5fd" stroke-width="1.5"/>
  <text x="550" y="75" text-anchor="middle" font-size="12" font-weight="500" fill="#1e40af">Walker</text>
  <text x="550" y="92" text-anchor="middle" font-size="10" fill="#3b82f6">inside any step map</text>

  <!-- Arrows down -->
  <line x1="130" y1="105" x2="130" y2="140" stroke="#374151" stroke-width="1.5" marker-end="url(#arrow)"/>
  <line x1="340" y1="105" x2="340" y2="140" stroke="#374151" stroke-width="1.5" marker-end="url(#arrow)"/>
  <line x1="550" y1="105" x2="550" y2="140" stroke="#374151" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- Error messages -->
  <rect x="20" y="145" width="200" height="55" rx="6" fill="#fef2f2" stroke="#fca5a5" stroke-width="1"/>
  <text x="120" y="165" text-anchor="middle" font-size="10" fill="#991b1b">IllegalArgumentException:</text>
  <text x="120" y="180" text-anchor="middle" font-size="9" fill="#b91c1c">"steps: wrapper not allowed</text>
  <text x="120" y="192" text-anchor="middle" font-size="9" fill="#b91c1c">in versioned playbooks"</text>

  <rect x="230" y="145" width="220" height="55" rx="6" fill="#fef2f2" stroke="#fca5a5" stroke-width="1"/>
  <text x="340" y="165" text-anchor="middle" font-size="10" fill="#991b1b">IllegalArgumentException:</text>
  <text x="340" y="180" text-anchor="middle" font-size="9" fill="#b91c1c">"top-level steps: not allowed —</text>
  <text x="340" y="192" text-anchor="middle" font-size="9" fill="#b91c1c">use bare-list after ---"</text>

  <rect x="460" y="145" width="200" height="55" rx="6" fill="#fef2f2" stroke="#fca5a5" stroke-width="1"/>
  <text x="560" y="165" text-anchor="middle" font-size="10" fill="#991b1b">IllegalArgumentException:</text>
  <text x="560" y="180" text-anchor="middle" font-size="9" fill="#b91c1c">"steps is no longer valid —</text>
  <text x="560" y="192" text-anchor="middle" font-size="9" fill="#b91c1c">use block for multiple actions"</text>

  <!-- Schema box -->
  <rect x="140" y="230" width="400" height="60" rx="6" fill="#f0fdf4" stroke="#86efac" stroke-width="1.5"/>
  <text x="340" y="255" text-anchor="middle" font-size="12" font-weight="500" fill="#166534">playbook-document.schema.json</text>
  <text x="340" y="272" text-anchor="middle" font-size="10" fill="#16a34a">steps: removed from top-level, testCase, and parallel map form</text>
</svg>

Three parsers, one schema, zero paths where `steps:` slips through. The Walker also rejects the parallel map form — if someone passes `parallel: { steps: [...] }`, they get a clear error telling them to use sibling keys instead.

## The Deeper Pattern

Format migrations that touch only one parser path always leave survivors. The question isn't whether you caught the main path — it's whether you audited every alternative path that reads the same input format. `PlaybookParser` and `YamlTestDiscovery` both read YAML files with step lists, but they were written by different people at different times, and only one got the migration. The `StepSchemaComposer` generates schemas at runtime — it had its own copy of the parallel map form that nobody thought to update.

The fix for this class of problem isn't vigilance. It's the lint itself — `Walker.REMOVED_KEYS`, `PlaybookParser.rejectStepsWrapper()`, and `YamlTestDiscovery`'s rejection all fail fast with actionable messages. Every surviving use got caught the moment we ran the tests after adding the rejection. The order matters: add the lint first, then let the test suite show you what you missed.
