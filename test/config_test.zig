const std = @import("std");
const config = @import("config");

test "defaults keep monitoring enabled without remote-control switches" {
    const cfg = config.Config.default();
    try std.testing.expectEqual(@as(f64, 1.0), cfg.interval);
    try std.testing.expectEqual(@as(i32, 3), cfg.max_retries);
    try std.testing.expectEqual(@as(i32, 5), cfg.reconnect_interval);
    try std.testing.expectEqual(@as(i32, 2), cfg.protocol_version);
    try std.testing.expect(!cfg.disable_compression);
    try std.testing.expect(!cfg.debug_log);
}

test "monitoring cli options parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{
        "komari-agent", "-t", "tok", "-e", "https://panel.example", "-i", "2.5",
        "-r",           "7",  "-c", "11", "--include-nics", "eth0,wlan0",
        "--exclude-nics", "docker0", "--month-rotate", "8", "--gpu",
    };
    const cfg = try config.parseArgs(arena.allocator(), &args);
    try std.testing.expectEqualStrings("tok", cfg.token);
    try std.testing.expectEqualStrings("https://panel.example", cfg.endpoint);
    try std.testing.expectEqual(@as(f64, 2.5), cfg.interval);
    try std.testing.expectEqual(@as(i32, 7), cfg.max_retries);
    try std.testing.expectEqual(@as(i32, 11), cfg.reconnect_interval);
    try std.testing.expectEqualStrings("eth0,wlan0", cfg.include_nics);
    try std.testing.expectEqualStrings("docker0", cfg.exclude_nics);
    try std.testing.expectEqual(@as(i32, 8), cfg.month_rotate);
    try std.testing.expect(cfg.enable_gpu);
}

test "json configuration keeps supported monitoring fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const json =
        \\{
        \\  "token": "json-token",
        \\  "endpoint": "https://json.example",
        \\  "interval": 3.5,
        \\  "max_retries": 9,
        \\  "reconnect_interval": 12,
        \\  "protocol_version": 1,
        \\  "include_nics": "eth0",
        \\  "custom_dns": "1.1.1.1",
        \\  "host_proc": "/host/proc"
        \\}
    ;

    var cfg = config.Config.default();
    try cfg.loadJson(arena.allocator(), json);
    try std.testing.expectEqualStrings("json-token", cfg.token);
    try std.testing.expectEqualStrings("https://json.example", cfg.endpoint);
    try std.testing.expectEqual(@as(f64, 3.5), cfg.interval);
    try std.testing.expectEqual(@as(i32, 9), cfg.max_retries);
    try std.testing.expectEqual(@as(i32, 12), cfg.reconnect_interval);
    try std.testing.expectEqual(@as(i32, 1), cfg.protocol_version);
    try std.testing.expectEqualStrings("eth0", cfg.include_nics);
    try std.testing.expectEqualStrings("1.1.1.1", cfg.custom_dns);
    try std.testing.expectEqualStrings("/host/proc", cfg.host_proc);
}

test "unknown flags and missing values do not block monitoring options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{ "komari-agent", "--future-flag", "x", "--token", "tok", "--max-retries" };
    const cfg = try config.parseArgs(arena.allocator(), &args);
    try std.testing.expectEqualStrings("tok", cfg.token);
    try std.testing.expectEqual(@as(i32, 3), cfg.max_retries);
}

test "config normalize defaults protocol version zero and validates values" {
    var cfg = config.Config.default();
    cfg.protocol_version = 0;
    try cfg.normalize();
    try std.testing.expectEqual(@as(i32, 2), cfg.protocol_version);

    cfg.protocol_version = 9;
    try std.testing.expectError(error.InvalidProtocolVersion, cfg.normalize());

    cfg.protocol_version = 2;
    cfg.prefer_ip_version = "5";
    try std.testing.expectError(error.InvalidPreferIpVersion, cfg.normalize());
}
