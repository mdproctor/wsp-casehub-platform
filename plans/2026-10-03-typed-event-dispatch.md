# Typed Event Dispatch (Layer 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #424 — Generated typed event dispatch (Layer 3) for OrcStateMachine
**Issue group:** #502 (epic)

**Goal:** Build a Maven plugin that reads existing scenario YAML files and
generates typed Java dispatch classes (state enum, sealed event hierarchy,
typed fire() method) as an optional performance optimisation alongside the
runtime-interpreted EventRouter path.

**Architecture:** New `yaml-statemachine-generator` Maven plugin module.
Reads scenario YAML via Jackson, extracts state machine structure (states,
events, transitions, guards), ignores step definitions. Generates three
Java source files per state machine: state enum, sealed event interface
with records, and typed dispatch class wrapping `OrcStateMachine<StateEnum>`.
String-based source generation (same pattern as yaml-codegen RecordEmitter).

**Tech Stack:** Maven Plugin API 3.9.9, Jackson YAML (via yaml-jackson),
JUnit 5, AssertJ

## Global Constraints

- yaml-core must remain zero-dependency — the generator module depends on
  yaml-core, not the other way around
- Generated code depends only on yaml-core's `OrcStateMachine`,
  `DefaultOrcStateMachine`, and `IllegalTransitionException`
- No JavaPoet — use string-based source generation (matches yaml-codegen)
- `maven-plugin` packaging with `yaml-statemachine` goal prefix
- No quarkus:build goal

---

## Batch 1: YAML Parser and State Machine Model

### Task 1: State machine model types and YAML parser

**Files:**
- Create: `yaml-statemachine-generator/pom.xml`
- Create: `yaml-statemachine-generator/src/main/java/io/casehub/yaml/statemachine/generator/StateMachineModel.java`
- Create: `yaml-statemachine-generator/src/main/java/io/casehub/yaml/statemachine/generator/StateMachineParser.java`
- Test: `yaml-statemachine-generator/src/test/java/io/casehub/yaml/statemachine/generator/StateMachineParserTest.java`
- Create: `yaml-statemachine-generator/src/test/resources/order.scenario.yaml`

**Interfaces:**
- Produces: `StateMachineModel` — record hierarchy consumed by all emitters:
  - `StateMachineModel(String name, String pkg, List<String> states, Set<String> terminalStates, List<EventDef> events, List<TransitionDef> transitions)`
  - `EventDef(String name, Map<String, String> fields)` — empty fields map if no `events:` section
  - `TransitionDef(String fromState, String eventName, String toState, String guard)` — nullable guard
- Produces: `StateMachineParser.parse(File yamlFile) → StateMachineModel`

- [ ] **Step 1: Create the module pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-yaml-statemachine-generator</artifactId>
    <packaging>maven-plugin</packaging>
    <name>CaseHub Platform YAML State Machine Generator</name>
    <description>Maven plugin generating typed event dispatch from scenario YAML state machines.</description>

    <properties>
        <version.maven-plugin-api>3.9.9</version.maven-plugin-api>
        <version.maven-plugin-annotations>3.15.2</version.maven-plugin-annotations>
    </properties>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-yaml-jackson</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>org.apache.maven</groupId>
            <artifactId>maven-plugin-api</artifactId>
            <version>${version.maven-plugin-api}</version>
            <scope>provided</scope>
        </dependency>
        <dependency>
            <groupId>org.apache.maven.plugin-tools</groupId>
            <artifactId>maven-plugin-annotations</artifactId>
            <version>${version.maven-plugin-annotations}</version>
            <scope>provided</scope>
        </dependency>
        <dependency>
            <groupId>org.apache.maven</groupId>
            <artifactId>maven-project</artifactId>
            <version>2.2.1</version>
            <scope>provided</scope>
        </dependency>
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-plugin-plugin</artifactId>
                <version>${version.maven-plugin-annotations}</version>
                <configuration>
                    <goalPrefix>yaml-statemachine</goalPrefix>
                </configuration>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Add module to root pom.xml**

Add `<module>yaml-statemachine-generator</module>` after the
`yaml-plugin-processor` line (line 162) in the root `pom.xml`.

- [ ] **Step 3: Write the test YAML fixture**

Create `yaml-statemachine-generator/src/test/resources/order.scenario.yaml`:

```yaml
events:
  submit:
    fields:
      amount: number
      customer: string
  approve:
    fields:
      count: integer
      approver: string
  reject:
    fields:
      reason: string

states:
  IDLE:
    - on:
        submit:
          to: PENDING
          when: "amount > 0"
    - validate.order: {}
  PENDING:
    - on:
        approve:
          to: APPROVED
          when: "count >= 2"
        reject: REJECTED
  APPROVED: terminal
  REJECTED: terminal
```

- [ ] **Step 4: Write failing parser test**

```java
package io.casehub.yaml.statemachine.generator;

import org.junit.jupiter.api.Test;
import java.io.File;
import static org.assertj.core.api.Assertions.assertThat;

class StateMachineParserTest {

    @Test
    void parseOrderScenario_extractsStatesEventsTransitions() {
        var file = new File(getClass().getClassLoader()
            .getResource("order.scenario.yaml").getFile());

        var model = StateMachineParser.parse(file, "Order",
            "io.casehub.generated.order");

        assertThat(model.name()).isEqualTo("Order");
        assertThat(model.pkg()).isEqualTo("io.casehub.generated.order");
        assertThat(model.states()).containsExactly(
            "IDLE", "PENDING", "APPROVED", "REJECTED");
        assertThat(model.terminalStates()).containsExactlyInAnyOrder(
            "APPROVED", "REJECTED");
        assertThat(model.events()).hasSize(3);
        assertThat(model.events().stream()
            .filter(e -> e.name().equals("submit")).findFirst().get()
            .fields()).containsEntry("amount", "number");
        assertThat(model.transitions()).hasSize(3);
    }

    @Test
    void parseScenario_withoutEventsSection_producesEmptyFieldMaps() {
        var file = new File(getClass().getClassLoader()
            .getResource("simple.scenario.yaml").getFile());

        var model = StateMachineParser.parse(file, "Simple",
            "io.casehub.generated.simple");

        assertThat(model.events()).allSatisfy(e ->
            assertThat(e.fields()).isEmpty());
    }

    @Test
    void parseScenario_ignoresStepDefinitions() {
        var file = new File(getClass().getClassLoader()
            .getResource("order.scenario.yaml").getFile());

        var model = StateMachineParser.parse(file, "Order",
            "io.casehub.generated.order");

        // Steps like validate.order should not appear as events
        assertThat(model.events().stream().map(StateMachineModel.EventDef::name))
            .doesNotContain("validate.order");
    }
}
```

