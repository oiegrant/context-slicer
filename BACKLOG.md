# Context Slice — Backlog

Items here are out-of-scope for the current implementation phase but are clearly worthwhile and should be designed carefully when prioritised. Each entry documents why it was deferred and what a good implementation would need to address.

---

## BL-001: PII / Sensitive Field Redaction in Transform Capture

**Context:** Phase 13 adds data transformation capture — field-level diffs of method parameters and return values written to `runtime_trace.json` and rendered in `architecture.md`. Because this captures raw object field values, sensitive data (passwords, API tokens, SSNs, email addresses, etc.) can appear in the output.

**Why deferred:** The transform capture feature itself is new and needs validation before adding a redaction layer on top of it. Adding an incomplete redaction implementation is worse than no redaction at all (engineers may assume they are protected when they are not). The right implementation requires careful design of the heuristic, opt-in vs. opt-out behaviour, and testing.

**What a good implementation requires:**

1. **`SensitiveFieldFilter` class** (`context-agent-java`): static utility with a global `enabled` flag. `isSensitive(String fieldName)` performs a case-insensitive substring match against a configurable list of sensitive patterns. Default sensitive patterns: `password`, `passwd`, `secret`, `token`, `apikey`, `api_key`, `credential`, `auth`, `ssn`, `cvv`, `pin`, `private`, `email`, `phone`, `card`.

2. **Integration into `ParameterSerializer`**: before emitting any field, call `SensitiveFieldFilter.isSensitive(fieldName)`. If `true`, emit `"<redacted>"` as the value.

3. **Configurable pattern list**: the sensitive field patterns should be user-configurable in `context-slice.json` under a `transforms.sensitive_fields` key so teams can add domain-specific patterns (e.g., `tenant_id`, `auth_header`).

4. **Default behaviour**: redaction should be **opt-in** (disabled by default) rather than opt-out. The reason: false positives (redacting non-sensitive fields like `orderId` because a substring matches) harm the quality of transform context more than the risk of sensitive data in a local dev tool. A `--sanitize` flag on the `record` command enables it.

5. **CLI flag**: `--sanitize` on the `record` command → `manifest.sanitize = true` → agent arg `sanitize=true` → `SensitiveFieldFilter.enabled = true`.

6. **`context-slice.json` integration**:
   ```json
   {
     "transforms": {
       "depth_limit": 2,
       "max_collection_elements": 3,
       "sanitize": false,
       "sensitive_fields": ["password", "token", "secret", "ssn", "email"]
     }
   }
   ```

7. **Documentation warning**: until this feature is implemented, the tool's README and `--help` output should include a note that raw field values are captured and the output should be treated as potentially sensitive.

**Accuracy note:** Heuristic field-name matching is imperfect by design. It will miss context-specific sensitive fields (e.g., `tenantKey`) unless added to the custom list, and may over-redact fields whose names coincidentally contain sensitive substrings (e.g., a `tokenCount` field is not sensitive). This limitation should be clearly documented.

**Estimated scope:** ~2 days. `SensitiveFieldFilter` is straightforward; the main work is the config integration and testing edge cases.

---

## BL-002: Per-Invocation Transform Capture (vs. First-Invocation-Only)

**Context:** Phase 13 captures only the first invocation of each symbol to avoid memory pressure and output bloat. This means that if the same method is called multiple times with different data (e.g., batch processing, retry logic, conditional branching based on input), only the first call's transform is visible.

**Why deferred:** For the MVP, one representative sample per method is sufficient to give an AI model an accurate picture of what the method does to data. Capturing all invocations introduces complexity (memory bounding, deduplication, output size) that should be solved once the basic feature is validated.

**What a good implementation requires:**

1. **`max_invocations_per_symbol` config field** in `context-slice.json`: controls how many invocations to capture per symbol (default 1; set to 0 for unlimited).

2. **Change from `putIfAbsent` to a bounded list**: `RuntimeTracer.transformRecords` becomes `ConcurrentHashMap<String, List<TransformRecord>>`. New records are appended until the list reaches `max_invocations_per_symbol`.

3. **Deduplication**: if two invocations produce identical entry/exit snapshots, the second is not stored (no value in duplicate records).

4. **Output format change**: `method_transforms` entries gain an `invocations` array rather than a flat record.

5. **Rendering change**: `architecture_writer.zig` renders multiple invocations as a collapsed diff: show only the first invocation in detail; if additional invocations differ, add a note like "*(called N more times with varying inputs)*".

**Estimated scope:** ~3 days including output format changes and updated fixture data.

Items to be cleaned up and added to backlog:

 Tier 1 — Complete the MVP Loop
  1. Live Claude API integration                                                                                                                The prompt command should POST to the Anthropic API, not just write a file. Stream the response back to the terminal. This turns
  context-slicer into a complete workflow: record → slice → answer. Without this, engineers have an extra manual step that kills momentum.


 2. Ability to run multiple curls per scenario

   Tier 2 — Team and Workflow Integration

  3. Scenario library
  Right now, recordings live in .context-slice/ and are effectively ephemeral. A team scenario library — committed to the repo, browseable —
  transforms context-slicer from a personal tool into a team artifact. context-slicer list shows available scenarios; context-slicer slice
  --scenario submit-order replays without re-recording. This also enables scenario diffing when code changes.

  4. MCP server mode
  This is a high-leverage integration. Expose the scenario library as an MCP server:
  get_context_slice(scenario: "submit-order") → returns compressed context
  list_scenarios() → returns available recordings
  Claude Desktop, Cursor, any MCP-aware agent could call this. Engineers working in their AI tool of choice get context-slicer context
  automatically, without touching the CLI. This is probably the highest-ROI surface area for the product.

  Tier 3 — Context Quality Expansion

  6. OpenTelemetry trace import
  Teams with observability already have production call traces. An OTel importer would let engineers record slices from real production
  traffic — context-slicer import --trace-id abc123 --otel-endpoint http://jaeger:16686. This is architecturally clean (OTel trace → IR
  runtime block) and removes ALL local execution requirements.

  7. Multi-scenario context merging
  A cross-cutting concern like "payment processing" touches multiple scenarios (submit-order, refund-order, retry-payment). Merge those slices
   into a unified context that shows shared infrastructure and divergence points. Useful for architectural understanding and refactoring
  tasks.

  8. Radius-N expansion with AI-guided selection
  Today the tool does radius-1 expansion. A "why is this file in the slice?" explainability feature, plus interactive expansion ("also include
   the retry logic") would let engineers tune context for their specific task. This could be a chat-like loop in the terminal.

    ---
  Tier 4 — Language and Platform Expansion

  9. TypeScript/Node adapter
  The IR schema is language-neutral. A TypeScript adapter using ts-morph for static analysis + Node.js --require hooks for runtime tracing
  would unlock a massive market. TypeScript monorepos have the same problem — DI containers (InversifyJS, tsyringe), deep module graphs,
  unclear actual execution paths.

  10. IDE extension (VS Code / IntelliJ)
  Right-click a method → "Generate context slice for this entrypoint." Shows a panel with the resulting architecture and file list. One-click
  "Ask Claude" button. Eliminates CLI friction entirely. This is a distribution play more than a technical one — the engine is already built.

*Context Slice — Backlog v0.1 — Last updated 2026-02-24*
