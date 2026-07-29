const std = @import("std");

// std.once was deprecated (https://cookbook.ziglang.cc/07-04-run-once/) so we roll our own;
// and unlike the mutex-based std one this cant require an io cuz we have to once initialize an io
// in the ffi.
pub fn Once(comptime f: anytype) type {
    const Result = @typeInfo(@TypeOf(f)).@"fn".return_type.?;

    return struct {
        const Self = @This();

        const State = enum(u8) {
            uninitialized,
            initializing,
            initialized,
        };

        state: std.atomic.Value(State) = .init(.uninitialized),
        result: Result = undefined,

        pub fn call(self: *Self) Result {
            if (self.state.load(.acquire) == .initialized) {
                return self.result;
            }

            if (self.state.cmpxchgStrong(
                .uninitialized,
                .initializing,
                .acq_rel,
                .acquire,
            ) == null) {
                self.result = f();

                self.state.store(.initialized, .release);

                return self.result;
            }

            while (self.state.load(.acquire) != .initialized) {
                std.atomic.spinLoopHint();
            }

            return self.result;
        }
    };
}

var test_call_count: usize = 0;

fn testOnceFn() usize {
    test_call_count += 1;

    return test_call_count;
}

var test_once: Once(testOnceFn) = .{};

test "once" {
    try std.testing.expectEqual(@as(usize, 1), test_once.call());
    try std.testing.expectEqual(@as(usize, 1), test_once.call());
    try std.testing.expectEqual(@as(usize, 1), test_once.call());
    try std.testing.expectEqual(@as(usize, 1), test_call_count);
}
