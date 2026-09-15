# graphql-generator APT Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #299 — graphql-generator APT: broken domain filter, illegal class names, GraphQL emitted despite flag
**Issue group:** #299

**Goal:** Make the graphql-generator annotation processor work correctly in consumer modules by fixing option handling, adding RoundEnvironment scanning, and providing diagnostic logging.

**Architecture:** Refactor `GraphQLResolverProcessor` to decouple Jandex scanning from code generation via a `ResolvedOperation` intermediate record. Add a parallel `RoundEnvironment` scanning path for consumer SPIs in the current compilation unit. Add diagnostic logging at every decision point. Fix `@SupportedSourceVersion` in both APTs.

**Tech Stack:** Java 26, javax.annotation.processing (APT), javax.lang.model (TypeMirror), Jandex, Google compile-testing

## Global Constraints

- `graphql-generator` is `jar` packaging with `<proc>none</proc>` — the processor itself is not annotation-processed
- No JavaPoet dependency — use plain `PrintWriter` string generation
- `casehub-platform-api` is the only casehub dependency — must remain so
- `compile-testing` 0.21.0 already in test scope
- All `@McpDomain` annotations use kebab-case domain names (hyphens, no slashes in current codebase)

---

## Batch 1: ResolvedOperation refactor + source version fix

After this batch: the processor produces identical output to before, but code generation is decoupled from Jandex types. Both APTs use `latestSupported()`. All existing tests pass.

### Task 1: Fix @SupportedSourceVersion in both APTs

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java:33-35`
- Modify: `callback-generator/src/main/java/io/casehub/platform/callback/generator/CallbackDecoratorProcessor.java:33`

**Interfaces:**
- Consumes: nothing
- Produces: nothing new — behavioral fix only

- [ ] **Step 1: Remove `@SupportedSourceVersion` annotation and add method override in GraphQLResolverProcessor**

In `GraphQLResolverProcessor.java`, remove line 34 (`@SupportedSourceVersion(SourceVersion.RELEASE_21)`) and add the override method after the field declarations:

```java
@Override
public SourceVersion getSupportedSourceVersion() {
    return SourceVersion.latestSupported();
}
```

- [ ] **Step 2: Same fix in CallbackDecoratorProcessor**

In `CallbackDecoratorProcessor.java`, remove line 33 (`@SupportedSourceVersion(SourceVersion.RELEASE_21)`) and add the same override:

```java
@Override
public SourceVersion getSupportedSourceVersion() {
    return SourceVersion.latestSupported();
}
```

- [ ] **Step 3: Run existing tests**

Run: `mvn --batch-mode test -pl graphql-generator,callback-generator`
Expected: all existing tests pass

- [ ] **Step 4: Commit**

```bash
git add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java callback-generator/src/main/java/io/casehub/platform/callback/generator/CallbackDecoratorProcessor.java
git commit -m "fix(#299): replace @SupportedSourceVersion with latestSupported() override

Both GraphQLResolverProcessor and CallbackDecoratorProcessor declared
RELEASE_21 which emits warnings on Java 22+. Override method returns
latestSupported() — best practice for processors with no version-specific
language features.

Refs #299"
```

### Task 2: Introduce ResolvedOperation and ResolvedParam records

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java:669-693`

**Interfaces:**
- Consumes: nothing
- Produces: `ResolvedOperation` record, `ResolvedParam` record, `Source` enum, updated `DomainOperations` — used by Tasks 3-5

- [ ] **Step 1: Add Source enum, ResolvedOperation, and ResolvedParam records**

Replace the `DomainOperations` and `OperationInfo` inner classes (lines 669-693) with:

```java
enum Source { JANDEX, ROUND_ENV }

static class DomainOperations {
    final String domain;
    final Source source;
    final List<ResolvedOperation> operations = new ArrayList<>();
    DomainOperations(String domain, Source source) {
        this.domain = domain;
        this.source = source;
    }
}

record ResolvedOperation(
    String methodName,
    String returnTypeStr,
    List<ResolvedParam> params,
    Set<String> typeImports,
    String declaringClassFqcn,
    String declaringClassSimple,
    OperationType type,
    String description,
    String restMethodOverride,
    String restPathOverride
) {}

record ResolvedParam(
    String name,
    String typeStr,
    String typeFqcn,
    boolean isPathParam,
    String pathParamName,
    boolean isSimpleType
) {}
```

- [ ] **Step 2: Run tests to verify compilation**

Run: `mvn --batch-mode test -pl graphql-generator`
Expected: compilation fails — `DomainOperations` constructor changed, `OperationInfo` references broken. This is expected; Task 3 fixes it.

- [ ] **Step 3: Commit the records (WIP)**

```bash
git add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java
git commit -m "wip(#299): add ResolvedOperation, ResolvedParam records and Source enum

Refs #299"
```

