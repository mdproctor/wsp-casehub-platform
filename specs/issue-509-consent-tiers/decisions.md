## D1: Scope — full consent tier integration

**Choice:** Complete §7 as one platform-api change: ConsentTier enum + new WorkerAction constants + AuthorizationDecision evolution + updated policy contract.
**Alternatives:**
- Types only, no policy change — simpler but leaves connector code interpreting tiers ad-hoc
- Incremental (types first, then policy) — reduces risk but doubles review overhead for a small change set
**Rationale:** The types, constants, and policy evolution are tightly coupled — shipping them separately creates a window where types exist but can't be meaningfully used.
**Trade-offs:** Slightly larger PR than types-only, but all changes are in platform-api with no runtime wiring.
**Sources:** connectors design doc §7, issue #509
**Exploration:** quick
**Status:** captured

## D2: AuthorizationDecision evolution strategy

**Choice:** Add ConsentOutcome enum field, keep `approved()` as backward-compatible convenience accessor returning `outcome == APPROVED`.
**Alternatives:**
- Replace boolean with enum, break callers — cleaner but forces all consumers to update simultaneously
- Sealed interface hierarchy (Approved/NeedsConfirmation/NeedsApproval/Denied) — type-safe pattern matching but heavy API change for a record that currently has two fields
**Rationale:** Existing callers use `decision.approved()` for binary checks. The convenience accessor preserves that contract while new callers use `outcome()` for graduated decisions. The record component changes from `boolean approved` to `ConsentOutcome outcome`, but the accessor name stays valid.
**Trade-offs:** `approved()` is now a derived method, not a record component — callers doing record destructuring (rare in this codebase) will break.
**Sources:** AuthorizationDecision.java, AutoApproveWorkerAuthorizationPolicyTest.java
**Exploration:** quick
**Status:** captured

## D3: ConsentTier binding to WorkerAction

**Choice:** Add `ConsentTier defaultTier` field to WorkerAction record with backward-compatible constructor defaulting to `ConsentTier.AUTO`.
**Alternatives:**
- Separate ConsentTierRegistry SPI — decouples tier from action definition, allows per-tenant tier configuration without changing action constants, but adds indirection
- ConsentTier on WorkerPermissionRequest — maximum flexibility but pushes tier knowledge to every call site
**Rationale:** The tier is an inherent property of the action's risk level. PURCHASE is always higher risk than SEARCH regardless of context. Per-tenant *overrides* are the policy's job, not the tier definition's.
**Trade-offs:** Adding a field to a record is a binary-incompatible change. The backward-compat constructor mitigates source compatibility.
**Sources:** WorkerAction.java, connectors design doc §7
**Exploration:** quick
**Status:** captured

## D4: Connector action constants location

**Choice:** Define SEARCH, ADD_TO_CART, BOOK_CANCELLABLE, PURCHASE, BOOK_NON_REFUNDABLE as static constants on WorkerAction alongside existing READ_CONTEXT and SIGNAL_CASE.
**Alternatives:**
- Separate ConnectorActions class in platform-api — keeps WorkerAction lean but splits the constant catalog
- In connectors repo — proper domain ownership but forces connectors to depend on its own constants for platform-level authorization
**Rationale:** These are platform-level action definitions usable by any domain module. Centralizing them on WorkerAction keeps a single catalog. The action set is small (7 total) and likely to stay small.
**Trade-offs:** Platform-api takes on connector-flavored constants. If the action set grows large, a separate class would be warranted.
**Sources:** WorkerAction.java (existing constants pattern), connectors design doc §7.1
**Exploration:** quick
**Status:** captured

## D5: Tier-outcome relationship model

**Choice:** Tier as policy input, outcome as policy output. The `defaultTier` on `WorkerAction` is advisory context — the policy evaluates it against tenant/user/amount context and produces a `ConsentOutcome`.
**Alternatives:**
- Direct tier-to-outcome mapping with policy override — simpler but can't express "CONFIRM unless amount < £20"
- Two-phase (ACL check then consent check) — cleaner separation but doubles API surface
**Rationale:** Matches the design doc model exactly. Policies get full flexibility: a CONFIRM-tier action can be elevated to NEEDS_APPROVAL for high-value amounts, or downgraded to APPROVED for trusted providers. AutoApproveWorkerAuthorizationPolicy stays trivially correct.
**Trade-offs:** Policy implementors must handle all tiers explicitly — no automatic tier→outcome default unless they choose to implement one.
**Sources:** connectors design doc §7.2
**Exploration:** quick
**Depends on:** D2, D3
**Status:** captured
