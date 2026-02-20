// zlint-disable suppressed-errors
const std = @import("std");
const builtin = @import("builtin");

const errors = @import("errors.zig");
const ffi_driver = @import("ffi-driver.zig");
const ffi_options = @import("ffi-options.zig");
const ffi_root_cli = @import("ffi-root-cli.zig");
const ffi_root_netconf = @import("ffi-root-netconf.zig");

const c = @cImport(@cInclude("signal.h"));

// zlinter-disable require_doc_comment
pub export const _ls_force_include_root_cli = &ffi_root_cli.noop;
pub export const _ls_force_include_root_netconf = &ffi_root_netconf.noop;
// zlinter-enable require_doc_comment

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
var da: std.heap.DebugAllocator(.{}) = .init;
const debug_allocator = da.allocator();

fn isDebugMode() bool {
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
const io = threaded.io();

fn segfaultHandler(_: c_int) callconv(.c) void {
    std.debug.dumpCurrentStackTrace(
        .{
            .first_address = @returnAddress(),
        },
    );

    std.process.exit(1);
}

// all exported functions are named using c standard and prepended with "ls" for libscrapli for
// namespacing reasons.
export fn ls_assert_no_leaks() callconv(.c) bool {
    if (!isDebugMode()) {
        return true;
    }

    switch (da.deinit()) {
        .leak => return false,
        .ok => return true,
    }
}

export fn ls_alloc_driver_options() callconv(.c) usize {
    const allocator = getAllocator();

    const o = allocator.create(ffi_options.FFIOptions) catch {
        return 0;
    };

    o.* = ffi_options.FFIOptions{
        .cli = .{},
        .netconf = .{},
        .session = .{},
        .auth = .{
            .lookups = .{},
        },
        .transport = .{
            .bin = .{},
            .ssh2 = .{},
            .test_ = .{},
        },
    };

    return @intFromPtr(o);
}

export fn ls_free_driver_options(options_ptr: usize) callconv(.c) void {
    const allocator = getAllocator();

    const o: *ffi_options.FFIOptions = @ptrFromInt(options_ptr);

    defer allocator.destroy(o);
}

export fn ls_cli_alloc(
    host: [*c]const u8,
    options_ptr: usize,
) callconv(.c) usize {
    if (isDebugMode()) {
        _ = c.signal(c.SIGSEGV, segfaultHandler);
    }

    const allocator = getAllocator();

    const o: *ffi_options.FFIOptions = @ptrFromInt(options_ptr);

    const d = ffi_driver.FfiDriver.init(
        allocator,
        io,
        std.mem.span(host),
        o.cliConfig(allocator),
    ) catch {
        return 0;
    };

    return @intFromPtr(d);
}

export fn ls_netconf_alloc(
    host: [*c]const u8,
    options_ptr: usize,
) callconv(.c) usize {
    if (isDebugMode()) {
        _ = c.signal(c.SIGSEGV, segfaultHandler);
    }

    const allocator = getAllocator();

    const o: *ffi_options.FFIOptions = @ptrFromInt(options_ptr);

    const d = ffi_driver.FfiDriver.initNetconf(
        getAllocator(),
        io,
        std.mem.span(host),
        o.*.netconfConfig(allocator),
    ) catch {
        return 0;
    };

    return @intFromPtr(d);
}

export fn ls_shared_get_poll_fd(
    d_ptr: usize,
) callconv(.c) u32 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    return @intCast(d.poll_fds[0]);
}

export fn ls_shared_free(
    d_ptr: usize,
) callconv(.c) void {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.deinit();
}

/// Reads from the driver's session, bypassing the "driver" itself, use with care. Bypasses the
/// ffi-driver operation loop entirely.
export fn ls_session_read(
    d_ptr: usize,
    buf: *[]u8,
    read_n: *usize,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const s = switch (d.real_driver) {
        .cli => |rd| rd.session,
        .netconf => |rd| rd.session,
    };

    const n = s.read(buf.*) catch {
        return 1;
    };

    read_n.* = n;

    return 0;
}

/// Writes from the driver's session, bypassing the "driver" itself, use with care. Bypasses the
/// ffi-driver operation loop entirely.
export fn ls_session_write(
    d_ptr: usize,
    buf: [*c]const u8,
    redacted: bool,
) callconv(.c) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const s = switch (d.real_driver) {
        .cli => |rd| rd.session,
        .netconf => |rd| rd.session,
    };

    s.write(std.mem.span(buf), redacted) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during driver write {any}",
            .{err},
        ) catch {};

        return 1;
    };

    return 0;
}

export fn ls_session_write_and_return(
    d_ptr: usize,
    buf: [*c]const u8,
    redacted: bool,
) callconv(.c) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const s = switch (d.real_driver) {
        .cli => |rd| rd.session,
        .netconf => |rd| rd.session,
    };

    s.writeAndReturn(std.mem.span(buf), redacted) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during driver write and return {any}",
            .{err},
        ) catch {};

        return 1;
    };

    return 0;
}

export fn ls_session_write_return(
    d_ptr: usize,
) callconv(.c) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const s = switch (d.real_driver) {
        .cli => |rd| rd.session,
        .netconf => |rd| rd.session,
    };

    s.writeReturn() catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during driver write return {any}",
            .{err},
        ) catch {};

        return 1;
    };

    return 0;
}

export fn ls_session_operation_timeout_ns(
    d_ptr: usize,
    value: u64,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.operation_timeout_ns = value;
        },
        .netconf => |rd| {
            rd.session.options.operation_timeout_ns = value;
        },
    }

    return 0;
}
