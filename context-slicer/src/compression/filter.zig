const std = @import("std");
const types = @import("../ir/types.zig");
const merger = @import("../ir/merger.zig");

/// An edge in the filtered graph — same shape as MergedEdge.
pub const FilteredEdge = struct {
    caller: []const u8,
    callee: []const u8,
    call_count: u32,
    runtime_observed: bool,
    is_static: bool,
};

/// The result of applying filters to an expanded graph.
/// Caller must call deinit().
pub const FilteredGraph = struct {
    symbols: []types.Symbol,
    edges: []FilteredEdge,
    config_reads: []const types.ConfigRead,
    _alloc: std.mem.Allocator,

    pub fn deinit(self: FilteredGraph) void {
        self._alloc.free(self.symbols);
        self._alloc.free(self.edges);
    }
};

/// Remove framework nodes not in `protected_ids`, and remove any edges whose
/// caller or callee was removed.
///
/// `symbols`      — the full expanded symbol set
/// `edges`        — the full merged edge set (will be filtered to symbols)
/// `config_reads` — passed through unchanged
/// `protected_ids`— set of symbol IDs to keep even if is_framework=true
pub fn applyFrameworkFilter(
    symbols: []const types.Symbol,
    edges: []const merger.MergedEdge,
    config_reads: []const types.ConfigRead,
    protected_ids: std.StringHashMap(void),
    allocator: std.mem.Allocator,
) !FilteredGraph {
    // Build set of surviving symbol IDs
    var surviving = std.StringHashMap(void).init(allocator);
    defer surviving.deinit();

    var filtered_syms: std.ArrayListUnmanaged(types.Symbol) = .{};
    errdefer filtered_syms.deinit(allocator);

    for (symbols) |sym| {
        if (sym.is_framework and !protected_ids.contains(sym.id)) {
            // Framework node not protected — skip
            continue;
        }
        try surviving.put(sym.id, {});
        try filtered_syms.append(allocator, sym);
    }

    // Filter edges: both endpoints must be in surviving set
    var filtered_edges: std.ArrayListUnmanaged(FilteredEdge) = .{};
    errdefer filtered_edges.deinit(allocator);

    for (edges) |e| {
        if (!surviving.contains(e.caller)) continue;
        if (!surviving.contains(e.callee)) continue;
        try filtered_edges.append(allocator, FilteredEdge{
            .caller = e.caller,
            .callee = e.callee,
            .call_count = e.call_count,
            .runtime_observed = e.runtime_observed,
            .is_static = e.is_static,
        });
    }

    return FilteredGraph{
        .symbols = try filtered_syms.toOwnedSlice(allocator),
        .edges = try filtered_edges.toOwnedSlice(allocator),
        .config_reads = config_reads,
        ._alloc = allocator,
    };
}

