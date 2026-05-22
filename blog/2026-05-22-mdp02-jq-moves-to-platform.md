---
layout: post
title: "JQ Moves to Platform"
date: 2026-05-22
type: phase-update
entry_type: note
subtype: log
projects: [casehub-platform]
tags: [expression, jq, platform-api]
---

The engine team filed a request: `JQEvaluator` needs to live in `casehub-platform`,
not `casehub-engine-common`. Foundation-tier repos like `casehub-work` can't reach
into the Orchestration tier to borrow a JQ evaluator. The fix is to move it down.

Most of the extraction is mechanical — copy `JQEvaluator`, `ValidationResult`,
`SecretManager`, `ConfigManager` and their exceptions from `casehub-engine-common`,
repackage them under `io.casehub.platform.*`. But before copying anything, I had to
decide where each piece lands.

`SecretManager` and `ConfigManager` are pure Java interfaces. No Jackson, no Quarkus,
no external deps of any kind. They belong in `platform-api/` — Tier 1. `JQEvaluator`
and `ValidationResult` have a Jackson + jackson-jq dependency, so they go in a new
`expression/` module alongside `quarkus-arc`. Same optional-module pattern as
`config/` and `oidc/`: add as a compile dep to activate, absent has zero classpath
cost.

The interesting call was where to put the `@DefaultBean` mocks for `SecretManager`
and `ConfigManager`. My first instinct was `platform/` — that's where all the other
mocks live. But if `expression/` is optional and `SecretManager` only matters when
you're using `JQEvaluator`, then the mocks should ship with the evaluator. Adding
`expression/` gives you a working CDI context out of the box. We moved both mocks
into `expression/` itself.

Then the code review came back. The reviewer flagged the `MockSecretManager` as
Critical — and it was right. I'd written:

```java
@ConfigProperty(name = "casehub.platform.secrets")
Optional<Map<String, String>> secretsConfig;
```

SmallRye Config doesn't sweep `casehub.platform.secrets.openai.apiKey=sk-test` into
that map. It looks for a property literally named `casehub.platform.secrets` and
returns `Optional.empty()` when it doesn't exist — which is always. The mock would
have silently served no secrets regardless of what was in `application.properties`.
The fix is the same pattern `MockConfigManager` already used correctly: iterate
`ConfigProvider.getConfig().getPropertyNames()` and filter by prefix.

The expression caching (`ConcurrentHashMap<String, JsonQuery>`) that engine#319
requested was already in the design — compiled queries are immutable and thread-safe,
so caching them is obvious once you know. Engine#319 is now closed.

Consumer migration is tracked in engine#320 (remove the engine-common copy) and
work#207 (replace `JqConditionEvaluator`). Both block on this module publishing.
