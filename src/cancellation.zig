const std = @import("std");

pub fn cancelled(cancel: ?*bool) bool {
    if (cancel) |c| {
        return @atomicLoad(bool, c, .monotonic);
    }

    return false;
}
