# Context Slice — Technical Implementation Document

**Version:** 0.1 — MVP
**Derived from:** Architecture v1.0

---

## Table of Contents

1. [Repository Layout](#1-repository-layout)
2. [System Map](#2-system-map)
3. [Subsystem: Zig Core](#3-subsystem-zig-core)
4. [Subsystem: Java Adapter](#4-subsystem-java-adapter)
5. [Subsystem: ByteBuddy Agent](#5-subsystem-bytebuddy-agent)
6. [Shared Artifact Space — `.context-slice/`](#6-shared-artifact-space----context-slice)
7. [Subsystem Boundaries](#7-subsystem-boundaries)
8. [Data Flow Summary](#8-data-flow-summary)

---

## 1. Repository Layout

```
context-slicer/                          # Repo root
  ├── context-slicer/                    # Zig core binary
  │   ├── build.zig
  │   ├── build.zig.zon
  │   └── src/
  │       ├── main.zig
  │       ├── cli/
  │       ├── orchestrator/
  │       ├── ir/
  │       ├── graph/
  │       ├── compression/
  │       ├── packager/
  │       ├── ai/
  │       └── util/
  ├── context-adapter-java/              # Java adapter subprocess (fat JAR)
  │   ├── pom.xml
  │   └── src/main/java/com/contextslice/adapter/
  ├── context-agent-java/                # ByteBuddy Java Agent (separate JAR)
  │   ├── pom.xml
  │   └── src/main/java/com/contextslice/agent/
  └── TECHNICAL_IMPLEMENTATION.md
```

The Zig core and Java components are **separate build artifacts**. The Zig binary ships alongside the adapter JAR and agent JAR. The agent JAR must be a separate artifact because it is attached via `-javaagent:` to the *target application's* JVM, not to the adapter's JVM.

---

## 2. System Map

```
┌───────────────────────────────────────────────────────────┐
│                     ZIG CORE BINARY                       │
│                                                           │
│  ┌────────────┐    ┌──────────────────┐                   │
│  │  CLI Layer │───▶│  Orchestrator    │                   │
│  └────────────┘    └────────┬─────────┘                   │
│                             │ spawns subprocess            │
│                             ▼                             │
│  ┌──────────────────────────────────────────────────────┐ │
│  │               IR Layer                               │ │
│  │  Loader ──▶ Validator ──▶ Merger ──▶ IR Types        │ │
│  └────────────────────────┬─────────────────────────────┘ │
│                           ▼                               │
│  ┌──────────────────────────────────────────────────────┐ │
│  │               Graph Layer                            │ │
│  │  Builder ──▶ Graph ──▶ Traversal ──▶ Expansion       │ │
│  └────────────────────────┬─────────────────────────────┘ │
│                           ▼                               │
│  ┌──────────────────────────────────────────────────────┐ │
│  │            Compression Layer                         │ │
│  │  Filter ──▶ Dedup ──▶ Compressor                     │ │
│  └────────────────────────┬─────────────────────────────┘ │
│                           ▼                               │
│  ┌──────────────────────────────────────────────────────┐ │
│  │               Packager Layer                         │ │
│  │  architecture_writer · config_writer · packager      │ │
│  └────────────────────────┬─────────────────────────────┘ │
│                           ▼                               │
│  ┌──────────────────────────────────────────────────────┐ │
│  │             AI Integration Layer                     │ │
│  │  prompt_builder ──▶ claude (HTTP client)             │ │
│  └──────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────┘
          │ file IPC (manifest.json)       ▲
          │                               │ file IPC (IR JSON files)
          ▼                               │
┌───────────────────────────────────────────────────────────┐
│              JAVA ADAPTER (subprocess JAR)                │
│                                                           │
│  AdapterMain ──▶ ManifestReader                           │
│       │                                                   │
│       ├──▶ ┌──────────────────────────┐                   │
│       │    │   Static Analysis Module │                   │
│       │    │  SourceRootResolver      │                   │
│       │    │  JdtAstParser            │                   │
│       │    │  SymbolExtractor         │                   │
│       │    │  CallEdgeExtractor       │                   │
│       │    │  AnnotationProcessor     │                   │
│       │    └──────────────────────────┘                   │
│       │                                                   │
│       ├──▶ ┌──────────────────────────┐                   │
│       │    │  Runtime Instrumenta-    │                   │
│       │    │  tion Module             │                   │
│       │    │  BuildRunner             │                   │
│       │    │  AgentLauncher           │                   │
│       │    └──────────────────────────┘                   │
│       │                                                   │
│       └──▶ ┌──────────────────────────┐                   │
│            │  IR Emitter              │                   │
│            │  IrMerger                │                   │
│            │  IrSerializer            │                   │
│            └──────────────────────────┘                   │
└───────────────────────────────────────────────────────────┘
                         │ -javaagent:
                         ▼
          ┌──────────────────────────────────┐
          │    BYTEBUDDY AGENT JAR           │
          │   (attached to target app JVM)   │
          │                                  │
          │  AgentBootstrap                  │
          │  MethodAdvice                    │
          │  ConfigAdvice                    │
          │  RuntimeTracer                   │
          │  ShutdownHook ──▶ runtime_trace.json │
          └──────────────────────────────────┘
```

---

## 3. Subsystem: Zig Core

### 3.1 CLI Layer

**Location:** `context-slicer/src/cli/`
**Role:** Parse command-line arguments and dispatch to the correct command handler. No business logic lives here.

| File | Struct / Function | Responsibility |
|---|---|---|
| `main.zig` | `main()` | Process entry point; initializes allocator, calls `cli.run()` |
| `cli/cli.zig` | `Cli`, `run()` | Parses `argv`, routes to subcommand handler |
| `cli/commands/record.zig` | `RecordCommand`, `execute()` | Handles `context-slice record <scenario>` |
| `cli/commands/slice.zig` | `SliceCommand`, `execute()` | Handles `context-slice slice` (re-compress existing IR) |
| `cli/commands/prompt.zig` | `PromptCommand`, `execute()` | Handles `context-slice prompt "<task>"` |
| `cli/commands/diff.zig` | `DiffCommand`, `execute()` | Post-MVP: `context-slice diff <s1> <s2>` |

**Boundary out:** Each command handler receives a fully parsed `Args` struct and delegates immediately to the Orchestrator or AI Integration layer. The CLI layer never reads IR or constructs graphs.

---

### 3.2 Orchestrator Layer

**Location:** `context-slicer/src/orchestrator/`
**Role:** Detect repo type, set up the working directory, write `manifest.json`, spawn and supervise the adapter subprocess, validate adapter exit.

| File | Struct / Function | Responsibility |
|---|---|---|
| `orchestrator/orchestrator.zig` | `Orchestrator`, `run()` | Top-level coordination: detect → manifest → spawn → wait |
| `orchestrator/detector.zig` | `RepoDetector`, `detect()` | Scans for `pom.xml`, `build.gradle`, `mvnw`, `go.mod`, etc.; returns `Language` enum |
| `orchestrator/manifest.zig` | `Manifest`, `write()` | Constructs and serializes `manifest.json` to `.context-slice/` |
| `orchestrator/subprocess.zig` | `Subprocess`, `spawn()`, `wait()` | Cross-platform subprocess launch, stdout/stderr capture, exit code handling |

**Key types:**

```zig
// orchestrator/detector.zig
pub const Language = enum { java, go, python, cpp, unknown };

// orchestrator/manifest.zig
pub const Manifest = struct {
    scenario_name: []const u8,
    entry_points: []const []const u8,
    run_args: []const []const u8,
    config_files: []const []const u8,
    output_dir: []const u8,
};
```

**Boundary in:** `RecordCommand.execute()` provides scenario name and CLI flags.
**Boundary out:** Adapter subprocess is launched; Orchestrator blocks until it exits with code 0. On success, hands control to the IR Loader. On failure, emits an error and exits.

---

### 3.3 IR Layer

**Location:** `context-slicer/src/ir/`
**Role:** Parse, validate, and merge the two JSON files emitted by the adapter. This layer is the correctness gate — malformed or incompatible IR never reaches the graph layer.

| File | Struct / Function | Responsibility |
|---|---|---|
| `ir/types.zig` | `IrFile`, `Symbol`, `CallEdge`, `ConfigRead`, `RuntimeEntry`, `IrRoot` | Canonical in-memory IR types used by all downstream layers |
| `ir/loader.zig` | `IrLoader`, `loadStatic()`, `loadRuntime()` | Reads and JSON-parses `static_ir.json` and `runtime_trace.json` |
| `ir/validator.zig` | `IrValidator`, `validate()` | Checks `ir_version` compatibility; rejects symbols with missing IDs or null file refs; logs warnings for quarantined symbols |
| `ir/merger.zig` | `IrMerger`, `merge()` | Joins static symbols with runtime observation data; annotates `CallEdge.runtime_observed` and `call_count`; deduplicates symbols |

**Key types:**

```zig
// ir/types.zig
pub const Symbol = struct {
    id: []const u8,
    kind: SymbolKind,          // .class, .method, .constructor, .interface
    name: []const u8,
    language: []const u8,
    file_id: []const u8,
    line_start: u32,
    line_end: u32,
    visibility: []const u8,
    container: ?[]const u8,
    annotations: []const []const u8,
    is_entry_point: bool,
    is_framework: bool,
    is_generated: bool,
};

pub const CallEdge = struct {
    caller: []const u8,        // Symbol ID
    callee: []const u8,        // Symbol ID
    static: bool,
    runtime_observed: bool,
    call_count: u64,
};

pub const ConfigRead = struct {
    symbol_id: []const u8,
    config_key: []const u8,
    resolved_value: []const u8,
    source_file: []const u8,
};
```

**Boundary in:** `.context-slice/static_ir.json`, `.context-slice/runtime_trace.json`
**Boundary out:** A merged `IrRoot` struct containing deduplicated symbols, annotated call edges, and config reads. This is handed to the Graph Builder.

---

### 3.4 Graph Layer

**Location:** `context-slicer/src/graph/`
**Role:** Construct an in-memory weighted directed graph from the merged IR. Build and expose the hot path. Run neighborhood expansion.

| File | Struct / Function | Responsibility |
|---|---|---|
| `graph/graph.zig` | `Graph`, `addNode()`, `addEdge()`, `getNeighbors()` | Core directed graph: nodes are symbol IDs (string keys), edges carry weight and metadata |
| `graph/builder.zig` | `GraphBuilder`, `build()` | Iterates merged IR; inserts symbol nodes, call edges (weighted by `call_count`), config dependency edges, file ownership entries |
| `graph/traversal.zig` | `Traversal`, `hotPath()`, `bfs()`, `dfs()` | BFS/DFS traversal; extracts hot path (symbols with `call_count > 0`) sorted by call frequency |
| `graph/expansion.zig` | `NeighborhoodExpander`, `expand()` | Radius-1 expansion from hot path; interface resolution; config file inclusion |

**Key types:**

```zig
// graph/graph.zig
pub const EdgeMeta = struct {
    call_count: u64,
    runtime_observed: bool,
    static: bool,
};

pub const Graph = struct {
    nodes: std.StringHashMap(Symbol),
    edges: std.ArrayList(Edge),
    file_map: std.StringHashMap([]const u8),  // symbol_id -> file_path
    // ...
};
```

**Boundary in:** Merged `IrRoot` from the IR Layer.
**Boundary out:** A `Graph` struct and an ordered `hot_path: []const []const u8` (symbol ID slice). These are consumed by the Compression Layer.

---

### 3.5 Compression Layer

**Location:** `context-slicer/src/compression/`
**Role:** Reduce the expanded graph to a minimal, high-signal slice. Remove noise. Produce the final set of symbols and files to include in AI context.

| File | Struct / Function | Responsibility |
|---|---|---|
| `compression/filter.zig` | `FrameworkFilter`, `apply()` | Removes nodes where `is_framework=true` unless explicitly included by expansion; drops edges below configurable `call_count` threshold |
| `compression/dedup.zig` | `StackDeduplicator`, `deduplicate()` | Collapses recursive call patterns; removes duplicate edges between the same caller/callee pair |
| `compression/compressor.zig` | `Compressor`, `compress()` | Orchestrates filter → dedup → ordering; produces a `Slice` struct: ordered symbol list, file list, config influence summary |

**Key types:**

```zig
// compression/compressor.zig
pub const Slice = struct {
    ordered_symbols: []const Symbol,    // entry point to leaves, post-compression
    relevant_file_paths: []const []const u8,
    config_influences: []const ConfigInfluence,
    call_graph_edges: []const CallEdge,
};

pub const ConfigInfluence = struct {
    config_key: []const u8,
    resolved_value: []const u8,
    source_file: []const u8,
    influenced_symbols: []const []const u8,
};
```

**Boundary in:** `Graph` + hot path from the Graph Layer.
**Boundary out:** A `Slice` struct. This is the final compressed representation passed to the Packager.

---

### 3.6 Packager Layer

**Location:** `context-slicer/src/packager/`
**Role:** Write the `Slice` to human- and AI-readable files in `.context-slice/`. This is the final output of the `record` and `slice` commands.

| File | Struct / Function | Responsibility |
|---|---|---|
| `packager/architecture_writer.zig` | `ArchitectureWriter`, `write()` | Generates `architecture.md`: ordered call path narrative from entry point to leaf symbols |
| `packager/config_writer.zig` | `ConfigWriter`, `write()` | Generates `config_usage.md`: table of config keys, resolved values, and which code paths they influenced |
| `packager/packager.zig` | `Packager`, `pack()` | Orchestrates all writers; writes `relevant_files.txt`, `call_graph.json`, `metadata.json` |

**Output files written:**

| File | Format | Consumer |
|---|---|---|
| `architecture.md` | Markdown | AI context preamble |
| `relevant_files.txt` | Newline-delimited paths | AI Integration Layer |
| `call_graph.json` | JSON | AI context, debugging |
| `config_usage.md` | Markdown | AI context preamble |
| `metadata.json` | JSON | Freshness checks, versioning |

**Boundary in:** `Slice` from Compression Layer.
**Boundary out:** Files written to `.context-slice/`. Control returns to the CLI.

---

### 3.7 AI Integration Layer

**Location:** `context-slicer/src/ai/`
**Role:** Read the packaged slice, assemble a Claude prompt, call the API, and stream the response to the terminal. Activated by the `prompt` subcommand.

| File | Struct / Function | Responsibility |
|---|---|---|
| `ai/prompt_builder.zig` | `PromptBuilder`, `build()` | Reads `relevant_files.txt`, loads file contents, prepends `architecture.md` + `config_usage.md`, appends user task |
| `ai/claude.zig` | `ClaudeClient`, `complete()` | HTTP POST to Anthropic Messages API; streams response chunks to stdout |

**Boundary in:** `.context-slice/` directory (reads packaged output) + user task string from CLI.
**Boundary out:** Streamed Claude response to terminal.

---

### 3.8 Utility Layer

**Location:** `context-slicer/src/util/`
**Role:** Shared helpers. No business logic.

| File | Purpose |
|---|---|
| `util/json.zig` | Thin helpers over `std.json` for common parse/serialize patterns |
| `util/fs.zig` | Directory creation, path joining, recursive file reads |
| `util/hash.zig` | SHA-256 file hashing for `metadata.json` build ID fields |

---

## 4. Subsystem: Java Adapter

**Location:** `context-adapter-java/src/main/java/com/contextslice/adapter/`
**Build artifact:** `context-adapter-java.jar` (fat JAR via Maven Assembly or Shade plugin)
**Role:** All Java-specific extraction. Runs as a subprocess. Never linked into the Zig core.

### 4.1 Entry Point & Manifest

| Class | Responsibility |
|---|---|
| `AdapterMain` | `public static void main(String[] args)`: parses `--manifest` and `--output` flags; orchestrates static analysis → build → runtime → IR emission phases sequentially |
| `manifest.ManifestReader` | Reads and deserializes `manifest.json` into a `ManifestConfig` POJO |
| `manifest.ManifestConfig` | POJO: `scenarioName`, `entryPoints`, `runArgs`, `configFiles`, `outputDir` |

---

### 4.2 Static Analysis Module

**Package:** `com.contextslice.adapter.static_analysis`

| Class | Responsibility |
|---|---|
| `StaticAnalyzer` | Orchestrates the full static analysis pass; returns `StaticIr` aggregate |
| `SourceRootResolver` | Parses `pom.xml` (via Maven Model) or `build.gradle` (text heuristic) to find `src/main/java` roots and classpath jars |
| `JdtAstParser` | Initializes Eclipse JDT `ASTParser`; sets `setResolveBindings(true)`, `setEnvironment()` with classpath; triggers multi-file parse across all source roots |
| `SymbolExtractor` | `ASTVisitor` subclass: visits `TypeDeclaration`, `MethodDeclaration`, `FieldDeclaration`; builds `List<IrSymbol>` |
| `CallEdgeExtractor` | `ASTVisitor` subclass: visits `MethodInvocation`, `ClassInstanceCreation`; resolves bindings to fully-qualified names; builds `List<IrCallEdge>` |
| `AnnotationProcessor` | Inspects annotation lists on symbols; sets `isFramework=true` for Spring stereotypes (`@Component`, `@Service`, `@Repository`, `@Controller`, `@Bean`); records annotation strings |

**Key Spring annotations flagged as `isFramework=true`:**
`@Component`, `@Service`, `@Repository`, `@Controller`, `@RestController`, `@Configuration`, `@Bean`, `@Autowired`, `@Transactional`, `@Scheduled`, `@EventListener`

---

### 4.3 Build Module

**Package:** `com.contextslice.adapter.build`

| Class | Responsibility |
|---|---|
| `BuildRunner` | Invokes `mvn package -DskipTests` or `gradle assemble` via `ProcessBuilder`; returns path to produced JAR; throws on non-zero exit |

---

### 4.4 Runtime Instrumentation Module

**Package:** `com.contextslice.adapter.runtime`

| Class | Responsibility |
|---|---|
| `AgentLauncher` | Constructs the `java -javaagent:context-agent.jar -jar <app.jar> <run_args>` command; launches it via `ProcessBuilder`; streams stdout/stderr; waits for process exit; returns path to `runtime_trace.json` written by the agent's shutdown hook |

Note: `AgentLauncher` does **not** contain the agent logic — it only launches the target JVM. The agent logic lives in the separate `context-agent-java` module (Section 5).

---

### 4.5 IR Emitter

**Package:** `com.contextslice.adapter.ir`

| Class | Responsibility |
|---|---|
| `IrModel` | POJOs matching the IR schema: `IrRoot`, `IrFile`, `IrSymbol`, `IrCallEdge`, `IrConfigRead`, `IrRuntime`, `IrObservedSymbol` |
| `SymbolIdGenerator` | Produces deterministic IDs: `java::<fully-qualified-class>::<method>(<param-types>)` |
| `IrMerger` | Joins `StaticIr` (from static analysis) with `RuntimeTrace` (from agent output file); annotates each `IrCallEdge` with `runtimeObserved` and `callCount` from the runtime data; deduplicates symbols |
| `IrSerializer` | Serializes merged `IrRoot` to `static_ir.json` (static phase) and forwards `runtime_trace.json` (already written by agent); also writes `metadata.json` |

**Serialization contract:** All arrays are sorted by `id` before serialization for deterministic output. Uses Gson with `GsonBuilder().setPrettyPrinting()`.

---

## 5. Subsystem: ByteBuddy Agent

**Location:** `context-agent-java/src/main/java/com/contextslice/agent/`
**Build artifact:** `context-agent.jar` — must declare `Premain-Class` in `MANIFEST.MF`
**Role:** Attached via `-javaagent:` to the *target application's* JVM. Instruments app methods at class-load time. Aggregates call data in memory. Writes `runtime_trace.json` on JVM shutdown.

| Class | Responsibility |
|---|---|
| `AgentBootstrap` | `premain(String args, Instrumentation inst)`: configures `AgentBuilder.Default()` with type matchers excluding CGLIB/JDK proxies; installs method advice and config advice; registers shutdown hook |
| `MethodAdvice` | `@Advice.OnMethodEnter`: peeks current caller from thread-local stack; records call edge; pushes self. `@Advice.OnMethodExit`: pops self from stack |
| `ConfigAdvice` | `@Advice.OnMethodExit` on `AbstractEnvironment.getProperty(String)`: records `(currentMethod, key, returnValue)` to `RuntimeTracer.configReads` |
| `RuntimeTracer` | Static class: `ThreadLocal<Deque<String>> stack`; `ConcurrentHashMap<String, LongAdder> methodCounts`; `ConcurrentHashMap<String, LongAdder> edgeCounts`; `ConcurrentHashMap<String, String> configReads`; static `push/pop/peek/recordEdge/recordConfig` methods |
| `ShutdownHook` | `Runnable` registered with `Runtime.getRuntime().addShutdownHook()`: builds `RuntimeTrace` POJO from `RuntimeTracer` maps; serializes to `runtime_trace.json` via Gson |
| `RuntimeTrace` | POJO: `List<ObservedSymbol>`, `List<ObservedEdge>`, `List<ConfigRead>` — matches the `runtime` block of the IR schema |

**Type matcher configuration in `AgentBootstrap`:**

```
include: nameStartsWith("com.company")          // restrict to app namespace
exclude: nameContains("$$EnhancerBySpring")     // CGLIB proxies
exclude: nameContains("$Proxy")                 // JDK dynamic proxies
exclude: nameContains("CGLIB")                  // other CGLIB artifacts
```

---

## 6. Shared Artifact Space — `.context-slice/`

This directory is the **sole communication channel** between the Zig core and the Java adapter. It is created by the Zig Orchestrator before the adapter is spawned and is read back by the Zig IR Loader after the adapter exits.

```
.context-slice/
  manifest.json          # Written by Zig Orchestrator → read by Java Adapter
  static_ir.json         # Written by Java Adapter (static phase) → read by Zig IR Loader
  runtime_trace.json     # Written by ByteBuddy Agent (via ShutdownHook) → read by Zig IR Loader
  metadata.json          # Written by Java Adapter (IR Emitter) → read by Zig Packager
  architecture.md        # Written by Zig Packager → read by AI Integration Layer
  relevant_files.txt     # Written by Zig Packager → read by AI Integration Layer
  call_graph.json        # Written by Zig Packager → optional debugging
  config_usage.md        # Written by Zig Packager → read by AI Integration Layer
```

**Schema versioning:** `static_ir.json` and `runtime_trace.json` carry `ir_version` fields. The Zig IR Validator checks these against the compiled-in `SUPPORTED_IR_VERSION` constant. A mismatch causes an early, clear error.

---

## 7. Subsystem Boundaries

### Boundary 1: CLI Layer → Orchestrator / AI Layer

**Direction:** One-way call
**Contract:** `RecordCommand.execute()` and `SliceCommand.execute()` pass a typed `RecordArgs` / `SliceArgs` struct to `Orchestrator.run()`. `PromptCommand.execute()` passes a `PromptArgs` struct to `PromptBuilder`. The CLI layer holds no state after dispatch.

---

### Boundary 2: Zig Orchestrator ↔ Java Adapter (subprocess)

**Direction:** File-based IPC
**Write side (Zig):** Orchestrator writes `manifest.json` then calls `Subprocess.spawn()`.
**Read side (Java):** `AdapterMain` reads `manifest.json` via `ManifestReader`.
**Return path (Java → Zig):** Adapter writes `static_ir.json`, `runtime_trace.json`, `metadata.json` to `.context-slice/` then exits 0.
**Contract enforcement:** Zig waits on the subprocess exit code. Non-zero exit aborts with an error. Zig IR Validator enforces schema version on the produced files.
**No shared memory, no sockets, no RPC.** This boundary is intentionally coarse.

---

### Boundary 3: Java Adapter ↔ ByteBuddy Agent (separate JVM)

**Direction:** File-based IPC (one-way: agent writes)
**Write side (Agent):** `ShutdownHook` writes `runtime_trace.json` to the output path passed via agent args.
**Read side (Adapter):** `AgentLauncher` waits for the target JVM to exit, then passes the `runtime_trace.json` path to `IrMerger`.
**Contract:** The agent JAR is a separate build artifact. The adapter only cares about the file it produces — not how it was produced.

---

### Boundary 4: IR Layer → Graph Layer

**Direction:** In-process struct handoff
**Contract:** `IrMerger.merge()` returns an `IrRoot` struct. `GraphBuilder.build()` accepts `IrRoot` and produces `Graph`. No JSON serialization crosses this boundary. The IR Layer is responsible for correctness; the Graph Layer assumes a valid, deduplicated `IrRoot`.

---

### Boundary 5: Graph Layer → Compression Layer

**Direction:** In-process struct handoff
**Contract:** `GraphBuilder.build()` returns a `Graph`. `NeighborhoodExpander.expand()` returns an expanded `Graph` + `hot_path`. `Compressor.compress()` accepts both and returns a `Slice`. The Graph Layer does not make decisions about what to include or exclude — that is the Compression Layer's responsibility.

---

### Boundary 6: Compression Layer → Packager Layer

**Direction:** In-process struct handoff
**Contract:** `Compressor.compress()` returns a `Slice` struct. `Packager.pack()` accepts `Slice` and writes files. The Packager does not filter or score — it faithfully serializes what the Compression Layer produced.

---

### Boundary 7: Packager Layer → AI Integration Layer

**Direction:** File system
**Contract:** The AI Integration Layer reads `.context-slice/` — specifically `relevant_files.txt`, `architecture.md`, and `config_usage.md`. It also reads the source files listed in `relevant_files.txt` directly from the repo. This boundary is intentionally file-based so the packaged slice can be inspected, version-controlled, or reused by multiple `prompt` invocations without re-running the full pipeline.

---

## 8. Data Flow Summary

```
User
  │
  │  context-slice record submit-order --config app-prod.yml
  ▼
CLI Layer (cli.zig, commands/record.zig)
  │  RecordArgs
  ▼
Orchestrator (orchestrator.zig, detector.zig, manifest.zig, subprocess.zig)
  │  writes manifest.json → spawns java -jar context-adapter-java.jar
  ▼
Java Adapter (AdapterMain)
  ├── StaticAnalyzer → JDT AST walk → List<IrSymbol>, List<IrCallEdge>
  ├── BuildRunner → mvn package → app.jar
  ├── AgentLauncher → launches app with context-agent.jar
  │     └── ByteBuddy Agent (in target JVM)
  │           RuntimeTracer accumulates call data during scenario
  │           ShutdownHook → runtime_trace.json
  └── IrMerger + IrSerializer → static_ir.json, metadata.json
  │  exits 0
  ▼
IR Layer (loader.zig, validator.zig, merger.zig)
  │  IrRoot (merged, validated, deduplicated)
  ▼
Graph Layer (builder.zig, graph.zig, traversal.zig, expansion.zig)
  │  Graph + hot_path
  ▼
Compression Layer (filter.zig, dedup.zig, compressor.zig)
  │  Slice
  ▼
Packager Layer (packager.zig, architecture_writer.zig, config_writer.zig)
  │  writes .context-slice/{architecture.md, relevant_files.txt, ...}
  ▼
  [record command completes]

User
  │
  │  context-slice prompt "Add idempotency to order submission"
  ▼
CLI Layer (commands/prompt.zig)
  │  PromptArgs
  ▼
AI Integration Layer (prompt_builder.zig, claude.zig)
  │  reads .context-slice/ + source files
  │  POST /v1/messages to Anthropic API
  ▼
Claude response streamed to terminal
```

---

*Context Slice — Technical Implementation Document v0.1 — MVP*
