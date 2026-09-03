## D1: Resolution API — static method on ModuleExpander

**Choice:** `ModuleExpander.resolveExtensions()` as a static method. Caller calls it before `expand()`.
**Alternatives:**
- Standalone `ModuleResolver` class — more files but no meaningful separation when it's a single static method tightly coupled to the module model
- ModuleExpander auto-resolves internally — convenient but hides the pre-processing step, violates single responsibility
**Rationale:** Consistent with `ModuleExpander` being the single utility class for module operations. Caller-resolves keeps expansion behavior unchanged and the pre-processing explicit.
**Trade-offs:** Caller has one extra step in the pipeline. Trivial — it's a single method call.
**Sources:** `ModuleExpander.expand()` (existing pattern), issue #269 design notes ("resolves before expansion — pre-processing step")
**Exploration:** quick
**Status:** captured

## D2: Resolution input — `List<YamlModuleFile>`

**Choice:** `resolveExtensions(List<YamlModuleFile>)` returns `Map<String, YamlModule>`. Takes file models (which carry the `extends` field on `YamlModuleHeader`), resolves extensions, calls `toModule()` internally, and returns a complete module map.
**Alternatives:**
- Two-arg `(List<YamlModuleFile>, Map<String, YamlModule>)` — supports programmatic parent modules but YAGNI
**Rationale:** `extends` lives on `YamlModuleHeader` (D3), which is discarded by `toModule()`. The resolution method must work with file models to see the extends field. Non-extended files pass through via `toModule()`, making this the standard pipeline from files to modules.
**Trade-offs:** Callers with programmatic modules would need to wrap them in `YamlModuleFile`. No known consumer needs this today.
**Depends on:** D3 (extends on header only)
**Sources:** `YamlModuleFile.toModule()` (existing conversion boundary)
**Exploration:** quick
**Status:** captured

## D3: Field name — `extendsModule` on `YamlModuleHeader`

**Choice:** `extendsModule` as the Java field name on `YamlModuleHeader`. `extends` is a Java reserved word. YAML key stays `extends:` via Jackson mapping in yaml-jackson.
**Alternatives:**
- `parent` — ambiguous, implies hierarchy/ownership rather than inheritance
- `base` — vague, overloaded term
**Rationale:** Explicit, reads naturally as "this module extends [module]". Consistent with `YamlImport.module()` naming convention. Lives on `YamlModuleHeader` only — `YamlModule` (the logical model) has no `extends` field. `toModule()` discards it, same lifecycle as `imports`.
**Trade-offs:** Slightly verbose. Acceptable — clarity over brevity for a keyword that's read once per module definition.
**Sources:** `YamlModuleFile.YamlModuleHeader` (current record), Java Language Specification §3.9 (reserved keywords)
**Exploration:** quick
**Status:** captured

## D4: Section merge — shallow replace at entry level

**Choice:** When parent and child define the same section, merge at the entry-key level: child's entry replaces parent's entirely on key match. No deep merge of `Map<String, Object>` entry values.
**Alternatives:**
- Deep merge for Map entries — recursively merge fields within section entries. More intuitive for users but violates yaml-core's domain-agnostic principle and has edge cases (arrays, nulls, nested maps)
**Rationale:** yaml-core treats section entry values as opaque `Object` — it never inspects content. Deep merge requires structural knowledge that belongs in the consumer domain. Consumers wanting deep merge can implement it via `ModuleBridge<T>.fromSections()`.
**Trade-offs:** Users must redeclare the full entry to override a single field. Documented clearly as the contract. Consumers have the escape hatch via `ModuleBridge<T>`.
**Sources:** yaml-core D3 (generic sections — opaque maps), `ModuleBridge<T>` (typed boundary conversion)
**Exploration:** quick
**Status:** captured

## D5: Parameter and output merge — full override

**Choice:** Child's `YamlModuleParameter` replaces parent's entirely on name match. Same for `YamlModuleOutput`. No constraint narrowing or merging.
**Alternatives:**
- Default-only override — child can only change `defaultValue` and `required`. Safer but overly restrictive.
- Additive narrowing — child can narrow constraints but not widen. Complex merge semantics for minimal benefit.
**Rationale:** Simple, predictable. If a child declares a parameter with the same name as the parent, the child's declaration is authoritative. This is standard override semantics in any inheritance system.
**Trade-offs:** No constraint safety — child can widen a parent's restrictions. Acceptable for pre-release; add a strict mode later if needed.
**Sources:** Issue #269 ("child can add new ones, override defaults"), clarified via brainstorming to full override
**Exploration:** quick
**Status:** captured
