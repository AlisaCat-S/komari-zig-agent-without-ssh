//! Regression tests for errno decoding of raw Linux syscalls.
//!
//! Background: with libc linked (musl and glibc, i.e. every Linux build target)
//! `std.posix.errno` resolves to `std/c.zig`'s implementation
//! `return if (rc == -1) @enumFromInt(_errno().*) else .SUCCESS;`.
//! Raw `std.os.linux.*` syscalls return `usize`, and Zig cannot coerce the comptime
//! literal `-1` into `usize`, so `rc == -1` is constantly false and
//! `std.posix.errno` reports `.SUCCESS` for *every* raw syscall return value,
//! success or failure alike. Callers then `@intCast` the raw `0xFFFF...FF` into a
//! `fd`, silently getting `-1`.
//!
//! Real-world consequence: inside a container without `CAP_NET_RAW`,
//! `socket(SOCK_RAW, IPPROTO_ICMP)` fails with EPERM but was reported as success
//! with `fd = -1`, so the ICMP raw鈫抎atagram fallback in `ping.zig` never ran, every
//! latency sample came back as -1, and the panel's latency chart stayed blank
//! (the frontend maps negative values to `null`).
//!
//! The tests below are deterministic and do not depend on ambient thread-local
//! errno state.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");

// `rawErrno` must decode a failing raw syscall return value, which is exactly the
// case `std.posix.errno` gets wrong on musl/glibc.
test "rawErrno decodes -1 as an error, unlike std.posix.errno" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const rc: usize = @bitCast(@as(isize, -1));

    // The correct answer: -1 means the syscall failed, with errno 1 (EPERM).
    try std.testing.expectEqual(std.posix.E.PERM, compat.rawErrno(rc));

    // A success return must stay SUCCESS, and must not be mistaken for an error.
    try std.testing.expectEqual(std.posix.E.SUCCESS, compat.rawErrno(0));
    try std.testing.expectEqual(std.posix.E.SUCCESS, compat.rawErrno(3));

    // Values outside the syscall error range (-4096, 0) are success, not errors.
    try std.testing.expectEqual(std.posix.E.SUCCESS, compat.rawErrno(@bitCast(@as(isize, -4097))));
}

// Pin the root cause itself. With libc linked, `std.posix.errno` is
// `if (rc == -1) ... else .SUCCESS`, and because `rc` is a `usize` that comparison
// can never be true. This is what made every raw syscall failure look like success,
// and it is the reason `rawErrno` exists. If a future Zig release ever makes
// `std.posix.errno` work for `usize`, this test will fail and the helper can be
// dropped in favour of the std function.
test "std.posix.errno cannot detect failure in a usize syscall return" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!builtin.link_libc) return error.SkipZigTest;

    // The mechanism is `rc == -1` being constantly false for a `usize`, so libc's
    // thread-local errno is never even consulted. Poison it anyway so that this test
    // also fails if a future implementation starts reading it and happens to agree
    // with the broken result by accident.
    std.c._errno().* = 4242;

    const failed: usize = @bitCast(@as(isize, -1));
    // Assert the current (broken) behaviour deliberately: if a future Zig release
    // ever makes `std.posix.errno` work for `usize`, this fails loudly and the
    // `rawErrno` helper can be dropped in favour of the std function.
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(failed));

    // The helper decodes the return value itself and must be immune to that.
    try std.testing.expectEqual(std.posix.E.PERM, compat.rawErrno(failed));
}
