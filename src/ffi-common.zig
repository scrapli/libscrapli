// zlint-disable suppressed-errors
const std = @import("std");
const builtin = @import("builtin");

const c = @import("c");

const errors = @import("errors.zig");

const libscrapli_ffi_debug_mode_env_var = "LIBSCRAPLI_DEBUG";

/// The base debug allocator for ffi operations.
// zlinter-disable no_global_vars
pub var da = std.heap.SafeAllocator.init(std.heap.page_allocator, .{});
const debug_allocator = da.allocator();

/// Returns true if built w/ debug optimizations or the `libscrapli_ffi_debug_mode_env_var` is not
/// empty.
pub fn isDebugMode() bool {
    if (builtin.mode == .Debug) {
        return true;
    }

    return std.c.getenv(libscrapli_ffi_debug_mode_env_var) != null;
}

/// Returns the allocator for use in ffi mode.
pub fn getAllocator() std.mem.Allocator {
    if (isDebugMode()) {
        return debug_allocator;
    } else {
        return std.heap.c_allocator;
    }
}

// this may need to be revisited, but doing it this way there is no requirement for
// deinit to free anything so this seems safest/most ideal for the ffi side of things
// zlinter-disable no_global_vars
var threaded: std.Io.Threaded = .init_single_threaded;

/// The base io object for ffi ops.
pub const io = threaded.io();

/// Opaque types for use in ffi handles.
pub const LsOptions = opaque {};
/// Opaque types for use in ffi handles.
pub const LsDriver = opaque {};

// zlinter-disable no_global_vars
var segfault_handler_registered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// The handler to attached to segfault signals when in debug mode.
pub fn segfaultHandler(_: c_int) callconv(.c) void {
    std.debug.dumpCurrentStackTrace(
        .{
            .first_address = @returnAddress(),
        },
    );

    std.process.exit(1);
}

/// Registers the segfault handler if in debug mode and not already registered.
pub fn registerSegfaultHandler() void {
    if (!isDebugMode()) {
        return;
    }

    if (segfault_handler_registered.swap(true, .acquire)) {
        return;
    }

    _ = c.signal(c.SIGSEGV, segfaultHandler);
}

/// Represents stable error codes for FFI consumers.
pub const FfiResult = enum(u8) {
    success = 0,
    unknown = 1,
    out_of_memory = 2,
    eof = 3,
    cancelled = 4,
    timeout = 5,
    driver = 6,
    session = 7,
    transport = 8,
    operation = 9,
    invalid_argument = 10,
};

/// Maps a Zig error to a stable FFI result code.
pub fn toFfiResult(err: anyerror) u8 {
    const out = switch (err) {
        error.OutOfMemory => FfiResult.out_of_memory,
        errors.ScrapliError.EOF => FfiResult.eof,
        errors.ScrapliError.Cancelled => FfiResult.cancelled,
        errors.ScrapliError.TimeoutExceeded => FfiResult.timeout,
        errors.ScrapliError.Driver => FfiResult.driver,
        errors.ScrapliError.Session => FfiResult.session,
        errors.ScrapliError.Transport => FfiResult.transport,
        errors.ScrapliError.Operation => FfiResult.operation,
        else => FfiResult.unknown,
    };

    return @intFromEnum(out);
}
