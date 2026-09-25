# Dynamic Step Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #433 — Dynamic step catalog: schema-validated YAML step definitions with multi-invoke bindings
**Issue group:** #429, #432, #433

**Goal:** Extend yaml-core with YAML-declared step definitions that are schema-validated at load time and executable via 6 invoke binding types (MCP, REST, GraphQL, Python, Agent, Process), assembled into a runtime catalog alongside APT-generated @StepPlugin actions.

**Architecture:** Three layers — (1) step definition model in yaml-core (zero-dep records, parser, validator), (2) catalog SPI in yaml-step-runtime (CatalogEntry, StepCatalog, CatalogSource), (3) invoke handlers + composite catalog in yaml-step-runtime (CDI beans, 6 handlers, 3 sources). StepResult.Success gains executionMetadata. YamlImport gains a `steps` field for step-definition imports.

**Tech Stack:** Java 21, yaml-core (zero-dep), yaml-plugin-api (zero-dep), yaml-jackson (Jackson), yaml-step-runtime (new, Quarkus CDI, java.net.http, AgentProvider, MCP tool registry)

## Global Constraints

- yaml-core must remain zero-dependency — no Jackson, no Quarkus, no framework imports
- yaml-plugin-api must remain zero-dependency — no yaml-core dependency added (review finding R1-02)
- StepParameterType is a separate enum from ParameterType — no shared type hierarchy
- InvokeBinding records are pure data — no execution logic in yaml-core
- All new yaml-core types live in `io.casehub.yaml.core.step` package
- Tests use JUnit 5 + AssertJ
- Every commit references `Refs #433`

---

## Batch 1: Step definition model (yaml-core)

