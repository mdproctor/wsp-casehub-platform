# Embedding Similarity Utility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #134 — feat: shared embedding similarity utility — consolidate cosine similarity from engine and work
**Issue group:** #134

**Goal:** Add a `Vectors` utility class to `platform-api` providing cosine similarity, dot product, and magnitude for `float[]` vectors.

**Architecture:** Single final utility class in `io.casehub.platform.api.util` (alongside `UUIDv7`). Three static methods — `dotProduct`, `magnitude`, `cosineSimilarity`. Zero dependencies. Pure Java math.

**Tech Stack:** Java 21, JUnit Jupiter, AssertJ

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports. Pure Java only.
- All `float` operands explicitly promoted to `double` before multiplication — `(double) a[i] * b[i]` — to preserve precision across high-dimensional vectors.
- Zero vectors return `0.0` from `cosineSimilarity` (sentinel, avoids NaN).
- Mismatched array lengths throw `IllegalArgumentException`.
- Null inputs throw `NullPointerException` via standard array dereference (no explicit null checks).

---

### Task 1: Vectors utility — TDD implementation

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/util/Vectors.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/util/VectorsTest.java`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `Vectors.dotProduct(float[] a, float[] b) → double`
  - `Vectors.magnitude(float[] a) → double`
  - `Vectors.cosineSimilarity(float[] a, float[] b) → double`

#### Phase 1: cosineSimilarity

- [ ] **Step 1: Write failing tests for cosineSimilarity**

```java
package io.casehub.platform.api.util;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.within;

class VectorsTest {

    private static final double DELTA = 1e-9;

    // --- cosineSimilarity ---

    @Test
    void cosineSimilarity_identicalVectors_returnsOne() {
        float[] v = {1.0f, 2.0f, 3.0f};
        assertThat(Vectors.cosineSimilarity(v, v)).isCloseTo(1.0, within(DELTA));
    }

    @Test
    void cosineSimilarity_oppositeVectors_returnsNegativeOne() {
        float[] a = {1.0f, 2.0f, 3.0f};
        float[] b = {-1.0f, -2.0f, -3.0f};
        assertThat(Vectors.cosineSimilarity(a, b)).isCloseTo(-1.0, within(DELTA));
    }

    @Test
    void cosineSimilarity_orthogonalVectors_returnsZero() {
        float[] a = {1.0f, 0.0f};
        float[] b = {0.0f, 1.0f};
        assertThat(Vectors.cosineSimilarity(a, b)).isCloseTo(0.0, within(DELTA));
    }

    @Test
    void cosineSimilarity_zeroVectorA_returnsZero() {
        float[] zero = {0.0f, 0.0f, 0.0f};
        float[] v = {1.0f, 2.0f, 3.0f};
        assertThat(Vectors.cosineSimilarity(zero, v)).isEqualTo(0.0);
    }

    @Test
    void cosineSimilarity_zeroVectorB_returnsZero() {
        float[] v = {1.0f, 2.0f, 3.0f};
        float[] zero = {0.0f, 0.0f, 0.0f};
        assertThat(Vectors.cosineSimilarity(v, zero)).isEqualTo(0.0);
    }

    @Test
    void cosineSimilarity_bothZeroVectors_returnsZero() {
        float[] zero = {0.0f, 0.0f};
        assertThat(Vectors.cosineSimilarity(zero, zero)).isEqualTo(0.0);
    }

    @Test
    void cosineSimilarity_singleElement() {
        float[] a = {3.0f};
        float[] b = {5.0f};
        assertThat(Vectors.cosineSimilarity(a, b)).isCloseTo(1.0, within(DELTA));
    }

    @Test
    void cosineSimilarity_singleElementOpposite() {
        float[] a = {3.0f};
        float[] b = {-5.0f};
        assertThat(Vectors.cosineSimilarity(a, b)).isCloseTo(-1.0, within(DELTA));
    }

    @Test
    void cosineSimilarity_emptyArrays_returnsZero() {
        assertThat(Vectors.cosineSimilarity(new float[0], new float[0])).isEqualTo(0.0);
    }

