---
layout: post
title: "The OOM That Was Hiding a Config Bug"
date: 2026-06-01
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [quarkus, keycloak, devservices, config-mapping, smallrye-config]
---

The session opened with a heads-up from another Claude working in `casehub-work`: `casehub-platform-api` was shipping without a Jandex index. It's the pure-SPI jar — interfaces and records, zero dependencies — and until now it had got away without one. Quarkus ARC was finding the implementing beans in `casehub-platform-identity` (which had Jandex), and the type hierarchy lookup had landed somewhere useful. That luck ran out when the ledger SNAPSHOT cache was refreshed and CDI started reporting "Unsatisfied dependency for type DIDResolver" with `NoOpDIDResolver` sitting right there on the compile classpath.

One `<plugin>` block in `platform-api/pom.xml`. Filed as platform#54, verified with `mvn install -pl platform-api`, done.

Then the full build stalled on SCIM. The DevServices container for `quay.io/keycloak/keycloak:26.5.4` was starting, consuming everything available in the Podman VM, and dying before it could emit the startup log line Testcontainers was waiting for. OOMKilled. Sixty-plus seconds of nothing, then `ContainerLaunchException`.

I asked why Keycloak can't be lightweight for tests. The answer is that "dev mode" in Keycloak means "no TLS required" — not "small footprint." It boots the same Quarkus application, the same Infinispan cluster, the same Hibernate ORM whether you're in production or a test. There's a `quarkus-test-oidc-server` that genuinely is lightweight, but that's a separate thing Quarkus provides for when you can't or don't want to run a full OIDC server. Keycloak itself has no slim variant.

I brought Claude in to look at the memory issue, and we found the standard workaround from the Quarkus issue tracker — JVM tuning flags via `quarkus.keycloak.devservices.java-opts`, a container memory limit to keep the heap calculations sane. That would have worked. We had the properties file open and were about to commit when I looked at the SCIM test configuration.

The tests configure `casehub.platform.scim.token=test-static-token`. `ScimAuthFilter` does `config.token().orElseGet(this::fetchOidcToken)` — with a token set, the OIDC client branch never executes. Keycloak DevServices was starting because `quarkus-oidc-client` is on the classpath. Not because any test actually needs to acquire a token. Quarkus DevServices activation is classpath-driven, not call-path-driven.

`quarkus.keycloak.devservices.enabled=false`. That's it.

Quarkus booted in 6 seconds. Then immediately threw `SRCFG00050 — does not map to any root` for `casehub.platform.scim.member-page-size`.

This was the real bug. It had been invisible because the OOMKill was happening before Quarkus finished initialising — the config validator never ran. What looked like a Keycloak memory problem was a config mapping gap with a container crash in front of it.

`ScimConfig` uses `@ConfigMapping(prefix = "casehub.platform.scim")`. SmallRye Config's strict mode treats that prefix as an exclusive namespace. Any key under `casehub.platform.scim.*` that isn't declared as a method in the interface is rejected — regardless of whether another bean injects it via `@ConfigProperty`. `member-page-size` was consumed by `ScimGroupMembershipProvider` via `@ConfigProperty`, which is a completely separate mechanism, but since `ScimConfig` owns the prefix, SmallRye sees the key and looks for it in the mapping. Not there. Boot fails.

We moved `member-page-size` into `ScimConfig` as `memberPageSize()` with `@WithDefault("1000")`, updated `ScimGroupMembershipProvider` to inject `ScimConfig` and call `config.memberPageSize()` instead. The orphaned `@ConfigProperty` field disappeared. SCIM tests: 7/7 passing in 5 seconds with no containers.

Full build: green across all fourteen modules.

The third commit — `ScimActorDIDProvider` test constructor and `validateEndpoint` widened from package-private to public — was a leftover from the previous session, spotted in the diff before pushing. That constructor is needed by integration tests in consuming modules once platform#53 (moving `AgentIdentityVerificationService`) lands. It was already done; just hadn't been committed.
