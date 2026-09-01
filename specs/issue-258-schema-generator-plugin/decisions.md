# Decisions — platform#258

## D1: Generator approach

**Choice:** Extend jsonschema2pojo — use it as a library for schema parsing and $ref resolution, bypass JCodeModel, emit Java record source text directly.
**Alternatives:**
- Fork Cosium/json-schema-to-java-record — lacks $defs, oneOf, additionalProperties, annotation config; significant feature gap to close
- Standalone generator — simpler scope but reinvents schema parsing ($ref resolution, type graph construction) that jsonschema2pojo already handles
**Rationale:** jsonschema2pojo handles the hard part (JSON Schema 2020-12 parsing, $ref resolution, type graph). Engine already proves the extension model works via CasehubRuleFactory. The gap is output format only — JCodeModel can't emit records, so we replace the output stage with text-based record emission.
**Trade-offs:** Couples the plugin to jsonschema2pojo's internal API (SchemaStore, Schema, RuleFactory). If jsonschema2pojo changes internals, the plugin breaks. Acceptable because the parsing API has been stable for years.
**Sources:** jsonschema2pojo#1405 (records feature request, open since 2022), Cosium/json-schema-to-java-record README (feature gaps), engine codegen/CasehubRuleFactory.java (extension model proof)
**Exploration:** deep-analysis
**Status:** captured

## D2: Annotation override configuration model

**Choice:** YAML mapping file — a separate `record-mappings.yaml` declaring per-type, per-field overrides (deserializer, alias, jsonProperty, type override). Plugin reads it alongside the schema.
**Alternatives:**
- Schema extensions (x- properties) — co-located with schema but pollutes the JSON Schema with Java-specific concerns; violates schema portability (TypeScript generator would ignore them)
- Java annotations on package-info — type-safe but verbose for 15+ overrides, requires compile-time dependency on all override types at the generator level
**Rationale:** Keeps the JSON Schema language-neutral (important since engine#977 TypeScriptWriter reads the same schema). Consumer-specific config stays in the consumer repo. YAML is natural for declaring mappings and easy to validate.
**Trade-offs:** Two files to maintain per consumer (schema + mappings). Typos in class names aren't caught until compile time. Acceptable because the generated output is compiled immediately, so errors surface fast.
**Sources:** engine api/model/converter/yaml/*.java (15 annotation overrides catalogued), engine#977 (TypeScriptWriter sharing same schema)
**Exploration:** quick
**Status:** captured

## D3: Polymorphic type handling (oneOf)

**Choice:** Opaque + deserializer — for oneOf fields, emit the type declared in the mapping file (or JsonNode if unmapped). The @JsonDeserialize annotation from the mapping file handles parsing. Generator doesn't model polymorphism.
**Alternatives:**
- Sealed interface generation — more type-safe but significantly more complex (discriminator detection, per-variant records, @JsonTypeInfo wiring). Overkill when hand-written deserializers already exist.
- JsonNode fallback — simple but loses type safety. Acceptable for truly opaque fields (outcomePolicy, context) but not for typed polymorphics like Trigger.
**Rationale:** Matches the existing hand-written pattern exactly. The 5 polymorphic deserializers (Trigger, CaseCompletion, CbrConfig, AdaptationConfig, SubCaseMapping) are domain logic that belongs in the consumer, not the generator. Generator's job is structural mapping only.
**Trade-offs:** Consumer must maintain deserializers separately. Acceptable because these deserializers encode domain semantics that can't be derived from schema structure.
**Sources:** engine api/model/converter/deser/ (5 deserializers), engine api/model/converter/yaml/YamlBinding.java:32, YamlCaseSpec.java:35-46
**Exploration:** quick
**Status:** captured

## D4: Module placement

**Choice:** New sibling module `yaml-codegen` in platform, alongside `yaml-core`. Published as a Maven plugin. Package: `io.casehub.yaml.codegen`.
**Alternatives:**
- Add to yaml-core directly — breaks yaml-core's zero-dependency, J2CL-transpilable constraint by introducing jsonschema2pojo dependency
- Standalone repo — unnecessary isolation for a module that logically belongs with yaml-core
**Rationale:** yaml-core is zero-dep by design (variable resolution, forEach, modules). The codegen module needs jsonschema2pojo as a dependency. Sibling module keeps the namespace coherent while preserving yaml-core's constraints.
**Trade-offs:** Two modules instead of one. Acceptable — they have fundamentally different dependency profiles (runtime zero-dep vs build-time with jsonschema2pojo).
**Sources:** platform yaml-core/pom.xml (zero dependencies), yaml-core description ("Zero dependencies, J2CL-transpilable")
**Exploration:** quick
**Status:** captured
