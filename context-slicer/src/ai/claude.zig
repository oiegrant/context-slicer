const std = @import("std");

const API_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";
const MODEL = "claude-sonnet-4-6";
const MAX_TOKENS: u32 = 8192;

const Message = struct {
    role: []const u8,
    content: []const u8,
};

const RequestBody = struct {
    model: []const u8,
    max_tokens: u32,
    messages: []const Message,
};

const ContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
};

const ApiResponse = struct {
    content: []const ContentBlock,
};

/// Parses an Anthropic API response body and returns the concatenated text content.
/// Returns `error.UnexpectedApiResponse` if the response cannot be parsed.
/// Caller owns the returned slice and must free it with allocator.free().
pub fn parseResponseText(body: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const parsed = std.json.parseFromSlice(ApiResponse, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.UnexpectedApiResponse;
    defer parsed.deinit();

    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    for (parsed.value.content) |block| {
        if (std.mem.eql(u8, block.type, "text")) {
            if (block.text) |text| {
                try result.appendSlice(allocator, text);
            }
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Sends a prompt to the Anthropic Messages API and streams the response to stdout.
///
/// Requires `ANTHROPIC_API_KEY` environment variable.
/// Returns `error.MissingApiKey` if the variable is not set.
/// Returns `error.AuthFailed` for HTTP 401, `error.RateLimited` for HTTP 429,
/// `error.ApiError` for other HTTP errors.
pub fn complete(prompt: []const u8, allocator: std.mem.Allocator) !void {
    // Read API key from environment
    const api_key = std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            const stderr = std.fs.File.stderr();
            stderr.writeAll("Set ANTHROPIC_API_KEY environment variable\n") catch {};
            return error.MissingApiKey;
        }
        return err;
    };
    defer allocator.free(api_key);

    // Build JSON request body
    const messages = [_]Message{.{ .role = "user", .content = prompt }};
    const req_body = RequestBody{
        .model = MODEL,
        .max_tokens = MAX_TOKENS,
        .messages = &messages,
    };
    const body_json = try std.json.Stringify.valueAlloc(allocator, req_body, .{});
    defer allocator.free(body_json);

    // HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var response_storage: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0, .allocator = allocator };
    defer response_storage.deinit();

    const extra_headers = [_]std.http.Header{
        .{ .name = "x-api-key", .value = api_key },
        .{ .name = "anthropic-version", .value = ANTHROPIC_VERSION },
        .{ .name = "content-type", .value = "application/json" },
    };

    const fetch_result = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = API_URL },
        .extra_headers = &extra_headers,
        .payload = body_json,
        .response_storage = .{ .dynamic = &response_storage },
        .max_append_size = 10 * 1024 * 1024,
    });

    switch (fetch_result.status) {
        .ok => {},
        .unauthorized => return error.AuthFailed,
        .too_many_requests => return error.RateLimited,
        else => {
            const stderr = std.fs.File.stderr();
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "API error: HTTP {d}\n", .{@intFromEnum(fetch_result.status)}) catch "API error\n";
            stderr.writeAll(msg) catch {};
            return error.ApiError;
        },
    }

    // Parse and print response
    const text = try parseResponseText(response_storage.items, allocator);
    defer allocator.free(text);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(text);
    try stdout.writeAll("\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseResponseText: valid response returns text" {
    const json =
        \\{"content":[{"type":"text","text":"Hello, world!"}],"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5}}
    ;
    const text = try parseResponseText(json, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Hello, world!", text);
}

test "parseResponseText: multiple content blocks concatenated" {
    const json =
        \\{"content":[{"type":"text","text":"Part one. "},{"type":"text","text":"Part two."}]}
    ;
    const text = try parseResponseText(json, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Part one. Part two.", text);
}

test "parseResponseText: non-text blocks are ignored" {
    const json =
        \\{"content":[{"type":"thinking","text":"thinking..."},{"type":"text","text":"Answer."}]}
    ;
    const text = try parseResponseText(json, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Answer.", text);
}

test "parseResponseText: malformed JSON returns UnexpectedApiResponse" {
    const result = parseResponseText("not json at all", std.testing.allocator);
    try std.testing.expectError(error.UnexpectedApiResponse, result);
}

test "parseResponseText: missing content field returns UnexpectedApiResponse" {
    const result = parseResponseText("{\"id\":\"msg_1\"}", std.testing.allocator);
    try std.testing.expectError(error.UnexpectedApiResponse, result);
}

test "complete: missing API key returns MissingApiKey" {
    // Only runs when ANTHROPIC_API_KEY is not set in the environment.
    const has_key = std.process.getEnvVarOwned(std.testing.allocator, "ANTHROPIC_API_KEY") catch null;
    if (has_key) |key| {
        std.testing.allocator.free(key);
        return; // Skip test if key is present
    }
    const result = complete("hello", std.testing.allocator);
    try std.testing.expectError(error.MissingApiKey, result);
}
