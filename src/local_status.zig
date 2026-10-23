//! Optional local telemetry for appliance UIs. No listener, credentials, or remote control.
const std = @import("std");
const compat = @import("compat");

pub const Snapshot = struct {
    started_at: i64 = 0,
    updated_at: i64 = 0,
    connection: []const u8 = "starting",
    transport: []const u8 = "none",
    protocol_version: i32 = 0,
    reports_sent: u64 = 0,
    http_reports_confirmed: u64 = 0,
    last_report_sent_at: i64 = 0,
    last_http_confirmed_at: i64 = 0,
    basic_info_confirmed_at: i64 = 0,
    last_error: []const u8 = "",
};

var mutex: compat.Mutex = .{};
var file_path: ?[]const u8 = null;
var snapshot: Snapshot = .{};

pub fn init() void {
    const path = compat.getEnvVarOwned(std.heap.page_allocator, "KOMARI_STATUS_FILE") catch return;
    if (path.len == 0) return;
    file_path = path;
    snapshot.started_at = compat.unixTimestamp();
    save();
}

pub fn connection(state: []const u8, transport: []const u8, protocol: i32) void {
    if (file_path == null) return;
    mutex.lock();
    defer mutex.unlock();
    snapshot.connection = state;
    snapshot.transport = transport;
    snapshot.protocol_version = protocol;
    save();
}

pub fn failure(err: anyerror) void {
    if (file_path == null) return;
    mutex.lock();
    defer mutex.unlock();
    snapshot.last_error = @errorName(err); // never include URLs, tokens, or server-controlled text
    snapshot.connection = "reconnecting";
    save();
}

pub fn sent(http_confirmed: bool) void {
    if (file_path == null) return;
    mutex.lock();
    defer mutex.unlock();
    snapshot.reports_sent += 1;
    snapshot.last_report_sent_at = compat.unixTimestamp();
    snapshot.connection = "connected";
    snapshot.last_error = "";
    if (http_confirmed) {
        snapshot.http_reports_confirmed += 1;
        snapshot.last_http_confirmed_at = snapshot.last_report_sent_at;
    }
    save();
}

pub fn basicInfoConfirmed() void {
    if (file_path == null) return;
    mutex.lock();
    defer mutex.unlock();
    snapshot.basic_info_confirmed_at = compat.unixTimestamp();
    save();
}

fn save() void {
    const path = file_path orelse return;
    snapshot.updated_at = compat.unixTimestamp();
    saveTo(path) catch |err| std.log.warn("local status unavailable: {s}", .{@errorName(err)});
}

fn saveTo(path: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const bytes = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(bytes);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.new", .{path});
    defer allocator.free(tmp);
    const dir = std.Io.Dir.cwd();
    const permissions: std.Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600);
    try dir.writeFile(compat.io(), .{ .sub_path = tmp, .data = bytes, .flags = .{ .permissions = permissions } });
    try dir.rename(tmp, dir, path, compat.io());
}
