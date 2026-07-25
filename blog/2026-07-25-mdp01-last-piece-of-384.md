---
layout: post
title: "Last Piece of 384"
date: 2026-07-25
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [reactive, virtual-threads, acl, refactoring]
---

The ACL subsystem was the last holdout from the reactive tier retirement (#384). While 13 repos and 30,000+ lines of reactive code were removed in the main sweep, `acl-jpa` slipped through — still on Hibernate Reactive Panache, with `AccessControlProvider` returning `CompletionStage` on every method.

The fix was mechanical. Convert the SPI to blocking returns, swap `quarkus-hibernate-reactive-panache` for `quarkus-hibernate-orm-panache`, rewrite the Uni chains into direct Panache calls with `@Transactional`, strip the `CompletableFuture.completedFuture()` wrappers from the in-memory adapter. The recursive parent-traversal in `canAccessWithCandidates` actually reads better as a plain boolean method than it did as a `Uni<Boolean>` chain.

Zero cross-repo callers — the SPI break was fully contained within platform. Every other SPI in platform-api is now blocking, consistent with the virtual-thread execution model.

The installed features line in the test output tells the story: `hibernate-orm, hibernate-orm-panache` — no more `hibernate-reactive`.
