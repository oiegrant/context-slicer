const std = @import("std");

// Import every subsystem so their tests are included in `zig build test`.
// Cross-directory @import paths are relative to each file's location and must
// resolve within this module root (src/).
comptime {
    _ = @import("util/fs.zig");
    _ = @import("util/json.zig");
    _ = @import("util/hash.zig");
    _ = @import("ir/types.zig");
    _ = @import("ir/loader.zig");
    _ = @import("ir/validator.zig");
    _ = @import("ir/merger.zig");
    _ = @import("graph/graph.zig");
    _ = @import("graph/builder.zig");
    _ = @import("graph/traversal.zig");
    _ = @import("graph/expansion.zig");
    _ = @import("compression/filter.zig");
    _ = @import("compression/dedup.zig");
    _ = @import("compression/compressor.zig");
    _ = @import("packager/architecture_writer.zig");
    _ = @import("packager/config_writer.zig");
    _ = @import("packager/packager.zig");
    _ = @import("cli/cli.zig");
    _ = @import("orchestrator/detector.zig");
    _ = @import("orchestrator/manifest.zig");
    _ = @import("orchestrator/subprocess.zig");
    _ = @import("orchestrator/orchestrator.zig");
    _ = @import("ai/prompt_builder.zig");
    _ = @import("ai/claude.zig");
}

pub fn main() !void {
    // Entry point — CLI routing will be wired here in Phase 9
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator();

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("context-slicer v0.1.0\n");
}

test "main compiles" {
    const allocator = std.testing.allocator;
    _ = allocator;
}
