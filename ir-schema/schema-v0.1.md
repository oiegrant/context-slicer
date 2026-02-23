# Context Slice IR Schema v0.1

This document is the canonical contract between language adapters and the Zig core engine.
Both the Java adapter (`IrModel.java`) and the Zig IR layer (`ir/types.zig`) must conform to this spec.
Breaking changes require a version bump and a migration in the Zig IR Validator.

---

## Top-Level Structure

```json
{
  "ir_version":      "0.1",
  "language":        "java",
  "repo_root":       "/absolute/path/to/repo",
  "build_id":        "git-sha-or-content-hash",
  "adapter_version": "0.1.0",

  "scenario": {
    "name":         "submit-order",
    "entry_points": ["java::com.company.OrderController::submit(OrderRequest)"],
    "run_args":     ["--tenant=abc"],
    "config_files": ["application-prod.yml"]
  },

  "files":        [ ... ],
  "symbols":      [ ... ],
  "call_edges":   [ ... ],
  "config_reads": [ ... ],
  "runtime":      { "observed_symbols": [ ... ], "observed_edges": [ ... ] }
}
```

---

## Symbol ID Convention

```
<language>::<fully-qualified-class-name>::<method-name>(<param-simple-types>)

Examples:
  java::com.company.order.OrderService::createOrder(OrderRequest)
  java::com.company.order.StripePaymentService::charge(PaymentRequest)
  java::com.company.order.OrderService   (class/interface — no method suffix)
```

---

## Schema: files  [ REQUIRED ]

```json
{
  "id":       "f1",
  "path":     "src/main/java/com/company/order/OrderService.java",
  "language": "java",
  "hash":     "sha256:abc123..."
}
```

| Field      | Type   | Required | Notes                        |
|------------|--------|----------|------------------------------|
| `id`       | string | yes      | Short stable file reference  |
| `path`     | string | yes      | Relative to `repo_root`      |
| `language` | string | yes      | Same as top-level `language` |
| `hash`     | string | no       | SHA-256 hex prefixed sha256: |

---

## Schema: symbols  [ REQUIRED ]

```json
{
  "id":             "java::com.company.order.OrderService::createOrder(OrderRequest)",
  "kind":           "method",
  "name":           "createOrder",
  "language":       "java",
  "file_id":        "f2",
  "line_start":     35,
  "line_end":       102,
  "visibility":     "public",
  "container":      "java::com.company.order.OrderService",
  "annotations":    ["@Transactional"],
  "is_entry_point": false,
  "is_framework":   false,
  "is_generated":   false
}
```

| Field           | Type     | Required | Notes                                          |
|-----------------|----------|----------|------------------------------------------------|
| `id`            | string   | yes      | Follows symbol ID convention above             |
| `kind`          | enum     | yes      | `class`, `method`, `constructor`, `interface`  |
| `name`          | string   | yes      | Simple (unqualified) name                      |
| `language`      | string   | yes      |                                                |
| `file_id`       | string   | yes      | References a `files[].id`                      |
| `line_start`    | integer  | yes      | 1-based                                        |
| `line_end`      | integer  | yes      | 1-based, >= line_start                         |
| `visibility`    | string   | no       | `public`, `private`, `protected`, `package`    |
| `container`     | string   | no       | Symbol ID of the enclosing class/interface     |
| `annotations`   | string[] | no       | Simple annotation strings e.g. `@Transactional`|
| `is_entry_point`| boolean  | yes      | True if listed in scenario.entry_points        |
| `is_framework`  | boolean  | yes      | True if Spring stereotype or framework package |
| `is_generated`  | boolean  | yes      | True if CGLIB/proxy generated class            |

---

## Schema: call_edges  [ REQUIRED ]

```json
{
  "caller":           "java::com.company.OrderController::submit(OrderRequest)",
  "callee":           "java::com.company.StripePaymentService::charge(PaymentRequest)",
  "static":           true,
  "runtime_observed": true,
  "call_count":       1
}
```

| Field              | Type    | Required | Notes                                          |
|--------------------|---------|----------|------------------------------------------------|
| `caller`           | string  | yes      | Symbol ID                                      |
| `callee`           | string  | yes      | Symbol ID                                      |
| `static`           | boolean | yes      | True if found in static AST analysis           |
| `runtime_observed` | boolean | yes      | True if observed during instrumented run       |
| `call_count`       | integer | yes      | Number of times observed at runtime (0 if not) |

---

## Schema: config_reads  [ REQUIRED ]

```json
{
  "symbol_id":      "java::com.company.OrderService::createOrder(OrderRequest)",
  "config_key":     "order.payment.provider",
  "resolved_value": "stripe",
  "source_file":    "application-prod.yml"
}
```

| Field            | Type   | Required | Notes                              |
|------------------|--------|----------|------------------------------------|
| `symbol_id`      | string | yes      | Symbol that read the config key    |
| `config_key`     | string | yes      | Property key string                |
| `resolved_value` | string | yes      | Value at runtime; `"<unset>"` if null |
| `source_file`    | string | no       | Config file name (not full path)   |

---

## Schema: runtime block  [ REQUIRED ]

```json
"runtime": {
  "observed_symbols": [
    { "symbol_id": "java::...", "call_count": 12 }
  ],
  "observed_edges": [
    { "caller": "java::...", "callee": "java::...", "call_count": 3 }
  ]
}
```

---

## Validation Rules (enforced by Zig IR Validator)

1. `ir_version` must equal `"0.1"` (exact string match)
2. Every `symbols[].file_id` must reference an ID in the `files` array
3. Every `call_edges[].caller` and `.callee` must reference an ID in the `symbols` array
4. No two symbols may share the same `id`
5. `line_end >= line_start` for all symbols
6. Arrays are sorted by `id` (adapter responsibility — validator warns but does not reject)

---

## Serialization Rules (adapter responsibility)

- All arrays sorted by `id` before output (deterministic)
- Call edges sorted by `caller` then `callee`
- Pretty-printed JSON, UTF-8
- File paths are relative to `repo_root` (no absolute paths in IR)
