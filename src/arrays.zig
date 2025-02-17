const std = @import("std");

pub fn inlineInitArrayList(
    allocator: std.mem.Allocator,
    comptime T: type,
    items: []const T,
) !std.ArrayList(T) {
    var al = std.ArrayList(T).init(allocator);

    for (items) |item| {
        try al.append(item);
    }

    return al;
}
