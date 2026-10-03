# Single-Source YAML Scenarios Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehub-pages#466 — Single-source YAML scenarios for tutorials and showcase gallery
**Issue group:** #502, #466

**Goal:** Extract inline YAML from 8 showcase companion scripts into standalone `.scenario.yaml` files, replace the 8 scripts with one generic companion, and add `scenario-ref` support to the tutorial host.

**Architecture:** A new `scenarios/` directory at the repo root holds standalone `.scenario.yaml` files organised by category. A manifest generator indexes them. One generic companion script (`scenario-showcase.ts`) replaces 8 near-identical scripts by fetching scenarios from the manifest. The tutorial host gains `scenario-ref` support for referencing shared scenarios.

**Tech Stack:** TypeScript, YAML (yaml npm package), Lit (tutorial host), Node.js (manifest generator)

## Global Constraints

- All work in `casehub-pages` repo at `/Users/mdproctor/claude/casehub/slots/210/pages`
- Branch: `epic-502-yaml-parity`
- `.scenario.yaml` files use the existing `ScenarioEnvelope` format — no new parsing code
- `meta:` block format matches existing `ScriptMeta` (title, description, tags)
- The 7 custom companion scripts (Form Automation, Scenario Controller, Script Library, Step Catalog, Table Population, Composable Workflow, Parameterized Script) are NOT modified
- Tests run via `npm test` in relevant packages

---

## Batch 1: Scenario File Extraction

### Task 1: Extract .scenario.yaml files from companion scripts

Create standalone `.scenario.yaml` files by extracting inline YAML from the 8 standard companion scripts. Use a Node.js extraction script for reliability — 48 examples across 8 scripts is too many to copy manually.

**Files:**
- Create: `scripts/extract-scenarios.js` (one-time extraction script)
- Create: `scenarios/flow-control/*.scenario.yaml` (9 files)
- Create: `scenarios/coordination/*.scenario.yaml` (4 files from Coordination.ts)
- Create: `scenarios/coordination-primitives/*.scenario.yaml` (6 files)
- Create: `scenarios/concurrency-patterns/*.scenario.yaml` (7 files)
- Create: `scenarios/composition/*.scenario.yaml` (5 files)
- Create: `scenarios/data-delivery/*.scenario.yaml` (3 files)
- Create: `scenarios/invoke-bindings/*.scenario.yaml` (6 files)
- Create: `scenarios/step-workflows/*.scenario.yaml` (8 files)
- Create: `scripts/generate-scenario-manifest.js`
- Create: `scenarios/manifest.json` (generated)
- Test: `scripts/validate-scenarios.js` (one-time validation script)

**Interfaces:**
- Produces: `scenarios/manifest.json` — consumed by Task 2's generic companion script
- Produces: `scenarios/<category>/<name>.scenario.yaml` — consumed by Tasks 2, 3, and 4

- [ ] **Step 1: Write the extraction script**

Create `scripts/extract-scenarios.js`. This script reads each of the 8 companion `.ts` files, parses the `EXAMPLES` variable (array or object), and writes each example as a `.scenario.yaml` file with the existing envelope format plus a `meta:` block.

