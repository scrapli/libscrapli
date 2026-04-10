// zlint-disable suppressed-errors
const std = @import("std");
const builtin = @import("builtin");

const errors = @import("errors.zig");
const ffi_driver = @import("ffi-driver.zig");
const ffi_options = @import("ffi-options.zig");
const ffi_root_cli = @import("ffi-root-cli.zig");
const ffi_root_netconf = @import("ffi-root-netconf.zig");

const c = @cImport(@cInclude("signal.h"));

/// Setting std options mostly for quieting yaml logger things.
pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{
            .scope = .yaml,
            .level = .err,
        },
        .{
            .scope = .tokenizer,
            .level = .err,
        },
        .{
            .scope = .parser,
            .level = .err,
        },
    },
};

const libscrapli_ffi_debug_mode_env_var = "LIBSCRAPLI_DEBUG";
pub var da: std.heap.DebugAllocator(.{}) = .init;
const debug_allocator = da.allocator();

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
pub const io = threaded.io();

pub fn segfaultHandler(_: c_int) callconv(.c) void {
    std.debug.dumpCurrentStackTrace(
        .{
            .first_address = @returnAddress(),
        },
    );

    std.process.exit(1);
}