    @Test
    void cosineSimilarity_mismatchedLengths_throws() {
        float[] a = {1.0f, 2.0f};
        float[] b = {1.0f};
        assertThatThrownBy(() -> Vectors.cosineSimilarity(a, b))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode -pl platform-api test -Dtest=VectorsTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation failure — `Vectors` class does not exist.

- [ ] **Step 3: Write minimal Vectors class with cosineSimilarity**

Create `platform-api/src/main/java/io/casehub/platform/api/util/Vectors.java`:

```java
package io.casehub.platform.api.util;

public final class Vectors {

    private Vectors() {}

    public static double cosineSimilarity(float[] a, float[] b) {
        if (a.length != b.length) {
            throw new IllegalArgumentException(
                    "Vector length mismatch: " + a.length + " vs " + b.length);
        }
        double dot = 0.0;
        double magA = 0.0;
        double magB = 0.0;
        for (int i = 0; i < a.length; i++) {
            dot += (double) a[i] * b[i];
            magA += (double) a[i] * a[i];
            magB += (double) b[i] * b[i];
        }
        if (magA == 0.0 || magB == 0.0) {
            return 0.0;
        }
        return dot / (Math.sqrt(magA) * Math.sqrt(magB));
    }
}
```

- [ ] **Step 4: Run tests to verify cosineSimilarity tests pass**

Run: `mvn --batch-mode -pl platform-api test -Dtest=VectorsTest`
Expected: all cosineSimilarity tests PASS.

#### Phase 2: dotProduct

- [ ] **Step 5: Add failing tests for dotProduct**

Append to `VectorsTest`:

```java
    // --- dotProduct ---

    @Test
    void dotProduct_basicComputation() {
        float[] a = {1.0f, 2.0f, 3.0f};
        float[] b = {4.0f, 5.0f, 6.0f};
        // 1*4 + 2*5 + 3*6 = 32
        assertThat(Vectors.dotProduct(a, b)).isCloseTo(32.0, within(DELTA));
    }

    @Test
    void dotProduct_emptyArrays_returnsZero() {
        assertThat(Vectors.dotProduct(new float[0], new float[0])).isEqualTo(0.0);
    }

    @Test
    void dotProduct_mismatchedLengths_throws() {
        float[] a = {1.0f, 2.0f, 3.0f};
        float[] b = {1.0f};
        assertThatThrownBy(() -> Vectors.dotProduct(a, b))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void dotProduct_orthogonalVectors_returnsZero() {
        float[] a = {1.0f, 0.0f};
        float[] b = {0.0f, 1.0f};
        assertThat(Vectors.dotProduct(a, b)).isCloseTo(0.0, within(DELTA));
    }
```

- [ ] **Step 6: Run tests to verify dotProduct tests fail**

Run: `mvn --batch-mode -pl platform-api test -Dtest=VectorsTest`
Expected: compilation failure — `dotProduct` method does not exist.

- [ ] **Step 7: Add dotProduct to Vectors**

```java
    public static double dotProduct(float[] a, float[] b) {
        if (a.length != b.length) {
            throw new IllegalArgumentException(
                    "Vector length mismatch: " + a.length + " vs " + b.length);
        }
        double sum = 0.0;
        for (int i = 0; i < a.length; i++) {
            sum += (double) a[i] * b[i];
        }
        return sum;
    }
```

- [ ] **Step 8: Run tests to verify dotProduct tests pass**

Run: `mvn --batch-mode -pl platform-api test -Dtest=VectorsTest`
Expected: all tests PASS.

#### Phase 3: magnitude

- [ ] **Step 9: Add failing tests for magnitude**

Append to `VectorsTest`:

```java
    // --- magnitude ---

    @Test
    void magnitude_basicComputation() {
        float[] v = {3.0f, 4.0f};
        assertThat(Vectors.magnitude(v)).isCloseTo(5.0, within(DELTA));
    }

    @Test
    void magnitude_zeroVector_returnsZero() {
        assertThat(Vectors.magnitude(new float[]{0.0f, 0.0f})).isEqualTo(0.0);
    }

    @Test
    void magnitude_singleElement() {
        assertThat(Vectors.magnitude(new float[]{7.0f})).isCloseTo(7.0, within(DELTA));
    }

    @Test
    void magnitude_emptyArray_returnsZero() {
        assertThat(Vectors.magnitude(new float[0])).isEqualTo(0.0);
    }
```

- [ ] **Step 10: Run tests to verify magnitude tests fail**

Run: `mvn --batch-mode -pl platform-api test -Dtest=VectorsTest`
Expected: compilation failure — `magnitude` method does not exist.

- [ ] **Step 11: Add magnitude to Vectors**

```java
    public static double magnitude(float[] v) {
        double sum = 0.0;
        for (int i = 0; i < v.length; i++) {
            sum += (double) v[i] * v[i];
        }
        return Math.sqrt(sum);
    }
```

- [ ] **Step 12: Run all tests to verify everything passes**

Run: `mvn --batch-mode -pl platform-api test -Dtest=VectorsTest`
Expected: all 18 tests PASS.

- [ ] **Step 13: Run full platform-api build**

Run: `mvn --batch-mode -pl platform-api install`
Expected: BUILD SUCCESS.

- [ ] **Step 14: Verify with IntelliJ diagnostics**

Run: `ide_diagnostics` on `Vectors.java` and `VectorsTest.java`.
Expected: no errors.

- [ ] **Step 15: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  platform-api/src/main/java/io/casehub/platform/api/util/Vectors.java \
  platform-api/src/test/java/io/casehub/platform/api/util/VectorsTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#134): Vectors utility — cosine similarity, dot product, magnitude"
```
