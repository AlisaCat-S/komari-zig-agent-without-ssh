const std = @import("std");
const basic_info = @import("src/protocol/basic_info.zig");
const config = @import("src/config.zig");
const local_http = @import("test/local_http.zig");

test "basic info v2 upload sends rpc request and accepts response" {
    const body = "{\"jsonrpc\":\"2.0\",\"result\":{\"status\":\"ok\"}}";
    const response = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    const responses = [_][]const u8{response};
    var server = try local_http.Server.start(std.testing.allocator, &responses);

    basic_info.initRequestedProtocolVersionForTest(2);
    basic_info.resetConnectionProtocolVersionForTest();
    defer basic_info.resetConnectionProtocolVersionForTest();

    const endpoint = try server.url(std.testing.allocator, "");
    defer std.testing.allocator.free(endpoint);
    const cfg = config.Config{
        .endpoint = endpoint,
        .token = "tok",
        .disable_compression = true,
        .max_retries = 0,
    };
    try basic_info.uploadV2(std.testing.allocator, cfg, sampleBasicInfo(), true);

    var completed = try server.finish();
    defer completed.deinit();

    try std.testing.expectEqual(@as(usize, 1), completed.requests.len);
    const request = completed.requests[0];
    try std.testing.expectEqualStrings("POST /api/clients/v2/rpc?token=tok HTTP/1.1", request.requestLine());
    try std.testing.expectEqualStrings("komari-zig-agent", request.header("User-Agent").?);
    try std.testing.expectEqualStrings("application/json", request.header("Content-Type").?);
    try std.testing.expect(request.header("Content-Encoding") == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, request.body, .{});
    defer parsed.deinit();
    const root = try expectObject(parsed.value);
    try expectStringField(root, "jsonrpc", "2.0");
    try expectStringField(root, "method", "agent.basicInfo");
}

test "basic info v2 upload gzips body by default" {
    const body = "{\"jsonrpc\":\"2.0\",\"result\":{\"status\":\"ok\"}}";
    const response = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    const responses = [_][]const u8{response};
    var server = try local_http.Server.start(std.testing.allocator, &responses);
    errdefer server.join() catch unreachable;

    basic_info.initRequestedProtocolVersionForTest(2);
    basic_info.resetConnectionProtocolVersionForTest();
    defer basic_info.resetConnectionProtocolVersionForTest();

    const endpoint = try server.url(std.testing.allocator, "");
    defer std.testing.allocator.free(endpoint);
    const cfg = config.Config{
        .endpoint = endpoint,
        .token = "tok",
        .max_retries = 0,
    };
    try basic_info.uploadV2(std.testing.allocator, cfg, sampleBasicInfo(), true);

    var completed = try server.finish();
    defer completed.deinit();

    try std.testing.expectEqual(@as(usize, 1), completed.requests.len);
    const request = completed.requests[0];
    try std.testing.expectEqualStrings("gzip", request.header("Content-Encoding").?);

    const decoded = try decompressGzip(std.testing.allocator, request.body);
    defer std.testing.allocator.free(decoded);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, decoded, .{});
    defer parsed.deinit();
    const root = try expectObject(parsed.value);
    try expectStringField(root, "jsonrpc", "2.0");
    try expectStringField(root, "method", "agent.basicInfo");
}

test "basic info v2 rejects rpc error responses" {
    const body = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"boom\"}}";
    const response = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    const responses = [_][]const u8{response};
    var server = try local_http.Server.start(std.testing.allocator, &responses);
    defer server.join() catch unreachable;

    basic_info.initRequestedProtocolVersionForTest(2);
    basic_info.resetConnectionProtocolVersionForTest();
    defer basic_info.resetConnectionProtocolVersionForTest();

    const endpoint = try server.url(std.testing.allocator, "");
    defer std.testing.allocator.free(endpoint);
    const cfg = config.Config{
        .endpoint = endpoint,
        .token = "tok",
        .disable_compression = true,
        .max_retries = 0,
    };
    try std.testing.expectError(error.InvalidV2Response, basic_info.uploadV2(std.testing.allocator, cfg, sampleBasicInfo(), true));
}

