# Context Slicer — Code Review Guide

> **Purpose**: A reviewer's pathway through the codebase. Organized as the data flows, not alphabetically. Each section tells you what to look at, why it matters, and what questions to ask.

---

## 0. Orientation

The system has three physical components:

| Component | Language | Role |
|-----------|----------|------|
| `context-slicer/` | Zig | Core engine: CLI, graph pipeline, packager, AI call |
| `context-adapter-java/` | Java | Static analysis (JDT) + runtime instrumentation (ByteBuddy) |
| `context-agent-java/` | Java | ByteBuddy agent; attaches to target JVM at record time |

The Zig binary is the **orchestrator**. It never touches Java source directly — it drives the Java adapter as a subprocess via file IPC (a `manifest.json` in, IR JSON files out). The review pathway below covers the **Zig side only** (the code I wrote). The Java adapter is a separate review.

---

## 1. Start Here: Entry Point

**File**: `src/main.zig`

This is the right first file. It shows:
- How the allocator is set up (`GeneralPurposeAllocator` with leak detection in debug builds)
- The `--verbose` flag scan (linear argv scan before subcommand dispatch)
- JAR path resolution (env var `CONTEXT_SLICER_ADAPTER_JAR` → file fallback → error)
- Subcommand dispatch: `record`, `slice`, `prompt`
- Top-level error handling and exit codes

**Questions to ask here:**
- Is leak detection actually active in debug mode? Check `.detectLeaks()` call.
- The JAR path fallback uses a relative path — does that hold when the binary is installed system-wide?
- Error messages written to stderr use `catch {}` — is it acceptable to silently swallow write failures?

---

## 2. CLI Layer

### `src/cli/cli.zig`
Thin router. Maps argv[1] to a `SubcommandTag` enum. Little logic lives here — worth a quick read to confirm no edge cases in unknown-subcommand handling.

### `src/cli/commands/record.zig`
Parses the `record` subcommand arguments into `RecordArgs`.

**Critical to review:**
- The `--args` flag splits on spaces to produce `run_args: [][]const u8`. This is naive — it breaks if any run arg contains a space. Consider whether this is acceptable for MVP.
- `RecordArgs` is stack-allocated and owns no heap memory — the slices point into the original `argv`. Review that nothing outlives the argv lifetime.

### `src/cli/commands/slice.zig`
This is the **main pipeline orchestrator** for the `slice` command. Read it top-to-bottom — it's the spine of everything.

```
loadStatic → validate → loadRuntime (optional) → merge → build graph
    → hotPath → expand → compress → pack
```

**Critical to review:**
- Runtime trace has two fallback paths: `runtime/runtime_trace.json` (adapter layout) and `runtime_trace.json` (top-level fallback). Confirm both are needed and the precedence is correct.
- All intermediate `defer` calls — trace them to confirm no intermediate value leaks on error paths.
- The temporary `std.debug.print` error logging is still in place from debugging. These should either become `log.debug` calls or be removed before release.

### `src/cli/commands/prompt.zig`
Implements `context-slicer prompt <task>`. Checks slice health (age threshold, runtime_captured flag), then calls Claude.

**Questions:**
- The age threshold is hardcoded — is there a config for this?
- Slice health check reads `metadata.json` — what happens if the file is malformed or missing a field?

---

## 3. IR Layer (The Contract)

The IR layer is the most important contract in the system — it's the boundary between the Java adapter (which we don't control at runtime) and the Zig pipeline.

### `src/ir/types.zig` — Read This Carefully

Every struct here is a parsed JSON shape. Fields that are **missing from the JSON trigger `MissingField`** errors unless they have default values in Zig. This is the most fragile part of the codebase.

**Current defaults added for adapter compatibility:**

| Struct | Field | Default |
|--------|-------|---------|
| `IrRoot` | `build_id` | `""` |
| `Scenario` | `run_args` | `&.{}` |
| `Scenario` | `config_files` | `&.{}` |

