const std = @import("std");
const config = @import("../config.zig");
const debug = @import("debug");
const http = @import("http.zig");
const common = @import("../platform/common.zig");
const provider = @import("../platform/provider.zig");
const report = @import("../report/report.zig");
const v2 = @import("v2.zig");
const v2_state = @import("v2_state.zig");
const ws_client = @import("ws_client.zig");
const compat = @import("compat");
const timing = @import("report_timing.zig");
const thread_stacks = @import("../thread_stacks.zig");

/// Outbound monitoring reports. Server-originated frames are discarded.
const report_stack_buffer_size = 4096;

fn snapshotOptions(cfg: config.Config) common.SnapshotOptions {
    return .{
        .include_nics = cfg.include_nics,
        .exclude_nics = cfg.exclude_nics,
        .include_mountpoints = cfg.include_mountpoints,
        .month_rotate = cfg.month_rotate,
        .enable_gpu = cfg.enable_gpu,
        .host_proc = cfg.host_proc,
        .memory_include_cache = cfg.memory_include_cache,
        .memory_report_raw_used = cfg.memory_report_raw_used,
    };
}

pub fn runOnce(allocator: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    return report.allocReportJson(allocator, try provider.snapshotWithOptions(snapshotOptions(cfg)));
}

pub fn uploadProtocolVersionForTest() i32 {
    return v2_state.uploadProtocolVersion();
}

fn applyV1FallbackConnectResult(connect_ok: bool) void {
    if (connect_ok) {
        v2_state.setConnectionProtocolVersion(1);
        v2_state.resetV2ProtocolFailures(1);
    } else {
        v2_state.resetConnectionProtocolVersion();
    }
}

/// Test wrapper around sticky-v1 rules without network I/O.
pub fn applyV1FallbackConnectResultForTest(connect_ok: bool) void {
    applyV1FallbackConnectResult(connect_ok);
}

pub fn prepareReconnectCycleForTest() void {
    v2_state.resetConnectionProtocolVersion();
}

fn writeReportOnce(allocator: std.mem.Allocator, ws: *ws_client.Client, cfg: config.Config) !void {
    const snap = try provider.snapshotWithOptions(snapshotOptions(cfg));
    var owns_gpu_json = true;
    defer if (owns_gpu_json and snap.gpu_json.len != 0) std.heap.page_allocator.free(snap.gpu_json);

    const protocol_version = v2_state.uploadProtocolVersion();
    var buf: [report_stack_buffer_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    report.writeReportJson(&writer, snap) catch |err| switch (err) {
        error.WriteFailed => {
            owns_gpu_json = false;
            const payload = try report.allocReportJson(allocator, snap);
            defer allocator.free(payload);
            if (protocol_version >= 2) {
                const rpc = try v2.allocReportNotification(allocator, payload);
                defer allocator.free(rpc);
                try ws.writeText(rpc);
            } else {
                try ws.writeText(payload);
            }
            return;
        },
    };
    if (protocol_version >= 2) {
        const rpc = try v2.allocReportNotification(allocator, writer.buffered());
        defer allocator.free(rpc);
        try ws.writeText(rpc);
    } else {
        try ws.writeText(writer.buffered());
    }
}

pub const reportIntervalMs = timing.reportIntervalMs;
pub const remainingSleepMs = timing.remainingSleepMs;

pub fn reconnectSleepSeconds(value: i32) u64 {
    return if (value <= 0) 5 else @intCast(value);
}

pub fn loop(allocator: std.mem.Allocator, cfg: config.Config, stop_requested: ?*const std.atomic.Value(bool)) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = compat.fileWriter(std.Io.File.stdout(), &stdout_buf);
    defer stdout.flush() catch {};

    while (!isStopRequested(stop_requested)) {
        var ws = connectReportWsWithRetries(allocator, cfg, stop_requested) catch |err| blk: {
            if (v2_state.requestedProtocolVersion() >= 2 and v2_state.uploadProtocolVersion() >= 2) {
                const fallback_ws = runPostFallback(allocator, cfg, stop_requested) catch |fallback_err| {
                    if (isStopRequested(stop_requested)) return;
                    try stdout.print("WebSocket POST fallback failed: {s}\n", .{@errorName(fallback_err)});
                    return fallback_err;
                };
                if (fallback_ws == null) return error.ShutdownRequested;
                break :blk fallback_ws.?;
            }
            if (isStopRequested(stop_requested)) return;
            try stdout.print("WebSocket connect failed: {s}\n", .{@errorName(err)});
            return err;
        };
        startDiscardReader(allocator, ws);
        var last_heartbeat = compat.unixTimestamp();
        var closed = false;

        while (!isStopRequested(stop_requested)) {
            const report_start_ms = compat.milliTimestamp();
            const now = compat.unixTimestamp();
            if (now - last_heartbeat >= 30) {
                ws.writePing() catch |err| {
                    try stdout.print("Failed to send heartbeat: {s}\n", .{@errorName(err)});
                    ws.close(allocator);
                    v2_state.resetConnectionProtocolVersion();
                    closed = true;
                    break;
                };
                last_heartbeat = now;
            }
            writeReportOnce(allocator, ws, cfg) catch |err| {
                try stdout.print("WebSocket write failed: {s}\n", .{@errorName(err)});
                ws.close(allocator);
                v2_state.resetConnectionProtocolVersion();
                closed = true;
                break;
            };
            const sleep_ms = remainingSleepMs(report_start_ms, reportIntervalMs(cfg.interval), compat.milliTimestamp());
            if (sleepOrStopMs(sleep_ms, stop_requested)) return;
        }
        if (!closed and isStopRequested(stop_requested)) return;
    }
}

