const std = @import("std");
const types = @import("../ir/types.zig");
const graph_mod = @import("graph.zig");

pub const Graph = graph_mod.Graph;

/// Returns all symbols where any inbound or outbound edge has call_count > 0,
/// sorted descending by the maximum call_count among their edges.
/// Caller owns the returned slice (free with allocator.free).
pub fn hotPath(g: *const Graph, allocator: std.mem.Allocator) ![]types.Symbol {
    // Build: callee_id → max inbound call_count
    var inbound = std.StringHashMap(u32).init(allocator);
    defer inbound.deinit();

    var out_edge_it = g.out_edges.iterator();
    while (out_edge_it.next()) |entry| {
        for (entry.value_ptr.items) |edge| {
            if (edge.meta.call_count > 0) {
                const prev = inbound.get(edge.callee_id) orelse 0;
                try inbound.put(edge.callee_id, @max(prev, edge.meta.call_count));
            }
        }
    }

    // Build: caller_id → max outbound call_count
    var outbound = std.StringHashMap(u32).init(allocator);
    defer outbound.deinit();

    var out_edge_it2 = g.out_edges.iterator();
    while (out_edge_it2.next()) |entry| {
        for (entry.value_ptr.items) |edge| {
            if (edge.meta.call_count > 0) {
                const prev = outbound.get(entry.key_ptr.*) orelse 0;
                try outbound.put(entry.key_ptr.*, @max(prev, edge.meta.call_count));
            }
        }
    }

    // Collect hot symbols: those appearing in either map
    const HotEntry = struct { sym: types.Symbol, max_count: u32 };
    var hot: std.ArrayListUnmanaged(HotEntry) = .{};
    defer hot.deinit(allocator);

    var node_it = g.nodes.iterator();
    while (node_it.next()) |entry| {
        const id = entry.key_ptr.*;
        const sym = entry.value_ptr.*;
        const out_count = outbound.get(id) orelse 0;
        const in_count = inbound.get(id) orelse 0;
        const max_count = @max(out_count, in_count);
        if (max_count > 0) {
            try hot.append(allocator, .{ .sym = sym, .max_count = max_count });
        }
    }

    // Sort descending by max_count
    std.mem.sort(HotEntry, hot.items, {}, struct {
        fn lessThan(_: void, a: HotEntry, b: HotEntry) bool {
            return a.max_count > b.max_count; // descending
        }
    }.lessThan);

    // Extract just the symbols
    const result = try allocator.alloc(types.Symbol, hot.items.len);
    for (hot.items, 0..) |entry, i| {
        result[i] = entry.sym;
    }
    return result;
}

/// BFS from `start_id`, returning reachable symbol IDs in BFS order.
/// Caller owns the returned slice (free with allocator.free).
/// Returns empty slice if start_id is not in the graph.
pub fn bfsFrom(g: *const Graph, start_id: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    if (!g.nodes.contains(start_id)) {
        return allocator.alloc([]const u8, 0);
    }

    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    var queue: std.ArrayListUnmanaged([]const u8) = .{};
    defer queue.deinit(allocator);

    var result: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer result.deinit(allocator);

    try visited.put(start_id, {});
    try queue.append(allocator, start_id);

    var head: usize = 0;
    while (head < queue.items.len) {
        const current = queue.items[head];
        head += 1;
        try result.append(allocator, current);

        const edges = g.getOutEdges(current);
        for (edges) |edge| {
            if (!visited.contains(edge.callee_id)) {
                try visited.put(edge.callee_id, {});
                try queue.append(allocator, edge.callee_id);
            }
        }
    }

    return result.toOwnedSlice(allocator);
}

/// DFS from `start_id`, returning reachable symbol IDs in DFS order.
/// Caller owns the returned slice (free with allocator.free).
pub fn dfsFrom(g: *const Graph, start_id: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    if (!g.nodes.contains(start_id)) {
        return allocator.alloc([]const u8, 0);
    }

    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    var result: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer result.deinit(allocator);

    try dfsVisit(g, start_id, &visited, &result, allocator);

    return result.toOwnedSlice(allocator);
}

