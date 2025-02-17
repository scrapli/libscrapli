const std = @import("std");

pub const LookupPrefix = "__lookup::";

pub const LookupFn = ?*const fn (host: []const u8, port: u16, k: []const u8) ?[]const u8;

pub fn resolveValue(
    host: []const u8,
    port: u16,
    value_or_lookup_name: []const u8,
    lookup_fn: LookupFn,
) ![]const u8 {
    if (!std.mem.startsWith(u8, value_or_lookup_name, LookupPrefix)) {
        return value_or_lookup_name;
    }

    if (lookup_fn == null) {
        return error.LookupFailure;
    }

    const lookedup_value = lookup_fn.?(
        host,
        port,
        value_or_lookup_name[LookupPrefix.len..],
    );

    if (lookedup_value == null) {
        return error.LookupFailure;
    }

    return lookedup_value.?;
}