```javascript
// scripts/extract-scenarios.js
const fs = require('fs');
const path = require('path');

const SOURCES = [
  { file: 'Flow Control.ts', category: 'flow-control', varPattern: /var EXAMPLES\s*=\s*\[/ },
  { file: 'Coordination.ts', category: 'coordination', varPattern: /var EXAMPLES\s*=\s*\{/ },
  { file: 'Coordination Primitives.ts', category: 'coordination-primitives', varPattern: /var EXAMPLES\s*=\s*\{/ },
  { file: 'Concurrency Patterns.ts', category: 'concurrency-patterns', varPattern: /var EXAMPLES\s*=\s*\{/ },
  { file: 'Composition.ts', category: 'composition', varPattern: /var COMP_EXAMPLES\s*=\s*\{/ },
  { file: 'Data Delivery.ts', category: 'data-delivery', varPattern: /var DATA_EXAMPLES\s*=\s*\{/ },
  { file: 'Invoke Bindings.ts', category: 'invoke-bindings', varPattern: /var EXAMPLES\s*=\s*\{/ },
  { file: 'Step Workflows.ts', category: 'step-workflows', varPattern: /var EXAMPLES\s*=\s*\[/ },
];

const samplesDir = path.join(__dirname, '../examples/samples/Scenarios');
const outDir = path.join(__dirname, '../scenarios');

for (const source of SOURCES) {
  const tsPath = path.join(samplesDir, source.file);
  const tsCode = fs.readFileSync(tsPath, 'utf8');

  // Extract the EXAMPLES data by evaluating the variable declaration.
  // The TS files use plain JS (var, no imports) — safe to eval the data portion.
  // Find the variable assignment, extract until the matching closing bracket.
  const varMatch = tsCode.match(source.varPattern);
  if (!varMatch) { console.error(`No match in ${source.file}`); continue; }

  const startIdx = varMatch.index;
  // Find the end of the data structure by counting brackets
  let depth = 0;
  let endIdx = startIdx;
  let started = false;
  const opener = tsCode[startIdx + varMatch[0].length - 1]; // [ or {
  const closer = opener === '[' ? ']' : '}';
  for (let i = startIdx; i < tsCode.length; i++) {
    if (tsCode[i] === opener) { depth++; started = true; }
    if (tsCode[i] === closer) { depth--; }
    if (started && depth === 0) { endIdx = i + 1; break; }
  }

  const dataStr = tsCode.slice(startIdx, endIdx)
    .replace(source.varPattern, opener === '[' ? '[' : '{')
    .replace(/\.join\('\n'\)/g, '')           // remove .join('\n')
    .replace(/\.join\("\\n"\)/g, '')          // variant
    .replace(/\n\s*\]/g, (m) => m)            // keep array closings
    ;

  // Convert JS arrays to actual strings by eval
  // The data uses JS array syntax for yaml: ['line1', 'line2'].join('\n')
  // After removing .join('\n'), we have yaml: ['line1', 'line2']
  // We need to join them ourselves
  let examples;
  try {
    examples = eval('(' + dataStr + ')');
  } catch (e) {
    console.error(`Eval failed for ${source.file}: ${e.message}`);
    continue;
  }

  // Normalise to array of {name, yaml, tags, description}
  let items;
  if (Array.isArray(examples)) {
    items = examples.map(ex => ({
      name: ex.name,
      yaml: Array.isArray(ex.yaml) ? ex.yaml.join('\n') : ex.yaml,
      tags: ex.tags || [],
      description: ex.description || '',
    }));
  } else {
    items = Object.entries(examples).map(([key, ex]) => ({
      name: ex.title || key,
      yaml: Array.isArray(ex.yaml) ? ex.yaml.join('\n') : ex.yaml,
      tags: ex.tags || [],
      description: ex.description || '',
    }));
  }

  // Write each example as a .scenario.yaml file
  const categoryDir = path.join(outDir, source.category);
  fs.mkdirSync(categoryDir, { recursive: true });

  for (const item of items) {
    const slug = item.name.toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-|-$/g, '');
    const filename = `${slug}.scenario.yaml`;
    const yamlContent = item.yaml;

    // Check if the YAML already has a meta: block
    const hasMeta = /^meta:/m.test(yamlContent);
    const hasScenario = /^scenario:/m.test(yamlContent);

    let output;
    if (hasScenario && !hasMeta) {
      // Insert meta block after scenario: line
      const lines = yamlContent.split('\n');
      const scenarioLine = lines.findIndex(l => /^scenario:/.test(l));
      const before = lines.slice(0, scenarioLine + 1);
      const after = lines.slice(scenarioLine + 1);
      const metaBlock = [
        'meta:',
        `  title: "${item.name}"`,
        `  description: "${item.description.replace(/"/g, '\\"')}"`,
        '  tags:',
        ...item.tags.map(t => `    - ${t}`),
      ];
      output = [...before, ...metaBlock, ...after].join('\n') + '\n';
    } else if (!hasScenario) {
      // Non-scenario YAML (modules, forEach examples) — wrap with meta header
      const metaBlock = [
        `# ${item.name}`,
        'meta:',
        `  title: "${item.name}"`,
        `  description: "${item.description.replace(/"/g, '\\"')}"`,
        '  tags:',
        ...item.tags.map(t => `    - ${t}`),
        '---',
        '',
      ];
      output = metaBlock.join('\n') + yamlContent + '\n';
    } else {
      output = yamlContent + '\n';
    }

    fs.writeFileSync(path.join(categoryDir, filename), output);
    console.log(`  ${source.category}/${filename}`);
  }
}
console.log('Done.');
```

- [ ] **Step 2: Run the extraction script**

Run: `node scripts/extract-scenarios.js`
Expected: 48 `.scenario.yaml` files created across 8 category directories under `scenarios/`.

- [ ] **Step 3: Manually review and fix extracted files**

Spot-check 3-4 files per category. Verify:
- YAML is valid (no stray JS syntax)
- `scenario:` key present for runnable scenarios
- `meta:` block has title, description, tags
- Non-scenario examples (modules, forEach in Composition) have appropriate structure

Fix any extraction artifacts by hand.

- [ ] **Step 4: Write the manifest generator**

Create `scripts/generate-scenario-manifest.js`:

```javascript
// scripts/generate-scenario-manifest.js
const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const scenariosDir = path.join(__dirname, '../scenarios');
const outputFile = path.join(scenariosDir, 'manifest.json');

