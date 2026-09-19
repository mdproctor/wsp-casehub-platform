---
title: "Simulation DX: The Last Mile"
date: 2026-09-19
entry_type: note
subtype: diary
author: mdp
projects: [casehub-platform]
tags: [simulation, developer-experience, yaml, testing, architecture]
series: casehub-platform
---

# Simulation DX: The Last Mile

The simulation framework shipped four months ago with five strategies, a corpus model, overlay isolation, and generated decorators. It works. But "works" and "pleasant to use" are different things, and I'd been accumulating a list of friction points every time I wired a new consumer.

The ceremony was the problem. Setting up a key-lookup test required constructing an `InMemorySimulationCorpus`, seeding it with `InvocationRecord` instances (each needing a tenant ID, a key, input, output, and a timestamp), building a `SimulationConfig` via a 14-line anonymous class, wiring the runtime, registering an extractor, then finally resolving a strategy. Six objects, twelve lines, for what should be: seed some data, resolve, check the answer.

## Three lines

The fluent harness collapses all of that:

```java
var sim = Simulation.forTest()
    .stub("acl.canAccess", checkArgs, true)
    .stub("memory.query", query, results)
    .build();

assertThat(sim.resolve("acl.canAccess", checkArgs)).isTrue();
```

`stub()` implies key-lookup strategy and registers an identity extractor automatically. `seed()` implies sequential. Mix them on the same qualified name and you get a clear error telling you to pick one. The common case — one strategy per method, input-derived keys — needs zero configuration beyond the data itself.

I was tempted to add more to the harness. Typed resolution, CDI integration, YAML merging. Each would serve someone. But the design decision that mattered was keeping `forTest()` standalone — a POJO that creates its own runtime, independent of any CDI container or config file. The 80% case is a unit test with no application context. Serving that case well meant saying no to the 20%.

## One file instead of three

The bigger change was rethinking configuration. Strategy declarations lived in MicroProfile Config properties (`casehub.simulation.spi.method.strategy=key`). Corpus data lived in separate YAML files. The two were wired together by a third property pointing at file paths. Small scenarios — the kind you write while iterating on a feature — required creating a fixture file, declaring its path, and setting strategy properties. Three files to say "when someone queries cardiology, return lab results."

The unified `simulation.yaml` puts everything in one place:

```yaml
methods:
  case-memory-store.query:
    strategy: key
    key-extractor: "field:domain"
    corpus:
      - key: cardiology
        input: { domain: cardiology, question: "latest labs" }
        output: "Lab results for cardiology"
```

Strategy, extractor, and corpus entries coexist per method. Profiles nest inside the same file. External corpus files are still supported for large fixture sets via `corpus-files:` references — but the small-scenario path no longer forces you out of the config file.

The parser (`YamlSimulationConfig`) replaces both `SmallRyeSimulationConfig` and `YamlCorpusLoader`. Convention-based discovery loads `simulation.yaml` from the classpath root — zero config for the common case, one MicroProfile property to override the path. Environment knobs like `active-profile` stay in MicroProfile Config where Quarkus profile qualification (`%test.`, `%dev.`) can reach them. Structured data stays in YAML where it belongs.

## The audit found the documentation

Ten issues closed. Code green. I ran a DX audit before closing the branch — the kind where you walk through the consumer onboarding path and ask "could someone actually use this following our docs?"

The code was fine. The documentation wasn't. The simulation guide — the primary consumer-facing document at 1,780 lines — still showed the flat-key config format throughout. Every strategy section, the CI section, the profiles section: all pointing at the retired API. The consumer guide didn't mention `simulation-starter`, the one-dependency entry point that was the whole point of one of the issues.

Seven new issues came out of the audit. The simulation guide rewrite is the largest. The rest are small: starter missing the generator dependency, YAML typo detection, a tutorial example, the profile capture override bug, domain examples. Filed as a follow-on epic — the branch that built the DX tools didn't have time to fully document them.

That's the uncomfortable pattern with DX work: the last mile isn't the API. It's making sure someone who wasn't in the room can find and use it.