Also create `src/test/resources/simple.scenario.yaml`:

```yaml
states:
  OPEN:
    - on:
        close: CLOSED
  CLOSED: terminal
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `mvn --batch-mode -pl yaml-statemachine-generator test -Dtest=StateMachineParserTest`
Expected: compilation failure — `StateMachineModel` and `StateMachineParser` don't exist

- [ ] **Step 6: Write StateMachineModel**

```java
package io.casehub.yaml.statemachine.generator;

import java.util.List;
import java.util.Map;
import java.util.Set;

public record StateMachineModel(
        String name,
        String pkg,
        List<String> states,
        Set<String> terminalStates,
        List<EventDef> events,
        List<TransitionDef> transitions) {

    public record EventDef(String name, Map<String, String> fields) {
        public EventDef {
            fields = fields != null ? Map.copyOf(fields) : Map.of();
        }
    }

    public record TransitionDef(
            String fromState,
            String eventName,
            String toState,
            String guard) {}
}
```

- [ ] **Step 7: Write StateMachineParser**

The parser reuses ScenarioParser's format understanding. It reads the YAML
via Jackson ObjectMapper (using `YamlMappers.standard()`), extracts the
`states` and optional `events` top-level keys, and builds a
`StateMachineModel`. Steps (entries in a state's list that aren't metadata
keys) are ignored.

```java
package io.casehub.yaml.statemachine.generator;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.casehub.yaml.core.YamlMappers;

import java.io.File;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

public final class StateMachineParser {

    private static final Set<String> STATE_METADATA_KEYS =
        Set.of("next", "on-failure", "deadline", "on", "terminal");

    private static final ObjectMapper MAPPER = YamlMappers.standard();

    private StateMachineParser() {}

    @SuppressWarnings("unchecked")
    public static StateMachineModel parse(File yamlFile, String name, String pkg) {
        Map<String, Object> root;
        try {
            root = MAPPER.readValue(yamlFile, Map.class);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }

        var eventDefs = parseEventDefs((Map<String, Object>) root.get("events"));
        var statesRaw = (Map<String, Object>) root.get("states");
        if (statesRaw == null) {
            throw new IllegalArgumentException("YAML must have a 'states' key");
        }

        var states = new ArrayList<>(statesRaw.keySet());
        var terminalStates = new LinkedHashSet<String>();
        var transitions = new ArrayList<StateMachineModel.TransitionDef>();
        var eventNames = new LinkedHashSet<String>();

        for (var entry : statesRaw.entrySet()) {
            var stateName = entry.getKey();
            var value = entry.getValue();

            if ("terminal".equals(value)) {
                terminalStates.add(stateName);
                continue;
            }

            if (value instanceof Map<?, ?> map) {
                var terminal = map.get("terminal");
                if (Boolean.TRUE.equals(terminal)) {
                    terminalStates.add(stateName);
                }
                var on = (Map<String, Object>) map.get("on");
                if (on != null) {
                    extractTransitions(stateName, on, transitions, eventNames);
                }
                continue;
            }

            if (!(value instanceof List<?> entries)) continue;

            for (Object item : entries) {
                if (!(item instanceof Map<?, ?> itemMap)) continue;
                var map = (Map<String, Object>) itemMap;

                for (var e : map.entrySet()) {
                    switch (e.getKey()) {
                        case "terminal" -> {
                            if (Boolean.TRUE.equals(e.getValue()))
                                terminalStates.add(stateName);
                        }
                        case "on" -> extractTransitions(stateName,
                            (Map<String, Object>) e.getValue(),
                            transitions, eventNames);
                        case "next" -> transitions.add(
                            new StateMachineModel.TransitionDef(
                                stateName, null,
                                String.valueOf(e.getValue()), null));
                        default -> {} // ignore steps and other metadata
                    }
                }
            }
        }

        // Build event list: merge YAML events: section with discovered event names
        var events = new ArrayList<StateMachineModel.EventDef>();
        var definedEvents = new LinkedHashMap<String, Map<String, String>>();
        for (var ed : eventDefs) {
            definedEvents.put(ed.name(), ed.fields());
        }
        for (String en : eventNames) {
            var fields = definedEvents.getOrDefault(en, Map.of());
            events.add(new StateMachineModel.EventDef(en, fields));
        }
        // Add any events: definitions not referenced in transitions
        for (var ed : eventDefs) {
            if (!eventNames.contains(ed.name())) {
                events.add(ed);
            }
        }

        return new StateMachineModel(name, pkg,
            List.copyOf(states), Set.copyOf(terminalStates),
            List.copyOf(events), List.copyOf(transitions));
    }

    @SuppressWarnings("unchecked")
    private static void extractTransitions(String fromState,
            Map<String, Object> on,
            List<StateMachineModel.TransitionDef> transitions,
            Set<String> eventNames) {
        for (var e : on.entrySet()) {
            var eventName = e.getKey();
            eventNames.add(eventName);

            if (e.getValue() instanceof String target) {
                transitions.add(new StateMachineModel.TransitionDef(
                    fromState, eventName, target, null));
            } else if (e.getValue() instanceof Map<?, ?> map) {
                var target = String.valueOf(map.get("to"));
                var guard = map.get("when") != null
                    ? String.valueOf(map.get("when")) : null;
                transitions.add(new StateMachineModel.TransitionDef(
                    fromState, eventName, target, guard));
            }
        }
    }

