# HANDOFF — casehub-platform

**Date:** 2026-06-01
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Two-session summary: (1) #35/#47/#51 small-batch closes (reactive storeAll, SCIM pagination, erase contract test). (2) casehub-platform-identity created — identity SPIs (ActorDIDProvider, DIDResolver, AgentCredentialValidator), model types, CDI events, and all implementations (NoOp*, KeyDIDResolver, WebDIDResolver, ConfiguredActorDIDProvider, ScimActorDIDProvider, AbstractCachingIdentityProvider) extracted from casehub-ledger into new platform module. CLAUDE.md updated. Closes platform#52. Config prefix: casehub.identity.*

## Immediate Next Step

Phase 2: casehub-platform-identity — platform#53 (move AgentIdentityVerificationService) is blocked on ledger#113 (signature refactor). Wait for ledger#113 to land, then implement platform#53. Otherwise pick from What's Next below.

## Cross-Module

**Blocked by:**
- `casehubio/ledger#113` — AgentIdentityVerificationService signature refactor must land before platform#53 (Phase 2 move) can proceed · M · Med

**We're blocking:**
- Unknown repo — WorkBroker and ExclusionPolicy call `membersOf()` expecting `Set<String>`. Next session: identify correct repo before filing issue. · S · Low

## What's Left

- Hook install pending on 5 repos: `casehub/aml`, `casehub/clinical`, `hortora/garden`, `casehub/drafthouse`, `casehub-poc` · XS · Low
- parent#130 filed — `docs/PLATFORM.md` + `docs/repos/casehub-platform.md` need memory-sqlite added · XS · Low
- Workspace epic branches past deletion dates: `epic-platform-api`, `epic-platform-testing`, `epic-quarkus-alignment`, `epic-platform-config` — kept by user choice

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #49 | CDI emission investigation — Options A/B/C + storeAll batch | M | Med | Needs devtown/clinical/aml app feedback first |
| #39 | CDI priority revisit when `memory-mem0/` arrives | S | Med | Blocks on #33 |
| #33 | Mem0 adapter — builds against updated SPI | L | Med | |
| #34 | Graphiti adapter — builds against updated SPI | L | Med | |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Parked |

## References

- Blog: `blog/2026-06-01-mdp01-five-closes-one-gotcha.md`
- Garden: GE-20260531-c7f95a (git checkout silent failure in loop), GE-20260601-8c9e4b (commit-tree for locked worktree branch)
- Prior blog: `blog/2026-05-31-mdp01-durable-memory-no-server.md`
