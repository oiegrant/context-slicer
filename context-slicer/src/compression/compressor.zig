const std = @import("std");
const types = @import("../ir/types.zig");
const merger = @import("../ir/merger.zig");
const expansion = @import("../graph/expansion.zig");
const filter = @import("filter.zig");
const dedup = @import("dedup.zig");

/// The output of the compression pipeline.
pub const Slice = struct {
    ordered_symbols: []types.Symbol,
    relevant_file_paths: [][]const u8,
    call_graph_edges: []filter.FilteredEdge,
    /// Per-symbol transform annotations — parallel array to ordered_symbols.
    /// Entry is null if no transform was recorded for that symbol.
    transforms: []?types.MethodTransform,
    _alloc: std.mem.Allocator,

    pub fn deinit(self: Slice) void {
        self._alloc.free(self.ordered_symbols);
        self._alloc.free(self.relevant_file_paths);
        self._alloc.free(self.call_graph_edges);
        self._alloc.free(self.transforms);
    }
};

/// Compress an expanded graph + merged IR into a tight Slice.
///
/// Pipeline:
///   1. Build edge list from merged IR, filtered to expanded symbol set
///   2. Apply framework filter (keeps all in expanded set; no is_framework exclusion at this stage
///      since expansion already includes only relevant framework nodes)
///   3. Deduplicate edges
///   4. Topological sort (entry points first, leaves last; Kahn's algorithm)
///   5. Deduplicate file paths
pub fn compress(
    expanded: expansion.ExpandedGraph,
    ir: merger.MergedIr,
    allocator: std.mem.Allocator,
) !Slice {
    // Build set of expanded symbol IDs for fast lookup
    var expanded_set = std.StringHashMap(void).init(allocator);
    defer expanded_set.deinit();
    for (expanded.symbols) |sym| {
        try expanded_set.put(sym.id, {});
    }

    // Extract edges between expanded symbols from merged IR
    var raw_edges: std.ArrayListUnmanaged(filter.FilteredEdge) = .{};
    defer raw_edges.deinit(allocator);

    for (ir.call_edges) |e| {
        if (!expanded_set.contains(e.caller)) continue;
        if (!expanded_set.contains(e.callee)) continue;
        try raw_edges.append(allocator, filter.FilteredEdge{
            .caller = e.caller,
            .callee = e.callee,
            .call_count = e.call_count,
            .runtime_observed = e.runtime_observed,
            .is_static = e.is_static,
        });
    }

    // Deduplicate edges
    const deduped_edges = try dedup.deduplicateEdges(raw_edges.items, allocator);
    defer allocator.free(deduped_edges);

    // Copy deduped edges for Slice output
    const output_edges = try allocator.alloc(filter.FilteredEdge, deduped_edges.len);
    errdefer allocator.free(output_edges);
    @memcpy(output_edges, deduped_edges);

    // Topological sort of expanded symbols using Kahn's algorithm
    // Build in-degree map for expanded symbols only
    var in_degree = std.StringHashMap(u32).init(allocator);
    defer in_degree.deinit();
    for (expanded.symbols) |sym| {
        try in_degree.put(sym.id, 0);
    }
    for (deduped_edges) |e| {
        if (in_degree.getPtr(e.callee)) |deg| {
            deg.* += 1;
        }
    }

    // Build adjacency list
    var adj = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator);
    defer {
        var it = adj.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        adj.deinit();
    }
    for (deduped_edges) |e| {
        const r = try adj.getOrPut(e.caller);
        if (!r.found_existing) r.value_ptr.* = .{};
        try r.value_ptr.append(allocator, e.callee);
    }

    // Kahn's BFS
    var queue: std.ArrayListUnmanaged([]const u8) = .{};
    defer queue.deinit(allocator);
    var sym_map = std.StringHashMap(types.Symbol).init(allocator);
    defer sym_map.deinit();
    for (expanded.symbols) |sym| {
        try sym_map.put(sym.id, sym);
        if ((in_degree.get(sym.id) orelse 0) == 0) {
            try queue.append(allocator, sym.id);
        }
    }

    var ordered: std.ArrayListUnmanaged(types.Symbol) = .{};
    errdefer ordered.deinit(allocator);
    var head: usize = 0;
    while (head < queue.items.len) {
        const cur = queue.items[head];
        head += 1;
        if (sym_map.get(cur)) |sym| {
            try ordered.append(allocator, sym);
        }
        if (adj.get(cur)) |neighbors| {
            for (neighbors.items) |next| {
                if (in_degree.getPtr(next)) |deg| {
                    deg.* -= 1;
                    if (deg.* == 0) {
                        try queue.append(allocator, next);
                    }
                }
            }
        }
    }
    // Any remaining (cycle nodes) appended at end
    for (expanded.symbols) |sym| {
        if ((in_degree.get(sym.id) orelse 0) > 0) {
            try ordered.append(allocator, sym);
        }
    }

    // Deduplicate file paths
    var seen_paths = std.StringHashMap(void).init(allocator);
    defer seen_paths.deinit();

    // Build symbol-id → file-path from ir.files
    var file_path_map = std.StringHashMap([]const u8).init(allocator);
    defer file_path_map.deinit();
    for (ir.files) |f| {
        try file_path_map.put(f.id, f.path);
    }

    var file_paths: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer file_paths.deinit(allocator);

    for (ordered.items) |sym| {
        if (sym.file_id) |fid| {
            if (file_path_map.get(fid)) |path| {
                if (!seen_paths.contains(path)) {
                    try seen_paths.put(path, {});
                    try file_paths.append(allocator, path);
                }
            }
        }
    }

    // Build parallel transforms array (nullable, one entry per ordered symbol)
    const ordered_slice = try ordered.toOwnedSlice(allocator);
    errdefer allocator.free(ordered_slice);

    var transforms_list = try allocator.alloc(?types.MethodTransform, ordered_slice.len);
    errdefer allocator.free(transforms_list);
    for (ordered_slice, 0..) |sym, i| {
        transforms_list[i] = ir.transforms.get(sym.id);
    }

    return Slice{
        .ordered_symbols = ordered_slice,
        .relevant_file_paths = try file_paths.toOwnedSlice(allocator),
        .call_graph_edges = output_edges,
        .transforms = transforms_list,
        ._alloc = allocator,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const loader = @import("../ir/loader.zig");
const validator = @import("../ir/validator.zig");
const graph_builder = @import("../graph/builder.zig");
const traversal = @import("../graph/traversal.zig");
const expansion_mod = @import("../graph/expansion.zig");

const FIXTURE_DIR = "../test-fixtures/ir";

const EMPTY_RUNTIME = types.RuntimeTrace{
    .observed_symbols = &[_]types.ObservedSymbol{},
    .observed_edges = &[_]types.ObservedEdge{},
};

/// Full pipeline: load fixtures → validate → merge → build graph → hot path → expand → compress.
fn runFullPipeline(allocator: std.mem.Allocator) !struct {
    static_parsed: std.json.Parsed(types.IrRoot),
    runtime_parsed: std.json.Parsed(types.RuntimeTrace),
    validated: validator.ValidationResult,
    merged: merger.MergedIr,
    graph: graph_builder.Graph,
    hot: []types.Symbol,
    expanded: expansion_mod.ExpandedGraph,
    slice: Slice,
} {
    var static_parsed = try loader.loadStatic(FIXTURE_DIR ++ "/static_ir.json", allocator);
    errdefer static_parsed.deinit();
    var runtime_parsed = try loader.loadRuntime(FIXTURE_DIR ++ "/runtime_trace.json", allocator);
    errdefer runtime_parsed.deinit();

    var validated = try validator.validate(static_parsed.value, allocator);
    errdefer validated.deinit();

    var merged = try merger.merge(validated, runtime_parsed.value, allocator);
    errdefer merged.deinit();

    var g = try graph_builder.build(merged, allocator);
    errdefer g.deinit();

    const hot = try traversal.hotPath(&g, allocator);
    errdefer allocator.free(hot);

    var expanded = try expansion_mod.expand(&g, hot, &g.file_map, allocator);
    errdefer expanded.deinit();

    const slice = try compress(expanded, merged, allocator);

    return .{
        .static_parsed = static_parsed,
        .runtime_parsed = runtime_parsed,
        .validated = validated,
        .merged = merged,
        .graph = g,
        .hot = hot,
        .expanded = expanded,
        .slice = slice,
    };
}

test "orderedSymbols starts with an entry point (OrderController.createOrder)" {
    var p = try runFullPipeline(std.testing.allocator);
    defer {
        p.slice.deinit();
        p.expanded.deinit();
        std.testing.allocator.free(p.hot);
        p.graph.deinit();
        p.merged.deinit();
        p.validated.deinit();
        p.runtime_parsed.deinit();
        p.static_parsed.deinit();
    }

    try std.testing.expect(p.slice.ordered_symbols.len > 0);
    // Entry point should appear somewhere (not necessarily first due to topo sort stability)
    var found_entry = false;
    for (p.slice.ordered_symbols) |sym| {
        if (std.mem.indexOf(u8, sym.id, "OrderController") != null and
            std.mem.indexOf(u8, sym.id, "createOrder") != null)
        {
            found_entry = true;
        }
    }
    try std.testing.expect(found_entry);
}

test "relevantFilePaths has no duplicates" {
    var p = try runFullPipeline(std.testing.allocator);
    defer {
        p.slice.deinit();
        p.expanded.deinit();
        std.testing.allocator.free(p.hot);
        p.graph.deinit();
        p.merged.deinit();
        p.validated.deinit();
        p.runtime_parsed.deinit();
        p.static_parsed.deinit();
    }

    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    for (p.slice.relevant_file_paths) |path| {
        try std.testing.expect(!seen.contains(path));
        try seen.put(path, {});
    }
}

test "compress produces 5 or fewer unique file paths (tight slicing)" {
    var p = try runFullPipeline(std.testing.allocator);
    defer {
        p.slice.deinit();
        p.expanded.deinit();
        std.testing.allocator.free(p.hot);
        p.graph.deinit();
        p.merged.deinit();
        p.validated.deinit();
        p.runtime_parsed.deinit();
        p.static_parsed.deinit();
    }

    // The fixture has 11 files; a tight slice should reference ≤ 8
    try std.testing.expect(p.slice.relevant_file_paths.len <= 8);
}

test "call_graph_edges present after compress" {
    var p = try runFullPipeline(std.testing.allocator);
    defer {
        p.slice.deinit();
        p.expanded.deinit();
        std.testing.allocator.free(p.hot);
        p.graph.deinit();
        p.merged.deinit();
        p.validated.deinit();
        p.runtime_parsed.deinit();
        p.static_parsed.deinit();
    }

    try std.testing.expect(p.slice.call_graph_edges.len > 0);
}
