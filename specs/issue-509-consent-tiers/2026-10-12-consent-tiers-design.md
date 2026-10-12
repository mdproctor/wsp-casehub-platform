# WorkerAuthorizationPolicy Consent Tiers

**Issue:** casehubio/platform#509
**Date:** 2026-10-12
**Branch:** issue-509-consent-tiers

## Summary

Extend the platform-api worker authorization model with graduated consent
semantics for action-gated connectors. Two new enums (ConsentTier,
ConsentOutcome), two record modifications (WorkerAction, AuthorizationDecision),
and five new action constants. No runtime wiring changes.

## Motivation

The Real-World Knowledge Platform (Phase 3) introduces transactional connectors
that can purchase, book, and commit to real-world actions on behalf of users.
These actions require graduated consent — a search should proceed automatically,
a non-refundable booking should require explicit approval with full details.

The existing WorkerAuthorizationPolicy is binary (approve/deny). This design
extends it to support four consent outcomes while preserving backward
compatibility for existing callers.

## New Types

### ConsentTier enum

`io.casehub.platform.api.acl.ConsentTier`

Represents the inherent risk level of an action. This is an *input* property —
it tells the policy what level of consent the action's definition expects.

| Value | Meaning |
|-------|---------|
| `AUTO` | Action proceeds without user interaction |
| `CONFIRM` | One-click confirmation prompt |
| `APPROVE_WITH_DETAILS` | Show full details, require explicit approval |
| `DENY` | Action blocked by policy |

### ConsentOutcome enum

`io.casehub.platform.api.acl.ConsentOutcome`

Represents the policy's decision. This is an *output* — the result of evaluating
an action's tier against tenant/user/amount context.

| Value | Meaning |
|-------|---------|
| `APPROVED` | Proceed immediately |
| `NEEDS_CONFIRMATION` | Present one-click confirmation |
| `NEEDS_APPROVAL` | Present details for explicit approval |
| `DENIED` | Blocked with reason |

### Tier vs Outcome

ConsentTier is advisory — it encodes the action's default risk level. The policy
evaluates the tier against context (amount thresholds, provider trust, user
preferences) and produces a ConsentOutcome. A CONFIRM-tier action can be elevated
to NEEDS_APPROVAL for high-value amounts, or downgraded to APPROVED for trusted
providers under a threshold.

## Modified Types

### WorkerAction

Add `ConsentTier defaultTier` as third record component.

```java
public record WorkerAction(
    String name,
    AclAction aclAction,
    ConsentTier defaultTier) {

    // backward-compatible constructor — defaults to AUTO
    public WorkerAction(String name, AclAction aclAction) {
        this(name, aclAction, ConsentTier.AUTO);
    }
}
```

Existing constants (`READ_CONTEXT`, `SIGNAL_CASE`) are unchanged — the
backward-compatible constructor gives them `ConsentTier.AUTO` implicitly.

New constants:

| Constant | Name | AclAction | DefaultTier |
|----------|------|-----------|-------------|
| `SEARCH` | `"search"` | READ | AUTO |
| `ADD_TO_CART` | `"add-to-cart"` | WRITE | AUTO |
| `BOOK_CANCELLABLE` | `"book-cancellable"` | WRITE | CONFIRM |
| `PURCHASE` | `"purchase"` | WRITE | APPROVE_WITH_DETAILS |
| `BOOK_NON_REFUNDABLE` | `"book-non-refundable"` | WRITE | APPROVE_WITH_DETAILS |

### AuthorizationDecision

Replace `boolean approved` component with `ConsentOutcome outcome`.

```java
public record AuthorizationDecision(
    ConsentOutcome outcome,
    String reason) {

    public boolean approved() {
        return outcome == ConsentOutcome.APPROVED;
    }

    public static AuthorizationDecision approve() {
        return new AuthorizationDecision(ConsentOutcome.APPROVED, null);
    }

    public static AuthorizationDecision deny(String reason) {
        return new AuthorizationDecision(ConsentOutcome.DENIED, reason);
    }

    public static AuthorizationDecision needsConfirmation(String reason) {
        return new AuthorizationDecision(ConsentOutcome.NEEDS_CONFIRMATION, reason);
    }

    public static AuthorizationDecision needsApproval(String reason) {
        return new AuthorizationDecision(ConsentOutcome.NEEDS_APPROVAL, reason);
    }
}
```

The `approved()` convenience method preserves backward compatibility for callers
that only need a binary check. New callers use `outcome()` for graduated
decisions.

### Unchanged Types

- **WorkerAuthorizationPolicy** — no signature change. Default `evaluate()`
  returns `approve()` as before. Implementations can inspect each action's
  `defaultTier()` from the request.
- **WorkerPermissionRequest** — no change. Already carries `Set<WorkerAction>`,
  and each action now has a `defaultTier()`.
- **WorkerAuthorizationContext** — no change. Domain code provides context
  implementations (e.g., amount, provider) as before.
- **WorkerCredential**, **WorkerCredentialStore** — no change. Credential
  validation is orthogonal to consent.

## Impact on Existing Code

### platform-core

**AutoApproveWorkerAuthorizationPolicy** — no change. Inherits default
`evaluate()` which returns `approve()`. The factory now constructs
`AuthorizationDecision(ConsentOutcome.APPROVED, null)` — same behavior.

### acl-worker-core / acl-worker / acl-worker-spring

No change. Credential validation filters never call the policy.

### acl-inmem-core

**InMemoryWorkerCredentialStore** — no change. Stores/retrieves credentials,
no consent logic.

### Tests

- `AutoApproveWorkerAuthorizationPolicyTest` — update any assertions that
  reference the old `approved` record component directly. The `.approved()`
  accessor still works.
- `WorkerPermissionRequestTest` — update any direct `WorkerAction` construction
  if tests rely on record component count.
- Tests using `approve()` / `deny()` factories and `.approved()` accessor
  continue to work unchanged.

### CLAUDE.md

Update platform-api package structure documentation to reflect ConsentTier,
ConsentOutcome, and the new WorkerAction constants.

## Out of Scope

- Runtime policy wiring (invoking `evaluate()` from credential filters)
- Connector-specific policy implementations
- UI confirmation/approval flows
- Amount-based or provider-trust policy rules

These belong to downstream issues in the connectors and engine repos.

## References

- connectors `docs/specs/real-world-knowledge-platform/2026-10-03-real-world-knowledge-platform-design.md` §7 — action consent design
- connectors decisions.md D7 — chose to extend WorkerAuthorizationPolicy rather than building a new framework
- `platform-api/.../acl/WorkerAuthorizationPolicy.java` — existing policy SPI
- `platform-api/.../acl/WorkerAction.java` — existing action record
- `platform-api/.../acl/AuthorizationDecision.java` — existing decision record
- `platform-core/.../acl/AutoApproveWorkerAuthorizationPolicy.java` — only production implementation
- `acl-worker-core/.../acl/WorkerCredentialValidator.java` — runtime credential validation (unchanged)
