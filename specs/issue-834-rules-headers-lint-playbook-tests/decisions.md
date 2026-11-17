# Decisions — #834 Rules Headers and Lint

## D1: Header format — structured meta fields

**Choice:** Add `level`, `layer`, `teaches`, `builds-on` as structured YAML fields inside the existing `meta:` block
**Alternatives:**
- YAML comments — human-readable but requires comment-parsing regex for lint
- Separate header document — clean separation but changes the two-document file format established by WS-4
**Rationale:** Machine-readable, directly parseable by lint, consistent with existing meta block structure
**Trade-offs:** None significant — the meta block already exists in canonical form
**Sources:** playbook-direction.md (WS-5 section), existing playbook canonical form from WS-4
**Exploration:** quick
**Status:** captured

## D2: Drop R-ID rules from header schema

**Choice:** Exclude `rules` (R1, R2, etc.) from the header schema entirely
**Alternatives:**
- Full rules with R-IDs per direction doc — natural language rules with lint cross-referencing test names
- Rules without lint — documentation-only, no enforcement
**Rationale:** Rules are natural language documentation. The lint can only verify a test named "R1" exists, not that it actually tests the rule's claim. The `teaches` field already describes what the playbook demonstrates. The R-ID ceremony doesn't carry its weight.
**Trade-offs:** No per-teaching-point coverage tracking. Acceptable — lint still enforces assertion quality.
**Sources:** playbook-direction.md WS-5 section, discussion with user
**Exploration:** deep-analysis
**Status:** captured

## D3: Teaching-first test philosophy

**Choice:** Tests assert business logic and processing outcomes, serving as teaching documentation. Low-level "step executed" assertions are secondary and only included when they illustrate a point.
**Alternatives:**
- Verification-first — exhaustive execution trace assertions
- Compilation-only — structural assertions without execution
**Rationale:** Tests are sentences in a tutorial, not checkboxes in a test plan. Each assertion should illuminate behavior for the reader.
**Trade-offs:** Less exhaustive verification. Acceptable — step execution is a unit test concern.
**Sources:** User direction, existing test patterns in order-lifecycle.test.yaml (good example)
**Exploration:** quick
**Status:** captured

## D4: Result enrichment — both runner and explicit output

**Choice:** Enrich run-playbook result to expose orchestration state (counters, flags, state machines, retry counts) automatically, plus explicit output steps in playbooks where domain-specific outcomes need surfacing.
**Alternatives:**
- Runner enrichment only — not all outcomes are automatically observable
- Explicit output steps only — every playbook needs modifying, no automatic benefit
**Rationale:** Runner enrichment gives every playbook richer assertions for free. Explicit steps fill gaps for domain-specific outcomes.
**Trade-offs:** Runner changes affect yaml-test-core, not just playbooks module
**Sources:** RunPlaybookPlugin.java, existing result map shape
**Exploration:** quick
**Status:** captured

## D5: Lint strictness — fail build with per-file opt-out

**Choice:** Lint fails the Maven build by default. Per-file opt-out via `lint: skip` annotation in test file header for deliberate exceptions.
**Alternatives:**
- Warn only — risks being ignored
- Always fail, no opt-out — too rigid for WIP or TS-only examples
**Rationale:** Start strict to surface the real shape of the problem. Annotation escape hatch for legitimate exceptions.
**Trade-offs:** Initial run will likely fail many files — that's intentional, tells us what needs fixing
**Sources:** Issue #834 scope, P22 finding
**Exploration:** quick
**Status:** captured

## D6: Fix 3 failing catalog-parsing-gate examples

**Choice:** Fix modules.playbook.yaml, rest.playbook.yaml, and 08-structured-output.playbook.yaml so the gate expects 0 failures
**Alternatives:**
- Separate issue — keeps #834 focused but leaves the gate broken
**Rationale:** Part of the same quality sweep. We're touching every playbook for headers anyway.
**Trade-offs:** Small scope addition
**Sources:** catalog-parsing-gate.test.yaml line 9, P22 finding
**Exploration:** quick
**Status:** captured

## D7: Taxonomy — layer = directory, level = difficulty

**Choice:** `layer` maps to the directory category name (flow-control, coordination, etc.). `level` is a 1-5 difficulty progression within each layer.
**Alternatives:**
- Separate conceptual taxonomy for layer — more flexible but requires inventing a new grouping
- Drop layer entirely — directory already provides the category
**Rationale:** Simple, discoverable, no new taxonomy to invent. The directory structure is already a good category system.
**Trade-offs:** Layer is redundant with directory — but useful for index generation where the directory path isn't available
**Sources:** playbook-direction.md, existing directory structure
**Exploration:** quick
**Status:** captured

## D8: Test coverage scope — one test file per category

**Choice:** Each of the 10 directories gets a `.test.yaml` covering its playbooks with behavioral assertions. ~10 new test files.
**Alternatives:**
- One test per playbook — 62 new tests, thorough but large scope
- Only fix existing tests — minimal scope, leaves 62 playbooks uncovered
**Rationale:** Pragmatic coverage. Each category gets meaningful behavioral tests without one-test-per-playbook overhead.
**Trade-offs:** Some playbooks within a category may not get individual assertions — the category test covers representative examples
**Sources:** Existing test file pattern (agent-interaction-patterns has compilation + execution test files)
**Exploration:** quick
**Status:** captured

## D9: Lint location — test in playbooks module

**Choice:** A new test in playbooks/ that scans all .test.yaml files, parses assertions, and fails if any test only asserts succeeded/stepCount
**Alternatives:**
- Lint plugin in yaml-test-core — more reusable but heavier infrastructure
- Maven enforcer rule — cleanest separation but requires enforcer infrastructure
**Rationale:** Co-located with the playbooks. Runs as part of `mvn test`. Simple. Per-file opt-out via `lint: skip` in test file header.
**Trade-offs:** Not reusable outside the playbooks module. Acceptable — this is a playbooks-specific concern.
**Sources:** Existing ValidatePlaybookPlugin pattern, catalog-parsing-gate.test.yaml
**Exploration:** quick
**Status:** captured
