---
layout: post
title: "The abstraction that was hiding in plain sight"
date: 2026-09-29
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [spring-boot, kubernetes, expression, dual-framework, config]
series: issue-473-k8s-spring-fabric8
---

The Quarkus expression module had two classes — `MockConfigManager` and `MockSecretManager` — that read K8s ConfigMaps and Secrets through SmallRye Config. They'd been there since the early days of the platform, doing their job, and nobody had reason to touch them. The problem surfaced when I looked at the Spring Boot parity checklist for parent#515: `$config` and `$secret` variables in JQ expressions don't work on Spring deployments. The expression layer has no Spring equivalent.

The obvious approach would have been to write a parallel Spring implementation — `EnvironmentConfigManager`, `EnvironmentSecretManager` — and move on. But that's the path that creates two implementations that drift apart. The Quarkus versions would evolve, the Spring versions would lag behind, and eventually someone would find a subtle difference in how nested maps get built.

The better answer was already there in the codebase's own pattern. Every other CDI-coupled module — credentials, SCIM, identity, MCP — had been through the same extraction: pull the logic into a framework-neutral core POJO, wrap it with CDI on the Quarkus side, wrap it with `@AutoConfiguration` on the Spring side. The expression module just hadn't been done yet.

What made this extraction clean was the shape of the dependency. Both `MockConfigManager` and `MockSecretManager` needed exactly two things from their framework: look up a property by name, and iterate all property names. That's a two-method interface — `PropertySource`. SmallRye's `ConfigProvider.getConfig()` implements it trivially. Spring's `Environment` implements it trivially. The logic that sweeps properties by prefix and builds nested maps from dotted keys (`app.database.host` → `{database: {host: ...}}`) is pure string manipulation that belongs in neither framework.

`JQEvaluator` was the less obvious piece. It sits in the Quarkus module with `@Inject SecretManager` and `@Inject ConfigManager`, providing `$secret` and `$config` scope injection into JQ expressions. Without extracting it, those scope variables wouldn't exist on Spring — and that's the whole point of the K8s config integration. The extraction to `JQEvaluatorCore` was mechanical: constructor injection instead of `@Inject`, root scope initialised in the constructor instead of `@PostConstruct`.

The Spring auto-configuration ended up at seven beans — three expression engines, the registry, ConfigManager, SecretManager, and JQEvaluatorCore. All `@ConditionalOnMissingBean` so consumers can override. The K8s integration on the Spring side is the same shape as Quarkus: add `spring-cloud-kubernetes-fabric8-config` to your classpath, properties flow into Spring's `Environment`, `EnvironmentPropertySource` picks them up, done.

One thing that caught me: jackson-jq's `Scope.setValue()` has an overloaded method — `setValue(String, JsonNode)` and `setValue(String, Supplier<JsonNode>)`. Passing `MAPPER.valueToTree(map)` inline triggers a compilation error because the compiler can't resolve which overload to use. The fix is assigning to a local variable first. The original `JQEvaluator` already did this (it had a local `JsonNode secretsNode = ...` before the `setValue` call), but I missed it in the first extraction pass.

The branch adds 728 lines and removes 127 — most of the removal is the duplicated nested-map builder logic that `PropertyMapBuilder` now handles once. Expression-core gained 19 unit tests, expression-spring has 9, and the existing 72 Quarkus tests all pass unchanged. The spring-integration-test now asserts that `ConfigManager`, `SecretManager`, and `JQEvaluatorCore` compose into the Spring Boot application context alongside the other 40+ auto-configured beans.

What this actually unlocks: any Spring Boot deployment can now run JQ expressions with `$secret` and `$config` scope injection. K8s ConfigMaps and Secrets feed in through the standard Spring Cloud Kubernetes path — no CaseHub-specific K8s code needed. The platform's K8s role stays exactly where it should be: reading config, not wrapping clients.