### Task 3: Refactor scanAnnotatedInterfaces to produce ResolvedOperation

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java:164-202`

**Interfaces:**
- Consumes: `ResolvedOperation`, `ResolvedParam`, `Source` from Task 2
- Produces: `scanAnnotatedInterfaces` returns `Map<String, DomainOperations>` with `ResolvedOperation` entries — used by Task 4

- [ ] **Step 1: Add resolveFromJandex helper method**

Add a new private method that converts a Jandex `MethodInfo` + `ClassInfo` to a `ResolvedOperation`. This method extracts all type information during scanning (calls `typeToJava`, `addTypeImport`, `findParameterAnnotation`, `isSimpleType`):

```java
private ResolvedOperation resolveFromJandex(MethodInfo method, ClassInfo declaringClass,
                                             OperationType opType, String description,
                                             String restMethodOverride, String restPathOverride) {
    String returnTypeStr = typeToJava(method.returnType());
    Set<String> imports = new HashSet<>();
    addTypeImport(imports, method.returnType());

    List<ResolvedParam> params = new ArrayList<>();
    for (int i = 0; i < method.parameterTypes().size(); i++) {
        Type paramType = method.parameterTypes().get(i);
        String paramName = method.parameterName(i) != null ? method.parameterName(i) : "arg" + i;
        String typeStr = typeToJava(paramType);
        String typeFqcn = paramType.name().toString();
        addTypeImport(imports, paramType);

        AnnotationInstance ppAnn = findParameterAnnotation(method, i, PATH_PARAM_ANN);
        boolean isPathParam = ppAnn != null;
        String pathParamName = null;
        if (ppAnn != null && ppAnn.value() != null && !ppAnn.value().asString().isEmpty()) {
            pathParamName = ppAnn.value().asString();
        }

        boolean simple = isSimpleType(typeFqcn, jandexIndex);
        params.add(new ResolvedParam(paramName, typeStr, typeFqcn, isPathParam, pathParamName, simple));
    }

    return new ResolvedOperation(
        method.name(), returnTypeStr, params, imports,
        declaringClass.name().toString(), declaringClass.simpleName(),
        opType, description, restMethodOverride, restPathOverride
    );
}
```

- [ ] **Step 2: Update scanAnnotatedInterfaces to use resolveFromJandex**

Change the `scanAnnotatedInterfaces` method: replace `ops.operations.add(new OperationInfo(...))` with `ops.operations.add(resolveFromJandex(...))`. Update `DomainOperations` construction to pass `Source.JANDEX`:

```java
DomainOperations ops = domains.computeIfAbsent(domain,
    d -> new DomainOperations(d, Source.JANDEX));
```

- [ ] **Step 3: Run tests to verify compilation**

Run: `mvn --batch-mode test -pl graphql-generator`
Expected: compilation fails — code gen methods still reference `OperationInfo`. This is expected; Task 4 fixes it.

- [ ] **Step 4: Commit**

```bash
git add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java
git commit -m "wip(#299): refactor scanAnnotatedInterfaces to produce ResolvedOperation

Refs #299"
```

### Task 4: Refactor code generation methods to use ResolvedOperation

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java:204-509`

**Interfaces:**
- Consumes: `ResolvedOperation`, `ResolvedParam` from Tasks 2-3
- Produces: refactored `generateMethod`, `generateRestMethod`, `generateResolverSource`, `generateRestResourceSource`, `collectTypeImports` — all working with `ResolvedOperation`

- [ ] **Step 1: Refactor collectTypeImports**

Replace the current implementation (lines 500-509) that iterates `OperationInfo.method` types:

```java
private Set<String> collectTypeImports(List<ResolvedOperation> operations) {
    Set<String> imports = new HashSet<>();
    for (ResolvedOperation op : operations) {
        imports.addAll(op.typeImports());
    }
    return imports;
}
```

- [ ] **Step 2: Refactor generateMethod to use ResolvedOperation**

Replace `MethodInfo method = op.method;` pattern with record accessors:

```java
private void generateMethod(PrintWriter out, ResolvedOperation op) {
    String annotation = op.type() == OperationType.QUERY ? "@Query" : "@Mutation";

    out.println("    " + annotation);
    if (!op.description().isEmpty()) {
        out.println("    @Description(\"" + escapeJavaString(op.description()) + "\")");
    }

    StringBuilder params = new StringBuilder();
    for (int i = 0; i < op.params().size(); i++) {
        if (i > 0) params.append(", ");
        ResolvedParam p = op.params().get(i);
        params.append(p.typeStr()).append(" ").append(p.name());
    }

    out.println("    public " + op.returnTypeStr() + " " + op.methodName() + "(" + params + ") {");

    String fieldName = decapitalize(op.declaringClassSimple());
    StringBuilder args = new StringBuilder();
    for (int i = 0; i < op.params().size(); i++) {
        if (i > 0) args.append(", ");
        args.append(op.params().get(i).name());
    }

    if ("void".equals(op.returnTypeStr())) {
        out.println("        " + fieldName + "." + op.methodName() + "(" + args + ");");
    } else {
        out.println("        return " + fieldName + "." + op.methodName() + "(" + args + ");");
    }

    out.println("    }");
    out.println();
}
```

- [ ] **Step 3: Refactor generateRestMethod to use ResolvedOperation**

Replace Jandex type calls with record field reads:

