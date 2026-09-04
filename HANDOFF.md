# HANDOFF — casehub-platform

## Last Session

Implemented qhorus#428 — `ContextPressureCapacitySource` + `QhorusRedistributionExecutor`. Five commits to qhorus: Commitment.capabilityTag schema extension, CrossTenantCommitmentStore + ledger query extensions, signal source, executor + delegate, and a bug fix (escalation guard checking redistributable count not total obligations). Updated platform CLAUDE.md with `.capacity` package entries and added Capacity Signal section to contributor-guide.md. Blog entry written: "Feedback Loops That Converge" with inline SVG diagrams. Garden entry captured: GE-20260905-5296aa (stateless sweep-based eventual consistency technique).

## Immediate Next Step — RESUME WORK-END

Work-end is in progress (`state: closing:promoted`). The close sequence completed code review, branch audits, sweeps, doc sync, artifact promotion, trajectory, and blog publishing. **Stuck at the rebase step** — platform branch has 8 conflicts rebasing 9 commits against main. Qhorus branch also needs rebasing against qhorus main.

**Resume instructions:**

1. Run `work end` — it will detect the interrupted close and offer to resume
2. The rebase step needs manual conflict resolution:
   - Platform: `git -C /Users/mdproctor/claude/casehub/slots/171/platform rebase main` — resolve 8 conflicts across the capacity commits
   - Qhorus: `git -C /Users/mdproctor/claude/casehub/slots/171/qhorus rebase main` — untested, conflicts unknown
3. **Merge ordering dependency:** Platform must be merged and artifacts published FIRST. Qhorus depends on `casehub-platform-api:0.2-SNAPSHOT` which contains the capacity SPI types. Without platform on main, qhorus CI will fail to resolve the capacity classes.
4. After rebase: squash → land (platform first, then qhorus) → close issues → verify

**`.close-progress` state:** All review and sweep steps done. Promote done. Trajectory done. Rebase is the current gate.

## Cross-Module

- casehubio/eidos#151 — load-aware selection (Batch 2). Depends on platform#268 (done). Not blocking qhorus#428.
- Engine `ActorStateAccumulatorImpl.capacity()` override — needs an issue filed before branch merge.
- casehubio/qhorus#429 — prerequisite for compress path: `ChannelSummaryService.triggerUpdate()` must use `CrossTenantChannelStore`. `countMessagesSince()` was made public in this session but the cross-tenant channel lookup is still needed.
- Qhorus CLAUDE.md has uncommitted path normalization changes (harmless, from another session).
- `blog/assets/` directory in workspace is untracked (SVG files extracted during blog writing — can be deleted, went with inline SVGs).

## Garden Entries Consulted

GE-20260605-373190 (@ObservesAsync + @RequestScoped), GE-20260512-6887c9 (@ObservesAsync + @Transactional), GE-20260517-e10a0f (HANDOFF commitment gotcha), GE-20260512-0fe012 (fireAsync transaction timing), GE-20260627-f3476f (scope-safe CurrentPrincipal), GE-20260602-6941d6 (separate @Transactional delegate), GE-20260517-5de55b (dispatch auto-opens commitment)

## Garden Entries Captured

GE-20260905-5296aa — stateless sweep-based eventual consistency technique (pushed to garden)

## References

- Spec (platform): `specs/issue-268-capacity-redistribution/2026-09-02-capacity-signal-spi-design.md`
- Spec (qhorus): `specs/issue-268-capacity-redistribution/2026-09-03-qhorus-capacity-redistribution-design.md`
- Decisions: `specs/issue-268-capacity-redistribution/decisions.md` (D1–D12)
- Plan: `plans/2026-09-03-qhorus-capacity-redistribution.md`
- Blog: `blog/2026-09-03-mdp01-feedback-loops-that-converge.md`
- Blog (prior): `blog/2026-09-02-mdp01-shared-vocabulary-for-overload.md`
- Cross-platform spec: `wsp-casehub-qhorus/specs/cross-platform-capacity-redistribution/`
