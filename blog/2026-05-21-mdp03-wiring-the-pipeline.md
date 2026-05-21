---
layout: post
title: "Wiring the Pipeline"
date: 2026-05-21
type: phase-update
entry_type: note
subtype: log
projects: [casehub-platform]
tags: [ci, maven, housekeeping]
---

Three small things that had been sitting on the list since the oidc module shipped.

The first two were pure cleanup. Quarkus 3.31 relocated `quarkus-junit5` to `quarkus-junit` — the `oidc/` module already had the right name, but `platform/` and `config/` were still emitting relocation warnings on every build. Two line changes, done. The jandex plugin version was hardcoded separately in both `config/pom.xml` and `oidc/pom.xml`; we pulled it up into the parent `<properties>` block so there's one place to bump it.

The third was more interesting. I noticed the `distributionManagement` block in the parent pom has been pointing at GitHub Packages since the beginning. But there was no `.github/workflows/` directory — so `mvn deploy` was documented, configured, and completely inert. Nothing was ever actually published beyond my local `.m2`. We added the CI workflow, modelled on the parent repo's pattern: build and test on PRs, deploy on push to main. The pipeline is wired now.

Checked ledger#88 while I was orienting — the ActorType migration to platform-api is still open. The `actorType()` TODO on `CurrentPrincipal` will stay until that lands.
