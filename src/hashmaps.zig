const std = @import("std");

/// Conveneince function to initalize a string hashmap with the given keys and items.
pub fn inlineInitStringHashMap(
    allocator: std.mem.Allocator,
    comptime T: type,
    keys: []const []const u8,
    items: []const T,
) !std.StringHashMap(T) {
    var hm = std.StringHashMap(T).init(allocator);

    if (keys.len != items.len) {
        return error.InitError;
    }

    for (0.., keys) |idx, key| {
        try hm.put(key, items[idx]);
    }

    return hm;
}
