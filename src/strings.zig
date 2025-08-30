const std = @import("std");

pub const MaybeHeapString = struct {
    allocator: ?std.mem.Allocator,
    string: []const u8,

    pub fn deinit(self: *MaybeHeapString) void {
        if (self.allocator == null) {
            return;
        }

        self.allocator.?.free(self.string);
    }
};

pub fn allocPrintZ(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) ![:0]u8 {
    const result = try std.fmt.allocPrint(allocator, fmt ++ "\x00", args);
    return result[0 .. result.len - 1 :0];
}
