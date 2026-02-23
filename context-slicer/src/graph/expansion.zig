const std = @import("std");
const types = @import("../ir/types.zig");
const graph_mod = @import("graph.zig");

pub const Graph = graph_mod.Graph;

/// Result of expanding a hot path through the graph.
pub const ExpandedGraph = struct {
    /// All symbols included after expansion (hot path + radius-1 neighbors).
    symbols: []types.Symbol,
    _alloc: std.mem.Allocator,

    pub fn deinit(self: ExpandedGraph) void {
        self._alloc.free(self.symbols);
    }
};

/// Expand from a hot path through the graph using radius-1 neighborhood.
///
/// Rules applied in order:
///   1. All hot path symbols are included.
///   2. Radius-1: for each hot path node, add all direct out-neighbors
///      and in-neighbors not already in the set.
///   3. Interface resolution: if a hot path edge targets a symbol with
///      kind=.interface, include all callers of any symbol sharing the same
///      interface name (i.e. other nodes that also call that interface).
///      (Conservative implementation: include all nodes whose out-edges
///      include any callee that is an interface symbol reachable from hot path.)
///
/// Caller must call expanded.deinit() to free the result.
pub fn expand(
    g: *const Graph,
    hot_path: []const types.Symbol,
    file_map: *const std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
) !ExpandedGraph {
    var included = std.StringHashMap(void).init(allocator);
    defer included.deinit();

    var symbols: std.ArrayListUnmanaged(types.Symbol) = .{};
    errdefer symbols.deinit(allocator);

    // 1. Seed with hot path
    for (hot_path) |sym| {
        if (!included.contains(sym.id)) {
            try included.put(sym.id, {});
            try symbols.append(allocator, sym);
        }
    }

    // 2. Radius-1: out-neighbors
    for (hot_path) |sym| {
        const edges = g.getOutEdges(sym.id);
        for (edges) |edge| {
            if (!included.contains(edge.callee_id)) {
                if (g.getNode(edge.callee_id)) |neighbor| {
                    try included.put(neighbor.id, {});
                    try symbols.append(allocator, neighbor);
                }
            }
        }
    }

    // 2b. Radius-1: in-neighbors (find callers of hot path nodes)
    var hot_set = std.StringHashMap(void).init(allocator);
    defer hot_set.deinit();
    for (hot_path) |sym| {
        try hot_set.put(sym.id, {});
    }

    var edge_it = g.out_edges.iterator();
    while (edge_it.next()) |entry| {
        const caller_id = entry.key_ptr.*;
        for (entry.value_ptr.items) |edge| {
            if (hot_set.contains(edge.callee_id)) {
                // caller_id calls a hot path node — add caller as in-neighbor
                if (!included.contains(caller_id)) {
                    if (g.getNode(caller_id)) |caller_sym| {
                        try included.put(caller_sym.id, {});
                        try symbols.append(allocator, caller_sym);
                    }
                }
                break;
            }
        }
    }

    // 3. Interface resolution: for each interface node in the hot path or
    //    reached by radius-1, find all other nodes whose out-edges target
    //    that interface (they are alternative implementations).
    var interface_ids = std.StringHashMap(void).init(allocator);
    defer interface_ids.deinit();
    for (hot_path) |sym| {
        if (sym.kind == .interface) {
            try interface_ids.put(sym.id, {});
        }
    }
    // Also collect interface callees of hot path nodes
    for (hot_path) |sym| {
        const edges = g.getOutEdges(sym.id);
        for (edges) |edge| {
            if (g.getNode(edge.callee_id)) |callee| {
                if (callee.kind == .interface) {
                    try interface_ids.put(callee.id, {});
                }
            }
        }
    }
    // Find all callers of those interface nodes
    if (interface_ids.count() > 0) {
        var edge_it2 = g.out_edges.iterator();
        while (edge_it2.next()) |entry| {
            const caller_id = entry.key_ptr.*;
            for (entry.value_ptr.items) |edge| {
                if (interface_ids.contains(edge.callee_id)) {
                    if (!included.contains(caller_id)) {
                        if (g.getNode(caller_id)) |sym| {
                            try included.put(sym.id, {});
                            try symbols.append(allocator, sym);
                        }
                    }
                    break;
                }
            }
        }
    }

    _ = file_map; // unused after config expansion removal

    return ExpandedGraph{
        .symbols = try symbols.toOwnedSlice(allocator),
        ._alloc = allocator,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn makeSymbol(id: []const u8, kind: types.SymbolKind) types.Symbol {
    return types.Symbol{
        .id = id, .kind = kind, .name = id, .language = "java",
        .file_id = null, .line_start = 1, .line_end = 1,
        .visibility = "public", .container = null,
        .annotations = &[_][]const u8{},
        .is_entry_point = false, .is_framework = false, .is_generated = false,
    };
}

fn containsId(syms: []types.Symbol, id: []const u8) bool {
    for (syms) |s| {
        if (std.mem.eql(u8, s.id, id)) return true;
    }
    return false;
}

test "radius-1: hot=[B], graph A→B→C→D; expanded includes A, B, C; not D" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    for (&[_][]const u8{ "A", "B", "C", "D" }) |id| {
        try g.addNode(makeSymbol(id, .class));
    }
    try g.addEdge("A", "B", .{ .call_count = 1, .runtime_observed = true, .is_static = true });
    try g.addEdge("B", "C", .{ .call_count = 1, .runtime_observed = true, .is_static = true });
    try g.addEdge("C", "D", .{ .call_count = 0, .runtime_observed = false, .is_static = true });

    const hot = [_]types.Symbol{makeSymbol("B", .class)};
    var file_map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer file_map.deinit();

    const expanded = try expand(&g, &hot, &file_map, std.testing.allocator);
    defer expanded.deinit();

    try std.testing.expect(containsId(expanded.symbols, "A"));
    try std.testing.expect(containsId(expanded.symbols, "B"));
    try std.testing.expect(containsId(expanded.symbols, "C"));
    try std.testing.expect(!containsId(expanded.symbols, "D"));
}

test "interface resolution: interface in hot path causes all callers to be added" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    // OrderService is an interface; both StripeOrderService and MockOrderService call it
    try g.addNode(makeSymbol("OrderService", .interface));
    try g.addNode(makeSymbol("StripeOrderService", .class));
    try g.addNode(makeSymbol("MockOrderService", .class));
    try g.addNode(makeSymbol("Controller", .class));

    try g.addEdge("Controller", "OrderService", .{ .call_count = 1, .runtime_observed = true, .is_static = true });
    try g.addEdge("StripeOrderService", "OrderService", .{ .call_count = 0, .runtime_observed = false, .is_static = true });
    try g.addEdge("MockOrderService", "OrderService", .{ .call_count = 0, .runtime_observed = false, .is_static = true });

    // Hot path is OrderService interface
    const hot = [_]types.Symbol{makeSymbol("OrderService", .interface)};
    var file_map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer file_map.deinit();

    const expanded = try expand(&g, &hot, &file_map, std.testing.allocator);
    defer expanded.deinit();

    try std.testing.expect(containsId(expanded.symbols, "OrderService"));
    try std.testing.expect(containsId(expanded.symbols, "StripeOrderService"));
    try std.testing.expect(containsId(expanded.symbols, "MockOrderService"));
    try std.testing.expect(containsId(expanded.symbols, "Controller"));
}

