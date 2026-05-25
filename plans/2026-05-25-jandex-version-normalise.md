# Jandex Version Normalise Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace hardcoded `3.3.1` Jandex plugin version literals with `${jandex-maven-plugin.version}` in `platform/pom.xml` and `testing/pom.xml` so all modules consistently use the parent-managed property; then close issue #25.

**Architecture:** Two single-line XML changes. The parent pom already defines `<jandex-maven-plugin.version>3.3.1</jandex-maven-plugin.version>` — the effective version is unchanged. No code changes; verification is a clean `mvn install` and a JAR content check.

**Tech Stack:** Maven 3.x, `io.smallrye:jandex-maven-plugin`

---

### Task 1: Normalise version in `platform/pom.xml`

**Files:**
- Modify: `platform/pom.xml`

- [ ] **Step 1: Verify current state — confirm hardcoded version**

```bash
grep -n "3.3.1" /Users/mdproctor/claude/casehub/platform/platform/pom.xml
```

Expected: one hit inside the `jandex-maven-plugin` block.

- [ ] **Step 2: Replace hardcoded version with property**

In `platform/pom.xml`, inside the `jandex-maven-plugin` block, replace:

```xml
<version>3.3.1</version>
```

with:

```xml
<version>${jandex-maven-plugin.version}</version>
```

- [ ] **Step 3: Verify no literal version remains**

```bash
grep -n "3.3.1" /Users/mdproctor/claude/casehub/platform/platform/pom.xml
```

Expected: no output.

---

### Task 2: Normalise version in `testing/pom.xml`

**Files:**
- Modify: `testing/pom.xml`

- [ ] **Step 1: Verify current state — confirm hardcoded version**

```bash
grep -n "3.3.1" /Users/mdproctor/claude/casehub/platform/testing/pom.xml
```

Expected: one hit inside the `jandex-maven-plugin` block.

- [ ] **Step 2: Replace hardcoded version with property**

In `testing/pom.xml`, inside the `jandex-maven-plugin` block, replace:

```xml
<version>3.3.1</version>
```

with:

```xml
<version>${jandex-maven-plugin.version}</version>
```

- [ ] **Step 3: Verify no literal version remains**

```bash
grep -n "3.3.1" /Users/mdproctor/claude/casehub/platform/testing/pom.xml
```

Expected: no output.

---

### Task 3: Build, verify JAR index, commit

**Files:** none new

- [ ] **Step 1: Run full build**

```bash
mvn --batch-mode install -f /Users/mdproctor/claude/casehub/platform/pom.xml
```

Expected: `BUILD SUCCESS` with no warnings about missing Jandex index.

- [ ] **Step 2: Verify Jandex index present in both JARs**

```bash
python3 -c "import zipfile; z=zipfile.ZipFile('/Users/mdproctor/claude/casehub/platform/platform/target/casehub-platform-0.2-SNAPSHOT.jar'); print('jandex.idx' in ' '.join(z.namelist()))"
python3 -c "import zipfile; z=zipfile.ZipFile('/Users/mdproctor/claude/casehub/platform/testing/target/casehub-platform-testing-0.2-SNAPSHOT.jar'); print('jandex.idx' in ' '.join(z.namelist()))"
```

Expected: `True` for both.

- [ ] **Step 3: Commit and close issue**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform/pom.xml testing/pom.xml
git -C /Users/mdproctor/claude/casehub/platform commit -m "fix(platform): normalise Jandex plugin version to property in platform and testing poms

closes #25

Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>"
```
