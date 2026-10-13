# Consent Tiers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #509 — feat: WorkerAuthorizationPolicy consent tiers for action-gated connectors

**Goal:** Extend platform-api worker authorization model with graduated consent semantics — two new enums, two record modifications, five new action constants.

**Architecture:** Add ConsentTier (input: action risk level) and ConsentOutcome (output: policy decision) enums to platform-api. Modify WorkerAction to carry a defaultTier field with backward-compatible constructor. Modify AuthorizationDecision to use ConsentOutcome instead of boolean, keeping approved() as convenience accessor.

**Tech Stack:** Java 21, JUnit 5, Maven

## Global Constraints

- platform-api must remain zero-dependency — pure Java only
- All new types go in `io.casehub.platform.api.acl` package
- Backward compatibility: existing two-arg WorkerAction constructor must continue to work
- Backward compatibility: `AuthorizationDecision.approved()` must continue to return boolean
- Existing `approve()` and `deny(reason)` factory methods must be preserved

---

## Batch 1: Consent tier types and integration

### Task 1: ConsentTier and ConsentOutcome enums

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/acl/ConsentTier.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/acl/ConsentOutcome.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/acl/ConsentTierTest.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/acl/ConsentOutcomeTest.java`

**Interfaces:**
- Produces: `ConsentTier` enum (AUTO, CONFIRM, APPROVE_WITH_DETAILS, DENY)
- Produces: `ConsentOutcome` enum (APPROVED, NEEDS_CONFIRMATION, NEEDS_APPROVAL, DENIED)

- [ ] **Step 1: Write ConsentTier test**

```java
package io.casehub.platform.api.acl;

import static org.junit.jupiter.api.Assertions.*;

import org.junit.jupiter.api.Test;

class ConsentTierTest {

    @Test
    void hasFourValues() {
        assertEquals(4, ConsentTier.values().length);
    }