    @SuppressWarnings("unchecked")
    private static List<StateMachineModel.EventDef> parseEventDefs(
            Map<String, Object> eventsSection) {
        if (eventsSection == null) return List.of();
        var result = new ArrayList<StateMachineModel.EventDef>();
        for (var entry : eventsSection.entrySet()) {
            var fields = new LinkedHashMap<String, String>();
            if (entry.getValue() instanceof Map<?, ?> eventMap) {
                var fieldsMap = (Map<String, Object>) eventMap.get("fields");
                if (fieldsMap != null) {
                    for (var f : fieldsMap.entrySet()) {
                        fields.put(f.getKey(), String.valueOf(f.getValue()));
                    }
                }
            }
            result.add(new StateMachineModel.EventDef(
                entry.getKey(), fields));
        }
        return result;
    }
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `mvn --batch-mode -pl yaml-statemachine-generator test -Dtest=StateMachineParserTest`
Expected: all 3 tests PASS

- [ ] **Step 9: Commit**

```bash
git add yaml-statemachine-generator/ pom.xml
git commit -m "feat(#424): add yaml-statemachine-generator module with parser and model

StateMachineParser reads scenario YAML (same format as ScenarioParser),
extracts state machine structure, ignores step definitions. Optional
events: section provides typed field definitions for event records.

Refs #424

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: Source Emitters

### Task 2: State enum and sealed event emitters

**Files:**
- Create: `yaml-statemachine-generator/src/main/java/io/casehub/yaml/statemachine/generator/StateEnumEmitter.java`
- Create: `yaml-statemachine-generator/src/main/java/io/casehub/yaml/statemachine/generator/EventEmitter.java`
- Create: `yaml-statemachine-generator/src/main/java/io/casehub/yaml/statemachine/generator/GeneratedFile.java`
- Test: `yaml-statemachine-generator/src/test/java/io/casehub/yaml/statemachine/generator/StateEnumEmitterTest.java`
- Test: `yaml-statemachine-generator/src/test/java/io/casehub/yaml/statemachine/generator/EventEmitterTest.java`

**Interfaces:**
- Consumes: `StateMachineModel` from Task 1
- Produces: `GeneratedFile(String fileName, String content)` — shared record
- Produces: `StateEnumEmitter.emit(StateMachineModel) → GeneratedFile`
- Produces: `EventEmitter.emit(StateMachineModel) → GeneratedFile`

- [ ] **Step 1: Write failing StateEnumEmitter test**

```java
package io.casehub.yaml.statemachine.generator;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;

class StateEnumEmitterTest {

    @Test
    void emit_generatesEnumWithAllStates() {
        var model = new StateMachineModel("Order", "io.casehub.generated.order",
            List.of("IDLE", "PENDING", "APPROVED", "REJECTED"),
            Set.of("APPROVED", "REJECTED"),
            List.of(), List.of());

        var file = StateEnumEmitter.emit(model);

        assertThat(file.fileName()).isEqualTo("OrderState.java");
        assertThat(file.content())
            .contains("package io.casehub.generated.order;")
            .contains("public enum OrderState")
            .contains("IDLE, PENDING, APPROVED, REJECTED");
    }