### Task 1: StepParameterType + StepParameter + StepDefinition + InvokeBinding + StepDefinitionFile

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/step/StepParameterType.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/step/StepParameter.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/step/StepDefinition.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/step/InvokeBinding.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/step/StepDefinitionFile.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/step/StepParameterTypeTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/step/StepParameterTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/step/StepDefinitionTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/step/InvokeBindingTest.java`

**Interfaces:**
- Consumes: `io.casehub.yaml.core.condition.Truthiness` (for boolean parsing in StepParameterType)
- Produces: `StepParameterType` (enum: STRING, INTEGER, NUMBER, BOOLEAN, ARRAY, OBJECT; methods: fromString, isScalar, validate, parseScalar), `StepParameter(StepParameterType type, boolean required, String defaultValue, List<String> allowedValues, String format, String description)`, `StepDefinition(String name, String description, Map<String, StepParameter> inputs, Map<String, StepParameter> outputs, InvokeBinding invoke)`, `InvokeBinding` sealed interface with 6 permits (Mcp, Rest, Graphql, Python, Agent, Process), `StepDefinitionFile(String namespace, Map<String, StepDefinition> actions)`

- [ ] **Step 1: Write StepParameterType tests**

```java
package io.casehub.yaml.core.step;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class StepParameterTypeTest {

    @ParameterizedTest
    @CsvSource({"STRING,STRING", "string,STRING", "INTEGER,INTEGER", "NUMBER,NUMBER",
                "DECIMAL,NUMBER", "BOOLEAN,BOOLEAN", "ARRAY,ARRAY", "OBJECT,OBJECT"})
    void fromStringParsesAllTypes(String input, StepParameterType expected) {
        assertThat(StepParameterType.fromString(input)).isEqualTo(expected);
    }

    @Test
    void fromStringRejectsUnknown() {
        assertThatIllegalArgumentException()
                .isThrownBy(() -> StepParameterType.fromString("map"))
                .withMessageContaining("Unknown step parameter type");
    }

    @Test
    void isScalarTrueForScalarTypes() {
        assertThat(StepParameterType.STRING.isScalar()).isTrue();
        assertThat(StepParameterType.INTEGER.isScalar()).isTrue();
        assertThat(StepParameterType.NUMBER.isScalar()).isTrue();
        assertThat(StepParameterType.BOOLEAN.isScalar()).isTrue();
    }

    @Test
    void isScalarFalseForComplexTypes() {
        assertThat(StepParameterType.ARRAY.isScalar()).isFalse();
        assertThat(StepParameterType.OBJECT.isScalar()).isFalse();
    }

    @Test
    void validateChecksRuntimeTypes() {
        assertThat(StepParameterType.STRING.validate("hello")).isTrue();
        assertThat(StepParameterType.STRING.validate(42)).isFalse();
        assertThat(StepParameterType.INTEGER.validate(42)).isTrue();
        assertThat(StepParameterType.INTEGER.validate(42L)).isTrue();
        assertThat(StepParameterType.INTEGER.validate(3.14)).isFalse();
        assertThat(StepParameterType.NUMBER.validate(3.14)).isTrue();
        assertThat(StepParameterType.NUMBER.validate(42)).isTrue();
        assertThat(StepParameterType.BOOLEAN.validate(true)).isTrue();
        assertThat(StepParameterType.BOOLEAN.validate("true")).isFalse();
        assertThat(StepParameterType.ARRAY.validate(List.of("a", "b"))).isTrue();
        assertThat(StepParameterType.ARRAY.validate("not a list")).isFalse();
        assertThat(StepParameterType.OBJECT.validate(Map.of("k", "v"))).isTrue();
        assertThat(StepParameterType.OBJECT.validate("not a map")).isFalse();
    }

    @Test
    void parseScalarParsesStrings() {
        assertThat(StepParameterType.STRING.parseScalar("hello")).isEqualTo("hello");
        assertThat(StepParameterType.INTEGER.parseScalar("42")).isEqualTo(42);
        assertThat(StepParameterType.NUMBER.parseScalar("3.14")).isEqualTo(3.14);
        assertThat(StepParameterType.BOOLEAN.parseScalar("true")).isEqualTo(true);
    }

    @Test
    void parseScalarRejectsComplexTypes() {
        assertThatIllegalArgumentException()
                .isThrownBy(() -> StepParameterType.ARRAY.parseScalar("[]"))
                .withMessageContaining("Cannot parse");
        assertThatIllegalArgumentException()
                .isThrownBy(() -> StepParameterType.OBJECT.parseScalar("{}"))
                .withMessageContaining("Cannot parse");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode -pl yaml-core test -Dtest=StepParameterTypeTest -Dsurefire.useFile=false`
Expected: FAIL — class not found

- [ ] **Step 3: Implement StepParameterType**

Create `yaml-core/src/main/java/io/casehub/yaml/core/step/StepParameterType.java` — enum with STRING, INTEGER, NUMBER, BOOLEAN, ARRAY, OBJECT. Methods: `fromString(String)`, `isScalar()`, `validate(Object)`, `parseScalar(String)`. See spec §StepParameterType for exact implementation.

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode -pl yaml-core test -Dtest=StepParameterTypeTest -Dsurefire.useFile=false`
Expected: PASS

- [ ] **Step 5: Write StepParameter tests**

```java
package io.casehub.yaml.core.step;

import org.junit.jupiter.api.Test;
import java.util.List;
import static org.assertj.core.api.Assertions.*;

class StepParameterTest {

    @Test
    void defaultsToStringType() {
        var param = new StepParameter(null, false, null, null, null, null);
        assertThat(param.type()).isEqualTo(StepParameterType.STRING);
        assertThat(param.allowedValues()).isEmpty();
    }

    @Test
    void rejectsDefaultValueOnComplexType() {
        assertThatIllegalArgumentException()
                .isThrownBy(() -> new StepParameter(
                        StepParameterType.OBJECT, false, "{}", null, null, null))
                .withMessageContaining("Default values are only supported for scalar types");
    }

    @Test
    void acceptsDefaultValueOnScalarType() {
        var param = new StepParameter(StepParameterType.INTEGER, false, "42", null, null, null);
        assertThat(param.defaultValue()).isEqualTo("42");
    }

    @Test
    void allowedValuesArePreserved() {
        var param = new StepParameter(StepParameterType.STRING, true, null,
                List.of("LOW", "MEDIUM", "HIGH"), null, "Severity level");
        assertThat(param.required()).isTrue();
        assertThat(param.allowedValues()).containsExactly("LOW", "MEDIUM", "HIGH");
        assertThat(param.description()).isEqualTo("Severity level");
    }
}
```

- [ ] **Step 6: Implement StepParameter, StepDefinition, InvokeBinding, StepDefinitionFile**

Create all 4 files in `io.casehub.yaml.core.step`. See spec for exact record signatures and compact constructor validation.

- [ ] **Step 7: Write InvokeBinding tests**

```java
package io.casehub.yaml.core.step;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class InvokeBindingTest {

    @Test
    void mcpBindingStoresToolName() {
        var binding = new InvokeBinding.Mcp("fsi.risk.assess");
        assertThat(binding.tool()).isEqualTo("fsi.risk.assess");
    }

    @Test
    void restBindingDefaultsMethodToGet() {
        var binding = new InvokeBinding.Rest(null, "/api/test", null, null);
        assertThat(binding.method()).isEqualTo("GET");
        assertThat(binding.headers()).isEmpty();
        assertThat(binding.body()).isEmpty();
    }

    @Test
    void agentBindingRequiresDescriptor() {
        assertThatIllegalArgumentException()
                .isThrownBy(() -> new InvokeBinding.Agent(null, null, null, false))
                .withMessageContaining("Agent binding requires descriptor");
    }

    @Test
    void agentBindingAcceptsOptionalModelAndTimeout() {
        var binding = new InvokeBinding.Agent("analyst", "claude-sonnet-5", "30s", true);
        assertThat(binding.descriptor()).isEqualTo("analyst");
        assertThat(binding.model()).isEqualTo("claude-sonnet-5");
        assertThat(binding.timeout()).isEqualTo("30s");
        assertThat(binding.structuredOutput()).isTrue();
    }

    @Test
    void processBindingRequiresCommand() {
        assertThatIllegalArgumentException()
                .isThrownBy(() -> new InvokeBinding.Process(null, null, null, null, null, null, null))
                .withMessageContaining("Process binding requires command");
    }

    @Test
    void processBindingDefaultsOutputToJson() {
        var binding = new InvokeBinding.Process("/bin/echo", List.of("hello"), null, null, null, null, null);
        assertThat(binding.output()).isEqualTo("json");
        assertThat(binding.args()).containsExactly("hello");
        assertThat(binding.env()).isEmpty();
        assertThat(binding.onError()).isEqualTo("stderr");
    }

    @Test
    void sealedInterfacePermitsSixTypes() {
        assertThat(InvokeBinding.class.getPermittedSubclasses()).hasSize(6);
    }
}
```

- [ ] **Step 8: Write StepDefinition tests**

```java
package io.casehub.yaml.core.step;

import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class StepDefinitionTest {

    @Test
    void qualifiedNameWithNamespace() {
        var def = new StepDefinition("assess-risk", "Risk assessment", null, null,
                new InvokeBinding.Mcp("fsi.risk.assess"));
        assertThat(def.qualifiedName("fsitrading")).isEqualTo("fsitrading.assess-risk");
    }

    @Test
    void qualifiedNameWithoutNamespace() {
        var def = new StepDefinition("assess-risk", "Risk assessment", null, null,
                new InvokeBinding.Mcp("fsi.risk.assess"));
        assertThat(def.qualifiedName("")).isEqualTo("assess-risk");
    }

    @Test
    void inputsAndOutputsDefaultToEmptyMaps() {
        var def = new StepDefinition("test", null, null, null,
                new InvokeBinding.Mcp("test.tool"));
        assertThat(def.inputs()).isEmpty();
        assertThat(def.outputs()).isEmpty();
    }

    @Test
    void stepDefinitionFileWrapsActions() {
        var def = new StepDefinition("test", null, null, null,
                new InvokeBinding.Mcp("test.tool"));
        var file = new StepDefinitionFile("fsi", Map.of("test", def));
        assertThat(file.namespace()).isEqualTo("fsi");
        assertThat(file.actions()).containsKey("test");
    }

    @Test
    void stepDefinitionFileDefaultsNamespaceToEmpty() {
        var file = new StepDefinitionFile(null, Map.of());
        assertThat(file.namespace()).isEmpty();
    }
}
```

- [ ] **Step 9: Run all tests to verify green**

Run: `mvn --batch-mode -pl yaml-core test -Dtest="StepParameterTypeTest,StepParameterTest,InvokeBindingTest,StepDefinitionTest" -Dsurefire.useFile=false`
Expected: PASS

- [ ] **Step 10: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/step/ yaml-core/src/test/java/io/casehub/yaml/core/step/
git commit -m "feat(#433): step definition model — StepParameterType, StepParameter, StepDefinition, InvokeBinding, StepDefinitionFile

Refs #433

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: StepDefinitionParser + StepValidator

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/step/StepDefinitionParser.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/step/StepValidator.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/step/StepDefinitionParserTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/step/StepValidatorTest.java`

**Interfaces:**
- Consumes: `StepDefinitionFile`, `StepDefinition`, `StepParameter`, `StepParameterType`, `InvokeBinding` (from Task 1)
- Produces: `StepDefinitionParser.parse(Map<String, Object>) → StepDefinitionFile`, `StepValidator.validateStep(String, Map<String, Object>, StepDefinition) → List<String>`, `StepValidator.validateOutputs(Map<String, Object>, StepDefinition) → List<String>`

- [ ] **Step 1: Write StepDefinitionParser tests**

```java
package io.casehub.yaml.core.step;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class StepDefinitionParserTest {

    @Test
    void parsesMinimalMcpAction() {
        Map<String, Object> yaml = Map.of(
                "namespace", "fsi",
                "actions", Map.of(
                        "assess-risk", Map.of(
                                "description", "Evaluate risk",
                                "inputs", Map.of(
                                        "instrumentId", Map.of("type", "string", "required", true)),
                                "outputs", Map.of(
                                        "level", Map.of("type", "string",
                                                "enum", List.of("LOW", "MEDIUM", "HIGH"))),
                                "invoke", Map.of("mcp", "fsi.risk.assess"))));

        StepDefinitionFile file = StepDefinitionParser.parse(yaml);
        assertThat(file.namespace()).isEqualTo("fsi");
        assertThat(file.actions()).hasSize(1);

        StepDefinition def = file.actions().get("assess-risk");
        assertThat(def.name()).isEqualTo("assess-risk");
        assertThat(def.description()).isEqualTo("Evaluate risk");
        assertThat(def.inputs()).containsKey("instrumentId");
        assertThat(def.inputs().get("instrumentId").type()).isEqualTo(StepParameterType.STRING);
        assertThat(def.inputs().get("instrumentId").required()).isTrue();
        assertThat(def.outputs().get("level").allowedValues()).containsExactly("LOW", "MEDIUM", "HIGH");
        assertThat(def.invoke()).isInstanceOf(InvokeBinding.Mcp.class);
        assertThat(((InvokeBinding.Mcp) def.invoke()).tool()).isEqualTo("fsi.risk.assess");
    }

    @Test
    void parsesRestBinding() {
        Map<String, Object> yaml = Map.of(
                "actions", Map.of(
                        "notify", Map.of(
                                "invoke", Map.of("rest", Map.of(
                                        "method", "POST",
                                        "url", "/api/notifications",
                                        "body", Map.of("message", "${message}"))))));

        StepDefinitionFile file = StepDefinitionParser.parse(yaml);
        InvokeBinding.Rest rest = (InvokeBinding.Rest) file.actions().get("notify").invoke();
        assertThat(rest.method()).isEqualTo("POST");
        assertThat(rest.url()).isEqualTo("/api/notifications");
        assertThat(rest.body()).containsEntry("message", "${message}");
    }

    @Test
    void parsesProcessBinding() {
        Map<String, Object> yaml = Map.of(
                "actions", Map.of(
                        "calc", Map.of(
                                "invoke", Map.of("process", Map.of(
                                        "command", "/opt/risk-engine/calc",
                                        "args", List.of("--portfolio", "${portfolio}"),
                                        "output", "json",
                                        "timeout", "30s")))));

        StepDefinitionFile file = StepDefinitionParser.parse(yaml);
        InvokeBinding.Process proc = (InvokeBinding.Process) file.actions().get("calc").invoke();
        assertThat(proc.command()).isEqualTo("/opt/risk-engine/calc");
        assertThat(proc.args()).containsExactly("--portfolio", "${portfolio}");
        assertThat(proc.timeout()).isEqualTo("30s");
    }

    @Test
    void parsesAgentBinding() {
        Map<String, Object> yaml = Map.of(
                "actions", Map.of(
                        "analyse", Map.of(
                                "invoke", Map.of("agent", Map.of(
                                        "descriptor", "trade-analyst",
                                        "model", "claude-sonnet-5",
                                        "structured-output", true)))));

        StepDefinitionFile file = StepDefinitionParser.parse(yaml);
        InvokeBinding.Agent agent = (InvokeBinding.Agent) file.actions().get("analyse").invoke();
        assertThat(agent.descriptor()).isEqualTo("trade-analyst");
        assertThat(agent.model()).isEqualTo("claude-sonnet-5");
        assertThat(agent.structuredOutput()).isTrue();
    }

    @Test
    void parsesPythonBinding() {
        Map<String, Object> yaml = Map.of(
                "actions", Map.of(
                        "sentiment", Map.of(
                                "invoke", Map.of("python", "steps/sentiment.py"))));

        StepDefinitionFile file = StepDefinitionParser.parse(yaml);
        InvokeBinding.Python python = (InvokeBinding.Python) file.actions().get("sentiment").invoke();
        assertThat(python.script()).isEqualTo("steps/sentiment.py");
    }

    @Test
    void parsesGraphqlBinding() {
        Map<String, Object> yaml = Map.of(
                "actions", Map.of(
                        "position", Map.of(
                                "invoke", Map.of("graphql", "{ position(symbol: \"${symbol}\") { quantity } }"))));

        StepDefinitionFile file = StepDefinitionParser.parse(yaml);
        InvokeBinding.Graphql gql = (InvokeBinding.Graphql) file.actions().get("position").invoke();
        assertThat(gql.query()).contains("position(symbol:");
    }

    @Test
    void rejectsUnknownInvokeType() {
        Map<String, Object> yaml = Map.of(
                "actions", Map.of(
                        "bad", Map.of("invoke", Map.of("unknown", "value"))));

        assertThatIllegalArgumentException()
                .isThrownBy(() -> StepDefinitionParser.parse(yaml))
                .withMessageContaining("Unknown invoke binding type");
    }

    @Test
    void defaultsNamespaceToEmpty() {
        Map<String, Object> yaml = Map.of(
                "actions", Map.of(
                        "test", Map.of("invoke", Map.of("mcp", "test"))));

        StepDefinitionFile file = StepDefinitionParser.parse(yaml);
        assertThat(file.namespace()).isEmpty();
    }

    @Test
    void parsesParameterWithFormatAndDefault() {
        Map<String, Object> yaml = Map.of(
                "actions", Map.of(
                        "test", Map.of(
                                "inputs", Map.of(
                                        "date", Map.of("type", "string", "format", "date", "default", "2026-01-01")),
                                "invoke", Map.of("mcp", "test"))));

        StepDefinitionFile file = StepDefinitionParser.parse(yaml);
        StepParameter param = file.actions().get("test").inputs().get("date");
        assertThat(param.format()).isEqualTo("date");
        assertThat(param.defaultValue()).isEqualTo("2026-01-01");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode -pl yaml-core test -Dtest=StepDefinitionParserTest -Dsurefire.useFile=false`
Expected: FAIL — class not found

- [ ] **Step 3: Implement StepDefinitionParser**

Create `yaml-core/src/main/java/io/casehub/yaml/core/step/StepDefinitionParser.java`. Pure function — `parse(Map<String, Object>)` extracts namespace, iterates actions, parses parameters and invoke bindings. Handle kebab-case to camelCase conversion for invoke binding fields (e.g. `structured-output` → `structuredOutput`, `working-dir` → `workingDir`, `on-error` → `onError`). Invoke binding dispatch: check which key exists in the invoke map (mcp, rest, graphql, python, agent, process) and construct the appropriate record. If invoke map has a string value (e.g. `mcp: "tool"`, `python: "script.py"`, `graphql: "query"`), parse as shorthand. If invoke map has a map value (e.g. `rest: {method: POST, ...}`), parse as full form.

- [ ] **Step 4: Run parser tests to verify they pass**

Run: `mvn --batch-mode -pl yaml-core test -Dtest=StepDefinitionParserTest -Dsurefire.useFile=false`
Expected: PASS

- [ ] **Step 5: Write StepValidator tests**

```java
package io.casehub.yaml.core.step;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class StepValidatorTest {

    private StepDefinition defWithRequiredString() {
        return new StepDefinition("test", null,
                Map.of("name", new StepParameter(StepParameterType.STRING, true, null, null, null, null)),
                Map.of("result", new StepParameter(StepParameterType.STRING, true, null, null, null, null)),
                new InvokeBinding.Mcp("test"));
    }

    @Test
    void validInputsPasses() {
        var errors = StepValidator.validateStep("test", Map.of("name", "hello"), defWithRequiredString());
        assertThat(errors).isEmpty();
    }

    @Test
    void missingRequiredInputFails() {
        var errors = StepValidator.validateStep("test", Map.of(), defWithRequiredString());
        assertThat(errors).anyMatch(e -> e.contains("name") && e.contains("required"));
    }

    @Test
    void wrongTypeFails() {
        var def = new StepDefinition("test", null,
                Map.of("count", new StepParameter(StepParameterType.INTEGER, true, null, null, null, null)),
                Map.of(), new InvokeBinding.Mcp("test"));

        var errors = StepValidator.validateStep("test", Map.of("count", "not-a-number"), def);
        assertThat(errors).anyMatch(e -> e.contains("count") && e.contains("INTEGER"));
    }

    @Test
    void invalidEnumValueFails() {
        var def = new StepDefinition("test", null,
                Map.of("level", new StepParameter(StepParameterType.STRING, true, null,
                        List.of("LOW", "HIGH"), null, null)),
                Map.of(), new InvokeBinding.Mcp("test"));

        var errors = StepValidator.validateStep("test", Map.of("level", "INVALID"), def);
        assertThat(errors).anyMatch(e -> e.contains("level") && e.contains("allowedValues"));
    }

    @Test
    void validEnumValuePasses() {
        var def = new StepDefinition("test", null,
                Map.of("level", new StepParameter(StepParameterType.STRING, true, null,
                        List.of("LOW", "HIGH"), null, null)),
                Map.of(), new InvokeBinding.Mcp("test"));

        var errors = StepValidator.validateStep("test", Map.of("level", "LOW"), def);
        assertThat(errors).isEmpty();
    }

    @Test
    void validOutputsPasses() {
        var errors = StepValidator.validateOutputs(Map.of("result", "ok"), defWithRequiredString());
        assertThat(errors).isEmpty();
    }

    @Test
    void missingRequiredOutputFails() {
        var errors = StepValidator.validateOutputs(Map.of(), defWithRequiredString());
        assertThat(errors).anyMatch(e -> e.contains("result") && e.contains("required"));
    }

    @Test
    void dateFormatValidation() {
        var def = new StepDefinition("test", null,
                Map.of("date", new StepParameter(StepParameterType.STRING, true, null, null, "date", null)),
                Map.of(), new InvokeBinding.Mcp("test"));

        var valid = StepValidator.validateStep("test", Map.of("date", "2026-01-15"), def);
        assertThat(valid).isEmpty();

        var invalid = StepValidator.validateStep("test", Map.of("date", "not-a-date"), def);
        assertThat(invalid).anyMatch(e -> e.contains("date") && e.contains("format"));
    }

    @Test
    void dateTimeFormatValidation() {
        var def = new StepDefinition("test", null,
                Map.of("ts", new StepParameter(StepParameterType.STRING, true, null, null, "date-time", null)),
                Map.of(), new InvokeBinding.Mcp("test"));

        var valid = StepValidator.validateStep("test", Map.of("ts", "2026-01-15T10:30:00+01:00"), def);
        assertThat(valid).isEmpty();

        var invalid = StepValidator.validateStep("test", Map.of("ts", "not-a-datetime"), def);
        assertThat(invalid).anyMatch(e -> e.contains("ts") && e.contains("format"));
    }

    @Test
    void uriFormatValidation() {
        var def = new StepDefinition("test", null,
                Map.of("url", new StepParameter(StepParameterType.STRING, true, null, null, "uri", null)),
                Map.of(), new InvokeBinding.Mcp("test"));

        var valid = StepValidator.validateStep("test", Map.of("url", "https://example.com/api"), def);
        assertThat(valid).isEmpty();
    }

    @Test
    void unknownFormatIsIgnored() {
        var def = new StepDefinition("test", null,
                Map.of("field", new StepParameter(StepParameterType.STRING, true, null, null, "custom-format", null)),
                Map.of(), new InvokeBinding.Mcp("test"));

        var errors = StepValidator.validateStep("test", Map.of("field", "anything"), def);
        assertThat(errors).isEmpty();
    }

    @Test
    void optionalInputCanBeAbsent() {
        var def = new StepDefinition("test", null,
                Map.of("optional", new StepParameter(StepParameterType.STRING, false, null, null, null, null)),
                Map.of(), new InvokeBinding.Mcp("test"));

        var errors = StepValidator.validateStep("test", Map.of(), def);
        assertThat(errors).isEmpty();
    }

    @Test
    void arrayTypeValidation() {
        var def = new StepDefinition("test", null,
                Map.of("items", new StepParameter(StepParameterType.ARRAY, true, null, null, null, null)),
                Map.of(), new InvokeBinding.Mcp("test"));

        var valid = StepValidator.validateStep("test", Map.of("items", List.of("a", "b")), def);
        assertThat(valid).isEmpty();

        var invalid = StepValidator.validateStep("test", Map.of("items", "not-a-list"), def);
        assertThat(invalid).anyMatch(e -> e.contains("items") && e.contains("ARRAY"));
    }

    @Test
    void objectTypeValidation() {
        var def = new StepDefinition("test", null,
                Map.of("data", new StepParameter(StepParameterType.OBJECT, true, null, null, null, null)),
                Map.of(), new InvokeBinding.Mcp("test"));

        var valid = StepValidator.validateStep("test", Map.of("data", Map.of("k", "v")), def);
        assertThat(valid).isEmpty();

        var invalid = StepValidator.validateStep("test", Map.of("data", "not-a-map"), def);
        assertThat(invalid).anyMatch(e -> e.contains("data") && e.contains("OBJECT"));
    }
}
```

- [ ] **Step 6: Implement StepValidator**

Create `yaml-core/src/main/java/io/casehub/yaml/core/step/StepValidator.java`. `validateStep` iterates the definition's inputs, checks required presence, type via `StepParameterType.validate()`, allowedValues, and format (date → LocalDate.parse, date-time → OffsetDateTime.parse, uri → URI.create, unknown → skip). `validateOutputs` does the same for outputs. Returns `List<String>` error messages — empty means valid.

- [ ] **Step 7: Run all tests to verify green**

Run: `mvn --batch-mode -pl yaml-core test -Dtest="StepParameterTypeTest,StepParameterTest,InvokeBindingTest,StepDefinitionTest,StepDefinitionParserTest,StepValidatorTest" -Dsurefire.useFile=false`
Expected: PASS

- [ ] **Step 8: Run full yaml-core test suite to verify no regressions**

Run: `mvn --batch-mode -pl yaml-core test -Dsurefire.useFile=false`
Expected: 603+ tests, PASS

- [ ] **Step 9: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/step/ yaml-core/src/test/java/io/casehub/yaml/core/step/
git commit -m "feat(#433): StepDefinitionParser and StepValidator — load-time playbook validation

Refs #433

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: Integration layer (yaml-plugin-api + yaml-core imports + yaml-jackson)

### Task 3: StepResult executionMetadata + YamlImport steps field + expander filters

**Files:**
- Modify: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StepResult.java`
- Modify: `yaml-plugin-api/src/test/java/io/casehub/yaml/plugin/api/StepResultTest.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlImport.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleExpander.java` (filter step imports)
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/ImportExpander.java` (filter step imports)
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/module/YamlImportTest.java` (new or extend)
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/module/ImportExpanderTest.java` (add step-import filter test)

**Interfaces:**
- Consumes: existing `StepResult`, `YamlImport`, `ModuleExpander`, `ImportExpander`
- Produces: `StepResult.Success(Map<String, Object> output, Map<String, Object> executionMetadata)`, `YamlImport(String module, String steps, String as, String when, Map<String, String> parameters, Object forEach, Object loop)`

- [ ] **Step 1: Write StepResult executionMetadata test**

```java
// Add to existing StepResultTest.java
@Test
void successWithMetadata() {
    var result = StepResult.of(Map.of("key", "value"), Map.of("cost", 0.05));
    assertThat(result.isSuccess()).isTrue();
    assertThat(result.output()).containsEntry("key", "value");
    assertThat(result.executionMetadata()).containsEntry("cost", 0.05);
}

@Test
void successWithoutMetadataDefaultsToEmpty() {
    var result = StepResult.of(Map.of("key", "value"));
    assertThat(result.executionMetadata()).isEmpty();
}

@Test
void failureMetadataIsEmpty() {
    var result = StepResult.failed("error");
    assertThat(result.executionMetadata()).isEmpty();
}
```

- [ ] **Step 2: Update StepResult with executionMetadata**

Use `ide_replace_member` on `StepResult.java`. Add `executionMetadata` field to `Success` record, default method `executionMetadata()` returning `Map.of()` on the interface, and new `of(output, metadata)` factory. See spec §Execution metadata for exact code.

- [ ] **Step 3: Write YamlImport mutual exclusivity tests**

```java
package io.casehub.yaml.core.module;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class YamlImportTest {

    @Test
    void moduleImportIsValid() {
        var imp = new YamlImport("my-module", null, "alias", null, null, null, null);
        assertThat(imp.module()).isEqualTo("my-module");
        assertThat(imp.steps()).isNull();
    }

    @Test
    void stepsImportIsValid() {
        var imp = new YamlImport(null, "trading-steps.yaml", null, null, null, null, null);
        assertThat(imp.steps()).isEqualTo("trading-steps.yaml");
        assertThat(imp.module()).isNull();
    }

    @Test
    void bothModuleAndStepsIsInvalid() {
        assertThatIllegalArgumentException()
                .isThrownBy(() -> new YamlImport("module", "steps.yaml", null, null, null, null, null))
                .withMessageContaining("mutually exclusive");
    }

    @Test
    void neitherModuleNorStepsIsInvalid() {
        assertThatIllegalArgumentException()
                .isThrownBy(() -> new YamlImport(null, null, null, null, null, null, null))
                .withMessageContaining("must specify either");
    }

    @Test
    void existingFourArgConstructorStillWorks() {
        var imp = new YamlImport("my-module", "alias", "when", null);
        assertThat(imp.module()).isEqualTo("my-module");
        assertThat(imp.steps()).isNull();
    }
}
```

- [ ] **Step 4: Update YamlImport with `steps` field**

Add `String steps` as the second field in the YamlImport record. Update compact constructor to validate mutual exclusivity. Update the 4-arg convenience constructor to pass `null` for steps. Update the 6-arg convenience constructor (module, as, when, parameters, forEach, loop) to also pass `null` for steps.

- [ ] **Step 5: Update ModuleExpander and ImportExpander to filter step imports**

Add a filter at the entry of `ModuleExpander.expand()` and `ModuleExpander.validateImports()`:
```java
List<YamlImport> moduleImports = imports.stream()
        .filter(imp -> imp.steps() == null)
        .toList();
```

Add the same filter at the entry of `ImportExpander.expand()`.

- [ ] **Step 6: Write import filter test**

```java
// Add to ImportExpanderTest.java
@Test
void stepImportsAreFilteredOut() {
    List<YamlImport> imports = List.of(
            new YamlImport("my-module", null, "mod", null, Map.of(), null, null),
            new YamlImport(null, "trading-steps.yaml", null, null, null, null, null));

    List<YamlImport> result = ImportExpander.expand(imports, Map.of(), Map.of(), resolver);
    assertThat(result).hasSize(1);
    assertThat(result.get(0).module()).isEqualTo("my-module");
}
```

- [ ] **Step 7: Run all affected tests**

Run: `mvn --batch-mode -pl yaml-plugin-api,yaml-core test -Dsurefire.useFile=false`
Expected: All pass (603+ yaml-core + yaml-plugin-api tests)

- [ ] **Step 8: Commit**

```bash
git add yaml-plugin-api/src/ yaml-core/src/
git commit -m "feat(#433): StepResult.executionMetadata, YamlImport.steps field, expander filters

Refs #433

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4: Jackson mixins + contract tests

**Files:**
- Create: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/StepDefinitionFileMixin.java`
- Create: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/StepDefinitionFileBuilder.java`
- Create: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/InvokeBindingDeserializer.java`
- Modify: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlCoreJacksonModule.java` (register new mixins)
- Test: `yaml-jackson/src/test/java/io/casehub/yaml/jackson/StepDefinitionFileDeserializationTest.java`
- Test: `yaml-jackson/src/test/java/io/casehub/yaml/jackson/StepDefinitionParserContractTest.java`

**Interfaces:**
- Consumes: `StepDefinitionFile`, `StepDefinition`, `StepParameter`, `StepParameterType`, `InvokeBinding` (from Task 1), `StepDefinitionParser` (from Task 2)
- Produces: Jackson deserializer for step definition YAML → StepDefinitionFile

- [ ] **Step 1: Write Jackson deserialization test**

Test that an ObjectMapper with YamlCoreJacksonModule deserializes a step definition YAML string into the same model as StepDefinitionParser. Use a YAML string with all 6 binding types and various parameter configurations.

- [ ] **Step 2: Implement StepDefinitionFileBuilder with @JsonAnySetter**

Follow the `YamlModuleFileBuilder` pattern: `@JsonProperty("namespace")` setter, `@JsonAnySetter` captures action names as map entries. The builder invokes `StepDefinitionParser.parseAction()` for each entry to produce `StepDefinition` records.

- [ ] **Step 3: Implement InvokeBindingDeserializer**

Custom `JsonDeserializer<InvokeBinding>` that reads the first key in the JSON object (`mcp`, `rest`, `graphql`, `python`, `agent`, `process`) and delegates to the appropriate `InvokeBinding` record constructor. String values (mcp, python, graphql shorthand) are handled directly.

- [ ] **Step 4: Register in YamlCoreJacksonModule**

Add `context.setMixInAnnotations(StepDefinitionFile.class, StepDefinitionFileMixin.class)` and register `InvokeBindingDeserializer` for `InvokeBinding.class`.

- [ ] **Step 5: Write contract test — both paths produce identical results**

```java
@Test
void jacksonAndParserProduceSameModel() {
    String yaml = "..."; // Same YAML content
    Map<String, Object> rawMap = yamlMapper.readValue(yaml, Map.class);

    StepDefinitionFile fromParser = StepDefinitionParser.parse(rawMap);
    StepDefinitionFile fromJackson = yamlMapper.readValue(yaml, StepDefinitionFile.class);

    assertThat(fromJackson.namespace()).isEqualTo(fromParser.namespace());
    assertThat(fromJackson.actions().keySet()).isEqualTo(fromParser.actions().keySet());
    // Deep equality on each action...
}
```

- [ ] **Step 6: Run yaml-jackson tests**

Run: `mvn --batch-mode -pl yaml-jackson test -Dsurefire.useFile=false`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add yaml-jackson/src/
git commit -m "feat(#433): Jackson mixins for step definition deserialization + contract tests

Refs #433

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 3: Runtime module foundation (yaml-step-runtime)

### Task 5: Module scaffolding + SPI types + ValidatingStepAction + StepExecutionEvent

**Files:**
- Create: `yaml-step-runtime/pom.xml`
- Modify: `pom.xml` (parent — add `<module>yaml-step-runtime</module>`)
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/CatalogEntry.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/StepCatalog.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/CatalogSource.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/InvokeHandler.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/ValidatingStepAction.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/StepExecutionEvent.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/ValidatingStepActionTest.java`

**Interfaces:**
- Consumes: `StepDefinition`, `StepValidator` (from yaml-core), `StepAction`, `StepResult` (from yaml-plugin-api)
- Produces: `CatalogEntry(String qualifiedName, StepDefinition definition, StepAction action)`, `StepCatalog` interface, `CatalogSource` interface, `InvokeHandler` interface, `ValidatingStepAction` (wraps StepAction with input/output validation + event emission), `StepExecutionEvent(String actionName, long durationMs, boolean success, Map<String, Object> metadata)`

- [ ] **Step 1: Create pom.xml for yaml-step-runtime**

Dependencies: yaml-core (compile), yaml-plugin-api (compile), yaml-jackson (compile), jackson-databind (compile), quarkus-arc (provided), casehub-platform-agent-api (compile), casehub-platform-api (compile). Test: junit-jupiter, assertj-core, quarkus-junit5-mockito.

- [ ] **Step 2: Add module to parent pom**

Add `<module>yaml-step-runtime</module>` after `yaml-plugin-processor` in the parent pom.xml.

- [ ] **Step 3: Create SPI interfaces and records**

CatalogEntry, StepCatalog, CatalogSource, InvokeHandler, StepExecutionEvent — all as specified in the design spec.

- [ ] **Step 4: Write ValidatingStepAction test**

```java
@Test
void validInputDelegatesAndReturnsResult() {
    // StepDefinition with required string input
    // Mock StepAction that returns Success
    // ValidatingStepAction wraps it
    // Call with valid input → expect Success
}

@Test
void invalidInputReturnsFailureWithoutDelegating() {
    // Missing required input → expect Failure, delegate never called
}

@Test
void invalidOutputReturnsFailure() {
    // Delegate returns Success with wrong output type → expect Failure
}

@Test
void executionMetadataFlowsThrough() {
    // Delegate returns Success with metadata → expect metadata preserved
}
```

- [ ] **Step 5: Implement ValidatingStepAction**

See spec §Validation-wrapping for exact implementation. Takes StepDefinition + delegate StepAction + CDI Event<StepExecutionEvent>. Validates inputs before delegating, validates outputs after, fires StepExecutionEvent with timing.

- [ ] **Step 6: Run tests**

Run: `mvn --batch-mode -pl yaml-step-runtime test -Dsurefire.useFile=false`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add yaml-step-runtime/ pom.xml
git commit -m "feat(#433): yaml-step-runtime module — SPI types, ValidatingStepAction, StepExecutionEvent

Refs #433

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 6: Six invoke handlers

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/handler/McpInvokeHandler.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/handler/RestInvokeHandler.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/handler/GraphqlInvokeHandler.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/handler/PythonInvokeHandler.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/handler/AgentInvokeHandler.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/handler/ProcessInvokeHandler.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/handler/McpInvokeHandlerTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/handler/RestInvokeHandlerTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/handler/ProcessInvokeHandlerTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/handler/PythonInvokeHandlerTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/handler/AgentInvokeHandlerTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/handler/GraphqlInvokeHandlerTest.java`

**Interfaces:**
- Consumes: `InvokeHandler` SPI (from Task 5), `InvokeBinding.*` (from Task 1), `StepDefinition` (from Task 1), `StepAction`/`StepResult` (from yaml-plugin-api), `AgentProvider` (from platform agent-api)
- Produces: 6 CDI `@ApplicationScoped` beans implementing `InvokeHandler`

- [ ] **Step 1: Write McpInvokeHandler test**

Mock the MCP tool manager. Verify it calls the tool with the correct parameters and maps the result.

- [ ] **Step 2: Implement McpInvokeHandler**

`@ApplicationScoped`. `supports(InvokeBinding.Mcp.class)`. `create()` returns a StepAction that calls the MCP tool manager. Inject via `Instance<ToolManager>` to handle optional availability.

- [ ] **Step 3: Write RestInvokeHandler test**

Use a simple local HTTP handler (or mock HttpClient). Verify URL interpolation, body interpolation, response parsing.

- [ ] **Step 4: Implement RestInvokeHandler**

`@ApplicationScoped`. Uses `java.net.http.HttpClient`. Variable interpolation: replace `${paramName}` in URL, headers, and body values with input parameters. Parse JSON response via Jackson ObjectMapper.

- [ ] **Step 5: Write ProcessInvokeHandler test**

Test with `/bin/echo '{"key":"value"}'` or equivalent. Verify JSON output parsing, timeout handling, error construction from stderr.

- [ ] **Step 6: Implement ProcessInvokeHandler**

`@ApplicationScoped`. Uses `ProcessBuilder`. Variable interpolation in args. Output parsing by mode (json, csv, lines, raw). Timeout via `Process.waitFor()`. Error from stderr or exit code based on `onError` setting. Include exit code and duration in `executionMetadata`.

- [ ] **Step 7: Write PythonInvokeHandler test**

Mock the subprocess. Verify JSON stdin/stdout protocol.

- [ ] **Step 8: Implement PythonInvokeHandler**

`@ApplicationScoped`. Runs `python3 <script>` via ProcessBuilder. Writes inputs as JSON to stdin. Reads JSON from stdout. Stderr for errors. Timeout enforcement.

- [ ] **Step 9: Write AgentInvokeHandler test**

Mock `AgentProvider`. Verify AgentSessionConfig construction from descriptor, response collection, structured output parsing.

- [ ] **Step 10: Implement AgentInvokeHandler**

`@ApplicationScoped`. Inject `AgentProvider` and `Instance<AgentDescriptorRegistrar>` (optional). Build `AgentSessionConfig` from eidos descriptor (briefing → systemPrompt, inputs JSON → userPrompt). Block on `Multi<AgentEvent>` via `.collect().asList().await().atMost(timeout)`. Collect TextDelta → text. Parse as JSON when structuredOutput=true. Include token/cost metadata from InvocationComplete event.

- [ ] **Step 11: Write GraphqlInvokeHandler test**

Mock the GraphQL client endpoint. Verify query interpolation, response mapping.

- [ ] **Step 12: Implement GraphqlInvokeHandler**

`@ApplicationScoped`. Uses platform's SmallRye GraphQL client or falls back to REST POST to `/graphql`. Variable interpolation in query string. Parse JSON response.

- [ ] **Step 13: Run all handler tests**

Run: `mvn --batch-mode -pl yaml-step-runtime test -Dsurefire.useFile=false`
Expected: PASS

- [ ] **Step 14: Commit**

```bash
git add yaml-step-runtime/src/
git commit -m "feat(#433): 6 invoke handlers — MCP, REST, GraphQL, Python, Agent, Process

Refs #433

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 4: Catalog assembly + integration

### Task 7: CompositeStepCatalog + 3 catalog sources + ImportScopedStepCatalog

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/CompositeStepCatalog.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/YamlStepDefinitionSource.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/AptPluginSource.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/McpToolSource.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ImportScopedStepCatalog.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/CompositeStepCatalogTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/YamlStepDefinitionSourceTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/AptPluginSourceTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/ImportScopedStepCatalogTest.java`

**Interfaces:**
- Consumes: `CatalogEntry`, `StepCatalog`, `CatalogSource`, `InvokeHandler` (from Task 5), `StepDefinitionParser` (from Task 2), `ValidatingStepAction` (from Task 5), all invoke handlers (from Task 6)
- Produces: `CompositeStepCatalog @ApplicationScoped @Startup implements StepCatalog`, `ImportScopedStepCatalog implements StepCatalog`

- [ ] **Step 1: Write CompositeStepCatalog test**

```java
@Test
void resolvesRegisteredAction() {
    // Register a CatalogEntry manually
    // resolve("action-name") → present
}

@Test
void resolveMissingActionReturnsEmpty() {
    // resolve("nonexistent") → empty
}

@Test
void availableActionsReturnsAllKeys() {
    // Register 2 entries → availableActions().size() == 2
}

@Test
void firstSourceWinsOnNameCollision() {
    // Two sources register same name
    // Lower priority source's entry wins (first-write)
}
```

- [ ] **Step 2: Implement CompositeStepCatalog**

`@ApplicationScoped @Startup`. `@PostConstruct` discovers `Instance<CatalogSource>`, sorts by priority(), populates entries with first-write-wins. Sets `initialized = true`. See spec §CompositeStepCatalog.

- [ ] **Step 3: Write YamlStepDefinitionSource test**

Test with a step definition YAML file on the classpath. Verify it loads, parses, resolves invoke handlers, wraps with validation, and registers entries.

- [ ] **Step 4: Implement YamlStepDefinitionSource**

`@ApplicationScoped`. Priority 100. Reads paths from `casehub.steps.definition-files` config. For each file: parse with StepDefinitionParser, resolve InvokeHandlers via injected `Instance<InvokeHandler>`, wrap with ValidatingStepAction, register both qualified and unqualified names.

- [ ] **Step 5: Write AptPluginSource test**

Test with a mock META-INF/yaml-plugins/*.json manifest. Verify it loads the action class and constructs a synthetic StepDefinition from the schema.

- [ ] **Step 6: Implement AptPluginSource**

`@ApplicationScoped`. Priority 200. Scans classpath for `META-INF/yaml-plugins/*.json`. For each manifest: load action class, read schema, construct synthetic StepDefinition, register.

- [ ] **Step 7: Write ImportScopedStepCatalog test**

```java
@Test
void importScopedShadowsGlobal() {
    // Global catalog has "action-a"
    // Import-scoped has different "action-a"
    // resolve("action-a") → import-scoped entry
}

@Test
void fallsBackToGlobalForUnimportedActions() {
    // Import-scoped has "local-action"
    // Global has "global-action"
    // resolve("global-action") → global entry
}
```

- [ ] **Step 8: Implement ImportScopedStepCatalog**

Wrapping StepCatalog — checks importedEntries map first, delegates to CompositeStepCatalog. See spec §Import-scoped catalog lifecycle.

- [ ] **Step 9: Run all yaml-step-runtime tests**

Run: `mvn --batch-mode -pl yaml-step-runtime test -Dsurefire.useFile=false`
Expected: PASS

- [ ] **Step 10: Run full build**

Run: `mvn --batch-mode install -Dsurefire.useFile=false`
Expected: BUILD SUCCESS

- [ ] **Step 11: Commit**

```bash
git add yaml-step-runtime/src/
git commit -m "feat(#433): CompositeStepCatalog + 3 catalog sources + ImportScopedStepCatalog

Refs #433

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## References

- `specs/issue-429-yaml-type-system/2026-09-25-dynamic-step-catalog-design.md` — design spec this plan implements
- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StepAction.java:6` — execution contract
- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StepResult.java:5` — result sealed interface
- `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/RegistryEmitter.java:9` — APT manifest format
- `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/SchemaEmitter.java:13` — APT schema format
- `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlImport.java:5` — import record to extend
- `yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleExpander.java` — needs step-import filter
- `yaml-core/src/main/java/io/casehub/yaml/core/module/ImportExpander.java` — needs step-import filter
- `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlModuleFileBuilder.java` — @JsonAnySetter pattern to follow
- `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlCoreJacksonModule.java` — mixin registration point
- GitHub #433, #429, #432
