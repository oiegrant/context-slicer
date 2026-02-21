const std = @import("std");
const types = @import("types.zig");

pub const SUPPORTED_IR_VERSION = "0.1";

pub const WarningKind = enum {
    invalid_file_id,
    invalid_caller_id,
    invalid_callee_id,
};

pub const ValidationWarning = struct {
    kind: WarningKind,
    message: []const u8,
};

/// Result of validating an IrRoot.
/// Contains only the clean (non-quarantined) symbols and edges.
/// The string slices in symbols/edges point into the original IrRoot's arena;
/// the caller must keep the source Parsed(IrRoot) alive.
/// Call deinit() to free warnings and the filtered slices.
pub const ValidationResult = struct {
    ir_version: []const u8,
    language: []const u8,
    repo_root: []const u8,
    build_id: []const u8,
    adapter_version: []const u8,
    scenario: types.Scenario,
    files: []const types.IrFile,
    symbols: []types.Symbol,
    call_edges: []types.CallEdge,
    config_reads: []const types.ConfigRead,
    warnings: []ValidationWarning,
    _alloc: std.mem.Allocator,

    pub fn deinit(self: ValidationResult) void {
        self._alloc.free(self.symbols);
        self._alloc.free(self.call_edges);
        self._alloc.free(self.warnings);
    }
};

