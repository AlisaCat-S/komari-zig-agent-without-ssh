//! DSM-authenticated, package-user-only configuration API. No network listener.
const std = @import("std");
const compat = @import("compat");
const runtime = @import("runtime");
const options = @import("dsm_options");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/file.h");
    @cInclude("sys/stat.h");
});
const root = options.root;
const config_path = root ++ "/var/config.json";
const control_path = root ++ "/scripts/start-stop-status";
const auth_path = options.auth;
const id_path = options.id;
const max_config = 1024 * 1024;

pub fn main(init: std.process.Init.Minimal) !void {
    runtime.init(init);
    _ = c.umask(0o077);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    handle(arena.allocator()) catch |err| {
        const code: u16 = switch (err) {
            error.Unauthorized => 401,
            error.Forbidden, error.CrossOrigin => 403,
            error.InvalidInput, error.InvalidLength, error.UnsupportedField => 400,
            error.Conflict => 409,
            error.MethodNotAllowed => 405,
            else => 500,
        };
        const message: []const u8 = switch (err) {
            error.Unauthorized => "请先登录 DSM，再从主菜单打开应用。",
            error.Forbidden => "仅 DSM 管理员可以访问此应用。",
            error.CrossOrigin => "请求来源校验失败，请从 DSM 重新打开应用。",
            error.Conflict => "配置已被其他页面修改，请重新加载后再保存。",
            error.InvalidInput, error.InvalidLength, error.UnsupportedField => "配置格式不正确，请检查地址、间隔和其他字段。",
            error.RestartFailedRestored => "新配置启动失败，已恢复原配置。请检查套件日志。",
            error.RecoveryFailed => "保存或重启失败，原配置备份在 var/config.json.previous；请在套件中心检查服务。",
            else => "操作失败，请检查套件权限和日志。",
        };
        try respond(arena.allocator(), code, .{ .ok = false, .message = message });
    };
}

fn env(a: std.mem.Allocator, key: []const u8) []const u8 {
    return compat.getEnvVarOwned(a, key) catch "";
}

