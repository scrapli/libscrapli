// zlint-disable suppressed-errors
const std = @import("std");

const errors = @import("errors.zig");
const ffi_common = @import("ffi-common.zig");
const ffi_driver = @import("ffi-driver.zig");
const ffi_options = @import("ffi-options.zig");
const ffi_root_cli = @import("ffi-root-cli.zig");
const ffi_root_netconf = @import("ffi-root-netconf.zig");

const c = @cImport(@cInclude("signal.h"));

// zlinter-disable require_doc_comment
pub export const _ls_force_include_root_cli = &ffi_root_cli.noop;
pub export const _ls_force_include_root_netconf = &ffi_root_netconf.noop;
// zlinter-enable require_doc_comment

// all exported functions are named using c standard and prepended with "ls" for libscrapli for
// namespacing reasons.
export fn ls_assert_no_leaks() callconv(.c) bool {
    if (!ffi_common.isDebugMode()) {
        return true;
    }

    switch (ffi_common.da.deinit()) {
        .leak => return false,
        .ok => return true,
    }
}

export fn ls_alloc_driver_options() callconv(.c) usize {
    const allocator = ffi_common.getAllocator();

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
    const allocator = ffi_common.getAllocator();

    const o: *ffi_options.FFIOptions = @ptrFromInt(options_ptr);

    defer allocator.destroy(o);
}

export fn ls_cli_alloc(
    host: [*c]const u8,
    options_ptr: usize,
) callconv(.c) usize {
    if (ffi_common.isDebugMode()) {
        _ = c.signal(c.SIGSEGV, ffi_common.segfaultHandler);
    }

    const allocator = ffi_common.getAllocator();

    const o: *ffi_options.FFIOptions = @ptrFromInt(options_ptr);

    const d = ffi_driver.FfiDriver.init(
        allocator,
        ffi_common.io,
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
    if (ffi_common.isDebugMode()) {
        _ = c.signal(c.SIGSEGV, ffi_common.segfaultHandler);
    }

    const allocator = ffi_common.getAllocator();

    const o: *ffi_options.FFIOptions = @ptrFromInt(options_ptr);

    const d = ffi_driver.FfiDriver.initNetconf(
        allocator,
        ffi_common.io,
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
