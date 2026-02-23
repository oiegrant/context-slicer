const std = @import("std");
const types = @import("../ir/types.zig");
const merger = @import("../ir/merger.zig");
const graph_mod = @import("graph.zig");

pub const Graph = graph_mod.Graph;

/// Build a Graph from a MergedIr.
///
/// - Each symbol becomes a node.
/// - Each call edge becomes a directed edge with EdgeMeta.
/// - file_map is populated using the IrFile.path lookup for each symbol's file_id.
///
/// The caller must keep MergedIr alive for the lifetime of the returned Graph,
/// as all string slices point into the MergedIr's data.
pub fn build(ir: merger.MergedIr, allocator: std.mem.Allocator) !Graph {
    var g = Graph.init(allocator);
    errdefer g.deinit();

    // Build a file ID → file path map
    var file_path_map = std.StringHashMap([]const u8).init(allocator);
    defer file_path_map.deinit();
    for (ir.files) |f| {
        try file_path_map.put(f.id, f.path);
    }

    // Add nodes
    for (ir.symbols) |sym| {
        try g.addNode(sym);
        // Populate file_map
        if (sym.file_id) |fid| {
            if (file_path_map.get(fid)) |path| {
                try g.setFileMap(sym.id, path);
            }
        }
    }

    // Add edges
    for (ir.call_edges) |edge| {
        try g.addEdge(edge.caller, edge.callee, .{
            .call_count = edge.call_count,
            .runtime_observed = edge.runtime_observed,
            .is_static = edge.is_static,
        });
    }

    return g;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const validator = @import("../ir/validator.zig");
const loader = @import("../ir/loader.zig");

const FIXTURE_DIR = "../test-fixtures/ir";

fn makeValidated(
    syms: []types.Symbol,
    edges: []types.CallEdge,
    files: []const types.IrFile,
) validator.ValidationResult {
    return validator.ValidationResult{
        .ir_version = "0.1", .language = "java",
        .repo_root = "/tmp", .build_id = "t", .adapter_version = "0.1.0",
        .scenario = .{ .name = "t", .entry_points = &[_][]const u8{}, .run_args = &[_][]const u8{}, .config_files = &[_][]const u8{} },
        .files = files,
        .symbols = syms,
        .call_edges = edges,
        .warnings = &[_]validator.ValidationWarning{},
        ._alloc = std.testing.allocator,
    };
}

fn makeSymbol(id: []const u8, kind: types.SymbolKind, file_id: ?[]const u8) types.Symbol {
    return types.Symbol{
        .id = id, .kind = kind, .name = id, .language = "java",
        .file_id = file_id, .line_start = 1, .line_end = 1,
        .visibility = "public", .container = null,
        .annotations = &[_][]const u8{},
        .is_entry_point = false, .is_framework = false, .is_generated = false,
    };
}

const EMPTY_RUNTIME = types.RuntimeTrace{
    .observed_symbols = &[_]types.ObservedSymbol{},
    .observed_edges = &[_]types.ObservedEdge{},
};

test "build from fixtures: nodeCount equals symbol count" {
    var static_parsed = try loader.loadStatic(FIXTURE_DIR ++ "/static_ir.json", std.testing.allocator);
    defer static_parsed.deinit();
    var runtime_parsed = try loader.loadRuntime(FIXTURE_DIR ++ "/runtime_trace.json", std.testing.allocator);
    defer runtime_parsed.deinit();

    const validated = try validator.validate(static_parsed.value, std.testing.allocator);
    defer validated.deinit();

    var merged = try merger.merge(validated, runtime_parsed.value, std.testing.allocator);
    defer merged.deinit();

    var g = try build(merged, std.testing.allocator);
    defer g.deinit();

    try std.testing.expectEqual(merged.symbols.len, g.nodeCount());
}

test "build from fixtures: edgeCount equals merged edge count" {
    var static_parsed = try loader.loadStatic(FIXTURE_DIR ++ "/static_ir.json", std.testing.allocator);
    defer static_parsed.deinit();
    var runtime_parsed = try loader.loadRuntime(FIXTURE_DIR ++ "/runtime_trace.json", std.testing.allocator);
    defer runtime_parsed.deinit();

    const validated = try validator.validate(static_parsed.value, std.testing.allocator);
    defer validated.deinit();

    var merged = try merger.merge(validated, runtime_parsed.value, std.testing.allocator);
    defer merged.deinit();

    var g = try build(merged, std.testing.allocator);
    defer g.deinit();

    try std.testing.expectEqual(merged.call_edges.len, g.edgeCount());
}

test "file_map entry for StripeOrderService.createOrder" {
    var static_parsed = try loader.loadStatic(FIXTURE_DIR ++ "/static_ir.json", std.testing.allocator);
    defer static_parsed.deinit();

    const validated = try validator.validate(static_parsed.value, std.testing.allocator);
    defer validated.deinit();

    var merged = try merger.merge(validated, EMPTY_RUNTIME, std.testing.allocator);
    defer merged.deinit();

    var g = try build(merged, std.testing.allocator);
    defer g.deinit();

    const key = "java::com.contextslice.fixture.StripeOrderService::createOrder(OrderRequest)";
    const path = g.file_map.get(key);
    try std.testing.expect(path != null);
    try std.testing.expect(std.mem.indexOf(u8, path.?, "StripeOrderService.java") != null);
}

test "edge from OrderController.createOrder to OrderService.createOrder is static" {
    var static_parsed = try loader.loadStatic(FIXTURE_DIR ++ "/static_ir.json", std.testing.allocator);
    defer static_parsed.deinit();

    const validated = try validator.validate(static_parsed.value, std.testing.allocator);
    defer validated.deinit();

    var merged = try merger.merge(validated, EMPTY_RUNTIME, std.testing.allocator);
    defer merged.deinit();

    var g = try build(merged, std.testing.allocator);
    defer g.deinit();

    const caller = "java::com.contextslice.fixture.OrderController::createOrder(OrderRequest)";
    const callee = "java::com.contextslice.fixture.OrderService::createOrder(OrderRequest)";
    const edges = g.getOutEdges(caller);

    var found = false;
    for (edges) |e| {
        if (std.mem.eql(u8, e.callee_id, callee)) {
            try std.testing.expect(e.meta.is_static);
            try std.testing.expect(!e.meta.runtime_observed);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "edge StripeOrderService.createOrder to PaymentService.charge runtime context" {
    var static_parsed = try loader.loadStatic(FIXTURE_DIR ++ "/static_ir.json", std.testing.allocator);
    defer static_parsed.deinit();
    var runtime_parsed = try loader.loadRuntime(FIXTURE_DIR ++ "/runtime_trace.json", std.testing.allocator);
    defer runtime_parsed.deinit();

    const validated = try validator.validate(static_parsed.value, std.testing.allocator);
    defer validated.deinit();

    var merged = try merger.merge(validated, runtime_parsed.value, std.testing.allocator);
    defer merged.deinit();

    var g = try build(merged, std.testing.allocator);
    defer g.deinit();

    // The static IR has StripeOrderService→PaymentService::charge (interface dispatch)
    // After merging with runtime, it remains static-only (no matching runtime edge)
    const caller = "java::com.contextslice.fixture.StripeOrderService::createOrder(OrderRequest)";
    const callee = "java::com.contextslice.fixture.PaymentService::charge(PaymentRequest)";
    const edges = g.getOutEdges(caller);

    var found = false;
    for (edges) |e| {
        if (std.mem.eql(u8, e.callee_id, callee)) {
            found = true;
        }
    }
    // The static edge to the interface must exist
    try std.testing.expect(found);
}
