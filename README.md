# context-slicer

Runtime-grounded code slicing platform that produces AI-usable architectural context for large, complex codebases.

Instead of dumping your entire codebase into an AI agent, context-slicer records a live scenario (e.g. "submit an order"), traces exactly which classes, methods, and config keys were exercised, then packages only the relevant code into a focused prompt file. The result: your AI agent gets the right context, not everything.

## How It Works

1. **`record`** — Runs your Java application under a scenario while attaching the ByteBuddy agent. Captures a runtime trace alongside a static analysis of your source. Writes output to `.context-slice/`.
2. **`slice`** — Merges the static IR and runtime trace, builds a call graph, compresses it to the most relevant symbols, and produces a set of context files in `.context-slice/`.
3. **`prompt`** — Assembles all context files into a single `prompt.md` that you can paste into any AI agent (Claude, Cursor, Copilot, etc.).

## Prerequisites

- **Zig** ≥ 0.14 — to build the core binary ([ziglang.org/download](https://ziglang.org/download/))
- **Java JDK** ≥ 21 — for the static analysis adapter and ByteBuddy runtime agent
- **Maven** or **Gradle** — to build your target Java project
- `JAVA_HOME` set to your JDK installation (e.g. `/opt/homebrew/opt/openjdk@21`)

## Installation

```sh
git clone https://github.com/your-org/context-slicer
cd context-slicer/context-slicer
zig build -Doptimize=ReleaseSafe
```

The binary is written to `zig-out/bin/context-slicer`.

Install it somewhere permanent so it's available from any directory:

```sh
# Option A: copy to /usr/local/bin (requires sudo)
sudo cp zig-out/bin/context-slicer /usr/local/bin/

# Option B: symlink (easy to update after rebuilds)
sudo ln -sf "$PWD/zig-out/bin/context-slicer" /usr/local/bin/context-slicer
```

Verify it works from any directory:

```sh
context-slicer --help
```

## Quickstart

All commands are run from your **Java project root** (the directory that contains `pom.xml` or `build.gradle`).

### 1. Record a scenario

```sh
context-slicer record <scenario-name> --adapter-jar <path> --agent-jar <path> [options]
```

Example — record the "submit-order" flow:

```sh
cd /path/to/your/java-project
context-slicer record submit-order \
  --adapter-jar /path/to/context-adapter-java.jar \
  --agent-jar   /path/to/context-agent-java.jar \
  --config      src/main/resources/application.yml \
  --namespace   com.example. \
  --run-script  "curl -s -X POST http://localhost:8080/orders \
    -H 'Content-Type: application/json' \
    -d '{\"amount\": 100, \"customerId\": \"cust-1\"}'"
```

`record` flags:

| Flag | Required | Description |
|---|---|---|
| `--adapter-jar <path>` | Yes | Path to `context-adapter-java.jar` |
| `--agent-jar <path>` | Yes | Path to `context-agent-java.jar` |
| `--run-script "<cmd>"` | Recommended | Shell command to trigger the scenario (e.g. a `curl` invocation) |
| `--namespace <prefix>` | Recommended | Java package prefix to scope analysis (e.g. `com.example.`) |
| `--port <N>` | No | Port the target server listens on |
| `--config <file>` | No | Config file to pass to the adapter |
| `--args "<run-args>"` | No | Extra JVM arguments to pass to the target application |

What happens:
- The adapter compiles your project (via `mvn package -DskipTests`)
- Starts your application with the ByteBuddy agent attached
- Executes `--run-script` to trigger the scenario (if provided)
- The agent writes the runtime trace on shutdown
- Static IR and runtime trace are saved to `.context-slice/`

### 2. Slice the context

```sh
context-slicer slice
```

Merges static + runtime data, builds the call graph, and writes five files to `.context-slice/`:

| File | Contents |
|---|---|
| `architecture.md` | Human-readable call graph summary |
| `config_usage.md` | Config keys and which classes read them |
| `relevant_files.txt` | Absolute paths of source files in the slice |
| `call_graph.json` | Machine-readable merged call graph |
| `metadata.json` | Scenario metadata and timestamps |

### 3. Build a prompt

```sh
context-slicer prompt "your task description"
```

Example:

```sh
context-slicer prompt "Add idempotency key support to the order submission endpoint"
```

This writes a complete, structured prompt to `.context-slice/prompt.md`. Open the file and paste it into your AI agent.

## Global Flags

| Flag | Effect |
|---|---|
| `--verbose` | Print debug output from the pipeline |
| `--help` | Show usage for any subcommand |

## Output Files

All output lives in `.context-slice/` inside your project root. Add it to `.gitignore` if desired:

```
.context-slice/
```

## Re-running

- Re-run `record` any time your codebase changes or you want to capture a different scenario.
- `slice` is fast (< 1 second) and safe to re-run without re-recording.
- `prompt` always reflects the latest `slice` output.

## Troubleshooting

**`No slice found. Run 'record' first.`**
The `.context-slice/metadata.json` file is missing. Run `record` first.

**`Unable to locate a Java Runtime`**
Set `JAVA_HOME` to your JDK path:
```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
```

**`Warning: This slice is more than 24 hours old.`**
Re-run `record` to capture fresh data.

**`Warning: This slice is static-only. Runtime instrumentation failed.`**
The ByteBuddy agent did not attach or the application exited before the trace was flushed. Check that `JAVA_HOME` points to a full JDK (not a JRE) and that your application had time to process at least one request before exiting.