const CATEGORY_DISPLAY = {
  'flow-control': 'Flow Control',
  'coordination': 'Coordination',
  'coordination-primitives': 'Coordination Primitives',
  'concurrency-patterns': 'Concurrency Patterns',
  'composition': 'Composition',
  'data-delivery': 'Data Delivery',
  'invoke-bindings': 'Invoke Bindings',
  'step-workflows': 'Step Workflows',
};

const categories = [];

for (const dir of fs.readdirSync(scenariosDir).sort()) {
  const dirPath = path.join(scenariosDir, dir);
  if (!fs.statSync(dirPath).isDirectory()) continue;

  const scenarios = [];
  for (const file of fs.readdirSync(dirPath).sort()) {
    if (!file.endsWith('.scenario.yaml')) continue;
    const content = fs.readFileSync(path.join(dirPath, file), 'utf8');
    const parsed = yaml.load(content);
    const meta = parsed.meta || {};
    scenarios.push({
      file: `${dir}/${file}`,
      title: meta.title || file.replace('.scenario.yaml', ''),
      description: meta.description || '',
      tags: meta.tags || [],
      runnable: !!parsed.scenario,
    });
  }

  if (scenarios.length > 0) {
    categories.push({
      name: CATEGORY_DISPLAY[dir] || dir,
      key: dir,
      scenarios,
    });
  }
}

const manifest = { version: '1.0.0', categories };
fs.writeFileSync(outputFile, JSON.stringify(manifest, null, 2));
console.log(`Generated manifest with ${categories.reduce((n, c) => n + c.scenarios.length, 0)} scenarios in ${categories.length} categories`);
```

- [ ] **Step 5: Run the manifest generator**

Run: `node scripts/generate-scenario-manifest.js`
Expected: `scenarios/manifest.json` created with all categories and scenario entries.

- [ ] **Step 6: Write validation script and verify all files parse**

Create `scripts/validate-scenarios.js` that loads each `.scenario.yaml` file and verifies it parses as valid YAML:

```javascript
const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const scenariosDir = path.join(__dirname, '../scenarios');
let passed = 0, failed = 0;

