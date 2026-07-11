const std = @import("std");

/// JSON-RPC helpers for one-way monitoring uploads.
pub const Version = "2.0";
pub const MethodAgentReport = "agent.report";
pub const MethodAgentBasicInfo = "agent.basicInfo";

pub fn writeNotification(writer: anytype, method: []const u8, params_json: []const u8) !void {
    try writer.print("{{\"jsonrpc\":\"{s}\",\"method\":{f}", .{ Version, std.json.fmt(method, .{}) });
    if (params_json.len != 0) try writer.print(",\"params\":{s}", .{params_json});
    try writer.writeAll("}");
}

pub fn writeRequest(writer: anytype, id: []const u8, method: []const u8, params_json: []const u8) !void {
    try writer.print("{{\"jsonrpc\":\"{s}\",\"method\":{f}", .{ Version, std.json.fmt(method, .{}) });
    if (params_json.len != 0) try writer.print(",\"params\":{s}", .{params_json});
    try writer.print(",\"id\":{f}}}", .{std.json.fmt(id, .{})});
}

pub fn allocReportNotification(allocator: std.mem.Allocator, report_json: []const u8) ![]u8 {
    var params = std.Io.Writer.Allocating.init(allocator);
    defer params.deinit();
    try params.writer.print("{{\"report\":{s}}}", .{report_json});

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeNotification(&out.writer, MethodAgentReport, params.writer.buffered());
    return out.toOwnedSlice();
}

pub fn allocReportRequest(allocator: std.mem.Allocator, id: []const u8, report_json: []const u8) ![]u8 {
    var params = std.Io.Writer.Allocating.init(allocator);
    defer params.deinit();
    try params.writer.print("{{\"report\":{s},\"ack_event_ids\":[]}}", .{report_json});

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeRequest(&out.writer, id, MethodAgentReport, params.writer.buffered());
    return out.toOwnedSlice();
}

pub fn allocBasicInfoNotification(allocator: std.mem.Allocator, info_json: []const u8) ![]u8 {
    var params = std.Io.Writer.Allocating.init(allocator);
    defer params.deinit();
    try params.writer.print("{{\"info\":{s}}}", .{info_json});

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeNotification(&out.writer, MethodAgentBasicInfo, params.writer.buffered());
    return out.toOwnedSlice();
}
