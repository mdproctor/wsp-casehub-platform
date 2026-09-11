# DisplayTermResolver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #283 — DisplayTermResolver — platform-wide vocabulary display resolution service
**Issue group:** #283

**Goal:** Add DisplayTermResolver SPI to platform-api and no-op @DefaultBean to platform.

**Architecture:** Zero-dependency SPI interface in `platform-api/.../display/` package. Passthrough @DefaultBean in `platform/.../display/`. Eidos provides real implementation via CDI priority (separate issue casehubio/eidos#171).

**Tech Stack:** Pure Java (SPI), Quarkus CDI (default bean), JUnit 5, AssertJ

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports
- `platform/` contains Quarkus @DefaultBean implementations only — no domain logic
- Every SPI in platform-api gets a @DefaultBean implementation in platform
- No-op default pattern: returns passthrough/empty — "not installed" means "nothing happens"

---

## Batch 1: DisplayTermResolver SPI + no-op default

### Task 1: DisplayTermResolver SPI and NoOpDisplayTermResolver

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/display/DisplayTermResolver.java`
- Create: `platform/src/main/java/io/casehub/platform/display/NoOpDisplayTermResolver.java`
- Create: `platform/src/test/java/io/casehub/platform/display/NoOpDisplayTermResolverTest.java`

**Interfaces:**
- Consumes: nothing — new SPI
- Produces: `DisplayTermResolver` (interface: `resolveLabel(String, String)`, `mapTerm(String, String, String)`, `mapTerm(String, String, String, String)`)

- [ ] **Step 1: Write failing tests**

Create `NoOpDisplayTermResolverTest.java` using `ide_create_file`:

```java
package io.casehub.platform.display;

import io.casehub.platform.api.display.DisplayTermResolver;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class NoOpDisplayTermResolverTest {

    private final DisplayTermResolver resolver = new NoOpDisplayTermResolver();

    @Test
    void resolveLabel_returnsRawValue() {
        assertThat(resolver.resolveLabel("D", "urn:disc")).isEqualTo("D");
    }

    @Test
    void resolveLabel_withNullValue_returnsNull() {
        assertThat(resolver.resolveLabel(null, "urn:disc")).isNull();
    }

    @Test
    void mapTerm_returnsEmpty() {
        assertThat(resolver.mapTerm("D", "urn:disc", "urn:bigfive")).isEmpty();
    }

    @Test
    void mapTerm_withContext_returnsEmpty() {
        assertThat(resolver.mapTerm("D", "urn:disc", "urn:bigfive", "autonomy")).isEmpty();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl platform test -Dtest=NoOpDisplayTermResolverTest --batch-mode`
Expected: Compilation failure — `DisplayTermResolver` and `NoOpDisplayTermResolver` not found.

- [ ] **Step 3: Create DisplayTermResolver SPI**

Create `DisplayTermResolver.java` using `ide_create_file`:

```java
package io.casehub.platform.api.display;

import java.util.Optional;

public interface DisplayTermResolver {

    String resolveLabel(String value, String vocabUri);

    Optional<String> mapTerm(String value, String sourceVocabUri,
                             String targetVocabUri);

    Optional<String> mapTerm(String value, String sourceVocabUri,
                             String targetVocabUri, String mappingContext);
}
```

- [ ] **Step 4: Create NoOpDisplayTermResolver**

Create `NoOpDisplayTermResolver.java` using `ide_create_file`:

```java
package io.casehub.platform.display;

import io.casehub.platform.api.display.DisplayTermResolver;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;
import java.util.Optional;

@DefaultBean
@ApplicationScoped
public class NoOpDisplayTermResolver implements DisplayTermResolver {

    @Override
    public String resolveLabel(String value, String vocabUri) {
        return value;
    }

    @Override
    public Optional<String> mapTerm(String value, String sourceVocabUri,
                                    String targetVocabUri) {
        return Optional.empty();
    }

    @Override
    public Optional<String> mapTerm(String value, String sourceVocabUri,
                                    String targetVocabUri, String mappingContext) {
        return Optional.empty();
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -pl platform test -Dtest=NoOpDisplayTermResolverTest --batch-mode`
Expected: All 4 tests PASS.

- [ ] **Step 6: Run full platform build**

Run: `mvn --batch-mode install`
Expected: Full build succeeds.

- [ ] **Step 7: Verify with ide_diagnostics**

Run `ide_diagnostics` on both new files to confirm no compilation errors.

- [ ] **Step 8: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/display/DisplayTermResolver.java platform/src/main/java/io/casehub/platform/display/NoOpDisplayTermResolver.java platform/src/test/java/io/casehub/platform/display/NoOpDisplayTermResolverTest.java
git commit -m "feat(#283): add DisplayTermResolver SPI + NoOp @DefaultBean

Platform-wide SPI for vocabulary display label resolution and cross-vocabulary
term mapping. String-keyed mapping context replaces eidos's DispositionAxis.
No-op default returns raw values — passthrough when no backend installed.

Refs #283"
```

---

## References

- [2026-09-11-display-term-resolver-design.md] — design spec this plan implements
- [eidos/api/src/main/java/io/casehub/eidos/api/DisplayTermResolver.java] — eidos SPI (source)
- [eidos/runtime/src/main/java/io/casehub/eidos/runtime/display/DefaultDisplayTermResolver.java] — eidos implementation
- [platform/src/main/java/io/casehub/platform/memory/NoOpCaseMemoryStore.java] — @DefaultBean pattern reference
- [GitHub #283] — focal issue
- [GitHub casehubio/eidos#171] — downstream eidos bridge issue
