# Context Slice — Execution Plan

**Status key:** `[ ]` pending · `[~]` in progress · `[x]` complete · `[!]` blocked

**Last updated:** 2026-02-24
**Derived from:** `TECHNICAL_IMPLEMENTATION.md` v0.1

---

## Table of Contents

- [Test Fixtures](#test-fixtures-required-before-phase-1)
- [Phase 0 — Project Scaffolding](#phase-0--project-scaffolding)
- [Phase 1 — Java Adapter: Static Analysis](#phase-1--java-adapter-static-analysis)
- [Phase 2 — ByteBuddy Agent](#phase-2--bytebuddy-agent)
- [Phase 3 — Java Adapter: Integration](#phase-3--java-adapter-integration)
- [Milestone 1 — Adapter Produces Valid IR](#-milestone-1--adapter-produces-valid-ir)
- [Phase 4 — Zig Core: Utility Layer](#phase-4--zig-core-utility-layer)
- [Phase 5 — Zig Core: IR Layer](#phase-5--zig-core-ir-layer)
- [Phase 6 — Zig Core: Graph Layer](#phase-6--zig-core-graph-layer)
- [Milestone 2 — IR-to-Graph Pipeline](#-milestone-2--ir-to-graph-pipeline)
- [Phase 7 — Zig Core: Compression Layer](#phase-7--zig-core-compression-layer)
- [Phase 8 — Zig Core: Packager Layer](#phase-8--zig-core-packager-layer)
- [Milestone 3 — Full Slice Pipeline](#-milestone-3--full-slice-pipeline)
- [Phase 9 — Zig Core: CLI Layer](#phase-9--zig-core-cli-layer)
- [Phase 10 — Zig Core: Orchestrator Layer](#phase-10--zig-core-orchestrator-layer)
- [Phase 11 — Zig Core: AI Integration Layer](#phase-11--zig-core-ai-integration-layer)
- [Milestone 4 — End-to-End Integration](#-milestone-4--end-to-end-integration)
- [Phase 12 — MVP Polish](#phase-12--mvp-polish)
- [Phase 13 — Data Transformation Capture](#phase-13--data-transformation-capture)
- [Milestone 5 — Transforms End-to-End](#-milestone-5--transforms-end-to-end)

---

## Test Fixtures (Required Before Phase 1)

These fixtures are shared across multiple phases. Create them before any implementation begins.

### TF-001: Minimal Spring Boot test project

**Location:** `test-fixtures/order-service/`

A self-contained, compilable Maven project with these classes:

```
OrderController.java       // @RestController; POST /orders calls OrderService
OrderService.java          // interface: createOrder(OrderRequest) : OrderResponse
StripeOrderService.java    // @Service impl of OrderService; calls PaymentService
PaymentService.java        // interface: charge(PaymentRequest) : PaymentResult
StripePaymentService.java  // @Service impl; reads order.payment.provider from env
OrderRequest.java          // simple POJO
OrderResponse.java         // simple POJO
PaymentRequest.java        // simple POJO
PaymentResult.java         // simple POJO
application.yml            // order.payment.provider=stripe
```

This fixture must:
- Compile with `mvn package -DskipTests`
- Be small enough that its full symbol list can be written out by hand for assertion
- Include one `@Transactional` annotation, one `@Autowired`, one `Environment.getProperty()` call
- Have at least one interface with two named implementations (only one active)

### TF-002: Hand-crafted IR JSON fixtures

**Location:** `test-fixtures/ir/`

Files:
- `static_ir.json` — written by hand, conforms to IR schema v0.1, represents the order-service fixture
- `runtime_trace.json` — represents a single execution of `POST /orders` through StripeOrderService
- `static_ir_malformed.json` — missing `ir_version`, has one symbol with null `file_id`
- `static_ir_wrong_version.json` — `ir_version: "99.0"`
- `static_ir_duplicate_symbols.json` — same symbol ID appears twice

The hand-crafted files must be verified by reading them and confirming they match expectations — they are the ground truth for all Zig IR layer tests.

### TF-003: Hand-crafted Slice fixture

**Location:** `test-fixtures/slice/`

Files:
- `expected_architecture.md` — the expected `architecture.md` output for the order-service scenario
- `expected_config_usage.md` — expected `config_usage.md` for the order-service scenario
- `expected_relevant_files.txt` — expected file paths in the slice

---

## Phase 0 — Project Scaffolding

### F-001: Initialize Zig project ✅

- *Files:* `context-slicer/build.zig`, `context-slicer/build.zig.zon`, `context-slicer/src/main.zig`
- *What to build:* Minimal Zig project that compiles to a binary, exits 0, prints nothing. Configure `build.zig` with test step. Set up module structure so all subsystem directories are recognized.
- *Tests:*
  - [x] `zig build` succeeds with no errors or warnings
  - [x] `zig build test` runs (0 test cases, 0 failures)
  - [x] Produced binary executes and exits 0

### F-002: Initialize Java adapter project ✅

- *Files:* `context-adapter-java/pom.xml`, `context-adapter-java/src/main/java/com/contextslice/adapter/AdapterMain.java`
- *What to build:* Maven project with `maven-assembly-plugin` configured for fat JAR. `AdapterMain.main()` prints `"context-adapter-java ok"` and exits 0. Add placeholders for all sub-packages.
- *Tests:*
  - [x] `mvn package -DskipTests` produces `target/context-adapter-java-0.1.0-jar-with-dependencies.jar`
  - [x] `java -jar target/context-adapter-java-*.jar` exits 0

### F-003: Initialize Java agent project ✅

- *Files:* `context-agent-java/pom.xml`, `context-agent-java/src/main/java/com/contextslice/agent/AgentBootstrap.java`
- *What to build:* Maven project configured to produce a JAR with `MANIFEST.MF` declaring `Premain-Class: com.contextslice.agent.AgentBootstrap`. `premain()` method exists but does nothing.
- *Tests:*
  - [x] `mvn package` succeeds
  - [x] `jar tf target/context-agent-java-*.jar | grep MANIFEST` confirms MANIFEST.MF present
  - [x] `unzip -p target/context-agent-java-*.jar META-INF/MANIFEST.MF | grep Premain-Class` prints the correct class name
  - [x] `java -javaagent:target/context-agent-java-*.jar -cp . com.example.Noop` does not crash (agent attaches, does nothing, JVM exits normally)

### F-004: Define IR schema v0.1 spec file ✅

- *Files:* `ir-schema/schema-v0.1.md` (or `ir-schema/examples/static_ir_example.json`)
- *What to build:* Canonical written definition of the IR schema. Not code — this is the contract document. Include: all required fields for MVP symbols, call edges, config reads, runtime block. Include the symbol ID convention string.
- *Tests:*
  - [x] `TF-002` hand-crafted fixtures validate against this spec by manual review
  - [x] All field names in spec match field names used in both the Java `IrModel.java` (Phase 1) and Zig `ir/types.zig` (Phase 5)

### F-005: Create test fixture TF-001 ✅

- *Files:* `test-fixtures/order-service/pom.xml` + all Java source files listed in TF-001
- *Tests:*
  - [x] `mvn package -DskipTests` succeeds from within `test-fixtures/order-service/`
  - [x] Produced JAR is a runnable Spring Boot app (even if it fails at startup without a DB — that's acceptable for fixture purposes)
  - [x] Symbol count is known and documented in a comment at the top of the fixture's README

### F-006: Create test fixtures TF-002 and TF-003 ✅

- *Files:* `test-fixtures/ir/static_ir.json` and friends, `test-fixtures/slice/expected_*.md`
- *Tests:*
  - [x] All JSON files parse without error using `jq .`
  - [x] `ir_version` field is `"0.1"` in all IR files
  - [x] Symbol IDs in `static_ir.json` follow the `java::<fqn>::<signature>` convention
  - [x] Every symbol referenced in `call_edges` exists in `symbols` array
  - [x] Every `file_id` referenced in `symbols` exists in `files` array

---

## Phase 1 — Java Adapter: Static Analysis

### SA-001: Add Eclipse JDT Core dependency ✅

- *Files:* `context-adapter-java/pom.xml`
- *What to build:* Add `org.eclipse.jdt:org.eclipse.jdt.core` dependency. Confirm it resolves and is included in the fat JAR.
- *Tests:*
  - [x] `mvn dependency:tree | grep jdt` shows the dependency
  - [x] `jar tf target/context-adapter-java-*.jar | grep jdt` confirms it's bundled

### SA-002: Implement `ManifestReader` ✅

- *Files:* `com/contextslice/adapter/manifest/ManifestReader.java`, `ManifestConfig.java`
- *What to build:* Deserialize `manifest.json` into `ManifestConfig` POJO using Gson. Handle missing optional fields gracefully (null or empty list, not exception).
- *Tests:*
  - [x] Round-trip test: write `ManifestConfig` to JSON, read it back, assert all fields equal
  - [x] Read known fixture manifest: assert `scenarioName`, `entryPoints`, `runArgs`, `configFiles`, `outputDir` match expected values
  - [x] Missing `runArgs` field in JSON → `ManifestConfig.runArgs` is empty list, not null
  - [x] File not found → throws `ManifestReadException` with clear message (not NPE)

### SA-003: Implement `SourceRootResolver` — Maven detection ✅

- *Files:* `com/contextslice/adapter/static_analysis/SourceRootResolver.java`
- *What to build:* Parse `pom.xml` in the given project root using Maven Model library. Extract `src/main/java` source root (absolute path). Collect classpath JAR paths from local Maven repository. Return `SourceRoots` record.
- *Tests:*
  - [x] Given `test-fixtures/order-service/` as project root, `sourceRoot` is the absolute path to `test-fixtures/order-service/src/main/java`
  - [x] `classpathJars` list is non-empty (contains at least `spring-core`, `spring-context` JARs)
  - [x] Project root with no `pom.xml` and no `build.gradle` → throws `UnsupportedBuildToolException`
  - [x] `pom.xml` with custom `<sourceDirectory>` → `sourceRoot` reflects the custom path

### SA-004: Implement `JdtAstParser` ✅

- *Files:* `com/contextslice/adapter/static_analysis/JdtAstParser.java`
- *What to build:* Initialize `ASTParser` with `setResolveBindings(true)`, `setBindingsRecovery(true)`, source roots, and classpath from `SourceRoots`. Parse a list of source files via `createASTs()`. Return a map of file path → `CompilationUnit`.
- *Tests:*
  - [x] Parse `OrderService.java` from fixture → returns non-null `CompilationUnit` with no parse errors (`cu.getProblems()` is empty or only warnings)
  - [x] Parse all 9 source files in fixture → all 9 `CompilationUnit` objects returned, no errors
  - [x] Type binding resolves across files: `StripeOrderService`'s `implements OrderService` binding is non-null and resolves to `OrderService` interface ITypeBinding
  - [x] Parse with intentional syntax error → `CompilationUnit.getProblems()` contains an ERROR-severity problem; parser does not throw exception

### SA-005: Implement `SymbolExtractor` ✅

- *Files:* `com/contextslice/adapter/static_analysis/SymbolExtractor.java`
- *What to build:* `ASTVisitor` subclass. `visit(TypeDeclaration)` emits `IrSymbol` of kind `class` or `interface`. `visit(MethodDeclaration)` emits `IrSymbol` of kind `method` or `constructor`. `visit(AnnotationTypeDeclaration)` ignored for MVP. Uses `SymbolIdGenerator` for IDs. Records `lineStart`, `lineEnd`, `visibility`, `container`, `annotations`.
- *Tests:*
  - [x] From `OrderService.java` (interface): emits exactly 1 symbol of kind `interface` with correct fully-qualified name
  - [x] From `StripeOrderService.java`: emits 1 class symbol + 1 method symbol (`createOrder`) with `container` pointing to the class symbol ID
  - [x] `createOrder` method annotated `@Transactional` → `annotations` list contains `"@Transactional"`
  - [x] `lineStart` and `lineEnd` are non-zero and `lineEnd >= lineStart`
  - [x] Private method → `visibility = "private"`; public method → `visibility = "public"`

### SA-006: Implement `CallEdgeExtractor` ✅

- *Files:* `com/contextslice/adapter/static_analysis/CallEdgeExtractor.java`
- *What to build:* `ASTVisitor` subclass. `visit(MethodInvocation)` resolves the `IMethodBinding`; extracts fully-qualified class name and method signature for callee; infers caller from the enclosing `MethodDeclaration`. Emits `IrCallEdge` with `static=true`, `runtimeObserved=false`, `callCount=0`.
- *Tests:*
  - [x] In `StripeOrderService.createOrder()`, the call to `paymentService.charge()` emits an edge with caller = `StripeOrderService::createOrder(...)` and callee resolving to `PaymentService::charge(...)` (or the concrete impl if binding resolves)
  - [x] Call to `Environment.getProperty()` emits an edge (will be filtered later but must be captured here)
  - [x] Static utility call (e.g. `Collections.emptyList()`) emits an edge
  - [x] Unresolvable binding (missing classpath entry) → edge is skipped with a warning logged, extractor does not throw

### SA-007: Implement `AnnotationProcessor` ✅

- *Files:* `com/contextslice/adapter/static_analysis/AnnotationProcessor.java`
- *What to build:* Takes a list of `IrSymbol` already constructed. For each, inspects annotation strings. Sets `isFramework=true` for symbols carrying any of the known Spring stereotype annotations. Also sets `isFramework=true` for symbols whose fully-qualified class name starts with `org.springframework`.
- *Tests:*
  - [x] `StripeOrderService` annotated `@Service` → class symbol has `isFramework=true`
  - [x] `createOrder` method with `@Transactional` → method symbol has `isFramework=false` (the method itself is not a framework class — only the annotation is recorded)
  - [x] `OrderController` with `@RestController` → `isFramework=true`
  - [x] `OrderRequest` POJO with no Spring annotations → `isFramework=false`
  - [x] A class in package `org.springframework.web` → `isFramework=true` regardless of annotations

### SA-008: Implement `SymbolIdGenerator` ✅

- *Files:* `com/contextslice/adapter/static_analysis/SymbolIdGenerator.java`
- *What to build:* Static utility. Produces IDs of the form `java::<fully-qualified-class-name>::<method-name>(<param-types>)` for methods, `java::<fully-qualified-class-name>` for classes/interfaces.
- *Tests:*
  - [x] `OrderService` interface → `java::com.contextslice.fixture.OrderService`
  - [x] `createOrder(OrderRequest)` method on `StripeOrderService` → `java::com.contextslice.fixture.StripeOrderService::createOrder(OrderRequest)`
  - [x] Same method invoked twice → identical ID (determinism test)
  - [x] Method with multiple parameters → params appear comma-separated, simple names (not fully-qualified) for MVP
  - [x] Constructor → kind `constructor`, ID uses `<init>` as method name

### SA-009: Integrate into `StaticAnalyzer` ✅

- *Files:* `com/contextslice/adapter/static_analysis/StaticAnalyzer.java`
- *What to build:* Orchestrates `SourceRootResolver` → `JdtAstParser` → `SymbolExtractor` → `CallEdgeExtractor` → `AnnotationProcessor`. Returns `StaticIr` aggregate (symbols + call edges).
- *Tests:*
  - [x] Run against `test-fixtures/order-service/`: symbol count equals the hand-documented expected count from TF-001
  - [x] All interface symbols present; all method symbols have non-null `container`
  - [x] Call edge from `OrderController.createOrder()` → `OrderService.createOrder()` is present
  - [x] Call edge from `StripeOrderService.createOrder()` → `PaymentService.charge()` is present
  - [x] No symbol has a null or empty `id`
  - [x] No call edge has a null `caller` or `callee`

---

## Phase 2 — ByteBuddy Agent

### BA-001: Add ByteBuddy dependency to agent project ✅

- *Files:* `context-agent-java/pom.xml`
- *What to build:* Add `net.bytebuddy:byte-buddy-agent` and `net.bytebuddy:byte-buddy` dependencies. Configure fat JAR. Confirm the MANIFEST.MF still has `Premain-Class`.
- *Tests:*
  - [x] `mvn package` succeeds
  - [x] `jar tf` shows ByteBuddy classes bundled
  - [x] Agent still attaches to a blank JVM without exception

### BA-002: Implement `RuntimeTracer` — core data structures ✅

- *Files:* `com/contextslice/agent/RuntimeTracer.java`
- *What to build:* Static class. `ThreadLocal<Deque<String>> stack`. `ConcurrentHashMap<String, LongAdder> methodCounts`. `ConcurrentHashMap<EdgeKey, LongAdder> edgeCounts` (record key). `ConcurrentHashMap<String, ConcurrentHashMap<String, String>> configReads` (nested map avoids :: collision). Static methods: `push(id)`, `pop()`, `peek()` → nullable String, `recordEdge(caller, callee)`, `recordConfig(symbolId, key, value)`.
- *Tests:*
  - [x] Single-thread: `push("A")`, `push("B")`, `peek()` returns `"B"`, `pop()`, `peek()` returns `"A"`, `pop()`, `peek()` returns null
  - [x] `recordEdge("A", "B")` increments `edgeCounts[EdgeKey(A,B)]` to 1; called again → 2
  - [x] `recordConfig("A", "key", "val")` → `configReads["A"]["key"] = "val"`
  - [x] Two threads push independently: each thread's stack is isolated (Thread 1 pushes "X", Thread 2 peeks → null)
  - [x] 50 threads each calling `recordEdge` on the same edge concurrently → final count = 50 (no races)
  - [x] Empty stack pop does not throw

### BA-003: Implement `MethodAdvice` ✅

- *Files:* `com/contextslice/agent/MethodAdvice.java`
- *What to build:* `@Advice.OnMethodEnter`: read `@Advice.Origin("#t::#m")` string, call `RuntimeTracer.recordEdge(RuntimeTracer.peek(), symbol)`, call `RuntimeTracer.push(symbol)`. `@Advice.OnMethodExit(onThrowable = Throwable.class)`: call `RuntimeTracer.pop()`. Must handle null caller (entry point — first method on the stack) without throwing.
- *Tests:*
  - [x] Manually call `onEnter("com.example.Foo::bar")` with empty stack: `methodCounts["com.example.Foo::bar"]` = 1, `edgeCounts` unchanged (null caller edge not recorded)
  - [x] Call `onEnter("A")` then `onEnter("B")`: `edgeCounts[EdgeKey(A,B)]` = 1
  - [x] Call `onEnter("A")`, `onEnter("B")`, `onExit("B")`, `onEnter("C")`: `edgeCounts[EdgeKey(A,C)]` = 1
  - [x] Exception path: `onExit` called from `onThrowable` branch → stack still pops correctly

### BA-004: Implement `ConfigAdvice` ✅

- *Files:* `com/contextslice/agent/ConfigAdvice.java`
- *What to build:* `@Advice.OnMethodExit` on `getProperty(String)`. Reads `@Advice.Argument(0)` (the key) and `@Advice.Return` (the value string). Calls `RuntimeTracer.recordConfig(RuntimeTracer.peek(), key, value)`. Handles null return value (property not set) — records `"<unset>"`.
- *Tests:*
  - [x] With "A" on stack, key="order.provider", value="stripe" → `configReads["A"]["order.provider"] = "stripe"`
  - [x] Null return value → records `"<unset>"`
  - [x] Called with empty stack → records against null symbolId (skips — null symbolId check)

### BA-005: Implement `AgentBootstrap` — type matchers and `AgentBuilder` setup ✅

- *Files:* `com/contextslice/agent/AgentBootstrap.java`
- *What to build:* `premain(String args, Instrumentation inst)`. Parse `args` to extract output path and namespace. Configure `AgentBuilder.Default()` with namespace prefix matcher and proxy/CGLIB exclusions. Install `MethodAdvice` on all non-abstract methods. Install `ConfigAdvice` on `AbstractEnvironment.getProperty`. Call `installOn(inst)`.
- *Tests:*
  - [x] Type matcher accepts `com.company.OrderService` → true
  - [x] Type matcher rejects `com.company.OrderService$$EnhancerBySpringCGLIB$$abc123` → false
  - [x] Type matcher rejects `com.company.$Proxy12` → false
  - [x] Type matcher rejects `org.springframework.anything` (not in namespace) → false
  - [x] parseArgs parses `output=` and `namespace=` correctly

### BA-006: Implement `ShutdownHook` and `RuntimeTrace` serialization ✅

- *Files:* `com/contextslice/agent/ShutdownHook.java`, `RuntimeTrace.java`
- *What to build:* `ShutdownHook implements Runnable`. Reads from `RuntimeTracer` maps. Builds `RuntimeTrace` POJO with observed symbols, edges, config reads. Serializes to `runtime_trace.json`. Registered in `AgentBootstrap`.
- *Tests:*
  - [x] Populate `RuntimeTracer` with 3 method counts, 2 edge counts, 1 config read; trigger `ShutdownHook.run()` directly; assert `runtime_trace.json` exists and is valid JSON
  - [x] `observedSymbols` length = 3; correct `symbolId` and `callCount` values
  - [x] `observedEdges` length = 2; correct `caller`, `callee`, `callCount`
  - [x] `configReads` length = 1; correct `symbolId`, `configKey`, `resolvedValue`
  - [x] Determinism: same `RuntimeTracer` state → identical JSON output (arrays sorted by symbol ID)
  - [x] Output path directory does not exist → `ShutdownHook` creates it before writing (does not throw)

### BA-007: Integration test — agent on a live test target ✅

- *What to test:* Full agent attach and data capture on a real (minimal) Spring Boot app.
- *Tests:*
  - [x] Launch `test-fixtures/order-service` JAR with `-javaagent:context-agent-java.jar=output=/tmp/cs-ba007`
  - [x] Make a single `POST /orders` HTTP call to the running app (HTTP 200 confirmed)
  - [x] Graceful shutdown (SIGTERM) triggers the shutdown hook
  - [x] `runtime_trace.json` exists in `/tmp/cs-ba007`
  - [x] `observedSymbols` contains `StripeOrderService::createOrder` and `StripePaymentService::charge`
  - [x] `observedSymbols` does NOT contain `$$EnhancerBySpring` class names
  - [x] `configReads` contains an entry for `order.payment.provider` with value `"stripe"`
  - [x] `callCount` for `createOrder` is exactly 1

---

## Phase 3 — Java Adapter: Integration

### JA-001: Implement `BuildRunner` ✅

- *Files:* `com/contextslice/adapter/build/BuildRunner.java`
- *What to build:* Detects whether project uses Maven or Gradle (presence of `pom.xml` vs `build.gradle`). Invokes the build via `ProcessBuilder`. Streams stdout/stderr to the adapter's own stderr. Locates the produced JAR (largest, excludes -sources/-tests/original-). Returns absolute path to JAR.
- *Tests:*
  - [x] Run against `test-fixtures/order-service/` → succeeds, returns a path ending in `.jar` that exists on disk
  - [x] Non-existent project root → throws `BuildException` with clear message
  - [x] Directory with no build file → `BuildException`
  - [x] JAR path returned is not a sources or original JAR

### JA-002: Implement `AgentLauncher` ✅

- *Files:* `com/contextslice/adapter/runtime/AgentLauncher.java`
- *What to build:* Constructs the command `java -javaagent:<agentJar>=output=<outputDir>,namespace=<ns> -jar <appJar> <runArgs...>`. Launches via `ProcessBuilder`. Waits for process exit (120s timeout). Reads `runtime_trace.json`. Returns deserialized `RuntimeTrace`.
- *Tests:*
  - [x] Tested end-to-end via BA-007 integration test (agent attaches, runtime_trace.json produced)
  - [x] Non-zero exit → `AgentLaunchException` with exit code in message
  - [x] Missing runtime_trace.json → `AgentLaunchException`
  - [x] Timeout → process forcibly killed, `AgentLaunchException`

### JA-003: Implement Java `IrModel` POJOs ✅

- *Files:* `com/contextslice/adapter/ir/IrModel.java`, `RuntimeTrace.java`
- *What to build:* POJOs matching IR schema v0.1 exactly with `@SerializedName` snake_case mapping. Also `RuntimeTrace` POJO for agent output.
- *Tests:*
  - [x] IrSerializer round-trips IrRoot correctly (verified in IrSerializerTest)
  - [x] RuntimeTrace deserialized correctly in ShutdownHookTest (agent project)
  - [x] All IrSymbol fields accessible after deserialization

### JA-004: Implement `IrMerger` ✅

- *Files:* `com/contextslice/adapter/ir/IrMerger.java`
- *What to build:* Merges StaticIr + RuntimeTrace into IrRoot. Annotates call edges with runtime counts. Deduplicates symbols. Includes config reads from runtime trace.
- *Tests:*
  - [x] Static edge not in runtime → `runtimeObserved=false, callCount=0`
  - [x] Static edge in runtime with count=3 → `runtimeObserved=true, callCount=3`
  - [x] Duplicate symbol IDs → deduplicated (first wins)
  - [x] Runtime symbol not in static → logged, excluded from output
  - [x] Edge with unknown caller/callee → excluded
  - [x] Config reads from runtime included in merged output

### JA-005: Implement `IrSerializer` ✅

- *Files:* `com/contextslice/adapter/ir/IrSerializer.java`
- *What to build:* Copies arrays to mutable lists, sorts by ID, writes `static_ir.json` and `metadata.json` with pretty-printing.
- *Tests:*
  - [x] Symbols sorted lexicographically by id field
  - [x] Call edges sorted by caller then callee
  - [x] Deterministic: two runs produce identical output
  - [x] metadata.json contains scenarioName, language, adapterVersion, timestamp
  - [x] Output is valid parseable JSON
  - [x] Output dir created if absent

### JA-006: Implement `AdapterMain` — end-to-end orchestration ✅

- *Files:* `com/contextslice/adapter/AdapterMain.java`
- *What to build:* Parses `--manifest`, `--output`, `--agent`, `--namespace` flags. Orchestrates ManifestReader → StaticAnalyzer → BuildRunner → AgentLauncher → IrMerger → IrSerializer. Exits 0 on success, non-zero on error.
- *Tests:*
  - [x] No args → UsageException
  - [x] Unknown subcommand → UsageException
  - [x] Missing --manifest → UsageException
  - [x] Missing --output → UsageException
  - [x] Missing --agent → UsageException
  - [x] Unknown flag → UsageException

---

## ✦ Milestone 1 — Adapter Produces Valid IR

**Gate:** All Phase 0, 1, 2, 3 tasks complete. All tests passing.

### What to test at this checkpoint

**M1-T001: Full adapter run on test fixture** ✅
- [x] Run: `java -jar context-adapter-java.jar record --manifest test-fixtures/order-service/manifest.json --output /tmp/cs-m1-test/`
- [x] Exit code is 0
- [x] `static_ir.json` exists and is valid JSON (38 symbols, 13 edges)
- [x] `runtime_trace.json` exists in runtime/ subdirectory (13 observed symbols)
- [x] `metadata.json` exists and is valid JSON

**M1-T002: IR schema conformance** ✅
- [x] `static_ir.json` `ir_version` = `"0.1"`
- [x] All symbols have non-empty `id`, `kind`, `name`, `file_id`
- [x] All `file_id` references in `symbols` exist in the `files` array
- [x] All `caller` and `callee` IDs in `call_edges` exist in the `symbols` array

**M1-T003: Correct content** ✅
- [x] Symbol `java::com.contextslice.fixture.StripeOrderService::createOrder(OrderRequest)` is present
- [x] Call edge from `OrderController` → `OrderService.createOrder()` is present with `static=true`
- [x] Call edge from `StripeOrderService.createOrder()` → `StripePaymentService.charge()` is present with `runtimeObserved=true` and `callCount=1`
- [x] `configReads` contains an entry for `order.payment.provider` with value `"stripe"`
- [x] `StripeOrderService` class symbol has `isFramework=true` (carries `@Service`)

**M1-T004: Determinism** ✅
- [x] Run adapter twice on the same fixture; symbol IDs and call edges are identical across runs

**M1-T005: Noise filtering** ✅
- [x] No symbol ID in `static_ir.json` contains `$$EnhancerBySpring` or `$Proxy`
- [x] No CGLIB proxy symbols present

### Pass criteria
All M1 tests pass. Adapter output is considered the stable ground truth for all subsequent Zig layer testing. The hand-crafted `test-fixtures/ir/static_ir.json` must be updated to match the real adapter output if any discrepancies are found.

---

## Phase 4 — Zig Core: Utility Layer

### U-001: Implement `util/fs.zig` ✅

- *Files:* `context-slicer/src/util/fs.zig`
- *What to build:* `createDirIfAbsent(path)`, `readFileAlloc(path, allocator) []u8`, `writeFile(path, content)`, `joinPath(allocator, parts...) []u8`, `fileExists(path) bool`.
- *Tests:*
  - [x] `createDirIfAbsent` on an existing dir → no error
  - [x] `createDirIfAbsent` on a new dir → dir exists afterwards
  - [x] `readFileAlloc` on a known file → correct bytes returned
  - [x] `readFileAlloc` on nonexistent file → returns error, not segfault
  - [x] `writeFile` + `readFileAlloc` round-trip → contents identical
  - [x] `joinPath` with 3 segments → correct OS-native path separator

### U-002: Implement `util/json.zig` ✅

- *Files:* `context-slicer/src/util/json.zig`
- *What to build:* Thin wrappers over `std.json`. `parseFileAlloc(path, allocator)`, `parseTypedFromFile(T, path, allocator)`, `parseTypedFromSlice(T, data, allocator)`, `writeToFile(value, path, allocator)`. Uses `alloc_always` to ensure strings are copied into arena (safe to free source buffer).
- *Tests:*
  - [x] Parse known JSON file → succeeds, root is Object
  - [x] Parse malformed JSON → returns `error.SyntaxError`, not panic
  - [x] Round-trip: write struct → parse back → all fields equal
  - [x] `parseTypedFromSlice` ignores unknown fields

### U-003: Implement `util/hash.zig` ✅

- *Files:* `context-slicer/src/util/hash.zig`
- *What to build:* `sha256File(path, allocator) [64]u8` — returns hex SHA-256. `sha256Bytes(data) [64]u8`.
- *Tests:*
  - [x] `sha256Bytes("")` = known SHA-256 of empty string
  - [x] `sha256Bytes("hello")` = known SHA-256 of "hello"
  - [x] Same file → same hash (determinism)
  - [x] Two different files → different hashes

---

## Phase 5 — Zig Core: IR Layer ✅

### IR-001: Define `ir/types.zig` ✅

- *Files:* `context-slicer/src/ir/types.zig`
- *What to build:* Zig structs mirroring every field from IR schema v0.1. `IrFile`, `Symbol`, `SymbolKind` (enum), `CallEdge`, `ConfigRead`, `RuntimeEntry`, `IrRoot`. All string fields are `[]const u8`. All optional fields are `?T`. All list fields are `[]const T`.
- *Tests:*
  - [x] `zig build` compiles with all types defined — no errors
  - [x] Can construct an `IrRoot` with all fields in a test function
  - [x] `SymbolKind` enum covers `.class`, `.method`, `.constructor`, `.interface`

### IR-002: Implement `ir/loader.zig` ✅

- *Files:* `context-slicer/src/ir/loader.zig`
- *What to build:* `loadStatic(path, allocator) IrRoot` — reads and parses `static_ir.json`. `loadRuntime(path, allocator) RuntimeTrace` — reads and parses `runtime_trace.json`. Both use `util/json.zig`. Field mapping must handle both camelCase and snake_case keys (match the actual adapter output format).
- *Tests:*
  - [x] Load `test-fixtures/ir/static_ir.json` → `IrRoot.irVersion = "0.1"`, `IrRoot.language = "java"`
  - [x] `IrRoot.symbols` has the expected count from TF-001
  - [x] First symbol has non-empty `id`, `kind`, `fileId`
  - [x] `IrRoot.callEdges` non-empty
  - [x] Load `test-fixtures/ir/runtime_trace.json` → `RuntimeTrace.observedSymbols` non-empty
  - [x] File not found → returns `error.FileNotFound` with path in context, not panic
  - [x] Malformed JSON → returns `error.ParseFailure`, not panic

### IR-003: Implement `ir/validator.zig` ✅

- *Files:* `context-slicer/src/ir/validator.zig`
- *What to build:* `validate(ir: IrRoot) ValidationResult`. Checks: `ir_version` against `SUPPORTED_IR_VERSION = "0.1"`; all `symbol.file_id` values exist in `files` set; all `call_edge.caller/callee` values exist in `symbols` set. Returns `ValidatedIr` (clean symbols only) plus a list of `ValidationWarning` for quarantined entries.
- *Tests:*
  - [x] Valid `test-fixtures/ir/static_ir.json` → 0 warnings, all symbols pass
  - [x] `static_ir_wrong_version.json` → returns `error.IncompatibleIrVersion`
  - [x] `static_ir_malformed.json` (symbol with null `file_id`) → that symbol is quarantined, appears in `warnings`, valid symbols still returned
  - [x] Call edge referencing a non-existent symbol ID → edge is quarantined, warning emitted, remaining edges returned

### IR-004: Implement `ir/merger.zig` ✅

- *Files:* `context-slicer/src/ir/merger.zig`
- *What to build:* `merge(static_ir: ValidatedIr, runtime: RuntimeTrace, allocator) MergedIr`. Builds a `StringHashMap` of symbol ID → runtime `callCount`. For each `CallEdge` in static IR, looks up if the `caller→callee` pair was observed at runtime; sets `runtimeObserved` and `callCount`. Deduplicates symbols (by ID, first wins). Includes `configReads` from runtime trace.
- *Tests:*
  - [x] Static edge A→B not in runtime → `runtimeObserved=false`, `callCount=0`
  - [x] Static edge A→B in runtime with count=5 → `runtimeObserved=true`, `callCount=5`
  - [x] Duplicate symbol in static → `MergedIr.symbols` has unique IDs only
  - [x] Config reads from runtime appended to `MergedIr.configReads`
  - [x] Symbol not observed at runtime → still present in `MergedIr.symbols` (static is the source of truth for symbols)
  - [x] Merge of `test-fixtures/ir/static_ir.json` + `runtime_trace.json` → `StripePaymentService.charge` edge has `runtimeObserved=true`

---

## Phase 6 — Zig Core: Graph Layer ✅

### GR-001: Implement `graph/graph.zig` ✅

- *Files:* `context-slicer/src/graph/graph.zig`
- *What to build:* `Graph` struct. `nodes: StringHashMap(Symbol)`. `outEdges: StringHashMap(ArrayList(Edge))` (caller → list of edges). `fileMap: StringHashMap([]const u8)` (symbol_id → file_path). Methods: `addNode()`, `addEdge()`, `getOutEdges(symbolId)`, `getNode(symbolId)`, `nodeCount()`, `edgeCount()`.
- *Tests:*
  - [x] `addNode` then `getNode` → same symbol returned
  - [x] `addEdge(A, B, meta)` → `getOutEdges(A)` contains one edge pointing to B
  - [x] `addEdge(A, B)` then `addEdge(A, C)` → `getOutEdges(A)` has 2 entries
  - [x] `getOutEdges` for unknown node → returns empty slice, not panic
  - [x] `nodeCount()` and `edgeCount()` accurate after multiple adds
  - [x] Adding the same node ID twice → second add is a no-op (no duplicate)

### GR-002: Implement `graph/builder.zig` ✅

- *Files:* `context-slicer/src/graph/builder.zig`
- *What to build:* `build(ir: MergedIr, allocator) Graph`. Iterates symbols → `addNode`. Iterates call edges → `addEdge` with `EdgeMeta{callCount, runtimeObserved, static}`. Populates `fileMap` from `ir.files` lookup for each symbol.
- *Tests:*
  - [x] Build from `test-fixtures` merged IR → `nodeCount()` equals merged symbol count
  - [x] `edgeCount()` equals merged call edge count
  - [x] `fileMap` entry for `StripeOrderService.createOrder` points to the correct relative path
  - [x] Edge from `OrderController → OrderService.createOrder` has `static=true, runtimeObserved=false` (interface call — static only)
  - [x] Edge from `StripeOrderService.createOrder → StripePaymentService.charge` has `runtimeObserved=true`

### GR-003: Implement `graph/traversal.zig` ✅

- *Files:* `context-slicer/src/graph/traversal.zig`
- *What to build:* `hotPath(graph: Graph, allocator) []Symbol` — returns all symbols where any inbound or outbound edge has `callCount > 0`, sorted descending by `callCount`. `bfsFrom(graph, startId, allocator) [][]const u8` — BFS returning reachable symbol IDs in order. `dfsFrom(graph, startId, allocator) [][]const u8` — DFS.
- *Tests:*
  - [x] `hotPath` on graph with edges with callCount>0 → returns those symbols sorted desc
  - [x] `hotPath` on graph with no runtime edges → returns empty slice
  - [x] `bfsFrom` on a 3-node chain A→B→C from A → returns [A, B, C] in BFS order
  - [x] `bfsFrom` with a cycle (A→B→A) → terminates, each node appears once
  - [x] `bfsFrom` with disconnected node D → D not in result (not reachable from A)

### GR-004: Implement `graph/expansion.zig` ✅

- *Files:* `context-slicer/src/graph/expansion.zig`
- *What to build:* `expand(graph: Graph, hotPath: []Symbol, allocator) ExpandedGraph`. Radius-1: for each hot path node, add all direct out-neighbors and in-neighbors not already in the hot path set. Interface resolution: if a hot path edge calls an interface symbol, find all other nodes in the graph that have `kind=.class` and whose static edges include that interface as callee — add them. Config expansion: for each `ConfigRead` in IR where the symbol is in the hot path, mark the config source file for inclusion.
- *Tests:*
  - [x] Hot path = [B]; graph has A→B→C→D; after radius-1 expansion: [A, B, C] included, D not included
  - [x] `OrderService` interface in hot path → both `StripeOrderService` and any other impl added to expanded set
  - [x] Config read associated with a hot path symbol → that config file path included in `expandedConfigFiles`
  - [x] Node already in hot path is not duplicated in expansion result
  - [x] Empty hot path → expanded set is empty

---

## ✦ Milestone 2 — IR-to-Graph Pipeline ✅

**Gate:** All Phase 4, 5, 6 tasks complete and passing.

### What to test at this checkpoint

**M2-T001: Load real adapter output into graph** ✅
- [x] Load the `static_ir.json` + `runtime_trace.json` produced at Milestone 1
- [x] IR Loader succeeds
- [x] IR Validator passes with 0 warnings on real output
- [x] IR Merger produces merged IR with correct runtime annotations (7 merged edges including 2 runtime-only)
- [x] Graph Builder produces a graph with correct node and edge counts

**M2-T002: Hot path correctness** ✅
- [x] `hotPath()` on the graph from the order-service scenario returns `StripeOrderService.createOrder` and `StripePaymentService.charge`
- [x] `hotPath()` does NOT return `OrderService` interface (only called statically, no runtime edges)

**M2-T003: Expansion correctness** ✅
- [x] After expansion, `OrderService` interface IS included (added by interface resolution from the hot path)
- [x] `OrderController.createOrder` IS included (radius-1: direct caller of hot path entry)
- [x] `OrderServiceApplication` (@SpringBootApplication with no edges) is NOT included

**M2-T004: Framework noise** ✅
- [x] `OrderServiceApplication` (unrelated @SpringBootApplication) not in expanded set

### Pass criteria ✅
Given real adapter output from Milestone 1, the graph pipeline produces the correct hot path and an expanded set that includes exactly the logically relevant symbols for the `submit-order` scenario.

---

## Phase 7 — Zig Core: Compression Layer ✅

### CM-001: Implement `compression/filter.zig` ✅

- *Files:* `context-slicer/src/compression/filter.zig`
- *What to build:* `applyFrameworkFilter(graph: ExpandedGraph) FilteredGraph` — removes all nodes where `symbol.isFramework=true` unless the node was explicitly added to the expansion set via interface resolution (these are tagged). `applyEdgeFilter(graph, minCallCount: u64) FilteredGraph` — removes edges where `callCount < minCallCount`.
- *Tests:*
  - [x] Node with `isFramework=true` not in expansion set → removed
  - [x] Node with `isFramework=true` that IS in expansion set → kept
  - [x] Edge with `callCount=0, runtimeObserved=false` with `minCallCount=1` → removed
  - [x] Edge with `callCount=3, runtimeObserved=true` → kept
  - [x] Removing a node also removes all edges to/from that node

### CM-002: Implement `compression/dedup.zig` ✅

- *Files:* `context-slicer/src/compression/dedup.zig`
- *What to build:* `deduplicateEdges(edges: []CallEdge) []CallEdge` — merges multiple edges between the same caller/callee into one. `collapseRecursion` — removes back-edges of 2-node cycles.
- *Tests:*
  - [x] Two edges A→B with counts 3 and 2 → one edge with count 5, `runtimeObserved=true`
  - [x] A→B (runtimeObserved=false) + A→B (runtimeObserved=true) → merged with `runtimeObserved=true`
  - [x] Graph with A→B→A cycle → `collapseRecursion` terminates and removes the B→A back-edge
  - [x] No duplicates or cycles → output identical to input

### CM-003: Implement `compression/compressor.zig` ✅

- *Files:* `context-slicer/src/compression/compressor.zig`
- *What to build:* `compress(graph: ExpandedGraph, ir: MergedIr, allocator) Slice`. Orchestrates: filter → dedup → topological sort. Builds `Slice`: `orderedSymbols`, `relevantFilePaths`, `configInfluences`, `callGraphEdges`.
- *Tests:*
  - [x] `orderedSymbols` contains entry point (`OrderController.createOrder`)
  - [x] `relevantFilePaths` does not contain duplicates
  - [x] `configInfluences` for `order.payment.provider` lists `StripePaymentService` as influenced
  - [x] Compress on the order-service fixture produces ≤ 8 unique file paths (proving tight slicing)
  - [x] `call_graph_edges` present after compress

---

## Phase 8 — Zig Core: Packager Layer

### PK-001: Implement `packager/architecture_writer.zig` ✅

- *Files:* `context-slicer/src/packager/architecture_writer.zig`
- *Tests:*
  - [x] Output file `architecture.md` exists after `write()`
  - [x] File starts with `# Architecture:` header
  - [x] `StripeOrderService.createOrder` appears in the file

### PK-002: Implement `packager/config_writer.zig` ✅

- *Files:* `context-slicer/src/packager/config_writer.zig`
- *Tests:*
  - [x] Output file `config_usage.md` exists after `write()`
  - [x] Contains a Markdown table with the correct headers
  - [x] Row for `order.payment.provider` with value `stripe` present
  - [x] Empty `configInfluences` → file still written with header + empty table body (not skipped)

### PK-003: Implement `packager/packager.zig` ✅

- *Files:* `context-slicer/src/packager/packager.zig`
- *Tests:*
  - [x] After `pack()`, all 5 files exist: `architecture.md`, `config_usage.md`, `relevant_files.txt`, `call_graph.json`, `metadata.json`
  - [x] `relevant_files.txt` has no duplicate lines
  - [x] `call_graph.json` is valid JSON with a `edges` array
  - [x] `metadata.json` contains `scenarioName`, `timestamp`, `language`
  - [x] `pack()` called twice on same output dir → overwrites without error (idempotent)

---

## ✦ Milestone 3 — Full Slice Pipeline (Adapter Output → Packaged Slice) ✅

**Gate:** All Phase 4–8 tasks complete and passing.

### What to test at this checkpoint

**M3-T001: Full pipeline on real adapter output (no CLI yet)** ✅
- [x] Load `static_ir.json` + `runtime_trace.json` from Milestone 1 output
- [x] Run IR Loader → Validator → Merger → Graph Builder → Traversal → Expansion → Compression → Packager
- [x] All 5 output files written to a temp directory

**M3-T002: Slice quality for the order-service scenario** ✅
- [x] `relevant_files.txt` contains ≤ 8 files (the interface + impl pairs + controller)
- [x] `config_usage.md` references `order.payment.provider = stripe`

**M3-T003: Concrete vs abstract implementation captured** ✅
- [x] `relevant_files.txt` contains `StripePaymentService.java`
- [x] `relevant_files.txt` also contains `PaymentService.java` (interface included via expansion)
- [x] `MockPaymentService.java` NOT in slice (not active in this scenario)

**M3-T004: Packager output is valid for AI consumption** ✅
- [x] `architecture.md` is human-readable and correctly describes the call path
- [x] All files listed in `relevant_files.txt` exist on disk (no phantom paths)
- [x] `call_graph.json` parses without error

### Pass criteria
Given real adapter output, the full pipeline through the packager produces a tight, accurate slice. A human reading `architecture.md` + `relevant_files.txt` can understand the `submit-order` scenario without reading the full codebase.

---

## Phase 9 — Zig Core: CLI Layer ✅

### CL-001: Implement `cli/cli.zig` — argument parsing and routing ✅

- *Files:* `context-slicer/src/cli/cli.zig`
- *Tests:*
  - [x] `["record", "submit-order"]` → routes to `RecordCommand`
  - [x] `["slice"]` → routes to `SliceCommand`
  - [x] `["prompt", "Add idempotency"]` → routes to `PromptCommand`
  - [x] `["unknown"]` → returns `error.UnknownSubcommand`, usage printed to stderr
  - [x] Empty args `[]` → usage printed, non-zero error

### CL-002: Implement `cli/commands/record.zig` ✅

- *Files:* `context-slicer/src/cli/commands/record.zig`
- *Tests:*
  - [x] `["record", "submit-order", "--config", "app.yml"]` → `RecordArgs{scenarioName="submit-order", configFile="app.yml"}`
  - [x] `["record"]` (missing scenario name) → error with message indicating missing positional
  - [x] `["record", "submit-order", "--args", "--tenant=abc"]` → `RecordArgs.runArgs = ["--tenant=abc"]`
  - [x] Unknown flag `--foo` → error with message

### CL-003: Implement `cli/commands/slice.zig` ✅

- *Files:* `context-slicer/src/cli/commands/slice.zig`
- *Tests:*
  - [x] Run in a directory with an existing `.context-slice/` → succeeds (stub)
  - [x] Run in a directory without `.context-slice/` → error message: "No recorded scenario found. Run `record` first."

### CL-004: Implement `cli/commands/prompt.zig` ✅

- *Files:* `context-slicer/src/cli/commands/prompt.zig`
- *Tests:*
  - [x] Missing task string → error: "Usage: context-slice prompt \"<your task>\""
  - [x] Missing `.context-slice/` → error: "No slice found. Run `record` first."
  - [x] `metadata.json` present → succeeds

---

## Phase 10 — Zig Core: Orchestrator Layer ✅

### OR-001: Implement `orchestrator/detector.zig` ✅

- *Files:* `context-slicer/src/orchestrator/detector.zig`
- *Tests:*
  - [x] Directory containing `pom.xml` → `.java`
  - [x] Directory containing `build.gradle` but no `pom.xml` → `.java`
  - [x] Directory containing `go.mod` → `.go`
  - [x] Empty directory → `.unknown`
  - [x] Directory with both `pom.xml` and `go.mod` → `.java` (Maven takes precedence, log warning)
  - [x] `test-fixtures/order-service/` → `.java`

### OR-002: Implement `orchestrator/manifest.zig` ✅

- *Files:* `context-slicer/src/orchestrator/manifest.zig`
- *Tests:*
  - [x] Write then read back → all fields equal original
  - [x] JSON output has `scenario_name`, `entry_points`, `run_args`, `config_files`, `output_dir` keys
  - [x] `write()` on nonexistent output dir → creates the dir, then writes

### OR-003: Implement `orchestrator/subprocess.zig` ✅

- *Files:* `context-slicer/src/orchestrator/subprocess.zig`
- *Tests:*
  - [x] Spawn `["echo", "hello"]` → `ExitResult.exit_code = 0`
  - [x] Spawn `["sh", "-c", "exit 42"]` → `ExitResult.exit_code = 42`
  - [x] Nonexistent binary → error at spawn or wait time
  - [x] Subprocess writes to stderr → `ExitResult.stderr_output` captures the output
  - [x] Spawn a slow process (`sleep 100`), call `kill()` → process terminates, no hang

### OR-004: Implement `orchestrator/orchestrator.zig` ✅

- *Files:* `context-slicer/src/orchestrator/orchestrator.zig`
- *Tests:*
  - [x] Unknown project language (`Language.unknown`) → `error.UnsupportedLanguage`
  - [x] Manifest written before subprocess spawned (verified via manifest.json presence)
  - [x] Adapter JAR path does not exist → `error.AdapterNotFound`
  - [x] `buildAdapterCommand` produces expected argv (10 elements, correct order)

---

## Phase 11 — Zig Core: AI Integration Layer ✅

### AI-001: Implement `ai/prompt_builder.zig` ✅

- *Files:* `context-slicer/src/ai/prompt_builder.zig`
- *Tests:*
  - [x] Given a populated `.context-slice/` dir, prompt contains content of `architecture.md`
  - [x] Prompt contains content of `config_usage.md`
  - [x] Source file block has a header showing the file path and content
  - [x] User task appears at the end of the prompt
  - [x] Missing `relevant_files.txt` → `error.SliceNotFound`
  - [x] A path in `relevant_files.txt` that no longer exists → warning logged, file skipped

### AI-002: Implement `ai/claude.zig` — HTTP client ✅

- *Files:* `context-slicer/src/ai/claude.zig`
- *Tests:*
  - [x] Missing `ANTHROPIC_API_KEY` → `error.MissingApiKey`
  - [x] `parseResponseText` with valid JSON → returns text content
  - [x] `parseResponseText` with multiple content blocks → concatenated
  - [x] `parseResponseText` with non-text blocks → ignored
  - [x] Malformed JSON → `error.UnexpectedApiResponse`
  - [x] Response JSON missing `content` field → `error.UnexpectedApiResponse`

---

## ✦ Milestone 4 — End-to-End Integration

**Gate:** All phases complete. All individual tests passing.

### What to test at this checkpoint

**M4-T001: Full `record` command on order-service fixture** ✅
- [x] Run: `context-slice record submit-order --config application.yml` from within `test-fixtures/order-service/`
- [x] Exit code = 0
- [x] `.context-slice/` directory created
- [x] All 5 expected files written: `architecture.md`, `relevant_files.txt`, `config_usage.md`, `call_graph.json`, `metadata.json`
- [x] Files pass all Milestone 3 quality checks

**M4-T002: `slice` command re-runs compression without re-recording** ✅
- [x] After M4-T001, delete `architecture.md` from `.context-slice/`
- [x] Run `context-slice slice`
- [x] `architecture.md` is regenerated, identical to original
- [x] `static_ir.json` and `runtime_trace.json` are unchanged (adapter was NOT re-invoked)

**M4-T003: `prompt` command assembles context and writes to file** ✅
- [x] Run: `context-slice prompt "Add idempotency to the order submission flow"`
- [x] Prompt written to `.context-slice/prompt.md`
- [x] File contains architecture, config, source files, and task sections
- [x] File can be pasted into any AI agent (Claude, Cursor, Copilot, etc.)

**M4-T004: Error paths are user-friendly** ✅
- [x] Run `context-slice record` without a scenario name → clear error, no stack trace
- [x] Run `context-slice prompt "task"` without a prior `record` → clear error: "Run `record` first"
- [x] Run `context-slice record submit-order` in a non-Java directory → clear error: "Unsupported project type"
- [x] Run with no `ANTHROPIC_API_KEY` → clear error from `prompt` command

**M4-T005: Total elapsed time** ✅
- [x] Full `context-slice record` on order-service fixture completes in under 3 minutes (compilation + instrumentation + slicing)
- [x] `context-slice prompt` (excluding API response time) constructs and sends the request in under 5 seconds (measured: 0.37s)

### Pass criteria
Both commands work end-to-end. The slice produced for the `submit-order` scenario is tight (≤ 6 files), accurate (correct concrete implementations), and produces a coherent AI response addressing the task. A developer unfamiliar with the fixture codebase could implement the feature given only the AI response.

---

## Phase 12 — MVP Polish

### P-001: Verbose / debug logging mode ✅

- *Files:* `context-slicer/src/util/log.zig`, `context-slicer/src/cli/commands/slice.zig`
- *Tests:*
  - [x] Without `--verbose`: no debug output on stderr for a successful run
  - [x] With `--verbose`: each pipeline stage emits at least one log line with a count (symbols, edges, hot path, expanded, slice file count)

### P-002: `--help` for all subcommands ✅

- *Tests:*
  - [x] `context-slicer --help` prints usage with list of subcommands
  - [x] `context-slicer record --help` prints record-specific usage with flags
  - [x] `context-slicer prompt --help` prints prompt-specific usage
  - [x] `context-slicer slice --help` prints slice-specific usage

### P-003: `metadata.json` freshness warning ✅

- *Tests:*
  - [x] Slice older than 24h → `prompt` prints warning to stderr (not fatal)
  - [x] Slice under 24h → no warning

### P-004: Graceful partial failure handling ✅

- *Tests:*
  - [x] `metadata.json` has `runtimeCaptured: false` → `prompt` prints: "This slice is static-only. Runtime instrumentation failed. Results may be less accurate."
  - [x] `metadata.json` has `runtimeCaptured: true` → no warning

### P-005: Cross-platform subprocess spawn (macOS + Linux)

- *Tests:*
  - [x] All subprocess tests pass on macOS (Darwin)
  - [ ] Linux verification pending

---

---

## Phase 13 — Data Transformation Capture

**Goal:** At every method boundary in the hot path, capture the state of input parameters before and after execution, plus the return value. Produce a field-level diff that is rendered into `architecture.md` as inline transform annotations. Transform capture is enabled by default and can be disabled via `--no-transforms`. Serialization depth is user-configurable via `context-slice.json` at the repo root.

**Context:** The agent already intercepts every method via `@Advice.OnMethodEnter` / `@Advice.OnMethodExit`. This phase adds object serialization at those hooks for the first invocation of each symbol, computes a field-level diff on exit, and threads the result through the IR → Zig pipeline to the architecture output.

---

### TF-004: Extend order-service fixture with mutation-demonstrating data flow

- *Files:* `test-fixtures/order-service/src/main/java/com/contextslice/fixture/` (POJOs + service impls)
- *What to build:* Update the fixture so that transforms are observable end-to-end:
  - `OrderRequest`: add `orderId` (`String`, starts null) and `status` (`String`, starts null) fields alongside existing `customerId` and `amount`
  - `StripeOrderService.createOrder()`: assign `request.orderId = UUID.randomUUID().toString()` and `request.status = "PROCESSING"` before delegating to payment service — this makes the request parameter visibly mutate
  - `StripePaymentService.charge()`: return `PaymentResult` with `chargeId` and `status = "SUCCEEDED"` set — demonstrates return value capture
  - `OrderResponse`: add `orderId` and `status` fields so the controller response is also observable
- *Tests:*
  - [ ] `mvn package -DskipTests` still succeeds
  - [ ] `POST /orders` returns HTTP 200 with a JSON body containing `orderId` (non-null UUID) and `status = "CREATED"`
  - [ ] No existing IR fixture tests broken (hand-crafted fixtures in `test-fixtures/ir/` may need updating to reflect new fields)

---

### DT-CF: Define `context-slice.json` user config file

- *Files:* `context-slice.json` (repo root, committed with project); `context-slicer/src/cli/config.zig`
- *What to build:* A JSON file at the project root that engineers can modify to tune tool behaviour. The Zig CLI reads this file before building the manifest; values are merged into the manifest so the Java adapter and agent receive them without needing their own file I/O.

  Default file generated by `record` if none exists:
  ```json
  {
    "transforms": {
      "depth_limit": 2,
      "max_collection_elements": 3
    }
  }
  ```

  `config.zig`: `loadConfig(cwd, allocator) Config` — reads `context-slice.json` from the given directory. If the file is absent, returns `Config.defaults()` (depth=2, max_elements=3). Unknown keys are ignored. `Config` struct is passed to `RecordArgs` and threaded through to the manifest.

  `manifest.zig`: add `transform_depth: u32 = 2` and `transform_max_collection_elements: u32 = 3` fields. The orchestrator passes `depth=N,max_elements=N` as additional agent args.

  `AgentBootstrap.java`: parse `depth=N` and `max_elements=N` from agent args. Store in a static `SerializerConfig` record and pass to `ParameterSerializer`.

- *Tests:*
  - [ ] `context-slice.json` absent → `loadConfig` returns defaults (depth=2, max_elements=3), no error
  - [ ] `context-slice.json` with `"depth_limit": 3` → `Config.transforms.depth_limit = 3`
  - [ ] Unknown top-level key in config file → ignored, no error
  - [ ] Manifest serializes `transform_depth` field correctly
  - [ ] Agent command includes `depth=3` when manifest has `transform_depth = 3`
  - [ ] `ParameterSerializer` with `depth=1` stops recursion one level earlier than `depth=2`

---

### DT-001: Implement `ParameterSerializer`

- *Files:* `context-agent-java/src/main/java/com/contextslice/agent/ParameterSerializer.java`
- *What to build:* Static utility that serializes an arbitrary Java object to a `Map<String, String>` flat key-value snapshot. Used at method entry and exit to produce diffable representations. Accepts a `SerializerConfig` (depth limit, max collection elements) sourced from `DT-CF`.
  - Primitives and `String`: `{"value": String.valueOf(obj)}`
  - POJOs (via `getDeclaredFields()` with `setAccessible(true)`): `{"fieldName": "fieldValue"}` for each field
  - Depth limit: read from `SerializerConfig.depthLimit` (default 2). At depth 0, serialize scalar fields. At depth 1, recurse one level. At depth ≥ limit, emit `{"fieldName": "<ClassName>"}` (type name only, no recursion)
  - Collections and arrays: emit `{"fieldName.length": "N", "fieldName[0]": firstElementStr}` up to `SerializerConfig.maxCollectionElements` elements. Do not recurse into elements beyond depth limit.
  - Null object: return empty map `{}`
  - Null field value: emit `"null"` as the string value
  - Cycle detection: `IdentityHashMap<Object, Boolean> visited` passed through recursion — if an object is already in `visited`, emit `"<circular>"`
  - Superclass fields: walk the class hierarchy up to (but not including) `Object` to include inherited fields
- *Tests:*
  - [ ] `serialize(null)` → empty map
  - [ ] `serialize("hello")` → `{"value": "hello"}`
  - [ ] `serialize(42)` (boxed Integer) → `{"value": "42"}`
  - [ ] `serialize(new OrderRequest("cust-1", 100))` → map contains `{"customerId": "cust-1", "amount": "100", "orderId": "null", "status": "null"}`
  - [ ] Object with nested POJO field and `depthLimit=1` → nested object rendered as `"<NestedClassName>"` (not recursed)
  - [ ] Object with self-referential field → serialization terminates, circular field → `"<circular>"`
  - [ ] `List<String>{"a","b","c"}` with `maxCollectionElements=1` → `{"length": "3", "[0]": "a"}` (only first element)
  - [ ] All field values serialized as raw strings — no redaction of any kind

---

### DT-002: Implement `TransformRecord` POJO

- *Files:* `context-agent-java/src/main/java/com/contextslice/agent/TransformRecord.java`
- *What to build:* Data class representing the transformation record for one method invocation. Serialized as an entry in `method_transforms` in `runtime_trace.json`.

```java
public class TransformRecord {
    @SerializedName("symbol_id")    public String symbolId;
    @SerializedName("parameters")   public List<ParameterTransform> parameters;
    @SerializedName("return_value") public Map<String, String> returnValue;  // null if void
    @SerializedName("return_type")  public String returnType;                // null if void

    public static class ParameterTransform {
        @SerializedName("name")           public String name;
        @SerializedName("type")           public String type;
        @SerializedName("entry_snapshot") public Map<String, String> entrySnapshot;
        @SerializedName("exit_snapshot")  public Map<String, String> exitSnapshot;
        @SerializedName("mutated")        public boolean mutated;
        @SerializedName("changed_fields") public List<String> changedFields;
    }
}
```

`changedFields` is computed by comparing `entrySnapshot` and `exitSnapshot` key-by-key: a field is "changed" if its value differs between the two snapshots, or if it is present in one and absent in the other.

- *Tests:*
  - [ ] `changedFields` for identical entry/exit snapshots → empty list
  - [ ] `changedFields` for snapshot where `orderId` went from `"null"` to `"ord-456"` → `["orderId"]`
  - [ ] `mutated` is `false` when `changedFields` is empty
  - [ ] `mutated` is `true` when `changedFields` is non-empty
  - [ ] Serializes to JSON correctly via Gson round-trip

---

### DT-003: Extend `RuntimeTracer` for transform recording

- *Files:* `context-agent-java/src/main/java/com/contextslice/agent/RuntimeTracer.java`
- *What to build:* Add to `RuntimeTracer`:
  - `static final ConcurrentHashMap<String, TransformRecord> transformRecords = new ConcurrentHashMap<>()`
  - `static void recordTransform(String symbolId, TransformRecord record)` — uses `putIfAbsent` so only the first invocation is stored (low memory footprint, deterministic output)
  - Update `reset()` to also clear `transformRecords`
- *Tests:*
  - [ ] `recordTransform("A", record1)` then `recordTransform("A", record2)` → only `record1` stored
  - [ ] 50 threads all calling `recordTransform("A", ...)` concurrently → exactly 1 record stored
  - [ ] `reset()` clears `transformRecords`
  - [ ] `recordTransform` for a symbol already in `methodCounts` → no exception

---

### DT-004: Extend `MethodAdvice` to capture parameter state

- *Files:* `context-agent-java/src/main/java/com/contextslice/agent/MethodAdvice.java`
- *What to build:* Modify `MethodAdvice` to use `@Advice.Enter` to pass entry snapshots from `onEnter` to `onExit`, and capture transforms on exit.
  - `@Advice.OnMethodEnter`: add `@Advice.AllArguments(readOnly = true) Object[] args` and `@Advice.Origin Method method` parameters. Serialize each arg via `ParameterSerializer`. Return the entry snapshots array as `Map<String, String>[]` (the return value becomes available to `onExit` via `@Advice.Enter`).
  - `@Advice.OnMethodExit`: add `@Advice.Enter Map[] entrySnapshots`, `@Advice.AllArguments(readOnly = true) Object[] exitArgs`, `@Advice.Return(typing = Assigner.Typing.DYNAMIC) Object returnValue`, `@Advice.Origin Method method`. Skip serialization work if this symbol already has a transform record (`RuntimeTracer.transformRecords.containsKey(symbol)` — avoids redundant work for high-frequency methods; see accuracy note below). Otherwise, serialize exit args, serialize return value, build `TransformRecord`, call `RuntimeTracer.recordTransform`. Note: first-invocation-only is correct for the A→B chain case (A and B are different symbols, each gets a record); the accuracy gap is when the *same* method is called multiple times with different data (e.g., batch processing) — the first call's transform is captured as a representative sample.
  - `pop()` call must remain on all exit paths (including `onThrowable`). On exception path, record transform with null return value (exception case).
- *Tests:*
  - [ ] After `onEnter`+`onExit` on a method that mutates `request.status`: entry snapshot has `{"status": "null"}`, exit snapshot has `{"status": "PROCESSING"}`, `changedFields = ["status"]`
  - [ ] Void method: `returnValue = null` in `TransformRecord`, `returnType = "void"`
  - [ ] No-arg method: `parameters` list is empty
  - [ ] Second invocation of same symbol: no new `TransformRecord` created (first-invocation-only check)
  - [ ] Exception thrown mid-method: `pop()` still called, transform recorded with null `returnValue`

---

### DT-005: Extend `RuntimeTrace` POJO and `ShutdownHook`

- *Files:* `context-agent-java/src/main/java/com/contextslice/agent/RuntimeTrace.java`, `ShutdownHook.java`
- *What to build:*
  - Add `@SerializedName("method_transforms") public List<TransformRecord> methodTransforms` to `RuntimeTrace`
  - In `ShutdownHook.buildTrace()`: populate `trace.methodTransforms` from `RuntimeTracer.transformRecords.values()`, sorted by `symbolId` for determinism
- *Tests:*
  - [ ] Populate `RuntimeTracer` with 2 transform records, trigger `ShutdownHook.run()` → `runtime_trace.json` contains `"method_transforms"` array of length 2
  - [ ] Records sorted by `symbolId` in output
  - [ ] Zero transform records → `"method_transforms": []` (not null, not omitted)
  - [ ] Existing `observedSymbols` and `observedEdges` fields unaffected

---

### DT-006: Extend `AgentBootstrap` for transforms config args

- *Files:* `context-agent-java/src/main/java/com/contextslice/agent/AgentBootstrap.java`
- *What to build:* Parse three new agent args (all sourced from the manifest via `DT-CF` and `DT-012`):
  - `transforms=true/false` (default `true`) — when `false`, `MethodAdvice` skips all parameter serialization and `method_transforms` will be empty in the output
  - `depth=N` (default `2`) — passed to `SerializerConfig.depthLimit`
  - `max_elements=N` (default `3`) — passed to `SerializerConfig.maxCollectionElements`
  After parsing, store in a static `AgentConfig` accessible to `MethodAdvice`.
- *Tests:*
  - [ ] No args → `transforms=true`, `depth=2`, `max_elements=3`
  - [ ] `transforms=false` → `MethodAdvice` skips serialization; `runtime_trace.json` has `"method_transforms": []`
  - [ ] `depth=3` → `SerializerConfig.depthLimit = 3`
  - [ ] `max_elements=1` → `SerializerConfig.maxCollectionElements = 1`

---

### DT-007: Extend Zig IR types for transforms

- *Files:* `context-slicer/src/ir/types.zig`
- *What to build:* Add new types for transforms. Update `RuntimeTrace` to include `method_transforms`.

```zig
pub const FieldDiff = struct {
    field: []const u8,
    before: []const u8,
    after: []const u8,
};

pub const ParameterTransform = struct {
    name: []const u8,
    type_name: []const u8 = "",
    mutated: bool,
    changed_fields: []const FieldDiff,
};

pub const MethodTransform = struct {
    symbol_id: []const u8,
    parameters: []const ParameterTransform,
    return_value: ?[]const u8 = null,
    return_type: ?[]const u8 = null,
};
```

Update `RuntimeTrace`:
```zig
pub const RuntimeTrace = struct {
    observed_symbols: []const ObservedSymbol,
    observed_edges: []const ObservedEdge,
    method_transforms: []const MethodTransform = &.{},  // optional — absent in old traces
};
```

- *Tests:*
  - [ ] `zig build` succeeds with new types
  - [ ] Can construct a `MethodTransform` with all fields in a test
  - [ ] `RuntimeTrace` with no `method_transforms` field (old format) defaults to empty slice without parse error

---

### DT-008: Extend IR loader to parse transforms

- *Files:* `context-slicer/src/ir/loader.zig`
- *What to build:* `loadRuntime()` already parses the full `RuntimeTrace`. The new `method_transforms` field is parsed automatically if `RuntimeTrace` includes it (Zig's `std.json` ignores unknown fields, and the default `&.{}` handles absent keys). Add explicit parsing of `ParameterTransform.changed_fields` as `[]FieldDiff`, since it involves nested deserialization.
- *Tests:*
  - [ ] Load a `runtime_trace.json` containing `method_transforms` → `RuntimeTrace.method_transforms` has correct length
  - [ ] Each `MethodTransform.parameters[0].changed_fields` contains expected `FieldDiff` entries with correct `field`, `before`, `after`
  - [ ] Load a `runtime_trace.json` without `method_transforms` → parses successfully, `method_transforms` is empty slice
  - [ ] Create fixture: `test-fixtures/ir/runtime_trace_with_transforms.json` — hand-crafted to include 2 transform records for the order-service scenario

---

### DT-009: Extend IR merger to carry transforms through

- *Files:* `context-slicer/src/ir/merger.zig`
- *What to build:* In `merge()`, build a `StringHashMap(MethodTransform)` keyed by `symbol_id` from `runtime.method_transforms`. After building the merged symbol and edge lists, attach the transform map to `MergedIr`. Add a `transforms: StringHashMap(MethodTransform)` field to `MergedIr`.
- *Tests:*
  - [ ] Symbol in hot path with a recorded transform → `MergedIr.transforms` contains an entry for its symbol ID
  - [ ] Symbol not in `method_transforms` → no entry in `MergedIr.transforms` (no panic on lookup miss)
  - [ ] Zero transform records in runtime trace → `MergedIr.transforms` is empty map (not error)

---

### DT-010: Extend architecture writer to render transform annotations

- *Files:* `context-slicer/src/packager/architecture_writer.zig`
- *What to build:* For each symbol in the ordered call path, look up its symbol ID in `slice.transforms` (pass through from `MergedIr` via `Slice`). If a `MethodTransform` exists, append a "Data transformations" block below the method heading. Format:

```markdown
2. **StripeOrderService.createOrder**
   - Concrete implementation: StripeOrderService ✓ runtime-confirmed
   - *Transforms:*
     - `request`: mutates → `orderId` (null → "ord-456"), `status` (null → "PROCESSING")
   - *Returns:* `OrderResponse { orderId: "ord-456", status: "CREATED" }`
```

Rules:
  - Only emit the `Transforms:` block if the parameter has `mutated = true`
  - If all parameters are non-mutating and there is no return value, emit nothing (no noise for pass-through methods)
  - Return value block: emit only if `return_type` is not `"void"` and `return_value` is non-null
  - Each `FieldDiff` rendered as `` `fieldName` (before → after) ``
  - If `before = "null"` it is a population (null → value); if `after = "null"` it is a clear (value → null)

- *Tests:*
  - [ ] Symbol with no transform entry → no annotations appended to its section
  - [ ] Symbol with mutated parameter → `Transforms:` block present with correct field diffs
  - [ ] Symbol with `return_type = "void"` → no `Returns:` line
  - [ ] Symbol with non-void return value → `Returns:` line present with serialized fields
  - [ ] Output `architecture.md` is valid Markdown (no runaway formatting)
  - [ ] Slice.transforms must be threaded through `Compressor` → `Slice` → `architecture_writer` — update `Slice` struct and `compressor.zig` to carry `transforms`

---

### DT-011: Extend CLI `record`, manifest, and orchestrator for transforms config

- *Files:* `context-slicer/src/cli/commands/record.zig`, `context-slicer/src/cli/config.zig` (new), `context-slicer/src/orchestrator/manifest.zig`, `context-slicer/src/orchestrator/orchestrator.zig`
- *What to build:*
  - `config.zig` (new): `loadConfig(cwd_path, allocator) Config` — reads `context-slice.json` from the project root. Returns `Config.defaults()` if absent. `Config` struct holds `transforms.depth_limit` and `transforms.max_collection_elements`.
  - `record.zig`: add `--no-transforms` boolean flag to `RecordArgs`. Default: transforms enabled. Load `context-slice.json` from cwd and store in `RecordArgs.config`.
  - `manifest.zig`: add `transforms_enabled: bool = true`, `transform_depth: u32 = 2`, `transform_max_collection_elements: u32 = 3` fields.
  - `orchestrator.zig`: build agent args from manifest — append `,transforms=false` if `!manifest.transforms_enabled`; always append `,depth=N,max_elements=N` from manifest values.
- *Tests:*
  - [ ] `["record", "submit-order"]` (no flag) → `RecordArgs.transforms_enabled = true`
  - [ ] `["record", "submit-order", "--no-transforms"]` → `RecordArgs.transforms_enabled = false`
  - [ ] `context-slice.json` with `"depth_limit": 3` → manifest `transform_depth = 3`
  - [ ] `context-slice.json` absent → manifest uses defaults (`depth=2`, `max_elements=3`)
  - [ ] `buildAdapterCommand` with `transforms_enabled = false` → agent args contain `transforms=false`
  - [ ] `buildAdapterCommand` with `transforms_enabled = true` → agent args do NOT contain `transforms=false`
  - [ ] `buildAdapterCommand` always includes `depth=N` and `max_elements=N` from manifest values

---

## ✦ Milestone 5 — Transforms End-to-End

**Gate:** All Phase 13 tasks complete and passing.

### What to test at this checkpoint

**M5-T001: Full `record` produces transform annotations**
- [ ] Run `context-slicer record submit-order` on updated `test-fixtures/order-service/`
- [ ] `runtime_trace.json` contains a `method_transforms` array with at least 2 entries (`StripeOrderService.createOrder` and `StripePaymentService.charge`)
- [ ] `architecture.md` contains a `Transforms:` block under `StripeOrderService.createOrder` listing `orderId` and `status` as changed fields
- [ ] `architecture.md` contains a `Returns:` line under `StripePaymentService.charge` with `chargeId` and `status`
- [ ] All field values in the transform output are raw (no redaction)

**M5-T002: `--no-transforms` disables capture**
- [ ] Run `context-slicer record submit-order --no-transforms`
- [ ] `runtime_trace.json` contains `"method_transforms": []`
- [ ] `architecture.md` contains no `Transforms:` or `Returns:` blocks

**M5-T003: Depth config is respected**
- [ ] Add `context-slice.json` with `"depth_limit": 1` to the fixture project root
- [ ] Run `context-slicer record submit-order`
- [ ] Transform snapshots in `runtime_trace.json` show nested objects as `"<ClassName>"` (not recursed) at depth 1

**M5-T004: Backwards compatibility**
- [ ] `slice` command on an existing `.context-slice/` from before Phase 13 (no `method_transforms` in `runtime_trace.json`) → runs without error, produces `architecture.md` without transform annotations (graceful degradation)

**M5-T005: High-frequency method handling**
- [ ] A method called 100 times in a scenario → only 1 `TransformRecord` in `runtime_trace.json` for that symbol (first-invocation-only)
- [ ] `call_count` for that symbol still reflects 100 in `observed_symbols` (transform capture and call counting are independent)

### Pass criteria
`architecture.md` for the `submit-order` scenario contains inline data transformation annotations that correctly describe what each method in the hot path does to data, without requiring the reader to trace through source code. The Zig pipeline handles old traces (no `method_transforms`) without error. Depth and collection limits are configurable via `context-slice.json`.

---

## Appendix: Running the Full Test Suite

### Per-phase test commands

```bash
# Java adapter tests
cd context-adapter-java && mvn test

# Java agent tests
cd context-agent-java && mvn test

# Zig core unit tests
cd context-slicer && zig build test

# Zig core integration tests (requires adapter output from M1)
cd context-slicer && zig build test -- --integration
```

### Milestone gate checklist (run before each milestone commit)

```bash
# M1: Adapter produces valid IR
java -jar context-adapter-java/target/*.jar record \
  --manifest test-fixtures/order-service/manifest.json \
  --output /tmp/cs-m1/
jq '.ir_version' /tmp/cs-m1/static_ir.json    # should print "0.1"
jq '.symbols | length' /tmp/cs-m1/static_ir.json   # should match expected count

# M3: Slice pipeline (after M1 output exists)
cd context-slicer && zig build run -- slice \
  --ir-dir /tmp/cs-m1/ \
  --output /tmp/cs-m3/
cat /tmp/cs-m3/relevant_files.txt   # inspect for correctness

# M4: Full end-to-end
cd test-fixtures/order-service
context-slice record submit-order --config application.yml
context-slice prompt "Add idempotency key support to order creation"
```

---

*Context Slice — Execution Plan v0.1 — Last updated 2026-02-24*