    @Test
    void valuesInExpectedOrder() {
        assertArrayEquals(
            new ConsentTier[] {
                ConsentTier.AUTO,
                ConsentTier.CONFIRM,
                ConsentTier.APPROVE_WITH_DETAILS,
                ConsentTier.DENY
            },
            ConsentTier.values());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-api -Dtest=ConsentTierTest`
Expected: FAIL — `ConsentTier` does not exist

- [ ] **Step 3: Implement ConsentTier**

Use `ide_create_file` to create:

```java
package io.casehub.platform.api.acl;

public enum ConsentTier {
    AUTO,
    CONFIRM,
    APPROVE_WITH_DETAILS,
    DENY
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl platform-api -Dtest=ConsentTierTest`
Expected: PASS

- [ ] **Step 5: Write ConsentOutcome test**

```java
package io.casehub.platform.api.acl;

import static org.junit.jupiter.api.Assertions.*;

import org.junit.jupiter.api.Test;

class ConsentOutcomeTest {

    @Test
    void hasFourValues() {
        assertEquals(4, ConsentOutcome.values().length);
    }

    @Test
    void valuesInExpectedOrder() {
        assertArrayEquals(
            new ConsentOutcome[] {
                ConsentOutcome.APPROVED,
                ConsentOutcome.NEEDS_CONFIRMATION,
                ConsentOutcome.NEEDS_APPROVAL,
                ConsentOutcome.DENIED
            },
            ConsentOutcome.values());
    }
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-api -Dtest=ConsentOutcomeTest`
Expected: FAIL — `ConsentOutcome` does not exist

- [ ] **Step 7: Implement ConsentOutcome**

Use `ide_create_file` to create:

```java
package io.casehub.platform.api.acl;

public enum ConsentOutcome {
    APPROVED,
    NEEDS_CONFIRMATION,
    NEEDS_APPROVAL,
    DENIED
}
```

- [ ] **Step 8: Run test to verify it passes**

Run: `mvn --batch-mode test -pl platform-api -Dtest=ConsentOutcomeTest`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/acl/ConsentTier.java \
       platform-api/src/main/java/io/casehub/platform/api/acl/ConsentOutcome.java \
       platform-api/src/test/java/io/casehub/platform/api/acl/ConsentTierTest.java \
       platform-api/src/test/java/io/casehub/platform/api/acl/ConsentOutcomeTest.java
git commit -m "feat(platform-api): add ConsentTier and ConsentOutcome enums

ConsentTier represents the inherent risk level of a worker action
(AUTO, CONFIRM, APPROVE_WITH_DETAILS, DENY). ConsentOutcome represents
the policy's graduated decision (APPROVED, NEEDS_CONFIRMATION,
NEEDS_APPROVAL, DENIED).

Refs #509"
```

### Task 2: Evolve AuthorizationDecision to use ConsentOutcome

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/acl/AuthorizationDecision.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/acl/AuthorizationDecisionTest.java`

**Interfaces:**
- Consumes: `ConsentOutcome` enum from Task 1
- Produces: `AuthorizationDecision(ConsentOutcome outcome, String reason)` with `approved()` convenience accessor, `approve()`, `deny(String)`, `needsConfirmation(String)`, `needsApproval(String)` factories

- [ ] **Step 1: Write AuthorizationDecision tests**

```java
package io.casehub.platform.api.acl;

import static org.junit.jupiter.api.Assertions.*;

import org.junit.jupiter.api.Test;

class AuthorizationDecisionTest {

    @Test
    void approve_returnsApprovedOutcome() {
        var decision = AuthorizationDecision.approve();
        assertEquals(ConsentOutcome.APPROVED, decision.outcome());
        assertNull(decision.reason());
    }

    @Test
    void approve_backwardCompatApprovedReturnsTrue() {
        var decision = AuthorizationDecision.approve();
        assertTrue(decision.approved());
    }

    @Test
    void deny_returnsDeniedOutcome() {
        var decision = AuthorizationDecision.deny("blocked by policy");
        assertEquals(ConsentOutcome.DENIED, decision.outcome());
        assertEquals("blocked by policy", decision.reason());
    }

    @Test
    void deny_backwardCompatApprovedReturnsFalse() {
        var decision = AuthorizationDecision.deny("reason");
        assertFalse(decision.approved());
    }

    @Test
    void needsConfirmation_returnsCorrectOutcome() {
        var decision = AuthorizationDecision.needsConfirmation("confirm booking");
        assertEquals(ConsentOutcome.NEEDS_CONFIRMATION, decision.outcome());
        assertEquals("confirm booking", decision.reason());
        assertFalse(decision.approved());
    }

    @Test
    void needsApproval_returnsCorrectOutcome() {
        var decision = AuthorizationDecision.needsApproval("purchase requires approval");
        assertEquals(ConsentOutcome.NEEDS_APPROVAL, decision.outcome());
        assertEquals("purchase requires approval", decision.reason());
        assertFalse(decision.approved());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-api -Dtest=AuthorizationDecisionTest`
Expected: FAIL — `outcome()` method does not exist, `needsConfirmation`/`needsApproval` do not exist

- [ ] **Step 3: Modify AuthorizationDecision**

Use `ide_replace_member` to replace the record body. The full updated file:

```java
package io.casehub.platform.api.acl;

public record AuthorizationDecision(ConsentOutcome outcome, String reason) {

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

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl platform-api -Dtest=AuthorizationDecisionTest`
Expected: PASS

- [ ] **Step 5: Run existing tests to verify backward compat**

Run: `mvn --batch-mode test -pl platform-api -Dtest=WorkerPermissionRequestTest`
Expected: PASS — uses `approve()`/`deny()` factories only

Run: `mvn --batch-mode test -pl platform -Dtest=AutoApproveWorkerAuthorizationPolicyTest`
Expected: PASS — uses `.approved()` accessor which is preserved

- [ ] **Step 6: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/acl/AuthorizationDecision.java \
       platform-api/src/test/java/io/casehub/platform/api/acl/AuthorizationDecisionTest.java
git commit -m "feat(platform-api): evolve AuthorizationDecision to ConsentOutcome

Replace boolean approved component with ConsentOutcome outcome enum.
Keep approved() as backward-compatible convenience accessor. Add
needsConfirmation() and needsApproval() factory methods for
graduated consent decisions.

Refs #509"
```

### Task 3: Add defaultTier to WorkerAction and new connector constants

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/acl/WorkerAction.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/acl/WorkerActionTest.java`

**Interfaces:**
- Consumes: `ConsentTier` enum from Task 1
- Produces: `WorkerAction(String name, AclAction aclAction, ConsentTier defaultTier)` with backward-compatible two-arg constructor; new constants SEARCH, ADD_TO_CART, BOOK_CANCELLABLE, PURCHASE, BOOK_NON_REFUNDABLE

- [ ] **Step 1: Write new WorkerAction tests**

Add to existing `WorkerActionTest.java`:

```java
@Test
void twoArgConstructorDefaultsToAuto() {
    var action = new WorkerAction("test-action", AclAction.READ);
    assertEquals(ConsentTier.AUTO, action.defaultTier());
}

@Test
void threeArgConstructorSetsDefaultTier() {
    var action = new WorkerAction("purchase", AclAction.WRITE, ConsentTier.APPROVE_WITH_DETAILS);
    assertEquals(ConsentTier.APPROVE_WITH_DETAILS, action.defaultTier());
}

@Test
void rejectsNullDefaultTier() {
    assertThrows(IllegalArgumentException.class,
        () -> new WorkerAction("test", AclAction.READ, null));
}

@Test
void searchConstantHasAutoTier() {
    assertEquals("search", WorkerAction.SEARCH.name());
    assertEquals(AclAction.READ, WorkerAction.SEARCH.aclAction());
    assertEquals(ConsentTier.AUTO, WorkerAction.SEARCH.defaultTier());
}

@Test
void addToCartConstantHasAutoTier() {
    assertEquals("add-to-cart", WorkerAction.ADD_TO_CART.name());
    assertEquals(AclAction.WRITE, WorkerAction.ADD_TO_CART.aclAction());
    assertEquals(ConsentTier.AUTO, WorkerAction.ADD_TO_CART.defaultTier());
}

@Test
void bookCancellableConstantHasConfirmTier() {
    assertEquals("book-cancellable", WorkerAction.BOOK_CANCELLABLE.name());
    assertEquals(AclAction.WRITE, WorkerAction.BOOK_CANCELLABLE.aclAction());
    assertEquals(ConsentTier.CONFIRM, WorkerAction.BOOK_CANCELLABLE.defaultTier());
}

@Test
void purchaseConstantHasApproveWithDetailsTier() {
    assertEquals("purchase", WorkerAction.PURCHASE.name());
    assertEquals(AclAction.WRITE, WorkerAction.PURCHASE.aclAction());
    assertEquals(ConsentTier.APPROVE_WITH_DETAILS, WorkerAction.PURCHASE.defaultTier());
}

@Test
void bookNonRefundableConstantHasApproveWithDetailsTier() {
    assertEquals("book-non-refundable", WorkerAction.BOOK_NON_REFUNDABLE.name());
    assertEquals(AclAction.WRITE, WorkerAction.BOOK_NON_REFUNDABLE.aclAction());
    assertEquals(ConsentTier.APPROVE_WITH_DETAILS, WorkerAction.BOOK_NON_REFUNDABLE.defaultTier());
}

@Test
void existingConstantsDefaultToAuto() {
    assertEquals(ConsentTier.AUTO, WorkerAction.READ_CONTEXT.defaultTier());
    assertEquals(ConsentTier.AUTO, WorkerAction.SIGNAL_CASE.defaultTier());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-api -Dtest=WorkerActionTest`
Expected: FAIL — `defaultTier()` does not exist, new constants do not exist

- [ ] **Step 3: Modify WorkerAction**

Use `ide_replace_member` to update the record. The full updated file:

```java
package io.casehub.platform.api.acl;

public record WorkerAction(String name, AclAction aclAction, ConsentTier defaultTier) {

    public static final WorkerAction READ_CONTEXT = new WorkerAction("read-context", AclAction.READ);
    public static final WorkerAction SIGNAL_CASE = new WorkerAction("signal-case", AclAction.WRITE);

    public static final WorkerAction SEARCH = new WorkerAction("search", AclAction.READ, ConsentTier.AUTO);
    public static final WorkerAction ADD_TO_CART = new WorkerAction("add-to-cart", AclAction.WRITE, ConsentTier.AUTO);
    public static final WorkerAction BOOK_CANCELLABLE = new WorkerAction("book-cancellable", AclAction.WRITE, ConsentTier.CONFIRM);
    public static final WorkerAction PURCHASE = new WorkerAction("purchase", AclAction.WRITE, ConsentTier.APPROVE_WITH_DETAILS);
    public static final WorkerAction BOOK_NON_REFUNDABLE = new WorkerAction("book-non-refundable", AclAction.WRITE, ConsentTier.APPROVE_WITH_DETAILS);

    public WorkerAction(String name, AclAction aclAction) {
        this(name, aclAction, ConsentTier.AUTO);
    }

    public WorkerAction {
        if (name == null || name.isBlank()) {
            throw new IllegalArgumentException("name must not be blank");
        }
        if (aclAction == null) {
            throw new IllegalArgumentException("aclAction must not be null");
        }
        if (defaultTier == null) {
            throw new IllegalArgumentException("defaultTier must not be null");
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl platform-api -Dtest=WorkerActionTest`
Expected: PASS

- [ ] **Step 5: Run full platform-api and platform test suites**

Run: `mvn --batch-mode test -pl platform-api,platform`
Expected: ALL PASS — backward compat verified across both modules

- [ ] **Step 6: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/acl/WorkerAction.java \
       platform-api/src/test/java/io/casehub/platform/api/acl/WorkerActionTest.java
git commit -m "feat(platform-api): add ConsentTier to WorkerAction with connector constants

Add defaultTier field to WorkerAction with backward-compatible two-arg
constructor defaulting to AUTO. Add five connector action constants:
SEARCH, ADD_TO_CART (AUTO), BOOK_CANCELLABLE (CONFIRM), PURCHASE,
BOOK_NON_REFUNDABLE (APPROVE_WITH_DETAILS).

Refs #509"
```

### Task 4: Full build verification and CLAUDE.md update

**Files:**
- Modify: `CLAUDE.md` (update platform-api package structure docs)

**Interfaces:**
- Consumes: All types from Tasks 1-3

- [ ] **Step 1: Run full project build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and all tests pass

- [ ] **Step 2: Update CLAUDE.md package structure**

In the `## Package Structure (platform-api)` section under `.acl`, add the new types. Add after the existing `AuthorizationDecision` entry:

```
                   ConsentTier (enum: AUTO/CONFIRM/APPROVE_WITH_DETAILS/DENY — inherent risk level of worker action),
                   ConsentOutcome (enum: APPROVED/NEEDS_CONFIRMATION/NEEDS_APPROVAL/DENIED — policy evaluation result),
```

Update the `AuthorizationDecision` entry to reflect the new signature:

```
                   AuthorizationDecision (record: ConsentOutcome outcome, reason — approve()/deny(String)/needsConfirmation(String)/needsApproval(String) factories, approved() backward-compat convenience),
```

Update the `WorkerAction` entry to reflect the new fields and constants:

```
                   WorkerAction (record: name, AclAction aclAction, ConsentTier defaultTier — extensible action type with consent tier; backward-compat two-arg constructor defaults to AUTO; domains define constants; built-in: READ_CONTEXT, SIGNAL_CASE, SEARCH, ADD_TO_CART, BOOK_CANCELLABLE, PURCHASE, BOOK_NON_REFUNDABLE),
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for consent tier types

Add ConsentTier, ConsentOutcome enums and updated WorkerAction,
AuthorizationDecision signatures to package structure docs.

Refs #509"
```

## References

- [2026-10-12-consent-tiers-design.md] — design spec this plan implements
- [platform-api/.../acl/WorkerAction.java] — existing action record (modified)
- [platform-api/.../acl/AuthorizationDecision.java] — existing decision record (modified)
- [platform-api/.../acl/WorkerAuthorizationPolicy.java] — policy SPI (unchanged)
- [platform-core/.../acl/AutoApproveWorkerAuthorizationPolicy.java] — default impl (unchanged)
- [GitHub #509] — focal issue