fn success(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn authorize(a: std.mem.Allocator) !void {
    const token = env(a, "HTTP_X_SYNO_TOKEN");
    if (token.len == 0 or token.len > 256) return error.Unauthorized;
    for (token) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return error.Unauthorized;
    var auth_env = compat.emptyEnvMap(a);
    try auth_env.put("PATH", "/usr/bin:/bin:/usr/syno/bin");
    for ([_][]const u8{ "HTTP_COOKIE", "REMOTE_ADDR", "SERVER_ADDR", "SERVER_PORT", "HTTP_HOST", "HTTPS" }) |key| {
        const value = env(a, key);
        if (value.len > 16384) return error.Unauthorized;
        try auth_env.put(key, value);
    }
    try auth_env.put("HTTP_X_SYNO_TOKEN", token);
    try auth_env.put("QUERY_STRING", try std.fmt.allocPrint(a, "SynoToken={s}", .{token}));
    try auth_env.put("REQUEST_METHOD", "GET");
    const auth = compat.runOutputIgnoreStderr(a, &.{auth_path}, &auth_env, 512) catch return error.Unauthorized;
    const username = std.mem.trim(u8, auth.stdout, " \t\r\n");
    if (!success(auth.term) or username.len == 0 or username[0] == '-' or std.mem.indexOfScalar(u8, username, 0) != null) return error.Unauthorized;
    var clean_env = compat.emptyEnvMap(a);
    try clean_env.put("PATH", "/usr/bin:/bin");
    const groups = compat.runOutputIgnoreStderr(a, &.{ id_path, "-Gn", username }, &clean_env, 8192) catch return error.Forbidden;
    if (!success(groups.term)) return error.Forbidden;
    var names = std.mem.tokenizeAny(u8, groups.stdout, " \t\r\n");
    while (names.next()) |name| {
        if (std.mem.eql(u8, name, "administrators")) {
            // Preserve package identity when a shell is spawned from this setuid-package CGI.
            const uid = c.geteuid();
            if (uid == 0 or c.setresuid(uid, uid, uid) != 0) return error.Forbidden;
            return;
        }
    }
    return error.Forbidden;
}

fn handle(a: std.mem.Allocator) !void {
    try authorize(a);
    const method = env(a, "REQUEST_METHOD");
    if (std.mem.eql(u8, method, "GET")) {
        try status(a);
    } else if (std.mem.eql(u8, method, "POST")) {
        const origin = env(a, "HTTP_ORIGIN");
        const host = env(a, "HTTP_HOST");
        if (host.len == 0 or (!std.mem.eql(u8, origin, try std.fmt.allocPrint(a, "https://{s}", .{host})) and
            !std.mem.eql(u8, origin, try std.fmt.allocPrint(a, "http://{s}", .{host})))) return error.CrossOrigin;
        if (!std.mem.eql(u8, env(a, "HTTP_X_KOMARI_REQUEST"), "1")) return error.CrossOrigin;
        if (!std.mem.eql(u8, env(a, "CONTENT_TYPE"), "application/json")) return error.InvalidInput;
        const length = std.fmt.parseInt(usize, env(a, "CONTENT_LENGTH"), 10) catch return error.InvalidLength;
        if (length == 0 or length > 16384) return error.InvalidLength;
        const body = try a.alloc(u8, length);
        if (try compat.readAll(std.Io.File.stdin(), body) != length) return error.InvalidLength;
        const parsed = std.json.parseFromSlice(std.json.Value, a, body, .{ .allocate = .alloc_always }) catch return error.InvalidInput;
        if (parsed.value != .object) return error.InvalidInput;
        try saveConfig(a, parsed.value.object);
    } else return error.MethodNotAllowed;
}

fn readConfig(a: std.mem.Allocator) !std.json.Value {
    const bytes = try compat.readFileAlloc(a, config_path, max_config);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
    if (parsed.value != .object) return error.InvalidInput;
    return parsed.value;
}

fn revision(a: std.mem.Allocator) ![]const u8 {
    const stat = try compat.statFile(config_path);
    return std.fmt.allocPrint(a, "{d}:{d}:{d}", .{ stat.inode, stat.size, stat.mtime.toNanoseconds() });
}

fn service(a: std.mem.Allocator, action: []const u8) !bool {
    var service_env = compat.emptyEnvMap(a);
    try service_env.put("PATH", "/usr/sbin:/usr/bin:/sbin:/bin:/usr/syno/bin");
    try service_env.put("SYNOPKG_PKGDEST", root ++ "/target");
    try service_env.put("SYNOPKG_PKGVAR", root ++ "/var");
    try service_env.put("SYNOPKG_PKGTMP", root ++ "/tmp");
    const result = try compat.runOutputIgnoreStderr(a, &.{ "/bin/sh", control_path, action }, &service_env, 8192);
    return success(result.term);
}

fn status(a: std.mem.Allocator) !void {
    const lock = try lockConfig();
    defer _ = c.close(lock);
    const cfg = try readConfig(a);
    var public: std.json.ObjectMap = .{};
    for ([_][]const u8{ "endpoint", "interval", "protocol_version", "include_nics", "exclude_nics", "include_mountpoints" }) |key| {
        if (cfg.object.get(key)) |value| try public.put(a, key, value);
    }
    const token = cfg.object.get("token");
    var telemetry: std.json.Value = .null;
    if (compat.readFileAlloc(a, root ++ "/tmp/status.json", 8192)) |bytes| {
        if (std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always })) |parsed| {
            telemetry = parsed.value;
        } else |_| {}
    } else |_| {}
    try respond(a, 200, .{
        .ok = true,
        .running = try service(a, "status"),
        .config = std.json.Value{ .object = public },
        .token_configured = token != null and token.? == .string and token.?.string.len != 0,
        .revision = try revision(a),
        .telemetry = telemetry,
    });
}

