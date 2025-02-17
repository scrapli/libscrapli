const std = @import("std");

pub fn parseCustomFlag(flag: []const u8, default: bool) bool {
    for (std.os.argv) |arg| {
        const arg_slice = std.mem.span(arg);

        if (std.mem.eql(u8, arg_slice, flag)) {
            return !default;
        }
    }

    return default;
}
