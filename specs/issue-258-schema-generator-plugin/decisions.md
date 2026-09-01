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