for (const dir of fs.readdirSync(scenariosDir)) {
  const dirPath = path.join(scenariosDir, dir);
  if (!fs.statSync(dirPath).isDirectory()) continue;
  for (const file of fs.readdirSync(dirPath)) {
    if (!file.endsWith('.scenario.yaml')) continue;
    try {
      const content = fs.readFileSync(path.join(dirPath, file), 'utf8');
      const parsed = yaml.load(content);
      if (!parsed.meta) throw new Error('Missing meta block');
      if (!parsed.meta.title) throw new Error('Missing meta.title');
      passed++;
    } catch (e) {
      console.error(`FAIL: ${dir}/${file} — ${e.message}`);
      failed++;
    }
  }
}
console.log(`${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
```

Run: `node scripts/validate-scenarios.js`
Expected: All 48 files pass. Fix any failures.

- [ ] **Step 7: Commit**

```bash
git add scenarios/ scripts/extract-scenarios.js scripts/generate-scenario-manifest.js scripts/validate-scenarios.js
git commit -m "feat(#466): extract 48 scenario YAML files from 8 showcase companion scripts"
```

---

## Batch 2: Generic Companion + Page Migration

### Task 2: Create generic companion script

Write `scenario-showcase.ts` — a single companion script that replaces the 8 individual scripts. It reads a `data-category` attribute from the page DOM, fetches scenarios from the manifest, builds the picker dynamically, and drives the scheduler.

**Files:**
- Create: `examples/samples/Scenarios/scenario-showcase.ts`

**Interfaces:**
- Consumes: `scenarios/manifest.json` (from Task 1)
- Consumes: `scenarios/<category>/<name>.scenario.yaml` (from Task 1)
- Consumes: `window.casehubPages.parseScenario`, `window.casehubPages.createScheduler`, `window.casehubPages.createScenarioCatalog` (from pages-aria bundle)
- Produces: Runtime scenario picker + runner UI in the page DOM

- [ ] **Step 1: Write the generic companion script**

The script must handle three modes:
1. **Standard**: `scenario:` + `steps:` — parse and run via scheduler
2. **Trigger**: examples with `trigger:` blocks — show data inject buttons
3. **YAML-only**: no `scenario:` key — display YAML in code viewer without runner

All element IDs use a standardized convention: `scenario-state`, `scenario-step`, `scenario-time`, `scenario-progress`, `scenario-log`, `scenario-picker`, `scenario-run-btn`, `scenario-speed-slider`, `scenario-speed-label`, `scenario-yaml`, `scenario-description`, `scenario-root`, `scenario-trigger-panel`.

```typescript
// scenario-showcase.ts — generic companion for all scenario showcase pages
//
// Reads data-category from #scenario-root, fetches scenarios from manifest,
// builds picker dynamically, runs via parseScenario + createScheduler.

var scenarioRoot = document.getElementById('scenario-root');
var scenarioCategory = scenarioRoot ? scenarioRoot.getAttribute('data-category') : null;

if (!scenarioCategory) {
  console.error('scenario-showcase: no data-category on #scenario-root');
}

var scenarioManifestUrl = '../../scenarios/manifest.json';
var scenarioBaseUrl = '../../scenarios/';

var scState = document.getElementById('scenario-state');
var scStep = document.getElementById('scenario-step');
var scTime = document.getElementById('scenario-time');
var scProgress = document.getElementById('scenario-progress');
var scLogEl = document.getElementById('scenario-log');
var scPicker = document.getElementById('scenario-picker') as HTMLSelectElement;
var scRunBtn = document.getElementById('scenario-run-btn');
var scSpeedSlider = document.getElementById('scenario-speed-slider') as HTMLInputElement;
var scSpeedLabel = document.getElementById('scenario-speed-label');
var scYaml = document.getElementById('scenario-yaml') as any;
var scDesc = document.getElementById('scenario-description');
var scTriggerPanel = document.getElementById('scenario-trigger-panel');

var scStepDelay = 500;
var scCurrentRunner: any = null;
var scRunGeneration = 0;
var scLoadedScenarios: Array<{
  title: string;
  description: string;
  tags: string[];
  yaml: string;
  runnable: boolean;
}> = [];

if (scSpeedSlider) {
  scSpeedSlider.addEventListener('input', function () {
    scStepDelay = parseInt(scSpeedSlider.value, 10);
    if (scSpeedLabel) scSpeedLabel.textContent = scStepDelay + 'ms';
  });
}

function scFormatTime(ms: number): string {
  var s = Math.floor(ms / 1000);
  var m = Math.floor(s / 60);
  var sec = s % 60;
  var millis = ms % 1000;
  return (m < 10 ? '0' : '') + m + ':' + (sec < 10 ? '0' : '') + sec + '.' +
    (millis < 100 ? '0' : '') + (millis < 10 ? '0' : '') + millis;
}

function scLogEvent(time: number, queue: string, action: string, status: string) {
  if (!scLogEl) return;
  var line = document.createElement('div');
  var timeStr = '[' + scFormatTime(time) + ']';
  var queueStr = queue.padEnd(12);
  var actionStr = action.padEnd(16);
  line.textContent = timeStr + '  ' + queueStr + actionStr + status;
  if (status === '✓') line.style.color = '#4ade80';
  else if (status === '⏭') line.style.color = '#f59e0b';
  (scLogEl as any).appendChild(line);
  (scLogEl as any).scrollTop = (scLogEl as any).scrollHeight;
}

function scFindByAriaLabel(name: string) {
  var el = document.querySelector('[aria-label="' + name + '"]');
  if (el) return el;
  var hosts = document.querySelectorAll('*');
  for (var i = 0; i < hosts.length; i++) {
    var root = (hosts[i] as any).shadowRoot;
    if (root) {
      el = root.querySelector('[aria-label="' + name + '"]');
      if (el) return el;
    }
  }
  return null;
}

function scFlashButton(name: string) {
  var btn = scFindByAriaLabel(name) as HTMLElement;
  if (!btn) return;
  btn.style.background = '#22c55e';
  btn.style.borderColor = '#22c55e';
  btn.style.color = '#000';
  setTimeout(function () {
    btn.style.background = 'var(--pages-neutral-2)';
    btn.style.borderColor = 'var(--pages-neutral-5)';
    btn.style.color = 'var(--pages-neutral-12)';
  }, Math.max(scStepDelay - 150, 50));
}

function scResetUI() {
  if (scLogEl) (scLogEl as any).innerHTML = '';
  if (scState) { scState.textContent = 'idle'; scState.style.color = '#4ade80'; }
  if (scStep) scStep.textContent = '—';
  if (scTime) scTime.textContent = '0ms';
  if (scProgress) scProgress.textContent = '0%';
  if (scTriggerPanel) scTriggerPanel.style.display = 'none';
  var btns = document.querySelectorAll('#app-buttons button');
  btns.forEach(function (b: any) {
    b.style.background = 'var(--pages-neutral-2)';
    b.style.borderColor = 'var(--pages-neutral-5)';
    b.style.color = 'var(--pages-neutral-12)';
  });
}

function scShowExample(idx: number) {
  var ex = scLoadedScenarios[idx];
  if (!ex) return;
  if (scYaml) scYaml.value = ex.yaml;
  if (scDesc) {
    scDesc.innerHTML = '';
    if (ex.tags && ex.tags.length > 0) {
      var tagSpan = document.createElement('span');
      tagSpan.style.cssText = 'display: inline-flex; gap: 4px; margin-right: 6px; vertical-align: middle;';
      ex.tags.forEach(function (t) {
        var chip = document.createElement('span');
        chip.textContent = t;
        chip.style.cssText = 'padding: 1px 6px; border-radius: 3px; background: var(--pages-accent-3); color: var(--pages-accent-9); font-size: 10px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.3px;';
        tagSpan.appendChild(chip);
      });
      scDesc.appendChild(tagSpan);
    }
    scDesc.appendChild(document.createTextNode(ex.description));
  }
  // Hide interactive panel for non-runnable examples
  var interactive = document.getElementById('app-buttons');
  if (interactive) interactive.style.display = ex.runnable ? '' : 'none';
  if (scRunBtn) (scRunBtn as HTMLElement).style.display = ex.runnable ? '' : 'none';
}

function scRunExample(idx: number) {
  if (scCurrentRunner) { scCurrentRunner.dispose(); scCurrentRunner = null; }
  scRunGeneration++;
  var thisGen = scRunGeneration;
  scResetUI();

  var ex = scLoadedScenarios[idx];
  if (!ex || !ex.runnable) return;

  var cp = (window as any).casehubPages;
  var parseScenario = cp && cp.parseScenario;
  var createScheduler = cp && cp.createScheduler;
  var createScenarioCatalog = cp && cp.createScenarioCatalog;

  if (!parseScenario || !createScheduler || !createScenarioCatalog) {
    scLogEvent(0, 'system', 'error', 'scheduler not in bundle');
    return;
  }

  var catalog = createScenarioCatalog();
  var scenario;
  try { scenario = parseScenario(ex.yaml, catalog); }
  catch (e: any) { scLogEvent(0, 'system', 'parse error', e.message || String(e)); return; }

  var eventTarget = new EventTarget();
  eventTarget.addEventListener('pages-event', function (e: any) {
    if (thisGen !== scRunGeneration) return;
    var detail = e.detail;
    if (!detail) return;
    if (detail.topic === 'scenario:state') {
      var payload = detail.payload;
      if (scState) {
        if (payload.progress >= 1) { scState.textContent = 'done'; scState.style.color = '#4ade80'; }
        else if (payload.paused) { scState.textContent = 'paused'; scState.style.color = '#f59e0b'; }
        else { scState.textContent = 'playing'; scState.style.color = '#3b82f6'; }
      }
      if (scTime && payload.virtualTime !== undefined) scTime.textContent = Math.round(payload.virtualTime) + 'ms';
      if (scProgress) scProgress.textContent = Math.round(payload.progress * 100) + '%';
    }
    if (detail.topic === 'scenario:step') {
      var sp = detail.payload;
      var step = sp.step;
      var action = step ? (step.entry ? step.entry.qualifiedName : step.kind || '?') : '?';
      var target = step && step.params ? (step.params.name || '') : '';
      var label = action + (target ? ' ' + target : '');
      if (scStep) scStep.textContent = label;
      if (scTime) scTime.textContent = sp.virtualTime + 'ms';
      if (step && step.kind === 'delay') scLogEvent(sp.virtualTime, sp.queue || 'main', 'delay ' + (step.duration || ''), '⏱');
      else if (step && step.kind === 'plugin') scLogEvent(sp.virtualTime, sp.queue || 'main', label, '✓');
      else scLogEvent(sp.virtualTime, sp.queue || 'main', label, '⏭');
    }
  });

  var runner = createScheduler(scenario, { eventTarget: eventTarget, speed: 1, startPaused: false });
  scCurrentRunner = runner;
  runner.play();
  if (scState) { scState.textContent = 'playing'; scState.style.color = '#3b82f6'; }
}

// Load scenarios from manifest
async function scLoadScenarios() {
  try {
    var resp = await fetch(scenarioManifestUrl);
    var manifest = await resp.json();
    var cat = manifest.categories.find(function (c: any) { return c.key === scenarioCategory; });
    if (!cat) { console.error('Category not found: ' + scenarioCategory); return; }

    for (var entry of cat.scenarios) {
      var yamlResp = await fetch(scenarioBaseUrl + entry.file);
      var yamlText = await yamlResp.text();
      scLoadedScenarios.push({
        title: entry.title,
        description: entry.description,
        tags: entry.tags,
        yaml: yamlText,
        runnable: entry.runnable,
      });
    }

    // Build picker
    if (scPicker) {
      scPicker.innerHTML = '';
      scLoadedScenarios.forEach(function (s, i) {
        var opt = document.createElement('option');
        opt.value = String(i);
        opt.textContent = s.title;
        scPicker.appendChild(opt);
      });
    }

    scShowExample(0);
  } catch (e) {
    console.error('Failed to load scenarios:', e);
  }
}

if (scPicker) {
  scPicker.addEventListener('change', function () {
    if (scCurrentRunner) { scCurrentRunner.dispose(); scCurrentRunner = null; }
    scResetUI();
    scShowExample(parseInt(scPicker.value, 10));
  });
}

if (scRunBtn) {
  scRunBtn.addEventListener('click', function () {
    var idx = scPicker ? parseInt(scPicker.value, 10) : 0;
    scRunExample(idx);
  });
}

scLoadScenarios();
```

- [ ] **Step 2: Verify the script compiles (no TS errors)**

The gallery app uses `stripTs()` + `new Function()` to execute companion scripts. The script must use `var` declarations (not `const`/`let`), avoid module imports, and keep TS types as simple annotations that `stripTs()` can remove. Verify by reading the `stripTs` function in `app.js` to confirm compatibility.

- [ ] **Step 3: Commit**

```bash
git add examples/samples/Scenarios/scenario-showcase.ts
git commit -m "feat(#466): generic scenario showcase companion script"
```

### Task 3: Migrate 8 showcase pages and update infrastructure

Update `generate-samples.js` to support shared companion scripts. Update all 8 `.page.yaml` files to use standardized element IDs and `data-category`. Delete the 8 old companion scripts. Regenerate `samples.json`.

**Files:**
- Modify: `examples/scripts/generate-samples.js` (add shared companion fallback)
- Modify: `examples/samples/Scenarios/Flow Control.page.yaml` (standardize IDs, add data-category)
- Modify: `examples/samples/Scenarios/Coordination.page.yaml`
- Modify: `examples/samples/Scenarios/Coordination Primitives.page.yaml`
- Modify: `examples/samples/Scenarios/Concurrency Patterns.page.yaml`
- Modify: `examples/samples/Scenarios/Composition.page.yaml`
- Modify: `examples/samples/Scenarios/Data Delivery.page.yaml`
- Modify: `examples/samples/Scenarios/Invoke Bindings.page.yaml`
- Modify: `examples/samples/Scenarios/Step Workflows.page.yaml`
- Delete: `examples/samples/Scenarios/Flow Control.ts` (bash rm — non-source file in samples dir)
- Delete: `examples/samples/Scenarios/Coordination.ts`
- Delete: `examples/samples/Scenarios/Coordination Primitives.ts`
- Delete: `examples/samples/Scenarios/Concurrency Patterns.ts`
- Delete: `examples/samples/Scenarios/Composition.ts`
- Delete: `examples/samples/Scenarios/Data Delivery.ts`
- Delete: `examples/samples/Scenarios/Invoke Bindings.ts`
- Delete: `examples/samples/Scenarios/Step Workflows.ts`
- Regenerate: `examples/samples.json`

**Interfaces:**
- Consumes: `examples/samples/Scenarios/scenario-showcase.ts` (from Task 2)
- Consumes: `scenarios/manifest.json` (from Task 1)

- [ ] **Step 1: Update generate-samples.js**

Add shared companion fallback. After the existing per-page companion check (line 163-167), add:

```javascript
// Fallback: shared companion script in same directory
if (!entry.tsPath) {
  const sharedCompanion = path.join(dir, 'scenario-showcase.ts');
  if (fs.existsSync(sharedCompanion)) {
    entry.tsPath = path.relative(baseDir, sharedCompanion).split(path.sep).join('/');
  }
}
```

This means: when a `.page.yaml` file has no per-page companion `.ts` file with the same base name, but a `scenario-showcase.ts` exists in the same directory, use that as the companion.

- [ ] **Step 2: Update each .page.yaml file**

For each of the 8 pages, make two changes:

a) Add `id="scenario-root" data-category="<category>"` to the outermost `<div>` in the main content column.

