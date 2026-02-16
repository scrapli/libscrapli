const std = @import("std");
const builtin = @import("builtin");

const logging = @import("logging.zig");

/// Holds scrapli specific errors. We try to be broad enough so as to not have a bunch of errors
/// that end up getting used in only one place.
pub const ScrapliError = error{
    // EOF is a special error that can help signal to the read loop(s) to shutdown
    EOF,

    // obviously for when an operation is cancelled or timeout is exceeded
    Cancelled,
    TimeoutExceeded,

    // all other errors that we generate come from these -- usually we return the actual
    // error that we hit but in some cases we have to create our own since otherwise we
    // just have a return code from libssh2 or pcre2 etc
    Driver,
    Session,
    Transport,
    Operation,
};

/// Wraps a critical error with additional logging info.
pub fn wrapCriticalError(
    err: anyerror,
    src: std.builtin.SourceLocation,
    log: ?logging.Logger,
    comptime format: []const u8,
    args: anytype,
) anyerror {
    if (log) |l| {
        l.trace(
            "{s}:{s}:{d}: encountered error '{any}'",
            .{
                src.file, src.fn_name, src.line, err,
            },
        );

        l.critical(format, args);
    }

    if (builtin.is_test) {
        std.debug.print(
            "critical: {s}:{s}:{d}: encountered error '{any}'\n",
            .{
                src.file, src.fn_name, src.line, err,
            },
        );
    }

    return err;
}

test "wrapCriticalErrorNullLog" {
    const e = error.Foo;

    wrapCriticalError(
        e,
        @src(),
        null,
        "a message about '{s}'",
        .{"foo"},
    ) catch {};
}

test "wrapCriticalErrorLog" {
    const e = error.Foo;
    const l = logging.Logger{
        .allocator = std.testing.allocator,
    };

    wrapCriticalError(
        e,
        @src(),
        l,
        "a message about '{s}'",
        .{"foo"},
    ) catch {};
}

/// Wraps a warn error with additional logging info.
pub fn wrapWarnError(
    err: anyerror,
    src: std.builtin.SourceLocation,
    log: ?logging.Logger,
    comptime format: []const u8,
    args: anytype,
) anyerror {
    if (log) |l| {
        l.trace(
            "{s}:{s}:{d}: encountered error '{any}'",
            .{
                src.file, src.fn_name, src.line, err,
            },
        );

        l.warn(format, args);
    }

    if (builtin.is_test) {
        std.debug.print(
            "warn: {s}:{s}:{d}: encountered error '{any}'\n",
            .{
                src.file, src.fn_name, src.line, err,
            },
        );
    }

    return err;
}