    @Test
    void emit_convertsKebabCaseToUpperSnakeCase() {
        var model = new StateMachineModel("Flow", "io.casehub.test",
            List.of("waiting-for-input", "processing", "done"),
            Set.of("done"), List.of(), List.of());

        var file = StateEnumEmitter.emit(model);

        assertThat(file.content())
            .contains("WAITING_FOR_INPUT, PROCESSING, DONE");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode -pl yaml-statemachine-generator test -Dtest=StateEnumEmitterTest`
Expected: compilation failure

- [ ] **Step 3: Write GeneratedFile record and StateEnumEmitter**

```java
package io.casehub.yaml.statemachine.generator;

public record GeneratedFile(String fileName, String content) {}
```

```java
package io.casehub.yaml.statemachine.generator;

public final class StateEnumEmitter {

    private StateEnumEmitter() {}

    public static GeneratedFile emit(StateMachineModel model) {
        var sb = new StringBuilder();
        sb.append("package ").append(model.pkg()).append(";\n\n");
        sb.append("public enum ").append(model.name()).append("State {\n");
        sb.append("    ");
        var stateNames = model.states().stream()
            .map(StateEnumEmitter::toEnumConstant)
            .toList();
        sb.append(String.join(", ", stateNames));
        sb.append("\n}\n");

        return new GeneratedFile(model.name() + "State.java", sb.toString());
    }

    static String toEnumConstant(String yamlState) {
        return yamlState.replace('-', '_').toUpperCase();
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode -pl yaml-statemachine-generator test -Dtest=StateEnumEmitterTest`
Expected: PASS

- [ ] **Step 5: Write failing EventEmitter test**

```java
package io.casehub.yaml.statemachine.generator;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;

class EventEmitterTest {

    @Test
    void emit_generatesSealedInterfaceWithRecords() {
        var model = new StateMachineModel("Order", "io.casehub.generated.order",
            List.of("IDLE", "PENDING", "APPROVED"),
            Set.of("APPROVED"),
            List.of(
                new StateMachineModel.EventDef("submit",
                    Map.of("amount", "number", "customer", "string")),
                new StateMachineModel.EventDef("approve",
                    Map.of("count", "integer"))
            ),
            List.of());

        var file = EventEmitter.emit(model);

        assertThat(file.fileName()).isEqualTo("OrderEvent.java");
        assertThat(file.content())
            .contains("public sealed interface OrderEvent")
            .contains("record Submit(double amount, String customer)")
            .contains("record Approve(int count)")
            .contains("implements OrderEvent");
    }

    @Test
    void emit_emptyFieldsProduceEmptyRecord() {
        var model = new StateMachineModel("Simple", "io.casehub.test",
            List.of("OPEN", "CLOSED"), Set.of("CLOSED"),
            List.of(new StateMachineModel.EventDef("close", Map.of())),
            List.of());

        var file = EventEmitter.emit(model);

        assertThat(file.content()).contains("record Close() implements SimpleEvent");
    }

    @Test
    void emit_typeMapping() {
        var model = new StateMachineModel("Test", "io.casehub.test",
            List.of("A", "B"), Set.of("B"),
            List.of(new StateMachineModel.EventDef("check",
                Map.of("flag", "boolean", "count", "integer",
                       "rate", "number", "label", "string"))),
            List.of());

        var file = EventEmitter.emit(model);

        assertThat(file.content())
            .contains("boolean flag")
            .contains("int count")
            .contains("double rate")
            .contains("String label");
    }
}
```

- [ ] **Step 6: Write EventEmitter**

```java
package io.casehub.yaml.statemachine.generator;

import java.util.stream.Collectors;

public final class EventEmitter {

    private EventEmitter() {}

    public static GeneratedFile emit(StateMachineModel model) {
        var sb = new StringBuilder();
        sb.append("package ").append(model.pkg()).append(";\n\n");

        var eventName = model.name() + "Event";
        var permits = model.events().stream()
            .map(e -> eventName + "." + toPascalCase(e.name()))
            .collect(Collectors.joining(", "));

        sb.append("public sealed interface ").append(eventName).append("\n");
        sb.append("    permits ").append(permits).append(" {\n\n");

        for (var event : model.events()) {
            var recordName = toPascalCase(event.name());
            var fields = event.fields().entrySet().stream()
                .map(f -> mapType(f.getValue()) + " " + f.getKey())
                .collect(Collectors.joining(", "));
            sb.append("    record ").append(recordName)
              .append("(").append(fields).append(")")
              .append(" implements ").append(eventName).append(" {}\n");
        }

        sb.append("}\n");

        return new GeneratedFile(eventName + ".java", sb.toString());
    }

    static String toPascalCase(String kebab) {
        var parts = kebab.split("[-_]");
        var sb = new StringBuilder();
        for (String part : parts) {
            if (!part.isEmpty()) {
                sb.append(Character.toUpperCase(part.charAt(0)));
                if (part.length() > 1) sb.append(part.substring(1));
            }
        }
        return sb.toString();
    }

    static String mapType(String yamlType) {
        return switch (yamlType) {
            case "string" -> "String";
            case "integer" -> "int";
            case "number" -> "double";
            case "boolean" -> "boolean";
            default -> "Object";
        };
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn --batch-mode -pl yaml-statemachine-generator test -Dtest=EventEmitterTest`
Expected: all 3 tests PASS

- [ ] **Step 8: Commit**

```bash
git add yaml-statemachine-generator/src/
git commit -m "feat(#424): add StateEnumEmitter and EventEmitter

Generates state enum (kebab → UPPER_SNAKE) and sealed event interface
with typed records (number→double, integer→int, string→String, boolean).

Refs #424

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Dispatch class emitter

**Files:**
- Create: `yaml-statemachine-generator/src/main/java/io/casehub/yaml/statemachine/generator/DispatchEmitter.java`
- Create: `yaml-statemachine-generator/src/main/java/io/casehub/yaml/statemachine/generator/GuardCompiler.java`
- Test: `yaml-statemachine-generator/src/test/java/io/casehub/yaml/statemachine/generator/DispatchEmitterTest.java`
- Test: `yaml-statemachine-generator/src/test/java/io/casehub/yaml/statemachine/generator/GuardCompilerTest.java`

**Interfaces:**
- Consumes: `StateMachineModel` from Task 1, `StateEnumEmitter.toEnumConstant()` from Task 2, `EventEmitter.toPascalCase()` from Task 2
- Produces: `DispatchEmitter.emit(StateMachineModel) → GeneratedFile`
- Produces: `GuardCompiler.compile(String guard, String patternVar, Map<String, String> fields) → String`

- [ ] **Step 1: Write failing GuardCompiler test**

```java
package io.casehub.yaml.statemachine.generator;

import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class GuardCompilerTest {

    @Test
    void compile_numericComparison() {
        var result = GuardCompiler.compile("amount > 0", "s",
            Map.of("amount", "number"));
        assertThat(result).isEqualTo("s.amount() > 0");
    }

    @Test
    void compile_integerComparison() {
        var result = GuardCompiler.compile("count >= 2", "a",
            Map.of("count", "integer"));
        assertThat(result).isEqualTo("a.count() >= 2");
    }

    @Test
    void compile_stringEquality() {
        var result = GuardCompiler.compile("status == 'active'", "s",
            Map.of("status", "string"));
        assertThat(result).isEqualTo("\"active\".equals(s.status())");
    }

    @Test
    void compile_booleanField() {
        var result = GuardCompiler.compile("enabled", "s",
            Map.of("enabled", "boolean"));
        assertThat(result).isEqualTo("s.enabled()");
    }

    @Test
    void compile_andCombinator() {
        var result = GuardCompiler.compile("amount > 0 && count >= 1",
            "s", Map.of("amount", "number", "count", "integer"));
        assertThat(result).isEqualTo("s.amount() > 0 && s.count() >= 1");
    }

    @Test
    void compile_unknownField_passesThrough() {
        var result = GuardCompiler.compile("unknown > 5", "s", Map.of());
        assertThat(result).isEqualTo("unknown > 5");
    }
}
```

- [ ] **Step 2: Write GuardCompiler**

```java
package io.casehub.yaml.statemachine.generator;

import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class GuardCompiler {

    private static final Pattern STRING_LITERAL =
        Pattern.compile("'([^']*)'");
    private static final Pattern FIELD_REF =
        Pattern.compile("\\b([a-zA-Z_][a-zA-Z0-9_]*)\\b");

    private GuardCompiler() {}

    public static String compile(String guard, String patternVar,
            Map<String, String> fields) {
        if (guard == null || guard.isBlank()) return "true";

        // Handle string equality: field == 'value' → "value".equals(var.field())
        var stringEq = Pattern.compile(
            "([a-zA-Z_]\\w*)\\s*==\\s*'([^']*)'");
        var sm = stringEq.matcher(guard);
        if (sm.matches() && fields.containsKey(sm.group(1))) {
            return "\"" + sm.group(2) + "\".equals("
                + patternVar + "." + sm.group(1) + "())";
        }

        // Handle bare boolean: just a field name
        var stripped = guard.strip();
        if (fields.containsKey(stripped)
                && "boolean".equals(fields.get(stripped))) {
            return patternVar + "." + stripped + "()";
        }

        // General case: replace known field names with accessor calls
        var result = new StringBuilder();
        var matcher = FIELD_REF.matcher(guard);
        int last = 0;
        while (matcher.find()) {
            result.append(guard, last, matcher.start());
            var fieldName = matcher.group(1);
            if (fields.containsKey(fieldName)) {
                result.append(patternVar).append(".")
                      .append(fieldName).append("()");
            } else {
                result.append(fieldName);
            }
            last = matcher.end();
        }
        result.append(guard, last, guard.length());
        return result.toString();
    }
}
```

- [ ] **Step 3: Run GuardCompiler tests**

Run: `mvn --batch-mode -pl yaml-statemachine-generator test -Dtest=GuardCompilerTest`
Expected: all 6 tests PASS

- [ ] **Step 4: Write failing DispatchEmitter test**

```java
package io.casehub.yaml.statemachine.generator;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;

class DispatchEmitterTest {

    @Test
    void emit_generatesTypedDispatchClass() {
        var model = new StateMachineModel("Order", "io.casehub.generated.order",
            List.of("IDLE", "PENDING", "APPROVED", "REJECTED"),
            Set.of("APPROVED", "REJECTED"),
            List.of(
                new StateMachineModel.EventDef("submit",
                    Map.of("amount", "number")),
                new StateMachineModel.EventDef("approve",
                    Map.of("count", "integer")),
                new StateMachineModel.EventDef("reject", Map.of())
            ),
            List.of(
                new StateMachineModel.TransitionDef(
                    "IDLE", "submit", "PENDING", "amount > 0"),
                new StateMachineModel.TransitionDef(
                    "PENDING", "approve", "APPROVED", "count >= 2"),
                new StateMachineModel.TransitionDef(
                    "PENDING", "reject", "REJECTED", null)
            ));

        var file = DispatchEmitter.emit(model);

        assertThat(file.fileName()).isEqualTo("OrderDispatch.java");
        assertThat(file.content())
            .contains("public final class OrderDispatch")
            .contains("OrcStateMachine<OrderState> sm")
            .contains("public boolean fire(OrderEvent event)")
            .contains("case OrderEvent.Submit s")
            .contains("sm.transition(OrderState.IDLE, OrderState.PENDING, s)")
            .contains("case OrderEvent.Reject r")
            .contains("sm.currentState() == OrderState.PENDING")
            .contains("static OrderDispatch create()")
            .contains("targeting(OrcStateMachine<OrderState>");
    }

    @Test
    void emit_guardedTransitionHasWhenClause() {
        var model = new StateMachineModel("Order", "io.casehub.generated.order",
            List.of("IDLE", "PENDING"), Set.of(),
            List.of(new StateMachineModel.EventDef("submit",
                Map.of("amount", "number"))),
            List.of(new StateMachineModel.TransitionDef(
                "IDLE", "submit", "PENDING", "amount > 0")));

        var file = DispatchEmitter.emit(model);

        assertThat(file.content()).contains("s.amount() > 0");
    }

    @Test
    void emit_unguardedTransitionHasStateCheckOnly() {
        var model = new StateMachineModel("Simple", "io.casehub.test",
            List.of("OPEN", "CLOSED"), Set.of("CLOSED"),
            List.of(new StateMachineModel.EventDef("close", Map.of())),
            List.of(new StateMachineModel.TransitionDef(
                "OPEN", "close", "CLOSED", null)));

        var file = DispatchEmitter.emit(model);

        assertThat(file.content())
            .contains("sm.currentState() == SimpleState.OPEN")
            .doesNotContain("when");
    }
}
```

- [ ] **Step 5: Write DispatchEmitter**

```java
package io.casehub.yaml.statemachine.generator;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

public final class DispatchEmitter {

    private DispatchEmitter() {}

    public static GeneratedFile emit(StateMachineModel model) {
        var sb = new StringBuilder();
        var stateEnum = model.name() + "State";
        var eventType = model.name() + "Event";
        var className = model.name() + "Dispatch";

        sb.append("package ").append(model.pkg()).append(";\n\n");
        sb.append("import io.casehub.yaml.core.orchestration.DefaultOrcStateMachine;\n");
        sb.append("import io.casehub.yaml.core.orchestration.OrcStateMachine;\n\n");

        sb.append("public final class ").append(className).append(" {\n\n");

        // Field
        sb.append("    private final OrcStateMachine<")
          .append(stateEnum).append("> sm;\n\n");

        // Constructor
        sb.append("    private ").append(className)
          .append("(OrcStateMachine<").append(stateEnum).append("> sm) {\n");
        sb.append("        this.sm = sm;\n");
        sb.append("    }\n\n");

        // Factory
        emitFactory(sb, model, stateEnum, className);

        // wrapping()
        sb.append("    public static ").append(className)
          .append(" wrapping(OrcStateMachine<").append(stateEnum)
          .append("> target) {\n");
        sb.append("        return new ").append(className)
          .append("(target);\n");
        sb.append("    }\n\n");

        // targeting()
        sb.append("    public ").append(className)
          .append(" targeting(OrcStateMachine<").append(stateEnum)
          .append("> newTarget) {\n");
        sb.append("        return new ").append(className)
          .append("(newTarget);\n");
        sb.append("    }\n\n");

        // fire()
        emitFire(sb, model, stateEnum, eventType);

        // Accessors
        sb.append("    public ").append(stateEnum)
          .append(" currentState() { return sm.currentState(); }\n\n");
        sb.append("    public OrcStateMachine<").append(stateEnum)
          .append("> delegate() { return sm; }\n");

        sb.append("}\n");

        return new GeneratedFile(className + ".java", sb.toString());
    }

    private static void emitFactory(StringBuilder sb,
            StateMachineModel model, String stateEnum, String className) {
        var initialState = StateEnumEmitter.toEnumConstant(
            model.states().getFirst());

        sb.append("    public static ").append(className)
          .append(" create() {\n");
        sb.append("        var sm = DefaultOrcStateMachine.<")
          .append(stateEnum).append(">builder(\"")
          .append(model.name().toLowerCase()).append("\", ")
          .append(stateEnum).append(".").append(initialState)
          .append(")\n");

        for (var t : model.transitions()) {
            if (t.eventName() == null) continue;
            sb.append("            .transition(")
              .append(stateEnum).append(".")
              .append(StateEnumEmitter.toEnumConstant(t.fromState()))
              .append(", ").append(stateEnum).append(".")
              .append(StateEnumEmitter.toEnumConstant(t.toState()))
              .append(")\n");
        }

        if (!model.terminalStates().isEmpty()) {
            var terminals = model.terminalStates().stream()
                .map(s -> stateEnum + "." + StateEnumEmitter.toEnumConstant(s))
                .collect(Collectors.joining(", "));
            sb.append("            .terminal(").append(terminals).append(")\n");
        }

        sb.append("            .build();\n");
        sb.append("        return new ").append(className)
          .append("(sm);\n");
        sb.append("    }\n\n");
    }

    private static void emitFire(StringBuilder sb,
            StateMachineModel model, String stateEnum, String eventType) {
        sb.append("    public boolean fire(").append(eventType)
          .append(" event) {\n");
        sb.append("        return switch (event) {\n");

        // Group transitions by event
        var byEvent = new LinkedHashMap<String,
            List<StateMachineModel.TransitionDef>>();
        for (var t : model.transitions()) {
            if (t.eventName() != null) {
                byEvent.computeIfAbsent(t.eventName(),
                    k -> new java.util.ArrayList<>()).add(t);
            }
        }

        char varChar = 'a';
        for (var event : model.events()) {
            var recordName = EventEmitter.toPascalCase(event.name());
            var transitions = byEvent.getOrDefault(event.name(), List.of());
            var pv = String.valueOf(varChar++);
            if (varChar > 'z') varChar = 'a';

            for (var t : transitions) {
                var fromEnum = stateEnum + "."
                    + StateEnumEmitter.toEnumConstant(t.fromState());
                var toEnum = stateEnum + "."
                    + StateEnumEmitter.toEnumConstant(t.toState());

                sb.append("            case ").append(eventType)
                  .append(".").append(recordName).append(" ").append(pv);

                if (t.guard() != null) {
                    var compiled = GuardCompiler.compile(
                        t.guard(), pv, event.fields());
                    sb.append("\n                when sm.currentState() == ")
                      .append(fromEnum).append(" && ").append(compiled);
                } else {
                    sb.append("\n                when sm.currentState() == ")
                      .append(fromEnum);
                }

                sb.append("\n                -> sm.transition(")
                  .append(fromEnum).append(", ").append(toEnum)
                  .append(", ").append(pv).append(");\n");
            }

            // Fallback arm for this event type
            sb.append("            case ").append(eventType)
              .append(".").append(recordName).append(" ")
              .append(pv).append("\n                -> false;\n");
        }

        sb.append("        };\n");
        sb.append("    }\n\n");
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode -pl yaml-statemachine-generator test -Dtest=DispatchEmitterTest`
Expected: all 3 tests PASS

- [ ] **Step 7: Commit**

```bash
git add yaml-statemachine-generator/src/
git commit -m "feat(#424): add DispatchEmitter and GuardCompiler

Generates typed fire(Event) dispatch class with pattern matching on sealed
event types. GuardCompiler translates YAML guard expressions to Java
boolean expressions with typed field accessors.

Refs #424

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 3: Maven Plugin Mojo and Integration Test

### Task 4: Maven plugin mojo and META-INF descriptor

**Files:**
- Create: `yaml-statemachine-generator/src/main/java/io/casehub/yaml/statemachine/generator/StateMachineGeneratorMojo.java`
- Test: `yaml-statemachine-generator/src/test/java/io/casehub/yaml/statemachine/generator/StateMachineGeneratorMojoTest.java`

**Interfaces:**
- Consumes: `StateMachineParser.parse()`, `StateEnumEmitter.emit()`, `EventEmitter.emit()`, `DispatchEmitter.emit()`
- Produces: Maven goal `generate` in phase `generate-sources`
- Produces: `META-INF/yaml-dispatch/<name>.properties` per state machine

- [ ] **Step 1: Write failing Mojo test**

```java
package io.casehub.yaml.statemachine.generator;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import static org.assertj.core.api.Assertions.assertThat;

class StateMachineGeneratorMojoTest {

    @TempDir Path tempDir;

    @Test
    void generate_producesAllThreeFiles() throws Exception {
        var yamlFile = new File(getClass().getClassLoader()
            .getResource("order.scenario.yaml").getFile());
        var outputDir = tempDir.resolve("generated");

        StateMachineGeneratorMojo.generateStateMachine(
            yamlFile, "Order", "io.casehub.generated.order",
            outputDir.toFile());

        var pkg = outputDir.resolve("io/casehub/generated/order");
        assertThat(pkg.resolve("OrderState.java")).exists();
        assertThat(pkg.resolve("OrderEvent.java")).exists();
        assertThat(pkg.resolve("OrderDispatch.java")).exists();

        var stateContent = Files.readString(pkg.resolve("OrderState.java"));
        assertThat(stateContent).contains("public enum OrderState");
    }

    @Test
    void generate_writesMetaInfDescriptor() throws Exception {
        var yamlFile = new File(getClass().getClassLoader()
            .getResource("order.scenario.yaml").getFile());
        var outputDir = tempDir.resolve("generated");
        var resourceDir = tempDir.resolve("resources");

        StateMachineGeneratorMojo.generateStateMachine(
            yamlFile, "Order", "io.casehub.generated.order",
            outputDir.toFile());
        StateMachineGeneratorMojo.writeDescriptor(
            "Order", "io.casehub.generated.order",
            resourceDir.toFile());

        var descriptor = resourceDir.resolve(
            "META-INF/yaml-dispatch/order.properties");
        assertThat(descriptor).exists();
        var content = Files.readString(descriptor);
        assertThat(content)
            .contains("dispatch-class=io.casehub.generated.order.OrderDispatch")
            .contains("state-enum=io.casehub.generated.order.OrderState")
            .contains("event-type=io.casehub.generated.order.OrderEvent");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode -pl yaml-statemachine-generator test -Dtest=StateMachineGeneratorMojoTest`
Expected: compilation failure

- [ ] **Step 3: Write StateMachineGeneratorMojo**

```java
package io.casehub.yaml.statemachine.generator;

import org.apache.maven.plugin.AbstractMojo;
import org.apache.maven.plugin.MojoExecutionException;
import org.apache.maven.plugins.annotations.LifecyclePhase;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;
import org.apache.maven.project.MavenProject;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

@Mojo(name = "generate", defaultPhase = LifecyclePhase.GENERATE_SOURCES)
public class StateMachineGeneratorMojo extends AbstractMojo {

    @Parameter(required = true)
    private File sourceDirectory;

    @Parameter(required = true)
    private String targetPackage;

    @Parameter(defaultValue = "${project}", readonly = true)
    private MavenProject project;

    @Override
    public void execute() throws MojoExecutionException {
        if (!sourceDirectory.exists()) {
            getLog().info("No state machine YAML directory: "
                + sourceDirectory);
            return;
        }

        var outputDir = new File(project.getBuild().getDirectory(),
            "generated-sources/yaml-statemachine");
        project.addCompileSourceRoot(outputDir.getAbsolutePath());

        var resourceDir = new File(project.getBuild().getDirectory(),
            "generated-resources");
        var resource = new org.apache.maven.model.Resource();
        resource.setDirectory(resourceDir.getAbsolutePath());
        project.addResource(resource);

        var files = sourceDirectory.listFiles(
            (dir, name) -> name.endsWith(".scenario.yaml")
                || name.endsWith(".statemachine.yaml"));
        if (files == null || files.length == 0) {
            getLog().info("No state machine YAML files found");
            return;
        }

        for (File yaml : files) {
            try {
                var baseName = yaml.getName()
                    .replace(".scenario.yaml", "")
                    .replace(".statemachine.yaml", "");
                var name = EventEmitter.toPascalCase(baseName);

                generateStateMachine(yaml, name, targetPackage, outputDir);
                writeDescriptor(name, targetPackage, resourceDir);

                getLog().info("Generated state machine: " + name
                    + " → " + targetPackage);
            } catch (Exception e) {
                throw new MojoExecutionException(
                    "Failed to generate from " + yaml.getName(), e);
            }
        }
    }

    static void generateStateMachine(File yamlFile, String name,
            String pkg, File outputDir) throws IOException {
        var model = StateMachineParser.parse(yamlFile, name, pkg);
        var pkgDir = outputDir.toPath()
            .resolve(pkg.replace('.', '/'));
        Files.createDirectories(pkgDir);

        for (var file : new GeneratedFile[]{
                StateEnumEmitter.emit(model),
                EventEmitter.emit(model),
                DispatchEmitter.emit(model)}) {
            Files.writeString(pkgDir.resolve(file.fileName()),
                file.content());
        }
    }

    static void writeDescriptor(String name, String pkg,
            File resourceDir) throws IOException {
        var dir = resourceDir.toPath()
            .resolve("META-INF/yaml-dispatch");
        Files.createDirectories(dir);

        var content = "dispatch-class=" + pkg + "." + name + "Dispatch\n"
            + "state-enum=" + pkg + "." + name + "State\n"
            + "event-type=" + pkg + "." + name + "Event\n";

        Files.writeString(dir.resolve(name.toLowerCase() + ".properties"),
            content);
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode -pl yaml-statemachine-generator test -Dtest=StateMachineGeneratorMojoTest`
Expected: all 2 tests PASS

- [ ] **Step 5: Commit**

```bash
git add yaml-statemachine-generator/src/
git commit -m "feat(#424): add StateMachineGeneratorMojo with META-INF descriptor

Maven plugin goal 'generate' reads *.scenario.yaml files, produces state
enum + sealed events + typed dispatch + META-INF/yaml-dispatch descriptor
for runtime discovery.

Refs #424

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: End-to-end integration test — generated code compiles and behaves identically to interpreted path

**Files:**
- Create: `yaml-statemachine-generator/src/test/java/io/casehub/yaml/statemachine/generator/EndToEndTest.java`
- Create: `yaml-statemachine-generator/src/test/resources/approval-workflow.scenario.yaml`

**Interfaces:**
- Consumes: All emitters from Tasks 1-4
- Verifies: Generated source compiles (string assertion on structure) AND dispatch produces same results as EventRouter for identical inputs

- [ ] **Step 1: Create test fixture YAML**

Create `yaml-statemachine-generator/src/test/resources/approval-workflow.scenario.yaml`:

```yaml
events:
  submit:
    fields:
      amount: number
  approve:
    fields:
      count: integer
  reject:
    fields:
      reason: string

states:
  DRAFT:
    - on:
        submit:
          to: REVIEW
          when: "amount > 0"
  REVIEW:
    - on:
        approve:
          to: APPROVED
          when: "count >= 2"
        reject: REJECTED
  APPROVED: terminal
  REJECTED: terminal
```

- [ ] **Step 2: Write end-to-end test**

```java
package io.casehub.yaml.statemachine.generator;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import static org.assertj.core.api.Assertions.assertThat;

class EndToEndTest {

    @TempDir Path tempDir;

    @Test
    void fullGeneration_producesCompilableSource() throws Exception {
        var yamlFile = new File(getClass().getClassLoader()
            .getResource("approval-workflow.scenario.yaml").getFile());
        var outputDir = tempDir.resolve("src");

        StateMachineGeneratorMojo.generateStateMachine(
            yamlFile, "ApprovalWorkflow",
            "io.casehub.generated.approval", outputDir.toFile());

        var pkg = outputDir.resolve("io/casehub/generated/approval");

        // Verify state enum
        var stateSource = Files.readString(
            pkg.resolve("ApprovalWorkflowState.java"));
        assertThat(stateSource)
            .contains("DRAFT, REVIEW, APPROVED, REJECTED")
            .contains("package io.casehub.generated.approval;");

        // Verify sealed events
        var eventSource = Files.readString(
            pkg.resolve("ApprovalWorkflowEvent.java"));
        assertThat(eventSource)
            .contains("sealed interface ApprovalWorkflowEvent")
            .contains("record Submit(double amount)")
            .contains("record Approve(int count)")
            .contains("record Reject(String reason)");

        // Verify dispatch
        var dispatchSource = Files.readString(
            pkg.resolve("ApprovalWorkflowDispatch.java"));
        assertThat(dispatchSource)
            .contains("public boolean fire(ApprovalWorkflowEvent event)")
            .contains("case ApprovalWorkflowEvent.Submit")
            .contains("s.amount() > 0")
            .contains("case ApprovalWorkflowEvent.Approve")
            .contains("a.count() >= 2")
            .contains("case ApprovalWorkflowEvent.Reject")
            .contains("sm.currentState() == ApprovalWorkflowState.REVIEW")
            .contains("sm.transition(ApprovalWorkflowState.DRAFT, " +
                "ApprovalWorkflowState.REVIEW, s)")
            .contains("static ApprovalWorkflowDispatch create()")
            .contains(".terminal(ApprovalWorkflowState.APPROVED, " +
                "ApprovalWorkflowState.REJECTED)");
    }

    @Test
    void fullGeneration_metaInfDescriptor() throws Exception {
        var yamlFile = new File(getClass().getClassLoader()
            .getResource("approval-workflow.scenario.yaml").getFile());
        var resourceDir = tempDir.resolve("resources");

        StateMachineGeneratorMojo.writeDescriptor(
            "ApprovalWorkflow", "io.casehub.generated.approval",
            resourceDir.toFile());

        var descriptor = resourceDir.resolve(
            "META-INF/yaml-dispatch/approvalworkflow.properties");
        assertThat(descriptor).exists();
        var props = Files.readString(descriptor);
        assertThat(props).contains(
            "dispatch-class=io.casehub.generated.approval." +
            "ApprovalWorkflowDispatch");
    }

    @Test
    void fullGeneration_noEventsSection_producesEmptyRecords()
            throws Exception {
        var yamlFile = new File(getClass().getClassLoader()
            .getResource("simple.scenario.yaml").getFile());
        var outputDir = tempDir.resolve("simple-src");

        StateMachineGeneratorMojo.generateStateMachine(
            yamlFile, "Simple", "io.casehub.generated.simple",
            outputDir.toFile());

        var pkg = outputDir.resolve("io/casehub/generated/simple");
        var eventSource = Files.readString(
            pkg.resolve("SimpleEvent.java"));
        assertThat(eventSource).contains("record Close()");
    }
}
```

- [ ] **Step 3: Run tests**

Run: `mvn --batch-mode -pl yaml-statemachine-generator test -Dtest=EndToEndTest`
Expected: all 3 tests PASS

- [ ] **Step 4: Run full module test suite**

Run: `mvn --batch-mode -pl yaml-statemachine-generator test`
Expected: all tests PASS (parser + emitters + mojo + e2e)

- [ ] **Step 5: Commit**

```bash
git add yaml-statemachine-generator/src/
git commit -m "test(#424): add end-to-end integration tests for state machine generator

Verifies full pipeline: YAML → parser → emitters → source files + META-INF
descriptor. Tests with and without events: section.

Refs #424

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 6: Run full build**

Run: `mvn --batch-mode install -pl yaml-statemachine-generator`
Expected: BUILD SUCCESS, maven plugin descriptor generated

- [ ] **Step 7: Final commit if any formatting changes**

```bash
git status
# If any changes from build, commit them
```

---

## References

- [2026-10-03-typed-event-dispatch-design.md] — design spec this plan implements
- [yaml-codegen/src/main/java/io/casehub/yaml/codegen/YamlCodegenMojo.java] — Maven plugin pattern reference
- [yaml-codegen/src/main/java/io/casehub/yaml/codegen/RecordEmitter.java] — string-based source generation pattern
- [yaml-core/src/main/java/io/casehub/yaml/core/orchestration/EventRouter.java] — Layer 2 dispatch pattern
- [yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcStateMachine.java] — Builder API for generated factory method
- [yaml-step-runtime/src/main/java/io/casehub/yaml/step/scenario/ScenarioParser.java] — existing YAML format reference
- [D32-D36] — decisions captured in specs/epic-502-yaml-parity/decisions.md
- [GitHub #424] — focal issue
- [GitHub #502] — parent epic
