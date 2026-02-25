const std = @import("std");
const cli = @import("cli/cli.zig");
const record_cmd = @import("cli/commands/record.zig");
const slice_cmd = @import("cli/commands/slice.zig");
const prompt_cmd = @import("cli/commands/prompt.zig");
const orchestrator = @import("orchestrator/orchestrator.zig");
const log = @import("util/log.zig");

// Import every subsystem so their tests are included in `zig build test`.
// Cross-directory @import paths are relative to each file's location and must
// resolve within this module root (src/).
comptime {
    _ = @import("util/log.zig");
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
    _ = @import("packager/packager.zig");
    _ = @import("cli/cli.zig");
    _ = @import("cli/config.zig");
    _ = @import("orchestrator/detector.zig");
    _ = @import("orchestrator/manifest.zig");
    _ = @import("orchestrator/subprocess.zig");
    _ = @import("orchestrator/orchestrator.zig");
    _ = @import("ai/prompt_builder.zig");
    _ = @import("ai/claude.zig");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const all_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, all_args);
    const raw_args = if (all_args.len > 1) all_args[1..] else &[_][]const u8{};

    // Strip --verbose anywhere in args; set global flag if found.
    var clean_args: std.ArrayListUnmanaged([]const u8) = .{};
    defer clean_args.deinit(allocator);
    for (raw_args) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) {
            log.verbose = true;
        } else {
            try clean_args.append(allocator, arg);
        }
    }
    const args = clean_args.items;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_root = try std.fs.cwd().realpath(".", &cwd_buf);
    const tag = cli.run(args, allocator) catch |err| {
        switch (err) {
            error.HelpRequested => std.process.exit(0),
            error.MissingSubcommand, error.UnknownSubcommand => std.process.exit(1),
            else => return err,
        }
    };

    // Sub-args are everything after the subcommand name (--verbose already stripped).
    const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    switch (tag) {
        .record => {
            const record_args = record_cmd.parse(sub_args, allocator) catch |err| {
                const stderr = std.fs.File.stderr();
                switch (err) {
                    error.HelpRequested => std.process.exit(0),
                    error.MissingScenarioName => stderr.writeAll(
                        "Usage: context-slicer record <scenario> [--args \"<run-args>\"]\n",
                    ) catch {},
                    else => stderr.writeAll("record: argument error\n") catch {},
                }
                std.process.exit(1);
            };
            defer if (record_args.run_args.len > 0) allocator.free(record_args.run_args);

            const result = orchestrator.run(record_args, project_root, allocator) catch |err| {
                const stderr = std.fs.File.stderr();
                switch (err) {
                    error.UnsupportedLanguage => stderr.writeAll("Error: Unsupported project type. Only Java (Maven/Gradle) is supported.\n") catch {},
                    error.AdapterFailed => stderr.writeAll("Error: Adapter exited with a non-zero status.\n") catch {},
                    else => stderr.writeAll("Error: record failed.\n") catch {},
                }
                std.process.exit(1);
            };
            defer result.deinit(allocator);

            // Run the slice pipeline on the freshly recorded data
            slice_cmd.run(project_root, allocator) catch |err| {
                const stderr = std.fs.File.stderr();
                switch (err) {
                    error.NoRecordedScenario => stderr.writeAll("Slice not found after record — unexpected.\n") catch {},
                    else => stderr.writeAll("Error: slice pipeline failed.\n") catch {},
                }
                std.process.exit(1);
            };
        },

        .slice => {
            // P-002: Handle --help for the slice subcommand
            for (sub_args) |arg| {
                if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    slice_cmd.printSliceUsage();
                    std.process.exit(0);
                }
            }
            slice_cmd.run(project_root, allocator) catch |err| {
                switch (err) {
                    error.NoRecordedScenario => {}, // already printed by slice_cmd
                    else => {
                        const stderr = std.fs.File.stderr();
                        stderr.writeAll("Error: slice pipeline failed.\n") catch {};
                    },
                }
                std.process.exit(1);
            };
        },

        .prompt => {
            const task = if (sub_args.len > 0) sub_args[0] else null;
            prompt_cmd.run(task, project_root, allocator) catch |err| {
                switch (err) {
                    error.HelpRequested => std.process.exit(0),
                    error.MissingTaskString, error.NoSliceFound => {}, // already printed
                    else => {
                        const stderr = std.fs.File.stderr();
                        stderr.writeAll("Error: prompt failed.\n") catch {};
                    },
                }
                std.process.exit(1);
            };
        },
    }
}

test "main compiles" {
    const allocator = std.testing.allocator;
    _ = allocator;
}
