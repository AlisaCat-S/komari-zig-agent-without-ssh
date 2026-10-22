const std = @import("std");
const version = @import("../version.zig");
const types = @import("types.zig");
const http = @import("http.zig");
const common = @import("../platform/common.zig");
const v2 = @import("v2.zig");
const v2_state = @import("v2_state.zig");

/// BasicInfo payload serialization and upload helpers.
pub const BasicInfo = common.BasicInfo;

pub fn allocBasicInfoJson(allocator: std.mem.Allocator, info: common.BasicInfo, include_kernel: bool, include_physical_cores: bool) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try types.writeBasicInfoJson(&out.writer, .{
        .cpu_name = info.cpu.name,
        .cpu_cores = info.cpu.cores,
        .cpu_physical_cores = info.cpu.physical_cores,
        .arch = info.cpu.architecture,
        .os = info.os_name,
        .kernel_version = info.kernel_version,
        .ipv4 = info.ipv4,
        .ipv6 = info.ipv6,
        .mem_total = info.mem_total,
        .swap_total = info.swap_total,
        .disk_total = info.disk_total,
        .gpu_name = info.gpu_name,
        .virtualization = info.virtualization,
        .version = version.current,
    }, include_kernel, include_physical_cores);
    return out.toOwnedSlice();
}

pub fn upload(allocator: std.mem.Allocator, cfg: anytype, info: common.BasicInfo) !void {
    const protocol_version = v2_state.uploadProtocolVersion();
    if (protocol_version >= 2) {
        try uploadV2(allocator, cfg, info, true);
        return;
    }

    try uploadV1(allocator, cfg, info);
}

pub fn initRequestedProtocolVersionForTest(protocol_version: i32) void {
    v2_state.initRequestedProtocolVersion(protocol_version);
}

pub fn resetConnectionProtocolVersionForTest() void {
    v2_state.resetConnectionProtocolVersion();
}

pub fn uploadProtocolVersionForTest() i32 {
    return v2_state.uploadProtocolVersion();
}

pub fn uploadV1(allocator: std.mem.Allocator, cfg: anytype, info: common.BasicInfo) !void {
    const url = try http.basicInfoUrl(allocator, cfg.endpoint, cfg.token);
    defer allocator.free(url);
    const payload = try allocBasicInfoJson(allocator, info, true, true);
    defer allocator.free(payload);
    http.postJson(allocator, url, payload, cfg) catch {
        const fallback = try allocBasicInfoJson(allocator, info, false, false);
        defer allocator.free(fallback);
        try http.postJson(allocator, url, fallback, cfg);
    };
}

pub fn uploadV2(allocator: std.mem.Allocator, cfg: anytype, info: common.BasicInfo, include_physical_cores: bool) !void {
    const url = try http.v2RpcUrl(allocator, cfg.endpoint, cfg.token);
    defer allocator.free(url);
    const payload = try allocBasicInfoJson(allocator, info, true, include_physical_cores);
    defer allocator.free(payload);
    const rpc = try v2.allocBasicInfoNotification(allocator, payload);
    defer allocator.free(rpc);
    const body = try maybeCompress(allocator, rpc, cfg);
    defer allocator.free(body.body);
    var headers = http.Headers{};
    if (body.compressed) headers.content_encoding = "gzip";
    const response = http.postJsonReadAuthHeaders(allocator, url, body.body, cfg, "", headers) catch |err| {
        const attempt = v2_state.noteV2AttemptResult(2, err);
        if (attempt.fallback) {
            v2_state.setConnectionProtocolVersion(1);
            try uploadV1(allocator, cfg, info);
            return;
        }
        return err;
    };
    defer allocator.free(response);
    v2.validateUploadResponse(allocator, response) catch |err| {
        try handleV2UploadFailure(allocator, cfg, info, err);
        return;
    };
    v2_state.resetV2ProtocolFailures(2);
}

const GzipBody = struct {
    body: []u8,
    compressed: bool,
};

fn maybeCompress(allocator: std.mem.Allocator, payload: []const u8, cfg: anytype) !GzipBody {
    const result = try http.maybeGzip(allocator, payload, !cfg.disable_compression);
    return .{ .body = result.body, .compressed = result.compressed };
}

fn handleV2UploadFailure(allocator: std.mem.Allocator, cfg: anytype, info: common.BasicInfo, err: anyerror) !void {
    const attempt = v2_state.noteV2AttemptResult(2, err);
    if (attempt.fallback) {
        v2_state.setConnectionProtocolVersion(1);
        try uploadV1(allocator, cfg, info);
        return;
    }
    return err;
}