/// Remove edges where call_count < min_call_count.
/// Symbols whose only edges are removed may become isolated but remain in the graph.
pub fn applyEdgeFilter(
    graph: FilteredGraph,
    min_call_count: u32,
    allocator: std.mem.Allocator,
) !FilteredGraph {
    var kept_edges: std.ArrayListUnmanaged(FilteredEdge) = .{};
    errdefer kept_edges.deinit(allocator);

    for (graph.edges) |e| {
        if (e.call_count >= min_call_count) {
            try kept_edges.append(allocator, e);
        }
    }

    // Copy symbols slice
    const sym_copy = try allocator.alloc(types.Symbol, graph.symbols.len);
    errdefer allocator.free(sym_copy);
    @memcpy(sym_copy, graph.symbols);

    return FilteredGraph{
        .symbols = sym_copy,
        .edges = try kept_edges.toOwnedSlice(allocator),
        .config_reads = graph.config_reads,
        ._alloc = allocator,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn makeSymbol(id: []const u8, is_framework: bool) types.Symbol {
    return types.Symbol{
        .id = id, .kind = .class, .name = id, .language = "java",
        .file_id = null, .line_start = 1, .line_end = 1,
        .visibility = "public", .container = null,
        .annotations = &[_][]const u8{},
        .is_entry_point = false, .is_framework = is_framework, .is_generated = false,
    };
}

fn makeEdge(caller: []const u8, callee: []const u8, count: u32, observed: bool) merger.MergedEdge {
    return merger.MergedEdge{
        .caller = caller, .callee = callee,
        .call_count = count, .runtime_observed = observed, .is_static = true,
    };
}

test "framework node not in protected_ids is removed" {
    const syms = [_]types.Symbol{
        makeSymbol("App", false),
        makeSymbol("FwkOnly", true), // framework, not protected
    };
    const edges = [_]merger.MergedEdge{};
    var protected = std.StringHashMap(void).init(std.testing.allocator);
    defer protected.deinit();

    var result = try applyFrameworkFilter(&syms, &edges, &[_]types.ConfigRead{}, protected, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.symbols.len);
    try std.testing.expectEqualStrings("App", result.symbols[0].id);
}

test "framework node in protected_ids is kept" {
    const syms = [_]types.Symbol{
        makeSymbol("StripeService", true), // framework + protected
    };
    const edges = [_]merger.MergedEdge{};
    var protected = std.StringHashMap(void).init(std.testing.allocator);
    defer protected.deinit();
    try protected.put("StripeService", {});

    var result = try applyFrameworkFilter(&syms, &edges, &[_]types.ConfigRead{}, protected, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.symbols.len);
    try std.testing.expectEqualStrings("StripeService", result.symbols[0].id);
}

test "removing a node also removes edges to/from that node" {
    const syms = [_]types.Symbol{
        makeSymbol("A", false),
        makeSymbol("FwkB", true), // removed
        makeSymbol("C", false),
    };
    const edges = [_]merger.MergedEdge{
        makeEdge("A", "FwkB", 0, false),
        makeEdge("FwkB", "C", 0, false),
        makeEdge("A", "C", 0, false), // this one survives
    };
    var protected = std.StringHashMap(void).init(std.testing.allocator);
    defer protected.deinit();

    var result = try applyFrameworkFilter(&syms, &edges, &[_]types.ConfigRead{}, protected, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.symbols.len);
    try std.testing.expectEqual(@as(usize, 1), result.edges.len);
    try std.testing.expectEqualStrings("A", result.edges[0].caller);
    try std.testing.expectEqualStrings("C", result.edges[0].callee);
}

test "applyEdgeFilter: edge callCount=0 with minCallCount=1 is removed" {
    const syms = [_]types.Symbol{ makeSymbol("A", false), makeSymbol("B", false) };
    const edges = [_]merger.MergedEdge{
        makeEdge("A", "B", 0, false),
    };
    var protected = std.StringHashMap(void).init(std.testing.allocator);
    defer protected.deinit();

    var fg = try applyFrameworkFilter(&syms, &edges, &[_]types.ConfigRead{}, protected, std.testing.allocator);
    defer fg.deinit();

    var filtered = try applyEdgeFilter(fg, 1, std.testing.allocator);
    defer filtered.deinit();

    try std.testing.expectEqual(@as(usize, 0), filtered.edges.len);
}

test "applyEdgeFilter: edge callCount=3 is kept with minCallCount=1" {
    const syms = [_]types.Symbol{ makeSymbol("A", false), makeSymbol("B", false) };
    const edges = [_]merger.MergedEdge{
        makeEdge("A", "B", 3, true),
    };
    var protected = std.StringHashMap(void).init(std.testing.allocator);
    defer protected.deinit();

    var fg = try applyFrameworkFilter(&syms, &edges, &[_]types.ConfigRead{}, protected, std.testing.allocator);
    defer fg.deinit();

    var filtered = try applyEdgeFilter(fg, 1, std.testing.allocator);
    defer filtered.deinit();

    try std.testing.expectEqual(@as(usize, 1), filtered.edges.len);
    try std.testing.expectEqual(@as(u32, 3), filtered.edges[0].call_count);
}
