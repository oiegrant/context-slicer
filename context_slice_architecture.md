# CONTEXT SLICE
## Runtime-Aware AI Context Engine

**System Architecture & Product Design Document**
Version 1.0 — MVP + Platform Roadmap

---

> **Core Principle**
> Language-specific extraction → Language-neutral IR → Semantic compression → AI context

---

## Table of Contents

1. [Executive Summary & Product Vision](#1-executive-summary--product-vision)
2. [High-Level Architecture](#2-high-level-architecture)
3. [Component Deep-Dive: Zig Core](#3-component-deep-dive-zig-core)
4. [Component Deep-Dive: Java Adapter](#4-component-deep-dive-java-adapter)
5. [Language-Neutral IR Schema](#5-language-neutral-ir-schema)
6. [Orchestration Flow (End-to-End)](#6-orchestration-flow-end-to-end)
7. [Runtime Instrumentation: ByteBuddy](#7-runtime-instrumentation-bytebuddy-deep-dive)
8. [MVP Scope & Deliverables](#8-mvp-scope--deliverables)
9. [Post-MVP Roadmap](#9-post-mvp-roadmap)
10. [Tech Stack Reference](#10-tech-stack-reference)
11. [Strategic Notes](#11-strategic-notes)

---

## 1. Executive Summary & Product Vision

Context Slice is a runtime-grounded code slicing platform that produces AI-usable architectural context for large, complex codebases. The core problem it solves: modern AI coding assistants fail in enterprise monoliths not because the AI is bad, but because the context fed to it is wrong — too large, too noisy, and blind to runtime behavior.

Context Slice fixes this by combining static analysis with live runtime instrumentation to produce a tightly scoped, semantically meaningful slice of code — the exact files, call paths, config dependencies, and data shapes relevant to a specific scenario — and then feeding only that slice to the AI.

### 1.1 The Problem

- Enterprise Java monoliths have millions of lines of code — no AI context window covers this
- Spring/DI-heavy apps require understanding bean graphs, profile-based wiring, and `@Conditional` logic that static tools miss
- Config-driven behavior means two runs of the same code can take entirely different paths
- Feeding a raw repo to an AI produces hallucinated answers about code that was never actually executed

### 1.2 The Solution

- Record a real execution scenario (e.g. `submit-order`) with runtime instrumentation
- Extract the exact call path, config reads, bean resolutions, and data shapes observed during that run
- Merge with static analysis to add adjacent branches and interface expansions
- Compress into a structured AI context package — not the whole repo, just the relevant slice
- Feed that slice to Claude with a task prompt

### 1.3 Target Market

| Segment | Description |
|---|---|
| **Primary** | Large enterprise Java/Spring teams working in massive shared monoliths |
| **Secondary** | Startups with fast-growing complex codebases and small AI-forward eng teams |
| **Phase 2** | Go / Python codebases; smaller, well-structured repos |
| **Phase 3** | C++ systems codebases (HFT, embedded, game engines) |

---

## 2. High-Level Architecture

The architecture follows a clean three-layer model: a language-specific extraction layer, a language-neutral intermediate representation (IR), and a language-agnostic core engine. This design intentionally isolates all language-specific complexity behind a stable adapter contract so the platform can expand to new languages without rewriting the core.

### 2.1 Layer Diagram

```
┌──────────────────────────────────────────────┐
│              CLI / UX Layer (Zig)            │
│   record  |  slice  |  prompt  |  diff       │
└──────────────────────┬───────────────────────┘
                       ↓
┌──────────────────────────────────────────────┐
│          Core Slicing Engine (Zig)           │
│  IR loader · Graph builder · Compressor      │
│  Neighborhood expansion · Claude integration │
└──────────────────────┬───────────────────────┘
                       ↓
┌──────────────────────────────────────────────┐
│       Language Adapter Interface             │
│  Standardized JSON contract (IR + trace)     │
└────────┬─────────────────────────┬───────────┘
         ↓                         ↓
┌────────────────┐       ┌─────────────────────┐
│  Java Adapter  │       │  C++ Adapter (v2)   │
│  JDT · ByteBdy │       │  Clang LibTooling   │
└────────────────┘       └─────────────────────┘
```

### 2.2 Guiding Principles

- **Zig orchestrates, Java extracts.** The core engine is language-agnostic. It never parses Java or C++.
- **Language-neutral IR is the company's core IP.** All adapters emit the same JSON schema. The core graph algorithms work on that schema alone.
- **Runtime truth takes precedence over static analysis.** Static edges can exist that were never executed. Runtime-observed edges are weighted highest.
- **Framework noise is an explicit problem.** Every layer — instrumentation, filtering, compression — must actively remove Spring/framework artifacts.
- **The adapter is a subprocess contract.** Adapters are standalone executables communicating via JSON files. No shared memory, no RPC.

---

## 3. Component Deep-Dive: Zig Core

The Zig core is the platform's durable intellectual property. It must never contain Java-specific logic. Its job is to orchestrate adapters, consume IR, build graphs, compress semantics, and talk to AI. Estimated MVP size: 4,000–6,000 LOC.

### 3.1 CLI / UX Layer `[MVP]`

The entry point for all user interactions.

| Subcommand | Purpose |
|---|---|
| `record <scenario>` | Launch adapter, run instrumented scenario, collect IR output |
| `slice` | Re-run compression on an existing IR without re-recording |
| `prompt "<task>"` | Inject compressed slice as context, forward prompt to Claude |
| `diff <s1> <s2>` | Compare two scenario slices (post-MVP) |

The CLI is responsible for: detecting repo language, creating the `.context-slice/` working directory, generating the run manifest JSON, and spawning the adapter subprocess.

### 3.2 Adapter Orchestration Layer `[MVP]`

This layer manages the adapter lifecycle and enforces the adapter contract.

- Detect repo type by scanning for `pom.xml`, `build.gradle`, `mvnw`, `CMakeLists.txt`, `go.mod`, etc.
- Load the correct adapter binary based on detected language
- Pass scenario config via `manifest.json`
- Wait for adapter completion and collect output files
- Validate that emitted IR conforms to the expected schema version
- Handle adapter failures gracefully — error reporting, partial IR fallback

### 3.3 IR Loader & Validator `[MVP]`

Parses and validates adapter output before graph construction. This is a critical correctness boundary.

- Parse `static_ir.json` and `runtime_trace.json`
- Validate schema version compatibility
- Reject or quarantine malformed symbols (missing IDs, null file refs)
- Merge static and runtime data: for each call edge, join `runtime_observed` flag and `call_count`
- Deduplicate symbols — adapters may emit the same symbol from multiple analysis passes
- Build stable in-memory symbol map keyed by symbol ID

### 3.4 Graph Builder `[MVP]`

Constructs an in-memory weighted directed graph from the merged IR. This graph is language-neutral — nodes are symbol IDs, edges carry metadata.

| Graph Type | Description |
|---|---|
| Symbol graph | Nodes = symbols; edges = containment (class → method) |
| Call graph | Directed edges from caller to callee, weighted by `call_count` |
| Config dependency edges | Symbol → config key reads (with resolved values) |
| File ownership map | Symbol ID → file path, for context packaging |

### 3.5 Neighborhood Expansion Engine `[MVP — basic radius-1]`

Given the runtime-observed call path (the "hot path"), this engine expands outward to add adjacent context that may be needed for reasoning about the scenario.

- **Radius-1 expansion:** add direct callers and callees not already in runtime path
- **Interface resolution:** if a runtime edge resolves to a concrete type, also include the interface definition and other known implementations (from static graph)
- **Config expansion:** for each config key read in-scenario, locate its definition file and include it
- Post-MVP: configurable expansion radius, semantic relevance scoring

### 3.6 Semantic Compression Engine `[MVP — simple version]`

Transforms the expanded graph into a human- and AI-readable context package. The goal is to reduce signal-to-noise as aggressively as possible while preserving architectural truth.

- Deduplicate call stacks — collapse recursive patterns, remove loops
- Filter low-frequency edges below a configurable threshold (e.g. `call_count < 1` in a single-run scenario)
- Remove `is_framework=true` symbols unless explicitly included by expansion
- Produce ordered call path narrative (entry point to leaves)
- Summarize config influence — which keys changed which branches
- Post-MVP: ML-based relevance scoring, multi-run aggregation, cross-scenario diffing

### 3.7 Context Packager `[MVP]`

Writes the final output directory consumed by the AI integration layer.

```
.context-slice/
  architecture.md       # Human-readable call path narrative
  relevant_files.txt    # Exact file paths to include in AI context
  call_graph.json       # Compressed weighted graph
  config_usage.md       # Config keys and their resolved values
  runtime_shapes.json   # Data type summaries (post-MVP for full shapes)
  metadata.json         # Scenario name, build ID, adapter version, timestamp
```

### 3.8 AI Integration Layer `[MVP — minimal]`

For MVP, this wraps the Claude API. It reads the slice directory, constructs a prompt, and forwards the user's task.

- Read all files from `relevant_files.txt` and include their contents as context
- Prepend `architecture.md` and `config_usage.md` as preamble
- Append the user's task prompt
- Call Claude API or spawn `claude` CLI subprocess
- Post-MVP: streaming output, prompt templating, feedback loop for slice quality scoring

---

## 4. Component Deep-Dive: Java Adapter

The Java Adapter is a self-contained Java process responsible for all language-specific extraction. It runs as a subprocess spawned by the Zig core and communicates only through files. Estimated MVP size: 3,000–5,000 LOC.

### 4.1 Adapter Entry Point

The adapter is a standalone JAR invoked as:

```bash
java -jar context-adapter-java.jar record \
     --manifest .context-slice/manifest.json \
     --output   .context-slice/
```

It reads the manifest (scenario name, entry points, config files, run args) and executes two phases sequentially: static analysis, then runtime instrumentation.

### 4.2 Static Analysis Module `[MVP — basic]`

Parses Java source to build a structural model of the codebase without executing it.

#### Tool: Eclipse JDT Core

Eclipse JDT is the recommended tool for MVP static analysis. It is a pure Java library (no IDE required), resolves type bindings accurately across files, and handles standard Java annotations including Spring stereotypes.

- Initialize `ASTParser` with source roots derived from Maven/Gradle model or recursive `/src/main/java` scan
- Set `setResolveBindings(true)` to enable cross-file symbol resolution
- Walk the AST to extract: class declarations, method declarations, method invocations, interface implementations, and annotations (`@Component`, `@Service`, `@Repository`, `@Autowired`, `@Transactional`, etc.)
- Build in-memory maps: `SymbolId → Symbol` and `List<CallEdge>` of static call relationships
- Emit to `static_ir.json`

#### Post-MVP Static Enhancements

- Spring bean graph: extract `@Bean`, `@Configuration`, `@Conditional`, `@Profile` relationships
- Config property binding: map `@ConfigurationProperties` classes to their YAML/properties keys
- Proxy-aware type resolution: detect CGLIB and JDK proxy patterns
- Spoon or `javac` Compiler API for deeper semantic analysis

### 4.3 Runtime Instrumentation Module `[MVP]`

This is the adapter's core differentiator. It attaches a ByteBuddy Java Agent to the running Spring application and observes real execution.

#### Execution Sequence

1. Build the project (`mvn package` or `gradle assemble`)
2. Relaunch the app with the agent attached:
   ```bash
   java -javaagent:context-agent.jar \
        -jar app.jar <run_args>
   ```
3. Wait for scenario to complete (configurable signal: HTTP call, CLI trigger, time-based)
4. Agent writes `runtime_trace.json` on JVM shutdown
5. Adapter merges static and runtime outputs, emits final IR files

### 4.4 IR Emitter `[MVP]`

After both analysis phases complete, the emitter serializes all in-memory data structures to the standardized IR JSON files. It must be deterministic — same source, same output. Symbols and edges are sorted by ID before serialization.

### 4.5 Spring-Aware Enhancements `[Post-MVP]`

The hardest engineering problem in the entire platform is correctly reconstructing Spring's dependency injection graph under specific config conditions. Spring uses conditional beans, profile-based wiring, lazy initialization, factory beans, and CGLIB proxies — none of which are visible in static source analysis alone.

- **BeanFactory listener:** register an `ApplicationListener<ContextRefreshedEvent>` to capture all resolved bean definitions at startup
- **Profile awareness:** record which `@Profile` conditions were active during the run
- **`@Conditional` resolution:** log which conditions evaluated to true/false and why
- **Autowire graph:** for each `@Autowired` field, record the concrete bean that was injected

---

## 5. Language-Neutral IR Schema

The IR schema is the most important technical decision in the platform. It is the contract between language-specific extraction and language-agnostic intelligence. Breaking changes to the IR schema require versioned migrations. Treat it like a public API.

### 5.1 Design Philosophy

- Model executable architectural reality for a scenario — not raw AST, not bytecode
- Flat and mergeable: arrays of objects, not nested trees
- Deterministic: sorted output, stable IDs, SHA-256 file hashes
- Versioned: `ir_version` field must be checked by the Zig loader
- Language-neutral: the Zig core must not contain any Java- or C++-specific logic
- Expandable: all fields are optional beyond the MVP required subset

### 5.2 Symbol ID Convention

Every symbol must have a globally unique, deterministic, stable ID:

```
<language>::<fully-qualified-name>::<signature>

Examples:
  java::com.company.OrderService::createOrder(OrderRequest)
  cpp::OrderService::createOrder(OrderRequest const&)
```

### 5.3 Top-Level Structure

```json
{
  "ir_version":      "0.1",
  "language":        "java",
  "repo_root":       "/abs/path/to/repo",
  "build_id":        "git-sha-or-content-hash",
  "adapter_version": "0.1.0",

  "scenario": {
    "name":         "submit-order",
    "entry_points": ["java::com.company.OrderController::submit(OrderRequest)"],
    "run_args":     ["--tenant=abc"],
    "config_files": ["application-prod.yml"]
  },

  "files":        [...],
  "symbols":      [...],
  "call_edges":   [...],
  "config_reads": [...],
  "runtime":      { "observed_symbols": [...] }
}
```

### 5.4 Schema: Files

```json
{
  "id":       "f1",
  "path":     "src/main/java/com/company/order/OrderService.java",
  "language": "java",
  "hash":     "sha256:abc123..."
}
```

### 5.5 Schema: Symbols `[MVP required]`

```json
{
  "id":           "java::com.company.order.OrderService::createOrder(OrderRequest)",
  "kind":         "method",
  "name":         "createOrder",
  "language":     "java",
  "file_id":      "f2",
  "line_start":   35,
  "line_end":     102,
  "visibility":   "public",
  "container":    "java::com.company.order.OrderService",
  "annotations":  ["@Transactional"],
  "is_entry_point": false,
  "is_framework":   false,
  "is_generated":   false
}
```

Supported `kind` values (MVP): `class`, `method`, `constructor`, `interface`
Post-MVP: `lambda`, `template`, `macro_expansion`

### 5.6 Schema: Call Edges `[MVP required]`

The `static` and `runtime_observed` flags are what enable the platform's core insight: knowing which interfaces were called statically but which concrete implementations were actually invoked at runtime.

```json
{
  "caller":           "java::OrderController::submit(OrderRequest)",
  "callee":           "java::StripePaymentService::charge(PaymentRequest)",
  "static":           true,
  "runtime_observed": true,
  "call_count":       1
}
```

### 5.7 Schema: Config Reads `[MVP required]`

```json
{
  "symbol_id":      "java::OrderService::createOrder(OrderRequest)",
  "config_key":     "order.payment.provider",
  "resolved_value": "stripe",
  "source_file":    "application-prod.yml"
}
```

### 5.8 Schema: Runtime Block `[MVP required]`

```json
"runtime": {
  "observed_symbols": [
    {
      "symbol_id":  "java::OrderService::createOrder(OrderRequest)",
      "call_count": 12
    }
  ]
}
```

### 5.9 Post-MVP Schema Extensions

| Field | Description |
|---|---|
| `runtime_values` / `parameter_shapes` | Field-level type summaries of actual runtime objects passed to methods |
| `call_sequences` | Ordered arrays of symbol IDs representing observed call chains |
| `type_relationships` | `implements` / `extends` / `instantiates` edges between types |
| `avg_duration_ms` | Per-symbol timing captured by the agent |
| `exception_traces` | Exceptions thrown and caught during the scenario |
| `thread_id` | Per-edge thread annotation for async flow analysis |
| `bean_graph` | Spring bean resolution: which concrete bean was wired where |
| `language` (cross-language edges) | Enables polyglot monorepo support in future |

---

## 6. Orchestration Flow (End-to-End)

### 6.1 Command: `context-slice record submit-order`

#### Step 1 — Zig CLI

1. User runs: `context-slice record submit-order --config application-prod.yml --args "--tenant=abc"`
2. Zig detects repo type: scans for `pom.xml` / `build.gradle` in current directory
3. Creates `.context-slice/` working directory
4. Writes `manifest.json` with scenario name, entry points, run args, config files
5. Spawns Java adapter subprocess: `java -jar context-adapter-java.jar record --manifest ... --output ...`
6. Blocks waiting for adapter completion

#### Step 2 — Java Adapter: Static Analysis

1. Adapter reads `manifest.json`
2. Resolves source roots from `pom.xml` or `build.gradle`
3. Initializes Eclipse JDT `ASTParser` with source roots and classpath
4. Walks AST across all source files — extracts symbols, call expressions, type relationships
5. Applies annotation filters to mark Spring framework classes as `is_framework=true`
6. Serializes to `.context-slice/static_ir.json`

#### Step 3 — Java Adapter: Runtime Instrumentation

1. Runs `mvn package` or `gradle assemble` to produce the application JAR
2. Launches app with ByteBuddy agent: `java -javaagent:context-agent.jar -jar app.jar <run_args>`
3. ByteBuddy instruments all classes matching `com.company.*` at class-load time
4. Agent maintains per-thread call stacks and edge frequency counters
5. Agent intercepts `Environment.getProperty()` calls to capture config reads
6. Scenario executes (HTTP request, test runner, or time-based completion)
7. JVM shutdown hook fires — agent serializes to `.context-slice/runtime_trace.json`

#### Step 4 — Java Adapter: IR Emission

1. Adapter merges static symbol list with runtime observation data
2. Annotates each call edge with `runtime_observed=true/false` and `call_count`
3. Sorts all arrays by ID for deterministic output
4. Writes final IR files and `metadata.json` — exits with code 0

#### Step 5 — Zig Core: Graph Construction

1. Zig detects adapter has exited successfully
2. Loads and validates `static_ir.json` and `runtime_trace.json`
3. Builds weighted directed call graph in memory
4. Identifies runtime "hot path": symbols with `call_count > 0`

#### Step 6 — Zig Core: Expansion & Compression

1. Runs radius-1 neighborhood expansion from hot path
2. Resolves interface implementations from static graph for any polymorphic edges
3. Loads config definitions from source config files for each config key observed
4. Removes `is_framework=true` symbols from graph
5. Deduplicates edges, collapses trivial pass-through symbols
6. Generates `architecture.md`, `relevant_files.txt`, `config_usage.md`, `call_graph.json`

### 6.2 Command: `context-slice prompt "Add idempotency"`

1. Zig reads `.context-slice/` — checks `metadata.json` for freshness
2. Loads `relevant_files.txt` and reads all referenced source files
3. Constructs prompt: `[architecture.md]` + `[config_usage.md]` + `[file contents]` + `[user task]`
4. Calls Claude API with assembled context
5. Streams response back to terminal

---

## 7. Runtime Instrumentation: ByteBuddy Deep-Dive

ByteBuddy is a runtime code generation and instrumentation library that sits on top of the Java Instrumentation API and ASM. It enables method-level interception without source code modification, compile-time changes, or JVM restarts.

### 7.1 Agent Bootstrap

```java
public static void premain(String args, Instrumentation inst) {
  new AgentBuilder.Default()
    .type(nameStartsWith("com.company")            // only instrument app code
      .and(not(nameContains("$$EnhancerBySpring")))// exclude CGLIB proxies
      .and(not(nameContains("$Proxy")))             // exclude JDK proxies
    )
    .transform((builder, type, loader, module, pd) ->
      builder.method(isMethod()
               .and(not(isConstructor()))
               .and(not(isAbstract())))
             .intercept(Advice.to(MethodAdvice.class))
    )
    .installOn(inst);
}
```

### 7.2 MethodAdvice — Call Stack Tracking

```java
public class MethodAdvice {
  @Advice.OnMethodEnter
  public static void onEnter(@Advice.Origin("#t::#m") String symbol) {
    String caller = RuntimeTracer.peek();    // top of thread-local stack
    RuntimeTracer.recordEdge(caller, symbol);
    RuntimeTracer.push(symbol);
  }

  @Advice.OnMethodExit(onThrowable = Throwable.class)
  public static void onExit(@Advice.Origin("#t::#m") String symbol) {
    RuntimeTracer.pop();
  }
}
```

### 7.3 RuntimeTracer — In-Memory Aggregation

```java
class RuntimeTracer {
  // Per-thread call stack for accurate caller resolution
  static final ThreadLocal<Deque<String>> stack = ThreadLocal.withInitial(ArrayDeque::new);

  // Aggregated counts — no per-call allocation on the hot path
  static final ConcurrentHashMap<String, LongAdder>         methodCounts = ...;
  static final ConcurrentHashMap<String/*edge*/, LongAdder> edgeCounts   = ...;
  static final ConcurrentHashMap<String, String>            configReads  = ...;
}
```

### 7.4 Config Read Interception

```java
// Intercept Spring's Environment.getProperty at agent load time
new AgentBuilder.Default()
  .type(named("org.springframework.core.env.AbstractEnvironment"))
  .transform((b, t, l, m, pd) ->
    b.method(named("getProperty").and(takesArgument(0, String.class)))
     .intercept(Advice.to(ConfigAdvice.class)))
  .installOn(inst);

public class ConfigAdvice {
  @Advice.OnMethodExit
  public static void afterGetProperty(
    @Advice.Argument(0) String key,
    @Advice.Return      String value) {
    String currentMethod = RuntimeTracer.peek();
    RuntimeTracer.recordConfig(currentMethod, key, value);
  }
}
```

### 7.5 Shutdown & Serialization

```java
Runtime.getRuntime().addShutdownHook(new Thread(() -> {
  RuntimeTrace trace = RuntimeTrace.build(methodCounts, edgeCounts, configReads);
  try (FileWriter w = new FileWriter(outputPath)) {
    gson.toJson(trace, w);
  }
}));
```

### 7.6 Noise Filtering Strategy

| Source of Noise | Filter Strategy |
|---|---|
| CGLIB proxy classes (`$$EnhancerBySpring...`) | Exclude via `nameContains` matcher in `AgentBuilder` |
| JDK dynamic proxies (`$Proxy0...`) | Exclude via `nameContains` matcher |
| Spring framework internals | Restrict instrumentation to `com.company.*` namespace |
| ByteBuddy instrumentation artifacts | Excluded automatically — agent uses bootstrap classloader |
| Trivial getters/setters | Post-MVP: filter by method length or annotation heuristic |
| High-frequency infrastructure (logging, etc.) | Post-MVP: exclude by method name pattern list |

### 7.7 Performance Characteristics

- Instrumentation overhead: approximately 5–15% CPU in a dev environment for namespace-scoped agents
- Memory: `ConcurrentHashMap` + `LongAdder` are low-allocation; no per-call heap pressure
- Thread safety: `ThreadLocal` stacks per thread; atomic counters for aggregated data
- Startup cost: ByteBuddy instruments classes at class-load time, not at runtime method call
- Acceptable for dev/staging environments; not intended for production tracing

---

## 8. MVP Scope & Deliverables

> **The MVP must prove a single hypothesis:**
> *Does runtime-grounded context slicing materially improve AI reasoning quality in a large Spring monolith compared to feeding the raw repository?*

If yes — you have a defensible product. If no — you have a static analysis tool, which is a different (and more competitive) market.

### 8.1 MVP Component Checklist

| Component | Status | Notes |
|---|---|---|
| CLI: `record`, `slice`, `prompt` subcommands | ✅ MVP | Core user journey |
| Adapter orchestration + subprocess contract | ✅ MVP | Foundation for multi-language |
| IR schema v0.1 + Zig loader/validator | ✅ MVP | Must be stable — version carefully |
| Graph builder (symbol + call + config edges) | ✅ MVP | Language-neutral core |
| Radius-1 neighborhood expansion | ✅ MVP | Simplified version acceptable |
| Basic semantic compression (stack dedupe, noise removal) | ✅ MVP | Simple heuristics OK |
| Context packager (`relevant_files`, `architecture.md`, `config_usage.md`) | ✅ MVP | This is the AI input |
| Claude integration (minimal — construct prompt, call API) | ✅ MVP | Simple string construction |
| Java Adapter: Eclipse JDT static analysis | ✅ MVP | Basic class/method/call extraction |
| Java Adapter: ByteBuddy agent + `RuntimeTracer` | ✅ MVP | Core differentiator |
| Java Adapter: Config read interception | ✅ MVP | High value, low complexity |
| Java Adapter: IR emitter | ✅ MVP | Deterministic JSON serialization |
| Spring-aware bean graph extraction | ❌ Post-MVP | Complex, defer until proven needed |
| Advanced branch inference / data flow | ❌ Post-MVP | |
| Runtime value / parameter shape capture | ❌ Post-MVP | |
| Multi-language support (C++, Python, Go) | ❌ Post-MVP | Adapter contract ready now |
| IDE plugins, real-time slicing | ❌ Post-MVP | |
| Distributed tracing integration (OTel) | ❌ Post-MVP | |

### 8.2 Estimated MVP Effort

| Workstream | Estimate |
|---|---|
| Zig Core (CLI + orchestration + graph + compression + packager) | 4,000–6,000 LOC &ensp;&#124;&ensp; ~6–8 weeks |
| Java Adapter (JDT static + ByteBuddy runtime + IR emitter) | 3,000–5,000 LOC &ensp;&#124;&ensp; ~4–6 weeks |
| Integration testing on a real Spring monolith | ~2 weeks |
| **Total solo founder estimate** | **~10–14 weeks focused** |

### 8.3 MVP Success Criteria

- Given a real Spring monolith and a specific scenario, the tool produces a slice containing fewer than 20 files that is sufficient for Claude to correctly implement a non-trivial feature request
- The produced slice captures the correct concrete implementation path (e.g. `StripePaymentService`, not all `PaymentService` implementations)
- Config reads are correctly attributed to the scenario (e.g. `order.feature.idempotency=true` influenced branch X)
- Total end-to-end time from `context-slice record` to AI response is under 5 minutes for a typical dev workflow

---

## 9. Post-MVP Roadmap

### Phase 2 — Spring Depth

- Full Spring bean graph extraction via `BeanFactory` listener
- `@Conditional` and `@Profile`-aware bean resolution
- CGLIB proxy → original type mapping
- `@ConfigurationProperties` binding graph
- Multi-scenario trace aggregation and diffing
- Runtime parameter shape capture (field-level type summaries)

### Phase 3 — Platform Expansion

- Python adapter: `ast` module + `sys.settrace()` / `coverage.py` for runtime
- Go adapter: `go/ast` for static + `runtime/trace` package for instrumentation
- Multi-language monorepo support: cross-language edges in IR schema
- Configurable expansion radius and relevance scoring

### Phase 4 — Enterprise Features

- C++ adapter: Clang LibTooling for static + sanitizer/perf for runtime (high complexity — defer until customer demand)
- Persistent slice cache with invalidation on file hash changes
- Scenario diffing: compare how two config profiles change the execution path
- IDE plugin (VS Code / IntelliJ)
- Team-shared slice registry
- OpenTelemetry integration for production trace import

### Phase 5 — AI Intelligence Layer

- Fine-tuned slice quality scorer: train a model to rate how well a slice answers a given task
- Automatic scenario discovery: suggest which scenarios to record for a given task
- Change impact analysis: given a code diff, which scenarios are likely affected
- Proactive architecture documentation generation

---

## 10. Tech Stack Reference

| Layer | Technology | Rationale |
|---|---|---|
| Core Engine | Zig | Deterministic, fast, single static binary, great CLI ergonomics, no GC, perfect for graph processing |
| Core — JSON parsing | Zig `std.json` | Native to Zig, no dependencies |
| Core — Graph algorithms | Hand-rolled in Zig | BFS/DFS + weighted edge traversal; simple enough to own |
| Core — AI integration | Anthropic API (HTTP) | REST call with JSON body; no SDK needed for MVP |
| Java Adapter — Static | Eclipse JDT Core | Mature, type-binding resolution, no IDE required, pure Java |
| Java Adapter — Runtime | ByteBuddy + Java Agent API | Production-safe, expressive, widely used, Spring-compatible |
| Java Adapter — Build | Maven / Gradle invocation | Shell out to existing build tooling; no custom build parsing |
| Java Adapter — Serialization | Gson or Jackson | Standard; prefer Gson for simplicity in the adapter |
| IR Format | JSON (UTF-8) | Universal, human-readable, easy to diff, Zig parses natively |
| C++ Adapter (future) | Clang LibTooling + LLVM | Only mature option for C++ AST + call graph extraction |
| Python Adapter (future) | Python `ast` module + `coverage.py` | Standard library; no external dependencies |

### 10.1 Why NOT Other Choices

| Alternative | Reason Rejected |
|---|---|
| Pure Zig for all languages | Would require writing Java/C++ parsers from scratch. Years of work. |
| Everything in Java | C++ support would require embedding Clang in JVM — painful. |
| Everything in Python | Performance and distribution concerns; slower iteration for graph engine. |
| LSP-based static analysis | LSPs are interactive servers; too much latency and state management for batch extraction. |
| OpenRewrite for Java static | Excellent for refactoring; heavier than needed for IR extraction. JDT is simpler. |
| Javassist for instrumentation | ByteBuddy is more expressive and better maintained. Javassist is legacy. |

---

## 11. Strategic Notes

### 11.1 Your Competitive Moat

The value is not in being a better static analyzer. GitHub Copilot, Cursor, and Sourcegraph already do static analysis. The moat is:

- **Runtime-grounded slicing.** Knowing which code was actually executed for a specific scenario, under specific config, is something no static tool can replicate. This is observable only from inside the running JVM.
- **Config-aware context.** For Spring-heavy enterprise code, config is behavior. Capturing which config keys resolved to which values during a specific run — and which branches that influenced — is uniquely powerful.
- **Language-neutral IR platform.** The adapter architecture means each new language supported compounds the platform's value without rewriting the core.
- **Enterprise monolith specialization.** The "Spring + DI + autowiring + property-driven branching" environment is specifically the scenario where AI assistants fail most dramatically today. That is your beachhead.

### 11.2 Hardest Engineering Problems (Priority Order)

1. Filtering Spring framework noise from business logic — this is the #1 ongoing engineering challenge
2. Correctly reconstructing Spring's DI graph under specific config conditions (post-MVP)
3. Handling CGLIB proxies and correctly mapping proxy classes back to original types
4. Keeping in-memory trace aggregation bounded for long-running or high-traffic scenarios
5. Handling async / thread pool execution where `ThreadLocal` call stacks break down
6. Achieving deterministic IR output across different builds of the same source

### 11.3 What to Validate First

Before building the full platform, validate the core hypothesis with the simplest possible version:

1. Pick one specific Spring service in a real large codebase (your own experience is an advantage here)
2. Hand-write a minimal slice of the relevant files and call path for one scenario
3. Feed that hand-crafted slice to Claude with a real task
4. Compare quality of response to feeding Claude the full repo or a naive file selection
5. If the slice produces meaningfully better output — you have product-market fit signal. Build from there.

### 11.4 Go-To-Market Note

The sales motion is: find engineering leads at large enterprises who are already trying to use AI coding tools on their monolith and are frustrated with the quality. Your pitch is not "use AI" — they're already trying. Your pitch is: "here is why it's failing, and here is the runtime-grounded context layer that fixes it."

---

*Context Slice — Architecture v1.0 — Confidential*
