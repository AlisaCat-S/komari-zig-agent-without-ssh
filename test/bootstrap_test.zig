const std = @import("std");
const version = @import("version");

test "default version is available without an update repository" {
    try std.testing.expectEqualStrings("0.0.1", version.current);
}
