const std = @import("std");
const builtin = @import("builtin");

const ffi_driver = @import("ffi-driver.zig");
const ffi_apply_options = @import("ffi-apply-options.zig");
const ffi_root_cli = @import("ffi-root-cli.zig");
const ffi_root_netconf = @import("ffi-root-netconf.zig");

const logging = @import("logging.zig");
const session = @import("session.zig");
const transport = @import("transport.zig");

pub export const _force_include_apply_options = &ffi_apply_options.noop;
pub export const _force_include_root_driver = &ffi_root_cli.noop;
pub export const _force_include_root_driver_netconf = &ffi_root_netconf.noop;

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
var debug_allocator = std.heap.DebugAllocator(.{}){};

fn isDebugMode() bool {
    if (builtin.mode == .Debug) {
        return true;
    }

    return std.posix.getenv(libscrapli_ffi_debug_mode_env_var) != null;
}

pub fn getAllocator() std.mem.Allocator {
    if (isDebugMode()) {
        return debug_allocator.allocator();
    } else {
        return std.heap.c_allocator;
    }
}

// all exported functions are named using c standard and prepended with "ls" for libscrapli for
// namespacing reasons.
export fn ls_assert_no_leaks() bool {
    if (!isDebugMode()) {
        return true;
    }

    switch (debug_allocator.deinit()) {
        .leak => return false,
        .ok => return true,
    }
}

fn getTransport(transport_kind: []const u8) transport.Kind {
    if (std.mem.eql(
        u8,
        transport_kind,
        @tagName(transport.Kind.bin),
    )) {
        return transport.Kind.bin;
    } else if (std.mem.eql(
        u8,
        transport_kind,
        @tagName(transport.Kind.telnet),
    )) {
        return transport.Kind.telnet;
    } else if (std.mem.eql(
        u8,
        transport_kind,
        @tagName(transport.Kind.ssh2),
    )) {
        return transport.Kind.ssh2;
    } else if (std.mem.eql(
        u8,
        transport_kind,
        @tagName(transport.Kind.test_),
    )) {
        return transport.Kind.test_;
    } else {
        @panic("unsupported transport");
    }
}

export fn ls_cli_alloc(
    definition_string: [*c]const u8,
    logger_callback: ?*const fn (level: u8, message: *[]u8) callconv(.C) void,
    logger_level: [*c]const u8,
    host: [*c]const u8,
    port: u16,
    transport_kind: [*c]const u8,
) usize {
    var log = logging.Logger{
        .allocator = getAllocator(),
    };

    if (logger_callback) |cb| {
        log = logging.Logger{
            .allocator = getAllocator(),
            .f = cb,
            .level = logging.LogLevel.fromString(std.mem.span(logger_level)),
        };
    }

    var _port: ?u16 = null;
    if (port != 0) {
        _port = port;
    }

    const d = ffi_driver.FfiDriver.init(
        getAllocator(),
        std.mem.span(host),
        .{
            .definition = .{
                .string = std.mem.span(definition_string),
            },
            .logger = log,
            .port = _port,
            .transport = switch (getTransport(std.mem.span(transport_kind))) {
                transport.Kind.bin => .{ .bin = .{} },
                transport.Kind.telnet => .{ .telnet = .{} },
                transport.Kind.ssh2 => .{ .ssh2 = .{} },
                transport.Kind.test_ => .{ .test_ = .{} },
            },
        },
    ) catch |err| {
        log.critical("error during FfiDriver.init: {any}", .{err});

        return 0;
    };

    return @intFromPtr(d);
}

export fn ls_netconf_alloc(
    logger_callback: ?*const fn (level: u8, message: *[]u8) callconv(.C) void,
    logger_level: [*c]const u8,
    host: [*c]const u8,
    port: u16,
    transport_kind: [*c]const u8,
) usize {
    var log = logging.Logger{
        .allocator = getAllocator(),
        .f = null,
    };

    if (logger_callback) |cb| {
        log = logging.Logger{
            .allocator = getAllocator(),
            .f = cb,
            .level = logging.LogLevel.fromString(std.mem.span(logger_level)),
        };
    }
    var _port: ?u16 = null;
    if (port != 0) {
        _port = port;
    }

    const d = ffi_driver.FfiDriver.init_netconf(
        getAllocator(),
        std.mem.span(host),
        .{
            .logger = log,
            .port = _port,
            .transport = switch (getTransport(std.mem.span(transport_kind))) {
                transport.Kind.bin => .{ .bin = .{} },
                transport.Kind.ssh2 => .{ .ssh2 = .{} },
                transport.Kind.test_ => .{ .test_ = .{} },
                else => {
                    log.critical("telnet is not a valid transport for netconf", .{});

                    return 0;
                },
            },
        },
    ) catch |err| {
        log.critical("error during alloc driver {any}", .{err});

        return 0;
    };

    return @intFromPtr(d);
}

export fn ls_shared_get_poll_fd(
    d_ptr: usize,
) u32 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    return @intCast(d.poll_fds[0]);
}

export fn ls_shared_free(
    d_ptr: usize,
) void {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.deinit();
}

/// Reads from the driver's session, bypassing the "driver" itself, use with care. Bypasses the
/// ffi-driver operation loop entirely.
export fn ls_session_read(
    d_ptr: usize,
    buf: *[]u8,
    read_n: *u64,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    // SAFETY: will always be set!
    var s: *session.Session = undefined;

    switch (d.real_driver) {
        .cli => |rd| {
            s = rd.session;
        },
        .netconf => |rd| {
            s = rd.session;
        },
    }

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
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    // SAFETY: will always be set!
    var s: *session.Session = undefined;

    switch (d.real_driver) {
        .cli => |rd| {
            s = rd.session;
        },
        .netconf => |rd| {
            s = rd.session;
        },
    }

    s.write(std.mem.span(buf), redacted) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during driver write {any}",
            .{err},
        );

        return 1;
    };

    return 0;
}

export fn ls_session_write_and_return(
    d_ptr: usize,
    buf: [*c]const u8,
    redacted: bool,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    // SAFETY: will always be set!
    var s: *session.Session = undefined;

    switch (d.real_driver) {
        .cli => |rd| {
            s = rd.session;
        },
        .netconf => |rd| {
            s = rd.session;
        },
    }

    s.writeAndReturn(std.mem.span(buf), redacted) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during driver write {any}",
            .{err},
        );

        return 1;
    };

    return 0;
}