b) Standardize interactive element IDs to match the generic companion:
   - State display → `id="scenario-state"`
   - Step display → `id="scenario-step"`
   - Time display → `id="scenario-time"`
   - Progress display → `id="scenario-progress"`
   - Event log → `id="scenario-log"`
   - Picker select → `id="scenario-picker"`
   - Run button → `id="scenario-run-btn"`
   - Speed slider → `id="scenario-speed-slider"`
   - Speed label → `id="scenario-speed-label"`
   - YAML viewer → `id="scenario-yaml"`
   - Description → `id="scenario-description"`
   - Buttons container → `id="app-buttons"` (already standard)

c) Remove hardcoded `<option>` elements from the picker `<select>` — the generic script builds them dynamically. Keep the empty `<select>` element.

**Category mapping:**
- Flow Control.page.yaml → `data-category="flow-control"`
- Coordination.page.yaml → `data-category="coordination"`
- Coordination Primitives.page.yaml → `data-category="coordination-primitives"`
- Concurrency Patterns.page.yaml → `data-category="concurrency-patterns"`
- Composition.page.yaml → `data-category="composition"`
- Data Delivery.page.yaml → `data-category="data-delivery"`
- Invoke Bindings.page.yaml → `data-category="invoke-bindings"`
- Step Workflows.page.yaml → `data-category="step-workflows"`

