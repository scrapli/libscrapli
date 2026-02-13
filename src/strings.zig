const std = @import("std");

pub const MaybeHeapString = struct {
    allocator: ?std.mem.Allocator,
    string: []const u8,

    /// Deinitialize the object, freeing the string if it was heap allocated.
    pub fn deinit(self: *MaybeHeapString) void {
        if (self.allocator == null) {
            return;
        }

        self.allocator.?.free(self.string);
    }
};
