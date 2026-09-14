## D1: Fix @SupportedSourceVersion — use latestSupported()

**Choice:** Override `getSupportedSourceVersion()` to return `SourceVersion.latestSupported()` and remove `@SupportedSourceVersion(SourceVersion.RELEASE_21)`. Eliminates javac warnings on Java 22+ that may interfere with APT option handling in some compiler plugin configurations.
**Alternatives:**
- Bump to `RELEASE_26` — fixes the immediate issue but breaks again on Java 27+
**Rationale:** `latestSupported()` is the documented best practice for processors that don't use version-specific language features. The graphql-generator only uses standard APT APIs — no version coupling.
**Trade-offs:** None. The method override replaces the annotation with strictly better semantics.
**Sources:** GraphQLResolverProcessor.java line 34 (`@SupportedSourceVersion(SourceVersion.RELEASE_21)`), javac documentation on processor source version checking
**Exploration:** quick
**Status:** captured

## D2: Refactor OperationInfo to intermediate record (ResolvedOperation)

**Choice:** Extract a `ResolvedOperation` record holding pre-extracted string data: method name, return type string + import FQCNs, parameter info (name, type string, FQCNs, isPathParam, pathParamName, isSimpleType), declaring class FQCN/simple name, operation type, description, REST overrides. Both Jandex and TypeMirror scanning paths produce `ResolvedOperation`. Code gen methods (`generateMethod`, `generateRestMethod`, `collectTypeImports`) work with strings only. Follows the `DomainDescriptor` pattern from `graphql-spring-generator`.
**Alternatives:**
- Keep Jandex-based OperationInfo, duplicate code gen for TypeMirror path — maintenance trap: ~200 lines duplicated, every bug fix applied twice
- Convert TypeMirror to Jandex objects — not feasible (Jandex objects created only by Indexer)
**Rationale:** The current `OperationInfo` holds raw `MethodInfo`/`ClassInfo` (Jandex types), coupling scanning to Jandex. Code gen methods reach into Jandex for strings (`typeToJava()`, `addTypeImport()`, `findParameterAnnotation()`). Extracting strings during scanning decouples the two phases, enabling RoundEnvironment scanning (D3) without code duplication.
**Trade-offs:** Moderate refactor of the code generation methods. All data extraction moves from code gen time to scan time. The `typeToJava` and `collectImports` logic is unchanged — just called earlier.
**Sources:** GraphQLResolverProcessor.java lines 206-283 (generateResolverSource), 285-372 (generateRestResourceSource), 374-460 (generateRestMethod), 463-498 (generateMethod), 500-544 (collectTypeImports/addTypeImport/typeToJava). graphql-spring-generator DomainDescriptor.java (established pattern).
**Exploration:** quick
**Status:** captured

## D3: Add RoundEnvironment scanning for consumer SPI discovery

**Choice:** New method `scanRoundEnvironment(RoundEnvironment roundEnv)` iterates `roundEnv.getElementsAnnotatedWith(McpDomain.class)`, filters to interfaces, extracts `@PlatformQuery`/`@PlatformMutation` methods via `javax.lang.model` API (`TypeElement`, `ExecutableElement`, `AnnotationMirror`), and produces `ResolvedOperation` records. Results merge into the `domains` map alongside Jandex-sourced domains. For `isSimpleType`, falls back to static list + Jandex — consumer-source enums conservatively treated as complex types (request body). Consumer works around this via `@PathParam`.
**Depends on:** D2 (ResolvedOperation abstraction — both scanning paths must produce the same type)
**Alternatives:**
- Require consumers to run Jandex Maven plugin before compilation so their SPIs appear in classpath index — fragile, adds build complexity, ordering constraints between Jandex and compiler phases
**Rationale:** APTs exist to scan the current compilation unit. Without RoundEnvironment scanning, the APT can only find SPIs from dependency JARs (via Jandex), making it useless for consumers whose SPIs live in the same module or in source-only dependencies.
**Trade-offs:** TypeMirror API is more verbose than Jandex for type extraction. `isSimpleType` won't recognize consumer-source enums initially (safe default — treats as complex). The annotation class `McpDomain.class` must be on the processor classpath for `getElementsAnnotatedWith` — it already is (platform-api is a transitive dependency).
**Sources:** GraphQLResolverProcessor.java line 59 (`RoundEnvironment roundEnv` — imported but not used for scanning), #296 spec section "SPI discovery via RoundEnvironment", graphql-spring-generator McpDomainScanner.java (Jandex-only — same gap exists there but out of scope)
**Exploration:** quick
**Status:** captured

## D4: Diagnostic logging for options, domains, and filtering

**Choice:** At the start of `process()`, log all received APT options at `NOTE` level. During domain scanning, log each discovered domain and its source (Jandex or RoundEnvironment). When `domainFilter` is set, log which domains pass and which are excluded. When `generateGraphQL=false` or `generateRest=false`, log the suppression explicitly. When `domainFilter` is set but resolves to zero matching domains, emit `WARNING` (likely configuration error — filter values don't match any discovered domain names).
**Alternatives:**
- Fail fast when filter produces zero matches — overly aggressive; zero matches could be intentional (consumer wants to suppress all generation for a specific module)
**Rationale:** The root cause of bugs 3-4 (filter and flag not working) is invisible: options silently default, filter silently passes everything, no output tells the consumer what happened. Diagnostic logging at NOTE level is visible in Maven's `-X` debug output and in javac's `-verbose` mode. The WARNING for zero-match filter is louder — it surfaces in normal builds.
**Trade-offs:** Additional log lines during compilation. At NOTE level, invisible in normal builds — only visible with verbose/debug flags. The WARNING for zero-match filter is the only one visible in normal builds.
**Sources:** GraphQLResolverProcessor.java lines 79-84 (option reading — no logging), lines 86-89 (filter — no logging), lines 199-201 (domain count — only logging currently present)
**Exploration:** quick
**Status:** captured