- [ ] **Step 3: Delete the 8 old companion scripts**

```bash
rm "examples/samples/Scenarios/Flow Control.ts"
rm "examples/samples/Scenarios/Coordination.ts"
rm "examples/samples/Scenarios/Coordination Primitives.ts"
rm "examples/samples/Scenarios/Concurrency Patterns.ts"
rm "examples/samples/Scenarios/Composition.ts"
rm "examples/samples/Scenarios/Data Delivery.ts"
rm "examples/samples/Scenarios/Invoke Bindings.ts"
rm "examples/samples/Scenarios/Step Workflows.ts"
```

- [ ] **Step 4: Regenerate samples.json**

Run: `node examples/scripts/generate-samples.js`
Expected: `samples.json` regenerated. All 8 migrated scenario pages should have `tsPath: "Scenarios/scenario-showcase.ts"`. The 7 custom pages should still have their own `tsPath`.

Verify: `grep -c "scenario-showcase.ts" examples/samples.json` should show 8.

- [ ] **Step 5: Test in browser**

Start the examples dev server and verify:
1. Navigate to a migrated scenario page (e.g. Flow Control)
2. Picker dropdown is populated dynamically from manifest
3. Select each example — YAML displays in viewer
4. Click Run — scenario executes with button flashes and event log
5. Speed slider works
6. Navigate to a non-migrated page (e.g. Form Automation) — still works with its own companion

