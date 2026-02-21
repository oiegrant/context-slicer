const std = @import("std");
const fs = @import("fs.zig");

/// Returns the hex-encoded SHA-256 hash of a byte slice as a 64-character string.
pub fn sha256Bytes(data: []const u8) [64]u8 {
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return bytesToHex(hash);
}

/// Returns the hex-encoded SHA-256 hash of a file's contents.
/// Caller provides the allocator for the temporary read buffer.
pub fn sha256File(path: []const u8, allocator: std.mem.Allocator) ![64]u8 {
    const data = try fs.readFileAlloc(path, allocator);
    defer allocator.free(data);
    return sha256Bytes(data);
}

fn bytesToHex(bytes: [32]u8) [64]u8 {
    const hex_chars = "0123456789abcdef";
    var result: [64]u8 = undefined;
    for (bytes, 0..) |b, i| {
        result[i * 2] = hex_chars[b >> 4];
        result[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sha256Bytes of empty string matches known value" {
    const hash = sha256Bytes("");
    // SHA-256 of "" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    const expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    try std.testing.expectEqualStrings(expected, &hash);
}

test "sha256Bytes of 'hello' matches known value" {
    const hash = sha256Bytes("hello");
    // SHA-256 of "hello" = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    const expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    try std.testing.expectEqualStrings(expected, &hash);
}

test "sha256File is deterministic for the same file" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const file_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/data.bin", .{tmp_path});
    defer std.testing.allocator.free(file_path);

    try fs.writeFile(file_path, "deterministic content");

    const h1 = try sha256File(file_path, std.testing.allocator);
    const h2 = try sha256File(file_path, std.testing.allocator);
    try std.testing.expectEqualStrings(&h1, &h2);
}

test "sha256File of different files returns different hashes" {
    const tmp = std.testing.tmpDir(.{});
    defer @constCast(&tmp).cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const path1 = try std.fmt.allocPrint(std.testing.allocator, "{s}/file1.txt", .{tmp_path});
    defer std.testing.allocator.free(path1);
    const path2 = try std.fmt.allocPrint(std.testing.allocator, "{s}/file2.txt", .{tmp_path});
    defer std.testing.allocator.free(path2);

    try fs.writeFile(path1, "content one");
    try fs.writeFile(path2, "content two");

    const h1 = try sha256File(path1, std.testing.allocator);
    const h2 = try sha256File(path2, std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}
