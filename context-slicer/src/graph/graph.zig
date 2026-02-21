const std = @import("std");
const types = @import("../ir/types.zig");

/// Metadata attached to each edge in the graph.
pub const EdgeMeta = struct {
    call_count: u32,
    runtime_observed: bool,
    is_static: bool,
};

/// An edge from one symbol to another.
pub const Edge = struct {
    callee_id: []const u8,
    meta: EdgeMeta,
};

/// The call graph.
///
/// - `nodes`: symbol_id → Symbol (value copy)
/// - `out_edges`: symbol_id → list of outgoing Edge
/// - `file_map`: symbol_id → file path string
///
/// All keys/values that are slices point into external memory (the caller's
/// IR data); the Graph does not copy them. The allocator is used only for
/// the hash map and edge list book-keeping.
pub const Graph = struct {
    nodes: std.StringHashMap(types.Symbol),
    out_edges: std.StringHashMap(std.ArrayListUnmanaged(Edge)),
    file_map: std.StringHashMap([]const u8),
    alloc: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Graph {
        return Graph{
            .nodes = std.StringHashMap(types.Symbol).init(allocator),
            .out_edges = std.StringHashMap(std.ArrayListUnmanaged(Edge)).init(allocator),
            .file_map = std.StringHashMap([]const u8).init(allocator),
            .alloc = allocator,
        };
    }

    pub fn deinit(self: *Graph) void {
        var it = self.out_edges.valueIterator();
        while (it.next()) |list| {
            list.deinit(self.alloc);
        }
        self.out_edges.deinit();
        self.nodes.deinit();
        self.file_map.deinit();
    }

    /// Add a node. If the symbol ID is already present, this is a no-op.
    pub fn addNode(self: *Graph, sym: types.Symbol) !void {
        if (self.nodes.contains(sym.id)) return;
        try self.nodes.put(sym.id, sym);
    }

    /// Add a directed edge from `caller_id` to `callee_id`.
    /// Both nodes must have been added first.
    pub fn addEdge(
        self: *Graph,
        caller_id: []const u8,
        callee_id: []const u8,
        meta: EdgeMeta,
    ) !void {
        const result = try self.out_edges.getOrPut(caller_id);
        if (!result.found_existing) {
            result.value_ptr.* = .{};
        }
        try result.value_ptr.append(self.alloc, Edge{
            .callee_id = callee_id,
            .meta = meta,
        });
    }

    /// Set the file path for a symbol (for file_map).
    pub fn setFileMap(self: *Graph, symbol_id: []const u8, file_path: []const u8) !void {
        try self.file_map.put(symbol_id, file_path);
    }

    /// Returns all outgoing edges from `symbol_id`, or an empty slice if none.
    pub fn getOutEdges(self: *const Graph, symbol_id: []const u8) []const Edge {
        if (self.out_edges.get(symbol_id)) |list| {
            return list.items;
        }
        return &[_]Edge{};
    }

    /// Returns the symbol for the given ID, or null if not present.
    pub fn getNode(self: *const Graph, symbol_id: []const u8) ?types.Symbol {
        return self.nodes.get(symbol_id);
    }

    pub fn nodeCount(self: *const Graph) usize {
        return self.nodes.count();
    }

    pub fn edgeCount(self: *const Graph) usize {
        var total: usize = 0;
        var it = self.out_edges.valueIterator();
        while (it.next()) |list| {
            total += list.items.len;
        }
        return total;
    }
};

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

test "addNode then getNode returns same symbol" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    const sym = makeSymbol("java::com.example.Foo");
    try g.addNode(sym);

    const got = g.getNode("java::com.example.Foo");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("java::com.example.Foo", got.?.id);
}

test "addEdge then getOutEdges returns one edge" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    try g.addNode(makeSymbol("A"));
    try g.addNode(makeSymbol("B"));
    try g.addEdge("A", "B", .{ .call_count = 1, .runtime_observed = true, .is_static = true });

    const edges = g.getOutEdges("A");
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqualStrings("B", edges[0].callee_id);
}

test "two edges from same caller: getOutEdges returns 2" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    try g.addNode(makeSymbol("A"));
    try g.addNode(makeSymbol("B"));
    try g.addNode(makeSymbol("C"));
    try g.addEdge("A", "B", .{ .call_count = 0, .runtime_observed = false, .is_static = true });
    try g.addEdge("A", "C", .{ .call_count = 0, .runtime_observed = false, .is_static = true });

    const edges = g.getOutEdges("A");
    try std.testing.expectEqual(@as(usize, 2), edges.len);
}

test "getOutEdges for unknown node returns empty slice (no panic)" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    const edges = g.getOutEdges("NONEXISTENT");
    try std.testing.expectEqual(@as(usize, 0), edges.len);
}

test "nodeCount and edgeCount accurate after multiple adds" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    try g.addNode(makeSymbol("A"));
    try g.addNode(makeSymbol("B"));
    try g.addNode(makeSymbol("C"));
    try g.addEdge("A", "B", .{ .call_count = 0, .runtime_observed = false, .is_static = true });
    try g.addEdge("B", "C", .{ .call_count = 2, .runtime_observed = true, .is_static = true });

    try std.testing.expectEqual(@as(usize, 3), g.nodeCount());
    try std.testing.expectEqual(@as(usize, 2), g.edgeCount());
}

test "adding the same node ID twice is a no-op (no duplicate)" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    try g.addNode(makeSymbol("A"));
    try g.addNode(makeSymbol("A")); // second add — should be ignored

    try std.testing.expectEqual(@as(usize, 1), g.nodeCount());
}