- [ ] **Step 6: Commit**

```bash
git add -A examples/ scenarios/
git commit -m "feat(#466): migrate 8 showcase pages to generic companion + shared scenarios"
```

---

## Batch 3: Tutorial Integration

### Task 4: Add scenario-ref support to tutorial host

Add `scenario-ref` support to the tutorial host so tutorial sections can reference shared scenario files. When `scenario-ref` is present, the section displays the YAML source in a code viewer and provides a Run button.

**Files:**
- Modify: `packages/pages-aria/src/tutorial/tutorial-host.ts` (add scenario-ref handling)
- Modify: `packages/pages-aria/src/scenario/parser.ts` (accept scenario-ref in section type)
- Create: `packages/pages-aria/src/tutorial/tutorial-host.test.ts` (add test for scenario-ref)

**Interfaces:**
- Consumes: `scenarios/<category>/<name>.scenario.yaml` (from Task 1)
- Consumes: `parseScenario()` from `packages/pages-aria/src/scenario/parser.ts`

- [ ] **Step 1: Write the failing test**

Add a test to `tutorial-host.test.ts` that verifies scenario-ref sections fetch the referenced file and make its YAML available:

```typescript
it('should load scenario-ref YAML for section', async () => {
  // Mock fetch to return a .scenario.yaml file
  const scenarioYaml = `scenario: test-demo\nmeta:\n  title: Test\nsteps:\n  - click: { role: button, name: "A" }`;
  globalThis.fetch = vi.fn().mockResolvedValue({
    ok: true,
    text: () => Promise.resolve(scenarioYaml),
  });

  const tutorial = {
    scenario: 'test-tutorial',
    sections: [{
      title: 'Demo Section',
      'scenario-ref': 'flow-control/sequential.scenario.yaml',
      content: { type: 'inline', markdown: 'Watch this demo' },
      steps: [],
    }],
  };

  // Parse and verify the section has scenarioRef populated
  // The exact assertion depends on the tutorial host internals
  // — verify the section's scenarioYaml property is set after loading
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx vitest run packages/pages-aria/src/tutorial/tutorial-host.test.ts --reporter verbose`
Expected: FAIL — scenario-ref not yet handled.

