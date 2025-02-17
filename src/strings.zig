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