test "hot path symbol not duplicated in expansion result" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    try g.addNode(makeSymbol("A", .class));
    try g.addNode(makeSymbol("B", .class));
    try g.addEdge("A", "B", .{ .call_count = 1, .runtime_observed = true, .is_static = true });

    // Both A and B in hot path
    const hot = [_]types.Symbol{ makeSymbol("A", .class), makeSymbol("B", .class) };
    var file_map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer file_map.deinit();

    const expanded = try expand(&g, &hot, &file_map, std.testing.allocator);
    defer expanded.deinit();

    // Count occurrences of "A" and "B" — each should appear exactly once
    var count_a: usize = 0;
    var count_b: usize = 0;
    for (expanded.symbols) |s| {
        if (std.mem.eql(u8, s.id, "A")) count_a += 1;
        if (std.mem.eql(u8, s.id, "B")) count_b += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count_a);
    try std.testing.expectEqual(@as(usize, 1), count_b);
}

test "empty hot path returns empty expanded set" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    try g.addNode(makeSymbol("A", .class));

    const hot = [_]types.Symbol{};
    var file_map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer file_map.deinit();

    const expanded = try expand(&g, &hot, &file_map, std.testing.allocator);
    defer expanded.deinit();

    try std.testing.expectEqual(@as(usize, 0), expanded.symbols.len);
}