```java
private void generateRestMethod(PrintWriter out, ResolvedOperation op) {
    String httpVerb = resolveHttpVerb(op.type(), op.restMethodOverride());
    boolean isBodyVerb = httpVerb.equals("POST") || httpVerb.equals("PUT") || httpVerb.equals("PATCH");

    List<String> pathParams = new ArrayList<>();
    Set<Integer> pathParamPositions = new HashSet<>();
    int bodyParamIndex = -1;
    int complexCount = 0;

    for (int i = 0; i < op.params().size(); i++) {
        ResolvedParam p = op.params().get(i);
        if (p.isPathParam()) {
            pathParams.add(p.pathParamName() != null ? p.pathParamName() : p.name());
            pathParamPositions.add(i);
        } else if (isBodyVerb && !p.isSimpleType()) {
            complexCount++;
            if (bodyParamIndex < 0) bodyParamIndex = i;
        }
    }

    if (complexCount > 1) {
        processingEnv.getMessager().printMessage(Diagnostic.Kind.ERROR,
            "REST generator: method '" + op.methodName() + "' on domain '"
            + op.declaringClassSimple() + "' has " + complexCount
            + " complex parameters. Wrap them in a single request DTO"
            + " or annotate path parameters with @PathParam.");
        return;
    }

    boolean hasBody = bodyParamIndex >= 0;

    StringBuilder pathSuffix = new StringBuilder();
    pathSuffix.append("/").append(resolveRestPath(op.restPathOverride(), op.methodName()));
    for (String pp : pathParams) {
        pathSuffix.append("/{").append(pp).append("}");
    }

    out.println("    @" + httpVerb);
    out.println("    @Path(\"" + pathSuffix + "\")");
    if (hasBody) {
        out.println("    @Consumes(MediaType.APPLICATION_JSON)");
    }

    StringBuilder params = new StringBuilder();
    for (int i = 0; i < op.params().size(); i++) {
        if (i > 0) params.append(", ");
        ResolvedParam p = op.params().get(i);

        if (pathParamPositions.contains(i)) {
            String pathName = p.pathParamName() != null ? p.pathParamName() : p.name();
            params.append("@jakarta.ws.rs.PathParam(\"").append(pathName).append("\") ");
        } else if (i == bodyParamIndex) {
            params.append("@jakarta.validation.Valid ");
        } else {
            params.append("@QueryParam(\"").append(p.name()).append("\") ");
        }
        params.append(p.typeStr()).append(" ").append(p.name());
    }

    out.println("    public Response " + op.methodName() + "(" + params + ") {");

    String fieldName = decapitalize(op.declaringClassSimple());
    StringBuilder args = new StringBuilder();
    for (int i = 0; i < op.params().size(); i++) {
        if (i > 0) args.append(", ");
        args.append(op.params().get(i).name());
    }

    String delegateCall = fieldName + "." + op.methodName() + "(" + args + ")";
    String responseCode = generateResponseCode(op.returnTypeStr(), delegateCall);
    out.println("        " + responseCode);

    out.println("    }");
    out.println();
}
```

- [ ] **Step 4: Update generateResolverSource and generateRestResourceSource**

Change the injection field generation and method iteration to use `ResolvedOperation`:

In `generateResolverSource`, replace `OperationInfo op` with `ResolvedOperation op`:
```java
for (ResolvedOperation op : toGenerate) {
    String fieldName = decapitalize(op.declaringClassSimple());
    if (injectedFields.add(fieldName)) {
        out.println("    @Inject");
        out.println("    " + op.declaringClassSimple() + " " + fieldName + ";");
        out.println();
    }
}
```

Same pattern in `generateRestResourceSource`.

Also update the `toGenerate` list type from `List<OperationInfo>` to `List<ResolvedOperation>` in both methods.

- [ ] **Step 5: Remove old OperationInfo class**

Delete the `OperationInfo` class (formerly lines 677-693) — it's fully replaced by `ResolvedOperation`.

- [ ] **Step 6: Run all tests**

Run: `mvn --batch-mode test -pl graphql-generator`
Expected: all existing tests pass — the refactor preserves identical output

- [ ] **Step 7: Commit**

```bash
git add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java
git commit -m "refactor(#299): decouple code generation from Jandex types

Code gen methods now work with ResolvedOperation/ResolvedParam records
instead of Jandex MethodInfo/ClassInfo. Type information extracted during
scanning, not during generation. Enables RoundEnvironment scanning path.

Refs #299"
```

---

## Batch 2: RoundEnvironment scanning + diagnostic logging

After this batch: the processor discovers consumer SPIs via RoundEnvironment, respects domain filter and generation flags with clear diagnostic logging, and validates class names. The consumer use case works end-to-end.

