const std = @import("std");
const runtime = @import("runtime");

const fs = @import("compat/fs.zig");
const process = @import("compat/process.zig");
const posix = @import("compat/posix.zig");
const sync = @import("compat/sync.zig");
const time = @import("compat/time.zig");
const format = @import("compat/format.zig");

/// Compatibility facade kept stable while internals move to Zig 0.16 modules.
pub const Mutex = sync.Mutex;

pub fn io() std.Io {
    return runtime.io();
}

pub fn emptyEnvMap(allocator: std.mem.Allocator) std.process.Environ.Map {
    return .init(allocator);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    return runtime.getEnvVarOwned(allocator, key);
}

pub const readFileAlloc = fs.readFileAlloc;
pub const selfExePathAlloc = fs.selfExePathAlloc;
pub const statFile = fs.statFile;
pub const openFile = fs.openFile;
pub const createFileAbsolute = fs.createFileAbsolute;
pub const openDir = fs.openDir;
pub const readLinkAbsolute = fs.readLinkAbsolute;
pub const FileWriter = fs.FileWriter;
pub const fileWriter = fs.fileWriter;
pub const readAll = fs.readAll;

/// Decode errno from a raw `std.os.linux.*` syscall return value.
/// `std.posix.errno` always reports `.SUCCESS` for those, because its `rc == -1`
/// test can never hold for a `usize`. See `compat/posix.zig` for the full story.
pub const rawErrno = posix.rawErrno;
pub const closeFd = posix.closeFd;

pub const RunOutputResult = process.RunOutputResult;
pub const runOutputIgnoreStderr = process.runOutputIgnoreStderr;
pub const runOutputWindows = process.runOutputWindows;

pub const sleep = time.sleep;
pub const unixTimestamp = time.unixTimestamp;
pub const milliTimestamp = time.milliTimestamp;
pub const nanoTimestamp = time.nanoTimestamp;

pub const appendPrint = format.appendPrint;