test "basic info v2 falls back to v1 after three transport failures" {
    const responses = [_][]const u8{
        "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    };
    var server = try local_http.Server.start(std.testing.allocator, &responses);

    basic_info.initRequestedProtocolVersionForTest(2);
    basic_info.resetConnectionProtocolVersionForTest();
    defer basic_info.resetConnectionProtocolVersionForTest();

    const endpoint = try server.url(std.testing.allocator, "");
    defer std.testing.allocator.free(endpoint);
    const cfg = config.Config{
        .endpoint = endpoint,
        .token = "tok",
        .disable_compression = true,
        .max_retries = 0,
    };

    try std.testing.expectError(error.HttpStatusNotOk, basic_info.uploadV2(std.testing.allocator, cfg, sampleBasicInfo(), true));
    try std.testing.expectError(error.HttpStatusNotOk, basic_info.uploadV2(std.testing.allocator, cfg, sampleBasicInfo(), true));
    try basic_info.uploadV2(std.testing.allocator, cfg, sampleBasicInfo(), true);

    var completed = try server.finish();
    defer completed.deinit();

    try std.testing.expectEqual(@as(usize, 4), completed.requests.len);
    try std.testing.expectEqualStrings("POST /api/clients/v2/rpc?token=tok HTTP/1.1", completed.requests[0].requestLine());
    try std.testing.expectEqualStrings("POST /api/clients/v2/rpc?token=tok HTTP/1.1", completed.requests[1].requestLine());
    try std.testing.expectEqualStrings("POST /api/clients/v2/rpc?token=tok HTTP/1.1", completed.requests[2].requestLine());
    try std.testing.expectEqualStrings("POST /api/clients/uploadBasicInfo?token=tok HTTP/1.1", completed.requests[3].requestLine());
    try std.testing.expectEqual(@as(i32, 1), basic_info.uploadProtocolVersionForTest());
}

test "basic info v2 falls back to v1 after three invalid rpc responses" {
    const invalid_body = "{\"jsonrpc\":\"1.0\"}";
    const invalid_response = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ invalid_body.len, invalid_body },
    );
    const responses = [_][]const u8{
        invalid_response,
        invalid_response,
        invalid_response,
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    };
    var server = try local_http.Server.start(std.testing.allocator, &responses);
    errdefer server.join() catch unreachable;

    basic_info.initRequestedProtocolVersionForTest(2);
    basic_info.resetConnectionProtocolVersionForTest();
    defer basic_info.resetConnectionProtocolVersionForTest();

    const endpoint = try server.url(std.testing.allocator, "");
    defer std.testing.allocator.free(endpoint);
    const cfg = config.Config{
        .endpoint = endpoint,
        .token = "tok",
        .disable_compression = true,
        .max_retries = 0,
    };

    try std.testing.expectError(error.InvalidV2Response, basic_info.uploadV2(std.testing.allocator, cfg, sampleBasicInfo(), true));
    try std.testing.expectError(error.InvalidV2Response, basic_info.uploadV2(std.testing.allocator, cfg, sampleBasicInfo(), true));
    try basic_info.uploadV2(std.testing.allocator, cfg, sampleBasicInfo(), true);

    var completed = try server.finish();
    defer completed.deinit();

    try std.testing.expectEqual(@as(usize, 4), completed.requests.len);
    try std.testing.expectEqualStrings("POST /api/clients/v2/rpc?token=tok HTTP/1.1", completed.requests[0].requestLine());
    try std.testing.expectEqualStrings("POST /api/clients/v2/rpc?token=tok HTTP/1.1", completed.requests[1].requestLine());
    try std.testing.expectEqualStrings("POST /api/clients/v2/rpc?token=tok HTTP/1.1", completed.requests[2].requestLine());
    try std.testing.expectEqualStrings("POST /api/clients/uploadBasicInfo?token=tok HTTP/1.1", completed.requests[3].requestLine());
    try std.testing.expectEqual(@as(i32, 1), basic_info.uploadProtocolVersionForTest());
}

fn sampleBasicInfo() basic_info.BasicInfo {
    return .{
        .cpu = .{
            .name = "CPU",
            .architecture = "amd64",
            .cores = 8,
            .physical_cores = 4,
        },
        .os_name = "linux",
        .kernel_version = "6.1.0",
        .ipv4 = "192.0.2.1",
        .ipv6 = "2001:db8::1",
        .mem_total = 1024,
        .swap_total = 2048,
        .disk_total = 4096,
        .gpu_name = "GPU",
        .virtualization = "kvm",
    };
}

fn expectObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.TestUnexpectedResult;
    return value.object;
}

fn expectStringField(object: std.json.ObjectMap, key: []const u8, expected: []const u8) !void {
    const value = object.get(key) orelse return error.TestUnexpectedResult;
    if (value != .string) return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected, value.string);
}

fn decompressGzip(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var reader: std.Io.Reader = .fixed(compressed);
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&reader, .gzip, history[0..]);
    _ = try decompress.reader.streamRemaining(&out.writer);
    return try out.toOwnedSlice();
}

test "failed v1 fallback and reconnect prefer requested v2" {
    const report_ws = @import("src/protocol/report_ws.zig");
    basic_info.initRequestedProtocolVersionForTest(2);
    defer basic_info.resetConnectionProtocolVersionForTest();
    report_ws.applyV1FallbackConnectResultForTest(true);
    try std.testing.expectEqual(@as(i32, 1), report_ws.uploadProtocolVersionForTest());
    report_ws.applyV1FallbackConnectResultForTest(false);
    try std.testing.expectEqual(@as(i32, 2), report_ws.uploadProtocolVersionForTest());
    report_ws.applyV1FallbackConnectResultForTest(true);
    report_ws.prepareReconnectCycleForTest();
    try std.testing.expectEqual(@as(i32, 2), report_ws.uploadProtocolVersionForTest());
}
