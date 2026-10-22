const std = @import("std");
const builtin = @import("builtin");

/// Decode errors from raw Linux syscalls independently of libc errno.
pub fn rawErrno(rc: usize) std.posix.E {
    return std.os.linux.errno(rc);
}

/// Close the DNS socket descriptor.
pub fn closeFd(fd: std.posix.fd_t) void {
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.close(fd);
    } else {
        _ = std.c.close(fd);
    }
}
