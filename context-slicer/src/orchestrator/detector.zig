const std = @import("std");
const util_fs = @import("../util/fs.zig");

/// Languages supported by the orchestrator.
pub const Language = enum { java, go, python, unknown };

/// Detect the project language from build file presence.
/// Maven (pom.xml) takes precedence over Gradle when both exist.
/// Logs a warning to stderr if multiple build file types are detected.
pub fn detect(project_root: []const u8, allocator: std.mem.Allocator) !Language {
    const pom = try std.fmt.allocPrint(allocator, "{s}/pom.xml", .{project_root});
    defer allocator.free(pom);

    const gradle = try std.fmt.allocPrint(allocator, "{s}/build.gradle", .{project_root});
    defer allocator.free(gradle);

    const gradle_kts = try std.fmt.allocPrint(allocator, "{s}/build.gradle.kts", .{project_root});
    defer allocator.free(gradle_kts);

    const go_mod = try std.fmt.allocPrint(allocator, "{s}/go.mod", .{project_root});
    defer allocator.free(go_mod);

    const requirements = try std.fmt.allocPrint(allocator, "{s}/requirements.txt", .{project_root});
    defer allocator.free(requirements);

    const pyproject = try std.fmt.allocPrint(allocator, "{s}/pyproject.toml", .{project_root});
    defer allocator.free(pyproject);

    const has_pom = util_fs.fileExists(pom);
    const has_gradle = util_fs.fileExists(gradle) or util_fs.fileExists(gradle_kts);
    const has_go = util_fs.fileExists(go_mod);
    const has_python = util_fs.fileExists(requirements) or util_fs.fileExists(pyproject);

    if (has_pom) {
        if (has_go or has_python) {
            const stderr = std.fs.File.stderr();
            stderr.writeAll("Warning: multiple build file types found; using Maven (Java)\n") catch {};
        }
        return .java;
    }
    if (has_gradle) return .java;
    if (has_go) return .go;
    if (has_python) return .python;
    return .unknown;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "detect: pom.xml -> java" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const pom = try std.fmt.allocPrint(std.testing.allocator, "{s}/pom.xml", .{tmp_path});
    defer std.testing.allocator.free(pom);
    try util_fs.writeFile(pom, "<project/>");

    const lang = try detect(tmp_path, std.testing.allocator);
    try std.testing.expectEqual(Language.java, lang);
}

test "detect: build.gradle -> java" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const gradle = try std.fmt.allocPrint(std.testing.allocator, "{s}/build.gradle", .{tmp_path});
    defer std.testing.allocator.free(gradle);
    try util_fs.writeFile(gradle, "// gradle");

    const lang = try detect(tmp_path, std.testing.allocator);
    try std.testing.expectEqual(Language.java, lang);
}

test "detect: go.mod -> go" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const gomod = try std.fmt.allocPrint(std.testing.allocator, "{s}/go.mod", .{tmp_path});
    defer std.testing.allocator.free(gomod);
    try util_fs.writeFile(gomod, "module example.com/foo");

    const lang = try detect(tmp_path, std.testing.allocator);
    try std.testing.expectEqual(Language.go, lang);
}

test "detect: requirements.txt -> python" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const req = try std.fmt.allocPrint(std.testing.allocator, "{s}/requirements.txt", .{tmp_path});
    defer std.testing.allocator.free(req);
    try util_fs.writeFile(req, "requests==2.28.0");

    const lang = try detect(tmp_path, std.testing.allocator);
    try std.testing.expectEqual(Language.python, lang);
}

test "detect: empty directory -> unknown" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const lang = try detect(tmp_path, std.testing.allocator);
    try std.testing.expectEqual(Language.unknown, lang);
}

test "detect: pom.xml + go.mod -> java (Maven wins)" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const pom = try std.fmt.allocPrint(std.testing.allocator, "{s}/pom.xml", .{tmp_path});
    defer std.testing.allocator.free(pom);
    const gomod = try std.fmt.allocPrint(std.testing.allocator, "{s}/go.mod", .{tmp_path});
    defer std.testing.allocator.free(gomod);

    try util_fs.writeFile(pom, "<project/>");
    try util_fs.writeFile(gomod, "module example.com");

    const lang = try detect(tmp_path, std.testing.allocator);
    try std.testing.expectEqual(Language.java, lang);
}

test "detect: order-service fixture -> java" {
    const fixture = "../test-fixtures/order-service";
    if (!util_fs.fileExists(fixture)) return; // skip if fixture not present
    const lang = try detect(fixture, std.testing.allocator);
    try std.testing.expectEqual(Language.java, lang);
}