fn string(value: std.json.Value, limit: usize) ![]const u8 {
    if (value != .string or value.string.len > limit or std.mem.indexOfScalar(u8, value.string, 0) != null) return error.InvalidInput;
    return value.string;
}

fn saveConfig(a: std.mem.Allocator, updates: std.json.ObjectMap) !void {
    // One writer across CGI requests. Lifecycle scripts are still controlled by DSM.
    const lock = try lockConfig();
    defer _ = c.close(lock);
    const requested = updates.get("revision") orelse return error.InvalidInput;
    if (!std.mem.eql(u8, try string(requested, 128), try revision(a))) return error.Conflict;
    var cfg = try readConfig(a);
    var it = updates.iterator();
    while (it.next()) |item| {
        const key = item.key_ptr.*;
        const value = item.value_ptr.*;
        if (std.mem.eql(u8, key, "revision")) continue;
        if (std.mem.eql(u8, key, "endpoint")) {
            const url = try string(value, 2048);
            const uri = std.Uri.parse(url) catch return error.InvalidInput;
            if ((!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) or uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidInput;
            for (url) |ch| if (ch <= 32 or ch == 127) return error.InvalidInput;
        } else if (std.mem.eql(u8, key, "token")) {
            if ((try string(value, 4096)).len == 0) continue; // blank means unchanged
            try cfg.object.put(a, "auto_discovery_key", .{ .string = "" });
        } else if (std.mem.eql(u8, key, "interval")) {
            const n: f64 = switch (value) {
                .integer => @floatFromInt(value.integer),
                .float => value.float,
                else => return error.InvalidInput,
            };
            if (!std.math.isFinite(n) or n <= 0 or n > 86400) return error.InvalidInput;
        } else if (std.mem.eql(u8, key, "protocol_version")) {
            if (value != .integer or (value.integer != 1 and value.integer != 2)) return error.InvalidInput;
        } else if (std.mem.eql(u8, key, "include_nics") or std.mem.eql(u8, key, "exclude_nics") or std.mem.eql(u8, key, "include_mountpoints")) {
            _ = try string(value, 2048);
        } else return error.UnsupportedField;
        try cfg.object.put(a, key, value);
    }
    const old = try compat.readFileAlloc(a, config_path, max_config);
    const next = try std.json.Stringify.valueAlloc(a, cfg, .{ .whitespace = .indent_2 });
    const was_running = try service(a, "status");
    try atomicWrite(root ++ "/var/config.json.previous", root ++ "/var/config.previous.new", old);
    if (was_running and !try service(a, "stop")) return error.StopFailed;
    atomicWrite(config_path, root ++ "/var/config.ui.new", next) catch |err| {
        if (was_running and !try service(a, "start")) return error.RecoveryFailed;
        return err;
    };
    if (was_running and !try service(a, "start")) {
        try atomicWrite(config_path, root ++ "/var/config.ui.new", old);
        if (!try service(a, "start")) return error.RecoveryFailed;
        return error.RestartFailedRestored;
    }
    try respond(a, 200, .{ .ok = true, .restarted = was_running, .revision = try revision(a) });
}

fn lockConfig() !c_int {
    const fd = c.open(root ++ "/var/ui.lock", c.O_CREAT | c.O_RDWR | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.ConfigUnavailable;
    errdefer _ = c.close(fd);
    if (c.flock(fd, c.LOCK_EX) != 0) return error.ConfigUnavailable;
    return fd;
}

fn atomicWrite(path: []const u8, tmp: []const u8, bytes: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    try dir.writeFile(compat.io(), .{ .sub_path = tmp, .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
    try dir.rename(tmp, dir, path, compat.io());
}

fn respond(a: std.mem.Allocator, code: u16, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    var buffer: [4096]u8 = undefined;
    var out = compat.fileWriter(std.Io.File.stdout(), &buffer);
    try out.print("Status: {d}\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n{s}", .{ code, bytes });
    try out.flush();
}
