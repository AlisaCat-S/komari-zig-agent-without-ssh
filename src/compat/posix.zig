const std = @import("std");
const builtin = @import("builtin");

/// Minimal POSIX wrapper retained for the DNS socket lifecycle.
pub fn closeFd(fd: std.posix.fd_t) void {
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.close(fd);
    } else {
        _ = std.c.close(fd);
    }
}