### Task 5: Add RoundEnvironment scanning and merge logic

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java:59-99` (process method), add new methods

**Interfaces:**
- Consumes: `ResolvedOperation`, `ResolvedParam`, `DomainOperations`, `Source` from Tasks 2-4
- Produces: `scanRoundEnvironment()`, `resolveFromTypeMirror()`, `typeMirrorToJava()`, `collectTypeMirrorImports()`, `isSimpleTypeMirror()`, `findAnnotationMirror()`, `extractAnnotationStringValue()`

- [ ] **Step 1: Write integration test — RoundEnv discovers @McpDomain interface**

Add to `GraphQLResolverProcessorTest.java` using compile-testing:

```java
@Test
void roundEnvScanDiscoversLocalInterface() {
    JavaFileObject spi = JavaFileObjects.forSourceString(
        "test.SampleApi",
        """
        package test;
        import io.casehub.platform.api.mcp.McpDomain;
        import io.casehub.platform.api.mcp.PlatformQuery;
        import java.util.List;

        @McpDomain("sample")
        public interface SampleApi {
            @PlatformQuery("List items")
            List<String> listItems();
        }
        """);

    com.google.testing.compile.Compilation compilation =
        com.google.testing.compile.Compiler.javac()
            .withProcessors(new GraphQLResolverProcessor())
            .withOptions("-AgenerateRest=true", "-AgenerateGraphQL=true")
            .compile(spi);

    assertThat(compilation.status()).isEqualTo(
        com.google.testing.compile.Compilation.Status.SUCCESS);
    assertThat(compilation.generatedSourceFiles()).isNotEmpty();

    var restSource = compilation.generatedSourceFile(
        "io.casehub.platform.rest.generated.GeneratedSampleResource");
    assertThat(restSource).isPresent();
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=GraphQLResolverProcessorTest#roundEnvScanDiscoversLocalInterface`
Expected: FAIL — no generated source file found (RoundEnv scanning not yet implemented)

- [ ] **Step 3: Add TypeMirror helper methods**

Add these private methods to `GraphQLResolverProcessor`:

```java
private AnnotationMirror findAnnotationMirror(Element element, String annotationFqcn) {
    for (AnnotationMirror am : element.getAnnotationMirrors()) {
        if (am.getAnnotationType().toString().equals(annotationFqcn)) {
            return am;
        }
    }
    return null;
}

private String extractAnnotationStringValue(AnnotationMirror am) {
    for (var entry : am.getElementValues().entrySet()) {
        if (entry.getKey().getSimpleName().contentEquals("value")) {
            return entry.getValue().getValue().toString();
        }
    }
    return "";
}

private String typeMirrorToJava(javax.lang.model.type.TypeMirror type) {
    return switch (type.getKind()) {
        case VOID -> "void";
        case BOOLEAN -> "boolean";
        case BYTE -> "byte";
        case SHORT -> "short";
        case INT -> "int";
        case LONG -> "long";
        case FLOAT -> "float";
        case DOUBLE -> "double";
        case CHAR -> "char";
        case DECLARED -> {
            javax.lang.model.type.DeclaredType dt = (javax.lang.model.type.DeclaredType) type;
            String simple = ((javax.lang.model.element.TypeElement) dt.asElement()).getSimpleName().toString();
            if (dt.getTypeArguments().isEmpty()) {
                yield simple;
            }
            StringBuilder sb = new StringBuilder(simple).append("<");
            for (int i = 0; i < dt.getTypeArguments().size(); i++) {
                if (i > 0) sb.append(", ");
                sb.append(typeMirrorToJava(dt.getTypeArguments().get(i)));
            }
            sb.append(">");
            yield sb.toString();
        }
        case ARRAY -> typeMirrorToJava(((javax.lang.model.type.ArrayType) type).getComponentType()) + "[]";
        default -> type.toString();
    };
}

private void collectTypeMirrorImports(Set<String> imports, javax.lang.model.type.TypeMirror type) {
    if (type.getKind() == javax.lang.model.type.TypeKind.DECLARED) {
        javax.lang.model.type.DeclaredType dt = (javax.lang.model.type.DeclaredType) type;
        String fqcn = ((javax.lang.model.element.TypeElement) dt.asElement()).getQualifiedName().toString();
        if (!fqcn.startsWith("java.lang.") || fqcn.chars().filter(c -> c == '.').count() > 2) {
            imports.add(fqcn);
        }
        for (javax.lang.model.type.TypeMirror arg : dt.getTypeArguments()) {
            collectTypeMirrorImports(imports, arg);
        }
    } else if (type.getKind() == javax.lang.model.type.TypeKind.ARRAY) {
        collectTypeMirrorImports(imports, ((javax.lang.model.type.ArrayType) type).getComponentType());
    }
}

private boolean isSimpleTypeMirror(javax.lang.model.type.TypeMirror type) {
    if (type.getKind() != javax.lang.model.type.TypeKind.DECLARED) return false;
    String fqcn = ((javax.lang.model.element.TypeElement)
        ((javax.lang.model.type.DeclaredType) type).asElement()).getQualifiedName().toString();
    if (isSimpleType(fqcn, jandexIndex)) return true;
    javax.lang.model.element.Element element = ((javax.lang.model.type.DeclaredType) type).asElement();
    if (element.getKind() == javax.lang.model.element.ElementKind.ENUM) return true;
    for (javax.lang.model.element.Element enclosed : element.getEnclosedElements()) {
        if (enclosed.getKind() == javax.lang.model.element.ElementKind.METHOD) {
            javax.lang.model.element.ExecutableElement method =
                (javax.lang.model.element.ExecutableElement) enclosed;
            if (method.getModifiers().contains(javax.lang.model.element.Modifier.STATIC)
                && method.getParameters().size() == 1
                && method.getParameters().get(0).asType().toString().equals("java.lang.String")
                && (method.getSimpleName().contentEquals("fromString")
                    || method.getSimpleName().contentEquals("valueOf"))) {
                return true;
            }
        }
    }
    return false;
}
```

- [ ] **Step 4: Add scanRoundEnvironment method**

```java
private Map<String, DomainOperations> scanRoundEnvironment(RoundEnvironment roundEnv) {
    Map<String, DomainOperations> domains = new HashMap<>();

    Set<? extends javax.lang.model.element.Element> annotated;
    try {
        annotated = roundEnv.getElementsAnnotatedWith(
            io.casehub.platform.api.mcp.McpDomain.class);
    } catch (Exception e) {
        return domains;
    }

    for (javax.lang.model.element.Element element : annotated) {
        if (element.getKind() != javax.lang.model.element.ElementKind.INTERFACE) continue;
        javax.lang.model.element.TypeElement typeElement =
            (javax.lang.model.element.TypeElement) element;

        AnnotationMirror mcpAnn = findAnnotationMirror(element,
            "io.casehub.platform.api.mcp.McpDomain");
        if (mcpAnn == null) continue;
        String domain = extractAnnotationStringValue(mcpAnn);
        if (domain.isEmpty()) continue;

        DomainOperations ops = domains.computeIfAbsent(domain,
            d -> new DomainOperations(d, Source.ROUND_ENV));

        for (javax.lang.model.element.Element enclosed : typeElement.getEnclosedElements()) {
            if (enclosed.getKind() != javax.lang.model.element.ElementKind.METHOD) continue;
            javax.lang.model.element.ExecutableElement method =
                (javax.lang.model.element.ExecutableElement) enclosed;

            AnnotationMirror queryAnn = findAnnotationMirror(method,
                "io.casehub.platform.api.mcp.PlatformQuery");
            AnnotationMirror mutAnn = findAnnotationMirror(method,
                "io.casehub.platform.api.mcp.PlatformMutation");
            if (queryAnn == null && mutAnn == null) continue;

            OperationType opType = queryAnn != null ? OperationType.QUERY : OperationType.MUTATION;
            String desc = queryAnn != null
                ? extractAnnotationStringValue(queryAnn)
                : extractAnnotationStringValue(mutAnn);

            String restMethodOverride = null;
            AnnotationMirror restMethodAnn = findAnnotationMirror(method,
                "io.casehub.platform.api.mcp.RestMethod");
            if (restMethodAnn != null) {
                restMethodOverride = extractAnnotationStringValue(restMethodAnn);
            }

            String restPathOverride = null;
            AnnotationMirror restPathAnn = findAnnotationMirror(method,
                "io.casehub.platform.api.mcp.RestPath");
            if (restPathAnn != null) {
                restPathOverride = extractAnnotationStringValue(restPathAnn);
            }

            String returnTypeStr = typeMirrorToJava(method.getReturnType());
            Set<String> imports = new HashSet<>();
            collectTypeMirrorImports(imports, method.getReturnType());

            List<ResolvedParam> params = new ArrayList<>();
            for (var param : method.getParameters()) {
                String paramName = param.getSimpleName().toString();
                String typeStr = typeMirrorToJava(param.asType());
                String typeFqcn = param.asType().getKind() == javax.lang.model.type.TypeKind.DECLARED
                    ? ((javax.lang.model.element.TypeElement)
                        ((javax.lang.model.type.DeclaredType) param.asType()).asElement())
                        .getQualifiedName().toString()
                    : param.asType().toString();
                collectTypeMirrorImports(imports, param.asType());

                AnnotationMirror ppAnn = findAnnotationMirror(param,
                    "io.casehub.platform.api.mcp.PathParam");
                boolean isPathParam = ppAnn != null;
                String pathParamName = isPathParam ? extractAnnotationStringValue(ppAnn) : null;
                if (pathParamName != null && pathParamName.isEmpty()) pathParamName = null;

                boolean simple = isSimpleTypeMirror(param.asType());
                params.add(new ResolvedParam(paramName, typeStr, typeFqcn, isPathParam, pathParamName, simple));
            }

            String classFqcn = typeElement.getQualifiedName().toString();
            String classSimple = typeElement.getSimpleName().toString();
            imports.add(classFqcn);

            ops.operations.add(new ResolvedOperation(
                method.getSimpleName().toString(), returnTypeStr, params, imports,
                classFqcn, classSimple, opType, desc, restMethodOverride, restPathOverride));
        }
    }

    processingEnv.getMessager().printMessage(Diagnostic.Kind.NOTE,
        "GraphQL generator: RoundEnv scan found " + domains.size() + " domain(s)");
    return domains;
}
```

- [ ] **Step 5: Update process() to use both scanning paths**

Replace lines 59-99 of `process()`:

```java
@Override
public boolean process(Set<? extends TypeElement> annotations, RoundEnvironment roundEnv) {
    if (processed || roundEnv.processingOver()) {
        return false;
    }
    processed = true;

    IndexView index = loadCombinedIndex();
    this.jandexIndex = index;

    Set<String> graphqlSkipMethods = scanHandWrittenGraphQLMethods(index, roundEnv);
    Set<String> restSkipMethods = scanHandWrittenRestMethods(index, roundEnv);

    Map<String, DomainOperations> jandexDomains =
        index != null ? scanAnnotatedInterfaces(index) : new HashMap<>();
    Map<String, DomainOperations> roundEnvDomains = scanRoundEnvironment(roundEnv);

    Map<String, DomainOperations> allDomains = new HashMap<>(roundEnvDomains);
    allDomains.putAll(jandexDomains);

    if (allDomains.isEmpty()) {
        return false;
    }

    boolean generateGraphQL = !"false".equals(processingEnv.getOptions().get("generateGraphQL"));
    boolean generateRest = !"false".equals(processingEnv.getOptions().get("generateRest"));
    String domainFilter = processingEnv.getOptions().get("domainFilter");
    Set<String> allowedDomains = domainFilter != null
        ? java.util.Arrays.stream(domainFilter.split(",")).map(String::trim)
            .collect(java.util.stream.Collectors.toSet())
        : null;

    for (var entry : allDomains.entrySet()) {
        if (allowedDomains != null && !allowedDomains.contains(entry.getKey())) {
            continue;
        }
        if (generateGraphQL) {
            generateResolverSource(entry.getKey(), entry.getValue(), graphqlSkipMethods);
        }
        if (generateRest) {
            generateRestResourceSource(entry.getKey(), entry.getValue(), restSkipMethods);
        }
    }

    return false;
}
```

Note: `scanHandWrittenGraphQLMethods` and `scanHandWrittenRestMethods` still accept `IndexView` — they pass `null` safely when index is null.

- [ ] **Step 6: Update scanHandWrittenGraphQLMethods and scanHandWrittenRestMethods**

Update both methods to handle `null` index and add RoundEnvironment scanning:

```java
private Set<String> scanHandWrittenGraphQLMethods(IndexView index, RoundEnvironment roundEnv) {
    Set<String> methods = new HashSet<>();
    if (index != null) {
        for (AnnotationInstance ann : index.getAnnotations(GRAPHQL_API)) {
            if (ann.target().kind() != AnnotationTarget.Kind.CLASS) continue;
            ClassInfo classInfo = ann.target().asClass();
            AnnotationInstance mcpDomain = classInfo.annotation(MCP_DOMAIN);
            if (mcpDomain == null) continue;
            String domain = mcpDomain.value().asString();
            for (MethodInfo method : classInfo.methods()) {
                if (method.hasAnnotation(QUERY) || method.hasAnnotation(MUTATION)) {
                    methods.add(domain + ":" + method.name());
                }
            }
        }
    }
    // RoundEnv scan — uses string-based annotation lookup (GraphQLApi may not be on classpath)
    for (javax.lang.model.element.Element element : roundEnv.getRootElements()) {
        if (element.getKind() != javax.lang.model.element.ElementKind.CLASS) continue;
        AnnotationMirror graphqlApi = findAnnotationMirror(element,
            "org.eclipse.microprofile.graphql.GraphQLApi");
        if (graphqlApi == null) continue;
        AnnotationMirror mcpDomain = findAnnotationMirror(element,
            "io.casehub.platform.api.mcp.McpDomain");
        if (mcpDomain == null) continue;
        String domain = extractAnnotationStringValue(mcpDomain);
        for (javax.lang.model.element.Element enclosed : element.getEnclosedElements()) {
            if (enclosed.getKind() != javax.lang.model.element.ElementKind.METHOD) continue;
            if (findAnnotationMirror(enclosed, "org.eclipse.microprofile.graphql.Query") != null
                || findAnnotationMirror(enclosed, "org.eclipse.microprofile.graphql.Mutation") != null) {
                methods.add(domain + ":" + enclosed.getSimpleName().toString());
            }
        }
    }
    return methods;
}

private Set<String> scanHandWrittenRestMethods(IndexView index, RoundEnvironment roundEnv) {
    Set<String> methods = new HashSet<>();
    if (index != null) {
        for (AnnotationInstance pathAnn : index.getAnnotations(PATH)) {
            if (pathAnn.target().kind() != AnnotationTarget.Kind.CLASS) continue;
            ClassInfo classInfo = pathAnn.target().asClass();
            AnnotationInstance mcpDomain = classInfo.annotation(MCP_DOMAIN);
            if (mcpDomain == null) continue;
            String domain = mcpDomain.value().asString();
            for (MethodInfo method : classInfo.methods()) {
                if (method.hasAnnotation(JAX_GET) || method.hasAnnotation(JAX_POST)
                    || method.hasAnnotation(JAX_PUT) || method.hasAnnotation(JAX_DELETE)
                    || method.hasAnnotation(JAX_PATCH)) {
                    methods.add(domain + ":" + method.name());
                }
            }
        }
    }
    // RoundEnv scan
    for (javax.lang.model.element.Element element : roundEnv.getRootElements()) {
        if (element.getKind() != javax.lang.model.element.ElementKind.CLASS) continue;
        AnnotationMirror pathAnn = findAnnotationMirror(element, "jakarta.ws.rs.Path");
        if (pathAnn == null) continue;
        AnnotationMirror mcpDomain = findAnnotationMirror(element,
            "io.casehub.platform.api.mcp.McpDomain");
        if (mcpDomain == null) continue;
        String domain = extractAnnotationStringValue(mcpDomain);
        for (javax.lang.model.element.Element enclosed : element.getEnclosedElements()) {
            if (enclosed.getKind() != javax.lang.model.element.ElementKind.METHOD) continue;
            if (findAnnotationMirror(enclosed, "jakarta.ws.rs.GET") != null
                || findAnnotationMirror(enclosed, "jakarta.ws.rs.POST") != null
                || findAnnotationMirror(enclosed, "jakarta.ws.rs.PUT") != null
                || findAnnotationMirror(enclosed, "jakarta.ws.rs.DELETE") != null
                || findAnnotationMirror(enclosed, "jakarta.ws.rs.PATCH") != null) {
                methods.add(domain + ":" + enclosed.getSimpleName().toString());
            }
        }
    }
    return methods;
}
```

- [ ] **Step 7: Run integration test**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=GraphQLResolverProcessorTest#roundEnvScanDiscoversLocalInterface`
Expected: PASS — RoundEnv scanning discovers the interface and generates the REST resource

- [ ] **Step 8: Run all tests**

Run: `mvn --batch-mode test -pl graphql-generator`
Expected: all tests pass

- [ ] **Step 9: Commit**

```bash
git add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java
git commit -m "feat(#299): add RoundEnvironment scanning for consumer SPI discovery

Consumer @McpDomain interfaces in the current compilation unit are now
discovered via RoundEnvironment in addition to Jandex indexes from
dependency JARs. Null Jandex index no longer causes early return.
Jandex takes precedence on domain name conflict (per #296 D7).

Refs #299"
```

### Task 6: Add diagnostic logging, class name validation, and integration tests

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java` (process method)
- Modify: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java`

**Interfaces:**
- Consumes: all prior work
- Produces: diagnostic logging at every decision point, class name validation, comprehensive integration tests

- [ ] **Step 1: Write integration test — domainFilter excludes non-matching domains**

```java
@Test
void domainFilterExcludesNonMatchingDomains() {
    JavaFileObject spi = JavaFileObjects.forSourceString(
        "test.AlphaApi",
        """
        package test;
        import io.casehub.platform.api.mcp.McpDomain;
        import io.casehub.platform.api.mcp.PlatformQuery;

        @McpDomain("alpha")
        public interface AlphaApi {
            @PlatformQuery("Get alpha") String getAlpha();
        }
        """);

    JavaFileObject spi2 = JavaFileObjects.forSourceString(
        "test.BetaApi",
        """
        package test;
        import io.casehub.platform.api.mcp.McpDomain;
        import io.casehub.platform.api.mcp.PlatformQuery;

        @McpDomain("beta")
        public interface BetaApi {
            @PlatformQuery("Get beta") String getBeta();
        }
        """);

    var compilation = com.google.testing.compile.Compiler.javac()
        .withProcessors(new GraphQLResolverProcessor())
        .withOptions("-AdomainFilter=alpha", "-AgenerateGraphQL=false")
        .compile(spi, spi2);

    assertThat(compilation.status()).isEqualTo(
        com.google.testing.compile.Compilation.Status.SUCCESS);

    assertThat(compilation.generatedSourceFile(
        "io.casehub.platform.rest.generated.GeneratedAlphaResource")).isPresent();
    assertThat(compilation.generatedSourceFile(
        "io.casehub.platform.rest.generated.GeneratedBetaResource")).isEmpty();
    assertThat(compilation.generatedSourceFile(
        "io.casehub.platform.graphql.generated.GeneratedAlphaResolver")).isEmpty();
}
```

- [ ] **Step 2: Write integration test — generateGraphQL=false suppresses GraphQL**

```java
@Test
void generateGraphQLFalseSuppressesResolvers() {
    JavaFileObject spi = JavaFileObjects.forSourceString(
        "test.GammaApi",
        """
        package test;
        import io.casehub.platform.api.mcp.McpDomain;
        import io.casehub.platform.api.mcp.PlatformQuery;

        @McpDomain("gamma")
        public interface GammaApi {
            @PlatformQuery("Get gamma") String getGamma();
        }
        """);

    var compilation = com.google.testing.compile.Compiler.javac()
        .withProcessors(new GraphQLResolverProcessor())
        .withOptions("-AgenerateGraphQL=false")
        .compile(spi);

    assertThat(compilation.status()).isEqualTo(
        com.google.testing.compile.Compilation.Status.SUCCESS);
    assertThat(compilation.generatedSourceFile(
        "io.casehub.platform.graphql.generated.GeneratedGammaResolver")).isEmpty();
    assertThat(compilation.generatedSourceFile(
        "io.casehub.platform.rest.generated.GeneratedGammaResource")).isPresent();
}
```

- [ ] **Step 3: Write integration test — hyphenated domain produces valid class name**

```java
@Test
void hyphenatedDomainProducesValidClassName() {
    JavaFileObject spi = JavaFileObjects.forSourceString(
        "test.DeliveryChannelApi",
        """
        package test;
        import io.casehub.platform.api.mcp.McpDomain;
        import io.casehub.platform.api.mcp.PlatformQuery;
        import java.util.List;

        @McpDomain("delivery-channels")
        public interface DeliveryChannelApi {
            @PlatformQuery("List channels") List<String> listChannels();
        }
        """);

    var compilation = com.google.testing.compile.Compiler.javac()
        .withProcessors(new GraphQLResolverProcessor())
        .withOptions("-AgenerateGraphQL=false")
        .compile(spi);

    assertThat(compilation.status()).isEqualTo(
        com.google.testing.compile.Compilation.Status.SUCCESS);
    assertThat(compilation.generatedSourceFile(
        "io.casehub.platform.rest.generated.GeneratedDeliveryChannelsResource")).isPresent();
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl graphql-generator`
Expected: the domainFilter test may pass (filter logic exists); the others should pass too after Task 5. If all pass already, the tests validate existing behavior — move on.

- [ ] **Step 5: Add diagnostic logging to process()**

Insert after `processed = true;` and before scanning:

```java
processingEnv.getMessager().printMessage(Diagnostic.Kind.NOTE,
    "GraphQL generator: options received: " + processingEnv.getOptions());
```

After domain merging (after `allDomains.putAll(jandexDomains)`), add:

```java
for (var entry : allDomains.entrySet()) {
    processingEnv.getMessager().printMessage(Diagnostic.Kind.NOTE,
        "GraphQL generator: found domain '" + entry.getKey()
        + "' (" + entry.getValue().operations.size() + " operations)"
        + " [source: " + entry.getValue().source + "]");
}
```

After the generation loop, add zero-match warning and filter-absent advisory:

```java
if (allowedDomains != null) {
    long generatedCount = allDomains.keySet().stream()
        .filter(allowedDomains::contains).count();
    if (generatedCount == 0) {
        processingEnv.getMessager().printMessage(Diagnostic.Kind.WARNING,
            "GraphQL generator: domainFilter=" + domainFilter
            + " matched zero domains. Available domains: " + allDomains.keySet());
    }
} else if (allDomains.size() > 1) {
    processingEnv.getMessager().printMessage(Diagnostic.Kind.NOTE,
        "GraphQL generator: no domainFilter set — generating for all "
        + allDomains.size() + " domains. Set -AdomainFilter=... to restrict.");
}

if (!generateGraphQL) {
    processingEnv.getMessager().printMessage(Diagnostic.Kind.NOTE,
        "GraphQL generator: GraphQL resolver generation disabled (generateGraphQL=false)");
}
if (!generateRest) {
    processingEnv.getMessager().printMessage(Diagnostic.Kind.NOTE,
        "GraphQL generator: REST resource generation disabled (generateRest=false)");
}
```

Add filter skip logging inside the generation loop:

```java
if (allowedDomains != null && !allowedDomains.contains(entry.getKey())) {
    processingEnv.getMessager().printMessage(Diagnostic.Kind.NOTE,
        "GraphQL generator: skipping domain '" + entry.getKey()
        + "' — not in domainFilter");
    continue;
}
```

- [ ] **Step 6: Add class name validation guard**

In both `generateResolverSource` and `generateRestResourceSource`, after computing `className`:

```java
String className = "Generated" + toPascalCase(domain) + "Resolver";
if (!SourceVersion.isIdentifier(className)) {
    processingEnv.getMessager().printMessage(Diagnostic.Kind.ERROR,
        "GraphQL generator: domain '" + domain
        + "' produces invalid class name '" + className
        + "'. Domain names must contain only alphanumerics, hyphens, and slashes.");
    return;
}
```

Same guard in `generateRestResourceSource` with `"Resource"` suffix.

- [ ] **Step 7: Run all tests**

Run: `mvn --batch-mode test -pl graphql-generator`
Expected: all tests pass

- [ ] **Step 8: Run full build**

Run: `mvn --batch-mode install`
Expected: full build succeeds

- [ ] **Step 9: Commit**

```bash
git add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java
git commit -m "feat(#299): add diagnostic logging, class name validation, integration tests

- Log all APT options at NOTE level on process() entry
- Log each discovered domain with source (JANDEX/ROUND_ENV)
- Log filter decisions (skip/pass) for each domain
- WARNING when domainFilter matches zero domains
- NOTE when no filter set with multiple domains
- Class name validation guard after toPascalCase
- Integration tests: domainFilter, generateGraphQL flag, hyphenated domains

Refs #299"
```

---

## References

- [2026-09-15-graphql-generator-apt-fixes-design.md] — design spec this plan implements
- [GraphQLResolverProcessor.java:36-694] — full processor source
- [CallbackDecoratorProcessor.java:33] — @SupportedSourceVersion to fix
- [graphql-spring-generator/DomainDescriptor.java] — pattern for scan/gen decoupling
- [graphql-spring-generator/McpDomainScanner.java] — Jandex scanning abstraction
- [casehubio/platform#296 spec D7] — merge precedence (Jandex wins)
- [casehubio/platform#299] — focal issue
