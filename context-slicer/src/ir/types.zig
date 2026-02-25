const std = @import("std");

/// Kind of a symbol in the IR.
pub const SymbolKind = enum {
    class,
    method,
    constructor,
    interface,
};

/// A source file referenced by symbols.
pub const IrFile = struct {
    id: []const u8,
    path: []const u8,
    language: []const u8,
    hash: []const u8,
};

/// A code symbol (class, method, interface, constructor).
pub const Symbol = struct {
    id: []const u8,
    kind: SymbolKind,
    name: []const u8,
    language: []const u8,
    file_id: ?[]const u8 = null,
    line_start: u32,
    line_end: u32,
    visibility: []const u8,
    container: ?[]const u8 = null,
    annotations: []const []const u8,
    is_entry_point: bool,
    is_framework: bool,
    is_generated: bool,
};

/// A call edge between two symbols.
pub const CallEdge = struct {
    caller: []const u8,
    callee: []const u8,
    /// "static" is a keyword in Zig; use @"static" to reference it.
    @"static": bool,
    runtime_observed: bool,
    call_count: u32,
};

/// The scenario block from the static IR.
pub const Scenario = struct {
    name: []const u8,
    entry_points: []const []const u8,
    // Optional in adapter output — default to empty if absent
    run_args: []const []const u8 = &.{},
    config_files: []const []const u8 = &.{},
};

/// An observed symbol from the runtime trace.
pub const ObservedSymbol = struct {
    symbol_id: []const u8,
    call_count: u32,
};

/// An observed call edge from the runtime trace.
pub const ObservedEdge = struct {
    caller: []const u8,
    callee: []const u8,
    call_count: u32,
};

/// The embedded runtime block inside static_ir.json.
pub const RuntimeEntry = struct {
    observed_symbols: []const ObservedSymbol,
    observed_edges: []const ObservedEdge,
};

/// Top-level structure of static_ir.json.
pub const IrRoot = struct {
    ir_version: []const u8,
    language: []const u8,
    repo_root: []const u8,
    // Optional in some adapter versions — default to empty string if absent
    build_id: []const u8 = "",
    adapter_version: []const u8,
    scenario: Scenario,
    files: []const IrFile,
    symbols: []const Symbol,
    call_edges: []const CallEdge,
    runtime: RuntimeEntry,
};

// ---------------------------------------------------------------------------
// Phase 13: Data Transform types
// ---------------------------------------------------------------------------

/// A single field-level diff between entry and exit snapshots.
pub const FieldDiff = struct {
    field: []const u8,
    before: []const u8,
    after: []const u8,
};

/// Transform data for one parameter of a method invocation.
pub const ParameterTransform = struct {
    name: []const u8,
    type_name: []const u8 = "",
    mutated: bool,
    changed_fields: []const FieldDiff,
};

/// Transform data for one method invocation (first invocation only).
pub const MethodTransform = struct {
    symbol_id: []const u8,
    parameters: []const ParameterTransform,
    return_value: ?[]const u8 = null,
    return_type: ?[]const u8 = null,
};

/// Top-level structure of runtime_trace.json.
pub const RuntimeTrace = struct {
    observed_symbols: []const ObservedSymbol,
    observed_edges: []const ObservedEdge,
    method_transforms: []const MethodTransform = &.{},  // optional — absent in old traces
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "SymbolKind covers required variants" {
    const k1: SymbolKind = .class;
    const k2: SymbolKind = .method;
    const k3: SymbolKind = .constructor;
    const k4: SymbolKind = .interface;
    try std.testing.expect(k1 != k2);
    try std.testing.expect(k3 != k4);
}

test "can construct IrRoot with all fields" {
    const file = IrFile{
        .id = "f01",
        .path = "src/Foo.java",
        .language = "java",
        .hash = "sha256:abc",
    };
    const sym = Symbol{
        .id = "java::com.example.Foo",
        .kind = .class,
        .name = "Foo",
        .language = "java",
        .file_id = "f01",
        .line_start = 1,
        .line_end = 10,
        .visibility = "public",
        .container = null,
        .annotations = &[_][]const u8{},
        .is_entry_point = false,
        .is_framework = false,
        .is_generated = false,
    };
    const edge = CallEdge{
        .caller = "java::com.example.Foo::bar()",
        .callee = "java::com.example.Baz::qux()",
        .@"static" = true,
        .runtime_observed = false,
        .call_count = 0,
    };
    const scenario = Scenario{
        .name = "test",
        .entry_points = &[_][]const u8{"java::com.example.Foo::bar()"},
        .run_args = &[_][]const u8{},
        .config_files = &[_][]const u8{"application.yml"},
    };
    const root = IrRoot{
        .ir_version = "0.1",
        .language = "java",
        .repo_root = "/tmp/repo",
        .build_id = "test",
        .adapter_version = "0.1.0",
        .scenario = scenario,
        .files = &[_]IrFile{file},
        .symbols = &[_]Symbol{sym},
        .call_edges = &[_]CallEdge{edge},
        .runtime = RuntimeEntry{
            .observed_symbols = &[_]ObservedSymbol{},
            .observed_edges = &[_]ObservedEdge{},
        },
    };
    try std.testing.expectEqualStrings("0.1", root.ir_version);
    try std.testing.expectEqual(@as(usize, 1), root.symbols.len);
    try std.testing.expectEqual(SymbolKind.class, root.symbols[0].kind);
}

test "CallEdge static field accessible via @\"static\"" {
    const e = CallEdge{
        .caller = "A",
        .callee = "B",
        .@"static" = true,
        .runtime_observed = false,
        .call_count = 3,
    };
    try std.testing.expect(e.@"static");
    try std.testing.expectEqual(@as(u32, 3), e.call_count);
}

test "can construct MethodTransform with all fields" {
    const diff = FieldDiff{ .field = "orderId", .before = "null", .after = "ord-456" };
    const param = ParameterTransform{
        .name = "request",
        .type_name = "OrderRequest",
        .mutated = true,
        .changed_fields = &[_]FieldDiff{diff},
    };
    const mt = MethodTransform{
        .symbol_id = "java::com.example.Foo::createOrder(OrderRequest)",
        .parameters = &[_]ParameterTransform{param},
        .return_value = "ord-456",
        .return_type = "OrderResponse",
    };
    try std.testing.expectEqualStrings("java::com.example.Foo::createOrder(OrderRequest)", mt.symbol_id);
    try std.testing.expectEqual(@as(usize, 1), mt.parameters.len);
    try std.testing.expect(mt.parameters[0].mutated);
    try std.testing.expectEqualStrings("orderId", mt.parameters[0].changed_fields[0].field);
}

test "RuntimeTrace with no method_transforms defaults to empty slice" {
    const rt = RuntimeTrace{
        .observed_symbols = &[_]ObservedSymbol{},
        .observed_edges = &[_]ObservedEdge{},
    };
    try std.testing.expectEqual(@as(usize, 0), rt.method_transforms.len);
}
