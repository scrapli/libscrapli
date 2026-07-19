const std = @import("std");

/// Conveneince function to initalize a string hashmap with the given keys and items.
pub fn inlineInitStringHashMap(
    allocator: std.mem.Allocator,
    T: type,
    keys: []const []const u8,
    items: []const T,
) !std.StringHashMapUnmanaged(T) {
    var hm: std.StringHashMapUnmanaged(T) = .empty;
    errdefer hm.deinit(allocator);

    if (keys.len != items.len) {
        return error.InitError;
    }

    for (0.., keys) |idx, key| {
        try hm.put(allocator, key, items[idx]);
    }

    return hm;
}