/// Validates an IrRoot against the schema rules:
///   1. ir_version must match SUPPORTED_IR_VERSION (hard error if not)
///   2. Every symbol.file_id must exist in the files set (quarantine symbol if not)
///   3. Every call_edge.caller and .callee must exist in the symbol set (quarantine edge if not)
///
/// Returns ValidationResult with clean symbols/edges and a list of warnings.
/// Returns error.IncompatibleIrVersion if the version does not match.
pub fn validate(ir: types.IrRoot, allocator: std.mem.Allocator) !ValidationResult {
    // 1. Version check
    if (!std.mem.eql(u8, ir.ir_version, SUPPORTED_IR_VERSION)) {
        return error.IncompatibleIrVersion;
    }

    // Build a set of valid file IDs
    var file_ids = std.StringHashMap(void).init(allocator);
    defer file_ids.deinit();
    for (ir.files) |f| {
        try file_ids.put(f.id, {});
    }

    // Build a set of valid symbol IDs (populated as we accept symbols)
    var symbol_ids = std.StringHashMap(void).init(allocator);
    defer symbol_ids.deinit();

    // Filter symbols: quarantine those with null or unknown file_id
    // Use ArrayListUnmanaged (Zig 0.15.2 — ArrayList.init() removed)
    var clean_symbols: std.ArrayListUnmanaged(types.Symbol) = .{};
    errdefer clean_symbols.deinit(allocator);
    var warnings: std.ArrayListUnmanaged(ValidationWarning) = .{};
    errdefer warnings.deinit(allocator);

    for (ir.symbols) |sym| {
        const fid = sym.file_id orelse {
            try warnings.append(allocator, .{
                .kind = .invalid_file_id,
                .message = sym.id,
            });
            continue;
        };
        if (!file_ids.contains(fid)) {
            try warnings.append(allocator, .{
                .kind = .invalid_file_id,
                .message = sym.id,
            });
            continue;
        }
        try clean_symbols.append(allocator, sym);
        try symbol_ids.put(sym.id, {});
    }

    // Filter edges: quarantine those whose caller or callee is not in the clean symbol set
    var clean_edges: std.ArrayListUnmanaged(types.CallEdge) = .{};
    errdefer clean_edges.deinit(allocator);

    for (ir.call_edges) |edge| {
        if (!symbol_ids.contains(edge.caller)) {
            try warnings.append(allocator, .{
                .kind = .invalid_caller_id,
                .message = edge.caller,
            });
            continue;
        }
        if (!symbol_ids.contains(edge.callee)) {
            try warnings.append(allocator, .{
                .kind = .invalid_callee_id,
                .message = edge.callee,
            });
            continue;
        }
        try clean_edges.append(allocator, edge);
    }

    return ValidationResult{
        .ir_version = ir.ir_version,
        .language = ir.language,
        .repo_root = ir.repo_root,
        .build_id = ir.build_id,
        .adapter_version = ir.adapter_version,
        .scenario = ir.scenario,
        .files = ir.files,
        .symbols = try clean_symbols.toOwnedSlice(allocator),
        .call_edges = try clean_edges.toOwnedSlice(allocator),
        .config_reads = ir.config_reads,
        .warnings = try warnings.toOwnedSlice(allocator),
        ._alloc = allocator,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const loader = @import("loader.zig");

const FIXTURE_DIR = "../test-fixtures/ir";

test "validate valid static_ir.json returns 0 warnings" {
    var parsed = try loader.loadStatic(FIXTURE_DIR ++ "/static_ir.json", std.testing.allocator);
    defer parsed.deinit();

    const result = try validate(parsed.value, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
    try std.testing.expectEqual(@as(usize, 17), result.symbols.len);
}

test "validate wrong version returns IncompatibleIrVersion" {
    var parsed = try loader.loadStatic(FIXTURE_DIR ++ "/static_ir_wrong_version.json", std.testing.allocator);
    defer parsed.deinit();

    const result = validate(parsed.value, std.testing.allocator);
    try std.testing.expectError(error.IncompatibleIrVersion, result);
}

test "validate malformed IR (null file_id) quarantines symbol" {
    // static_ir_malformed.json has 2 symbols: one valid (f01), one with null file_id
    var parsed = try loader.loadStatic(FIXTURE_DIR ++ "/static_ir_malformed.json", std.testing.allocator);
    defer parsed.deinit();

    const result = try validate(parsed.value, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
    try std.testing.expectEqual(WarningKind.invalid_file_id, result.warnings[0].kind);
    // The quarantined symbol is "java::com.example.Bar" (null file_id)
    try std.testing.expectEqualStrings("java::com.example.Bar", result.warnings[0].message);
    // Only the valid symbol remains
    try std.testing.expectEqual(@as(usize, 1), result.symbols.len);
    try std.testing.expectEqualStrings("java::com.example.Foo", result.symbols[0].id);
}

test "validate edge with non-existent callee is quarantined" {
    // Build a minimal IrRoot in memory with a bad edge
    const file = types.IrFile{ .id = "f01", .path = "Foo.java", .language = "java", .hash = "sha256:x" };
    const sym_a = types.Symbol{
        .id = "A", .kind = .class, .name = "A", .language = "java",
        .file_id = "f01", .line_start = 1, .line_end = 5,
        .visibility = "public", .container = null, .annotations = &[_][]const u8{},
        .is_entry_point = false, .is_framework = false, .is_generated = false,
    };
    const bad_edge = types.CallEdge{
        .caller = "A", .callee = "NONEXISTENT",
        .@"static" = true, .runtime_observed = false, .call_count = 0,
    };
    const root = types.IrRoot{
        .ir_version = "0.1", .language = "java",
        .repo_root = "/tmp", .build_id = "t", .adapter_version = "0.1.0",
        .scenario = .{ .name = "t", .entry_points = &[_][]const u8{}, .run_args = &[_][]const u8{}, .config_files = &[_][]const u8{} },
        .files = &[_]types.IrFile{file},
        .symbols = &[_]types.Symbol{sym_a},
        .call_edges = &[_]types.CallEdge{bad_edge},
        .config_reads = &[_]types.ConfigRead{},
        .runtime = .{ .observed_symbols = &[_]types.ObservedSymbol{}, .observed_edges = &[_]types.ObservedEdge{} },
    };

    const result = try validate(root, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
    try std.testing.expectEqual(WarningKind.invalid_callee_id, result.warnings[0].kind);
    try std.testing.expectEqual(@as(usize, 0), result.call_edges.len);
}