**Questions:**
- `CallEdge.@"static"` — the Zig field name uses the keyword escape. The JSON key is `"static"`. Verify this round-trips correctly with the parser. (The Zig JSON parser maps struct field names to JSON keys directly, including the escaped name.)
- `Symbol.file_id` and `Symbol.container` are `?[]const u8` — the parser treats absent JSON keys as `null` for optional types. Confirm this is the correct semantic (a symbol without a `file_id` is valid? In what cases?).
- `ConfigRead.resolved_value` is `?[]const u8` — JSON `null` and JSON absent are both treated as Zig `null`. Is that the right merge behavior?
- `SymbolKind` enum: `class`, `method`, `constructor`, `interface`. If the adapter emits a new kind (e.g., `enum`, `record`), parsing will fail with `UnknownField`. Consider adding a fallback or explicit versioning check.

### `src/ir/loader.zig`
Thin wrapper over `json_util.parseTypedFromFile`. No logic here — its test cases are the important artifact. Review: do the fixture paths in tests match the actual test-fixtures layout?

### `src/ir/validator.zig`

**Critical section.** Validates the loaded IR before the graph sees it.

Review the quarantine logic:
- Symbols referencing a `file_id` that doesn't exist in `files[]` → quarantined
- Call edges where either endpoint isn't in the symbol set → quarantined
- IR version check: hard error on mismatch (not just a warning)

**Questions:**
- What's the policy on quarantined symbols? They're dropped silently — should there be a warning written to stderr? The user won't know if 20% of their IR was discarded.
- Is the version check a string equality (`"0.1" == "0.1"`) or a semver comparison? Patch-version mismatches would fail hard.
- `ValidationResult` holds slices that point into the original `Parsed(IrRoot)` arena — the caller must keep the `Parsed` alive. Is this documented/enforced?

### `src/ir/merger.zig`

Merges static IR + runtime trace into `MergedIr`. This is where call counts get enriched.

**Review:**
- Edge deduplication key: how are static edges that match runtime edges merged? Specifically: if the same `caller→callee` pair appears in both static and runtime, does `call_count` sum or does runtime win?
- `config_reads` from runtime trace — how are they merged with static config reads? Deduplicated by key? By `(symbol_id, key)` pair?
- `MergedIr` owns its own allocations — trace the `deinit` to confirm nothing leaks.

---

## 4. Graph Layer

### `src/graph/graph.zig`

The core data structure. Uses `StringHashMap(Symbol)` for nodes and `StringHashMap(ArrayListUnmanaged(Edge))` for adjacency.

**Critical:**
- Keys in the hash maps are **string slices pointing into the IR arena**. The `Graph` does not own copies of these strings. If the arena is freed before the graph, you get dangling pointers. Confirm the lifetime ordering in `slice.zig`: `static_ir` and `merged_ir` are deferred before `g`.
- `nodeCount()` and `edgeCount()` — used only for logging; confirm they're not used in any algorithmic invariant.

### `src/graph/builder.zig`

Populates the graph from `MergedIr`. Also builds `file_map: StringHashMap(IrFile)` for path lookups in the packager.

**Review:** Does `build()` validate that an edge's endpoint nodes exist before adding the edge, or does it trust the validator did that? If the validator was bypassed, this could produce a graph with orphaned edges.

### `src/graph/traversal.zig`

`hotPath()` returns the set of symbols reachable from entry points, sorted by descending call count.

**Review:**
- What happens when `runtime_observed = false` for all edges (static-only run)? All call counts are 0 — the hot path is the full reachable set, sorted arbitrarily. Is that acceptable?
- BFS vs DFS: which is used and why? For hot path extraction, BFS gives level-order (closer-to-entry-point first) which is usually more useful for context.

### `src/graph/expansion.zig`

Expands the hot path by radius-1 neighbors and interface implementations.