- [ ] **Step 3: Implement scenario-ref in the tutorial host**

In `tutorial-host.ts`, add logic to the section loading phase:

1. When a section has `scenario-ref`, fetch the referenced `.scenario.yaml` file
2. Store the raw YAML text on the section object
3. Render a read-only code viewer showing the YAML (before the prose content)
4. Add a "Run" button that executes the scenario via `createScheduler()`

The `scenario-ref` path is relative to `scenarios/` at the repo root. The tutorial host resolves the full URL based on its base URL configuration.

- [ ] **Step 4: Update the parser to pass through scenario-ref**

In `parser.ts`'s `parseScenario()`, when parsing a sectioned scenario (`sections:` format), preserve the `scenario-ref` key on each `TutorialSection` object. This is a passthrough — the parser doesn't need to fetch the file, just carry the reference.

Add `scenarioRef?: string` to the `TutorialSection` type.

- [ ] **Step 5: Run the test to verify it passes**

Run: `npx vitest run packages/pages-aria/src/tutorial/tutorial-host.test.ts --reporter verbose`
Expected: PASS

- [ ] **Step 6: Run full test suite**

Run: `npm test` in the pages-aria package
Expected: All existing tests pass + new scenario-ref test passes.

- [ ] **Step 7: Commit**

```bash
git add packages/pages-aria/
git commit -m "feat(#466): add scenario-ref support to tutorial host"
```

---

## References

- `specs/epic-502-yaml-parity/2026-10-03-single-source-scenarios-design.md` — design spec
- `examples/samples/Scenarios/Flow Control.ts` — canonical companion script pattern
- `examples/samples/Scenarios/Composition.ts` — trigger + YAML-only variant
- `examples/scripts/generate-samples.js` — existing gallery manifest generator
- `examples/src/app.js:460-473` — companion script execution model
- `packages/pages-aria/src/tutorial/tutorial-host.ts` — tutorial host component
- `packages/pages-aria/src/scenario/parser.ts` — TS scenario parser
- D27-D31 in `specs/epic-502-yaml-parity/decisions.md`
- casehub-pages#466 — focal issue
- casehub-pages#464 — orchestration showcase (created current entries)
