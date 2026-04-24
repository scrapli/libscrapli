// zlint-disable suppressed-errors
const std = @import("std");
const builtin = @import("builtin");

const c = @cImport(@cInclude("signal.h"));

const libscrapli_ffi_debug_mode_env_var = "LIBSCRAPLI_DEBUG";

/// The base debug allocator for ffi operations.
pub var da: std.heap.DebugAllocator(.{}) = .init;
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
var threaded: std.Io.Threaded = .init_single_threaded;

/// The base io object for ffi ops.
pub const io = threaded.io();

/// The handler to attached to segfault signals when in debug mode.
pub fn segfaultHandler(_: c_int) callconv(.c) void {
    std.debug.dumpCurrentStackTrace(
        .{
            .first_address = @returnAddress(),
        },
    );

    std.process.exit(1);
}