**Review:**
- "Radius-1 neighbor" means: for each symbol in the hot path, add all direct callers and callees. This can significantly inflate the slice on dense graphs. Is there a size limit?
- Interface resolution: how are interfaces identified? By `SymbolKind.interface`? What if an abstract class acts as an interface?
- Config file reads (`config_reads`) are threaded through here — confirm they survive into the `ExpandedGraph`.

---

## 5. Compression Layer

### `src/compression/compressor.zig` — Most Complex Algorithm

This is the most algorithmically dense file. Read it with the most scrutiny.

The pipeline:
1. Filter symbols to those in the expanded set
2. Deduplicate edges (via `dedup.zig`)
3. Topological sort (Kahn's algorithm)
4. Deduplicate relevant file paths
5. Build config influence map

**Kahn's sort implementation:**
- In-degree map is built over the filtered symbol set only
- Nodes with in-degree 0 go into the initial queue
- **Cycle handling**: symbols in cycles never reach in-degree 0 and are appended at the end of the ordered output. This is correct but worth confirming: are the cycle nodes appended in a deterministic order? Non-deterministic ordering makes diffs noisy.

**Questions:**
- Entry points — are they guaranteed to appear first in the topological order? The sort is correct but not entry-point-prioritized. The prompt builder reads the architecture.md which uses this order — verify the AI prompt makes sense if entry points appear mid-list.
- Config influence map: grouped by config key, not by symbol. Is that the right grouping for the AI prompt?

### `src/compression/filter.zig`

Removes `is_framework = true` symbols that are not in a protected set (e.g., `@RestController` is kept because it's diagnostic; generic Spring internals are dropped).

**Review:**
- The protected set is hardcoded. For a different framework (not Spring), it would need updating. Is this configurable?
- What's the effect on call edges when a framework node is removed? Are edges through the removed node reconnected or just dropped?

### `src/compression/dedup.zig`

`deduplicateEdges()`: key = `"caller\x00callee"`. For duplicate edges, sums `call_count` and ORs `runtime_observed`.

`collapseRecursion()`: removes 2-node back-edges (A→B and B→A compressed to A→B with ORed flags).

**Questions:**
- The `\x00` separator in edge keys — is it possible for a symbol ID to contain `\x00`? Java class names shouldn't, but the IR schema doesn't prohibit it.
- Recursion collapse removes the B→A direction. If A and B are both in the hot path independently, is that information lost?

---

## 6. Packager Layer

### `src/packager/packager.zig`

Writes 5 output files to `.context-slice/`:

| File | Content |
|------|---------|
| `architecture.md` | Hot path as numbered call list + source file map |
| `config_usage.md` | Markdown table: config key → value → influenced symbol |
| `relevant_files.txt` | Newline-delimited source file paths |
| `call_graph.json` | Serialized slice (symbols + edges) |
| `metadata.json` | Scenario name, timestamp, runtime_captured flag |

**Review `architecture.md` generation** (`architecture_writer.zig`):
- `displayName()` extracts `ClassName::method` from a symbol ID like `java::com.example.Foo::bar()`. Confirm this works for constructor IDs and nested class IDs.
- File paths in the source map are relative to `repo_root` — confirm the path is written as-is (adapter-relative) and not re-absolutized.

**Review `config_usage.md`** (`config_writer.zig`):
- `resolved_value` can be `null` — confirm the markdown table renders cleanly (blank cell vs literal "null").
- The "influenced by" column lists symbol IDs, not display names — should it use `displayName()`?

**Review `call_graph.json`**:
- This is serialized by `json_util.writeToFile` using `std.json.Stringify`. Confirm the output is valid JSON (no unescaped strings, proper null handling for optional fields).

---

## 7. Orchestrator Layer (Java Bridge)

### `src/orchestrator/orchestrator.zig`

The highest-risk subsystem from an IPC-correctness standpoint.

**Manifest write location**: Writes `manifest.json` to `{project_root}/manifest.json`. The Java adapter uses the manifest's parent directory as its `projectRoot`. This was a bug that was fixed — verify the test `"orchestrator: manifest written before subprocess spawned"` actually asserts the correct path.

**`buildAdapterCommand()`**: Constructs the `java -jar` argv array.
- **Shell injection**: There is no shell involved — `subprocess.Subprocess.spawn()` uses `execve`-style directly. No injection risk from symbol IDs or paths, but confirm no argv element is ever constructed from user-controlled data without validation.
- The argv hardcodes `"java"` — relies on `java` being on `$PATH`. No version check.

### `src/orchestrator/detector.zig`

Language detection via file existence checks. Maven → Gradle → Go → Python → unknown.

**Questions:**
- Multi-language repos (e.g., a Java service with a Python script) will detect Java. Is that correct?
- Only Maven (`pom.xml`) and Gradle (`build.gradle`) are supported for Java. What about Gradle Kotlin DSL (`build.gradle.kts`)?

### `src/orchestrator/subprocess.zig`

Spawns the adapter subprocess and captures its stderr.

**Critical — deadlock risk**: If the subprocess writes enough to stdout/stderr to fill the pipe buffer and no one is reading, it will block. Confirm `subprocess.zig` either:
1. Reads stderr in a separate thread/loop while waiting, OR
2. Redirects stdout to `/dev/null` and only captures stderr, OR
3. Sets non-blocking reads

This is a classic subprocess deadlock. Verify the implementation handles it.

**Review also**: What happens to the adapter's stdout? Is it passed through to the user's terminal, or discarded?

### `src/orchestrator/manifest.zig`

Simple JSON I/O. Low risk. Verify `readIfExists()` correctly returns `null` (not an error) when the file is absent.

---

## 8. AI Layer

### `src/ai/claude.zig`

Direct HTTP client to Anthropic Messages API. No SDK.

**Review:**
- `ANTHROPIC_API_KEY` is read from the environment. Confirm it is **never logged** (even at debug level).
- HTTP request body is assembled as a JSON string. Confirm the `task` string passed by the user is properly JSON-escaped before embedding. If the task contains `"` or `\`, the request body will be malformed.
- Response parsing: `parseResponseText()` extracts `content[0].text`. What happens if the response has multiple content blocks, or if `content` is empty (e.g., a refusal)?
- Error classification: does the code distinguish `401 Unauthorized` (bad key) from `429 Too Many Requests` (rate limit) from `500 Internal Server Error`? Each needs a different user message.
- **Max tokens**: hardcoded at `8192`. For large slices, the prompt itself may exceed the input context limit — no truncation logic exists.

### `src/ai/prompt_builder.zig`

Reads `architecture.md`, `config_usage.md`, `relevant_files.txt` from `.context-slice/` and assembles the prompt.

**Review:**
- `relevant_files.txt` lists source file paths — does the prompt builder read the **content** of those files? If yes, large source files could make the prompt enormous. If no, the AI only sees architecture metadata, not actual code.
- The system preamble is hardcoded in this file. Consider: is it the right framing for the task types users will ask?

---

## 9. Utilities

### `src/util/fs.zig`

Standard file I/O wrappers. Low risk. Confirm:
- `readFileAlloc` correctly propagates `FileNotFound` (not panics).
- `createDirIfAbsent` is idempotent (no error if directory already exists).

### `src/util/json.zig`

**`writeToFile`** uses `std.json.Stringify.valueAlloc` — verify this is the correct API for Zig 0.15.2. The API changed across Zig releases; a compile error here would surface immediately, but a silent behavioral difference (e.g., escaping) might not.

**`parseTypedFromSlice`** uses `.ignore_unknown_fields = true` — this is correct and intentional (adapter may add fields we don't need). Confirm `.alloc_always` is the right strategy (copies all strings into the arena; safe to free the source buffer).

### `src/util/log.zig`

A global `verbose` flag controls `log.debug()` output. Review:
- Is the flag set before any log calls could happen?
- Thread safety: if any future code is concurrent, a global mutable flag is a data race.

---

## 10. Cross-Cutting Concerns to Examine

### Memory Ownership Map

The most likely source of bugs. The ownership chain is:

```
Parsed(IrRoot)  →  owns arena  →  Symbol strings / CallEdge strings
                                        ↓
                               Graph nodes/edges (borrow, do not copy)
                                        ↓
                               Slice (borrows from MergedIr / Graph)
                                        ↓
                               Packager (reads, writes to files, no borrow)
```

**Key invariant**: `Parsed(IrRoot)` must outlive `Graph` which must outlive `Slice`. In `slice.zig`, verify the `defer` chain respects this ordering. Zig defers execute in reverse order of declaration, so the last-declared defer runs first.

### Error Propagation

Every `!T` return must be handled. Look for:
- `catch {}` (silently swallows — acceptable for write-to-stderr calls, not for logic)
- `catch unreachable` (panics in debug, undefined behavior in ReleaseFast — grep for these)
- `catch |err| return err` (correct propagation)

### Test Coverage Assessment

Assess coverage per layer:

| Layer | Test Style | Gap Risk |
|-------|------------|----------|
| IR types | Unit (struct construction) | Low |
| Loader | Integration (fixture files) | Medium — fixtures may not cover all field variants |
| Validator | Unit + error cases | Medium — quarantine logic |
| Merger | Unit | Medium — merge conflict cases |
| Graph | Unit | Low |
| Traversal | Unit (fixture graph) | Medium — cycle behavior |
| Compressor | End-to-end (`runAndPackM3`) | High — no isolated unit tests for topo sort |
| Packager | End-to-end | Medium — file content correctness |
| Orchestrator | Unit (error paths only) | High — no subprocess happy-path test |
| Claude | None | High — no mock HTTP tests |
| Prompt builder | None | High |

---

## 11. Recommended Review Order

1. **`src/ir/types.zig`** — understand the schema before anything else
2. **`src/main.zig`** — entry point and lifecycle
3. **`src/cli/commands/slice.zig`** — the pipeline spine
4. **`src/ir/validator.zig`** — the correctness gate
5. **`src/ir/merger.zig`** — runtime enrichment logic
6. **`src/graph/traversal.zig`** + **`expansion.zig`** — hot path algorithm
7. **`src/compression/compressor.zig`** — most complex; Kahn's sort
8. **`src/packager/packager.zig`** + writers — output correctness
9. **`src/orchestrator/subprocess.zig`** — deadlock risk
10. **`src/ai/claude.zig`** — security (API key, JSON injection)
11. **`src/util/json.zig`** + **`fs.zig`** — foundation correctness

---

## 12. Open Questions for the Implementer

These are questions I'd raise in a PR review. Some are intentional MVP tradeoffs; they should be documented if so.

1. **Subprocess deadlock**: How is stderr read concurrently with the subprocess running? (`subprocess.zig`)
2. **JSON injection in prompt**: Is the user's task string escaped before embedding in the API request body? (`claude.zig`)
3. **Silent quarantine**: Should validator warn the user when symbols are dropped? (`validator.zig`)
4. **Hot path with no runtime data**: What does the slice look like for a static-only run? Is it still useful?
5. **Topo sort non-determinism**: Are cycle nodes appended in insertion order? Could vary run-to-run.
6. **API key in logs**: Is there any code path (even at verbose/debug level) that could log the API key?
7. **Prompt size limit**: What happens if the assembled prompt exceeds Claude's input context window?
8. **`build.gradle.kts` detection**: Only `build.gradle` is checked; Kotlin DSL repos will fail to detect.
9. **Slice age threshold**: Hardcoded in `prompt.zig` — should it be configurable?
10. **`relevant_files.txt` content**: Does the prompt include the actual source file content, or just the paths? This is critical for AI response quality.