fn isStopRequested(stop_requested: ?*const std.atomic.Value(bool)) bool {
    const ptr = stop_requested orelse return false;
    return ptr.load(.acquire);
}

fn sleepOrStop(seconds: u64, stop_requested: ?*const std.atomic.Value(bool)) bool {
    var slept: u64 = 0;
    while (slept < seconds) : (slept += 1) {
        if (isStopRequested(stop_requested)) return true;
        compat.sleep(std.time.ns_per_s);
    }
    return isStopRequested(stop_requested);
}

fn sleepOrStopMs(milliseconds: u64, stop_requested: ?*const std.atomic.Value(bool)) bool {
    var remaining = milliseconds;
    while (remaining > 0) {
        if (isStopRequested(stop_requested)) return true;
        const chunk: u64 = @min(remaining, @as(u64, 100));
        compat.sleep(chunk * @as(u64, std.time.ns_per_ms));
        remaining -= chunk;
    }
    return isStopRequested(stop_requested);
}

fn connectReportWs(allocator: std.mem.Allocator, cfg: config.Config) !*ws_client.Client {
    const protocol_version = v2_state.uploadProtocolVersion();
    const url = try http.reportWsUrlForProtocol(allocator, cfg.endpoint, cfg.token, protocol_version);
    defer allocator.free(url);
    const ws = ws_client.connect(allocator, url, cfg) catch |err| {
        const attempt = v2_state.noteV2AttemptResult(protocol_version, err);
        if (attempt.fallback) {
            const fallback_url = try http.reportWsUrlForProtocol(allocator, cfg.endpoint, cfg.token, 1);
            defer allocator.free(fallback_url);
            const fallback_ws = ws_client.connect(allocator, fallback_url, cfg) catch |fallback_err| {
                // Failed v1 fallback must not stick; next reconnect cycle prefers requested v2 again.
                applyV1FallbackConnectResult(false);
                return fallback_err;
            };
            applyV1FallbackConnectResult(true);
            return fallback_ws;
        }
        return err;
    };
    v2_state.setConnectionProtocolVersion(protocol_version);
    v2_state.resetV2ProtocolFailures(protocol_version);
    return ws;
}

