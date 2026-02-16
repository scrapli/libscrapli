const std = @import("std");

/// Simple struct that optionally holds an allocator, when it does we assume that the string value
/// was heap allocated and as such we can know we need to deallocate it.
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
