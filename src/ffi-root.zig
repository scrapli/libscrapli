// zlint-disable suppressed-errors
const std = @import("std");

const errors = @import("errors.zig");
const ffi_common = @import("ffi-common.zig");
const ffi_driver = @import("ffi-driver.zig");
const ffi_options = @import("ffi-options.zig");
const ffi_root_cli = @import("ffi-root-cli.zig");
const ffi_root_netconf = @import("ffi-root-netconf.zig");

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

// all exported functions are named using c standard and prepended with "ls" for libscrapli for
// namespacing reasons.
export fn ls_assert_no_leaks() callconv(.c) bool {
    if (!ffi_common.isDebugMode()) {
        return true;
    }

    if (ffi_common.da.deinit() > 0) {
        return false;
    }

    return true;
}

export fn ls_alloc_driver_options() callconv(.c) ?*ffi_common.LsOptions {
    const allocator = ffi_common.getAllocator();

    const o = allocator.create(ffi_options.FFIOptions) catch {
        return null;
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

    return @ptrCast(o);
}

export fn ls_free_driver_options(options_ptr: *ffi_common.LsOptions) callconv(.c) void {
    const allocator = ffi_common.getAllocator();

    const o: *ffi_options.FFIOptions = @ptrCast(@alignCast(options_ptr));

    defer allocator.destroy(o);
}

export fn ls_cli_alloc(
    host: [*c]const u8,
    options_ptr: *ffi_common.LsOptions,
) callconv(.c) ?*ffi_common.LsDriver {
    if (host == null) {
        return null;
    }

    ffi_common.registerSegfaultHandler();

    const allocator = ffi_common.getAllocator();

    const o: *ffi_options.FFIOptions = @ptrCast(@alignCast(options_ptr));

    const d = ffi_driver.FfiDriver.init(
        allocator,
        ffi_common.io,
        std.mem.span(host),
        o.cliConfig(allocator),
    ) catch {
        return null;
    };

    if (o.cli.normalize_line_feeds) |b| {
        d.cli_get_results_options.normalize_line_feeds = b.*;
    }

    if (o.cli.normalize_trailing_whitespace) |b| {
        d.cli_get_results_options.normalize_trailing_whitespace = b.*;
    }

    return @ptrCast(d);
}

export fn ls_netconf_alloc(
    host: [*c]const u8,
    options_ptr: *ffi_common.LsOptions,
) callconv(.c) ?*ffi_common.LsDriver {
    if (host == null) {
        return null;
    }

    ffi_common.registerSegfaultHandler();

    const allocator = ffi_common.getAllocator();

    const o: *ffi_options.FFIOptions = @ptrCast(@alignCast(options_ptr));

    const d = ffi_driver.FfiDriver.initNetconf(
        allocator,
        ffi_common.io,
        std.mem.span(host),
        o.*.netconfConfig(allocator),
    ) catch {
        return null;
    };

    return @ptrCast(d);
}

export fn ls_shared_get_poll_fd(
    d_ptr: *ffi_common.LsDriver,
) callconv(.c) u32 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    return @intCast(d.poll_fds[0]);
}

export fn ls_shared_free(
    d_ptr: *ffi_common.LsDriver,
) callconv(.c) void {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    d.deinit();
}

/// Reads from the driver's session, bypassing the "driver" itself, use with care. Bypasses the
/// ffi-driver operation loop entirely.
export fn ls_session_read(
    d_ptr: *ffi_common.LsDriver,
    buf: *[]u8,
    read_n: *usize,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const s = switch (d.real_driver) {
        .cli => |rd| rd.session,
        .netconf => |rd| rd.session,
    };

    const n = s.read(buf.*) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during session read {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    read_n.* = n;

    return @intFromEnum(ffi_common.FfiResult.success);
}

/// Writes from the driver's session, bypassing the "driver" itself, use with care. Bypasses the
/// ffi-driver operation loop entirely.
export fn ls_session_write(
    d_ptr: *ffi_common.LsDriver,
    buf: [*c]const u8,
    redacted: bool,
) callconv(.c) u8 {
    if (buf == null) {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    var d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

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

        return ffi_common.toFfiResult(err);
    };

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_session_write_and_return(
    d_ptr: *ffi_common.LsDriver,
    buf: [*c]const u8,
    redacted: bool,
) callconv(.c) u8 {
    if (buf == null) {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    var d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

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

        return ffi_common.toFfiResult(err);
    };

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_session_write_return(
    d_ptr: *ffi_common.LsDriver,
) callconv(.c) u8 {
    var d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

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

        return ffi_common.toFfiResult(err);
    };

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_session_operation_timeout_ns(
    d_ptr: *ffi_common.LsDriver,
    value: u64,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.operation_timeout_ns = value;
        },
        .netconf => |rd| {
            rd.session.options.operation_timeout_ns = value;
        },
    }

    return @intFromEnum(ffi_common.FfiResult.success);
}

test "ffi: ls_cli_alloc null host" {
    const options = ls_alloc_driver_options().?;
    defer ls_free_driver_options(options);

    const driver = ls_cli_alloc(null, options);
    try std.testing.expect(driver == null);
}

test "ffi: ls_netconf_alloc null host" {
    const options = ls_alloc_driver_options().?;
    defer ls_free_driver_options(options);

    const driver = ls_netconf_alloc(null, options);
    try std.testing.expect(driver == null);
}

test "ffi: ls_session_write null buf" {
    const result = ls_session_write(@ptrFromInt(0xDEADBEEF), null, false);

    try std.testing.expectEqual(@intFromEnum(ffi_common.FfiResult.invalid_argument), result);
}

test "ffi: ls_session_write_and_return null buf" {
    const result = ls_session_write_and_return(@ptrFromInt(0xDEADBEEF), null, false);

    try std.testing.expectEqual(@intFromEnum(ffi_common.FfiResult.invalid_argument), result);
}