fn runPostFallback(allocator: std.mem.Allocator, cfg: config.Config, stop_requested: ?*const std.atomic.Value(bool)) !?*ws_client.Client {
    const report_interval_ms = reportIntervalMs(cfg.interval);
    const reconnect_interval_ms = @as(u64, @intCast(reconnectSleepSeconds(cfg.reconnect_interval))) * std.time.ms_per_s;
    var last_report_ms = compat.milliTimestamp() - @as(i64, @intCast(report_interval_ms));
    var last_reconnect_ms = compat.milliTimestamp() - @as(i64, @intCast(reconnect_interval_ms));

    while (!isStopRequested(stop_requested)) {
        const now_ms = compat.milliTimestamp();
        if (@as(u64, @intCast(@max(now_ms - last_report_ms, 0))) >= report_interval_ms) {
            last_report_ms = now_ms;
            postV2ReportOnce(allocator, cfg) catch |err| {
                if (v2_state.noteV2AttemptResult(2, err).fallback) {
                    v2_state.setConnectionProtocolVersion(1);
                    return err;
                }
            };
        }
        if (@as(u64, @intCast(@max(now_ms - last_reconnect_ms, 0))) >= reconnect_interval_ms) {
            last_reconnect_ms = now_ms;
            const ws = connectReportWs(allocator, cfg) catch continue;
            return ws;
        }
        compat.sleep(100 * std.time.ns_per_ms);
    }
    return null;
}

fn connectReportWsWithRetries(allocator: std.mem.Allocator, cfg: config.Config, stop_requested: ?*const std.atomic.Value(bool)) !*ws_client.Client {
    // Prefer requested protocol on each reconnect cycle (clears sticky v1 after a dropped session).
    v2_state.resetConnectionProtocolVersion();
    var retry: i32 = 0;
    while (retry <= cfg.max_retries) : (retry += 1) {
        if (isStopRequested(stop_requested)) return error.ShutdownRequested;
        debug.log("report websocket connect attempt {d} to {s}", .{ retry + 1, cfg.endpoint });
        const ws = connectReportWs(allocator, cfg) catch |err| {
            debug.log("report websocket connect attempt {d} failed: {s}", .{ retry + 1, @errorName(err) });
            if (retry >= cfg.max_retries) return err;
            if (sleepOrStop(reconnectSleepSeconds(cfg.reconnect_interval), stop_requested)) return error.ShutdownRequested;
            continue;
        };
        v2_state.resetV2ProtocolFailures(v2_state.uploadProtocolVersion());
        debug.log("report websocket connected on attempt {d}", .{retry + 1});
        return ws;
    }
    return error.WebSocketHandshakeFailed;
}

fn startDiscardReader(allocator: std.mem.Allocator, conn: *ws_client.Client) void {
    conn.acquire();
    const thread = std.Thread.spawn(.{ .stack_size = thread_stacks.tls_worker_stack_size }, discardServerFrames, .{ allocator, conn }) catch {
        conn.release(allocator);
        return;
    };
    thread.detach();
}

fn discardServerFrames(allocator: std.mem.Allocator, conn: *ws_client.Client) void {
    defer conn.release(allocator);
    while (true) {
        {
            const frame = conn.readFrame(allocator) catch {
                conn.shutdown();
                return;
            };
            defer frame.deinit(conn, allocator);
            switch (frame.opcode) {
                0x8 => {
                    conn.shutdown();
                    return;
                },
                0x9 => conn.writeFrame(0xA, frame.payload) catch return,
                else => {},
            }
        }
    }
}

fn postV2ReportOnce(allocator: std.mem.Allocator, cfg: config.Config) !void {
    const snap = try provider.snapshotWithOptions(snapshotOptions(cfg));
    const payload = try report.allocReportJson(allocator, snap);
    defer allocator.free(payload);
    const request_id = try std.fmt.allocPrint(allocator, "report-{d}", .{compat.nanoTimestamp()});
    defer allocator.free(request_id);
    const request = try v2.allocReportRequest(allocator, request_id, payload);
    defer allocator.free(request);
    try postV2Request(allocator, cfg, request);
    v2_state.resetV2ProtocolFailures(2);
}

fn postV2Request(allocator: std.mem.Allocator, cfg: config.Config, payload: []const u8) !void {
    const body = try http.maybeGzip(allocator, payload, !cfg.disable_compression);
    defer allocator.free(body.body);
    var headers = http.Headers{};
    if (body.compressed) headers.content_encoding = "gzip";
    const url = try http.v2RpcUrl(allocator, cfg.endpoint, cfg.token);
    defer allocator.free(url);
    const response = try http.postJsonReadAuthHeaders(allocator, url, body.body, cfg, "", headers);
    allocator.free(response);
}