fn dfsVisit(
    g: *const Graph,
    id: []const u8,
    visited: *std.StringHashMap(void),
    result: *std.ArrayListUnmanaged([]const u8),
    allocator: std.mem.Allocator,
) !void {
    if (visited.contains(id)) return;
    try visited.put(id, {});
    try result.append(allocator, id);

    const edges = g.getOutEdges(id);
    for (edges) |edge| {
        try dfsVisit(g, edge.callee_id, visited, result, allocator);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn makeSymbol(id: []const u8) types.Symbol {
    return types.Symbol{
        .id = id, .kind = .class, .name = id, .language = "java",
        .file_id = null, .line_start = 1, .line_end = 1,
        .visibility = "public", .container = null,
        .annotations = &[_][]const u8{},
        .is_entry_point = false, .is_framework = false, .is_generated = false,
    };
}

test "hotPath: edges with call_count>0 returns those symbols sorted desc" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    for (&[_][]const u8{ "A", "B", "C", "D", "E" }) |id| {
        try g.addNode(makeSymbol(id));
    }
    // A→B (count=5), C→D (count=3), D→E (count=1); node E (static-only, not in hot)
    try g.addEdge("A", "B", .{ .call_count = 5, .runtime_observed = true, .is_static = true });
    try g.addEdge("C", "D", .{ .call_count = 3, .runtime_observed = true, .is_static = true });
    try g.addEdge("D", "E", .{ .call_count = 1, .runtime_observed = true, .is_static = true });

    const hot = try hotPath(&g, std.testing.allocator);
    defer std.testing.allocator.free(hot);

    // 5 distinct nodes have at least one edge with count>0
    try std.testing.expectEqual(@as(usize, 5), hot.len);
    // First should be A or B (max count 5)
    try std.testing.expectEqual(@as(u32, 5), @max(
        if (std.mem.eql(u8, hot[0].id, "A")) @as(u32, 5) else 0,
        if (std.mem.eql(u8, hot[0].id, "B")) @as(u32, 5) else 0,
    ));
}

test "hotPath: graph with no runtime edges returns empty slice" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    try g.addNode(makeSymbol("A"));
    try g.addNode(makeSymbol("B"));
    try g.addEdge("A", "B", .{ .call_count = 0, .runtime_observed = false, .is_static = true });

    const hot = try hotPath(&g, std.testing.allocator);
    defer std.testing.allocator.free(hot);

    try std.testing.expectEqual(@as(usize, 0), hot.len);
}

test "bfsFrom on chain A→B→C returns [A, B, C]" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    for (&[_][]const u8{ "A", "B", "C" }) |id| {
        try g.addNode(makeSymbol(id));
    }
    try g.addEdge("A", "B", .{ .call_count = 0, .runtime_observed = false, .is_static = true });
    try g.addEdge("B", "C", .{ .call_count = 0, .runtime_observed = false, .is_static = true });

    const result = try bfsFrom(&g, "A", std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("A", result[0]);
    try std.testing.expectEqualStrings("B", result[1]);
    try std.testing.expectEqualStrings("C", result[2]);
}

test "bfsFrom with cycle A→B→A terminates, each node once" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    try g.addNode(makeSymbol("A"));
    try g.addNode(makeSymbol("B"));
    try g.addEdge("A", "B", .{ .call_count = 0, .runtime_observed = false, .is_static = true });
    try g.addEdge("B", "A", .{ .call_count = 0, .runtime_observed = false, .is_static = true });

    const result = try bfsFrom(&g, "A", std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "bfsFrom: disconnected node D not reachable from A" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    for (&[_][]const u8{ "A", "B", "D" }) |id| {
        try g.addNode(makeSymbol(id));
    }
    try g.addEdge("A", "B", .{ .call_count = 0, .runtime_observed = false, .is_static = true });

    const result = try bfsFrom(&g, "A", std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    for (result) |id| {
        try std.testing.expect(!std.mem.eql(u8, id, "D"));
    }
}
