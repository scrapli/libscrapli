const std = @import("std");

const ffi_driver = @import("ffi-driver.zig");
const ffi_operations = @import("ffi-operations.zig");
const ffi_apply_options = @import("ffi-apply-options.zig");
const ffi_root_cli = @import("ffi-root-cli.zig");
const ffi_root_netconf = @import("ffi-root-netconf.zig");

const logging = @import("logging.zig");
const transport = @import("transport.zig");

// TODO dont do this shit, just figure out including more shit in build.zig
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

// TODO should ensure that we use std page alloc for release/debug for test
// std page allocator
// const allocator = std.heap.page_allocator;

// gpa for testing allocs
var debug_allocator = std.heap.DebugAllocator(.{}){};
const allocator = debug_allocator.allocator();

export fn assertNoLeaks() bool {
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

export fn allocCliDriver(
    definition_string: [*c]const u8,
    logger_callback: ?*const fn (level: u8, message: *[]u8) callconv(.C) void,
    host: [*c]const u8,
    port: u16,
    transport_kind: [*c]const u8,
) usize {
    var log = logging.Logger{
        .allocator = allocator,
        .f = null,
    };

    if (logger_callback != null) {
        log = logging.Logger{
            .allocator = allocator,
            .f = logger_callback.?,
        };
    }

    const d = ffi_driver.FfiDriver.init(
        allocator,
        std.mem.span(host),
        .{
            .definition = .{
                .string = std.mem.span(definition_string),
            },
            .logger = log,
            .port = port,
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

export fn allocNetconfDriver(
    logger_callback: ?*const fn (level: u8, message: *[]u8) callconv(.C) void,
    host: [*c]const u8,
    port: u16,
    transport_kind: [*c]const u8,
) usize {
    var log = logging.Logger{
        .allocator = allocator,
        .f = null,
    };

    if (logger_callback != null) {
        log = logging.Logger{
            .allocator = allocator,
            .f = logger_callback.?,
        };
    }

    const d = ffi_driver.FfiDriver.init_netconf(
        allocator,
        std.mem.span(host),
        .{
            .logger = log,
            .port = port,
            .transport = switch (getTransport(std.mem.span(transport_kind))) {
                transport.Kind.bin => .{ .bin = .{} },
                transport.Kind.ssh2 => .{ .ssh2 = .{} },
                transport.Kind.test_ => .{ .test_ = .{} },
                else => {
                    // only for telnet in the case of netconf (obvs)
                    unreachable;
                },
            },
        },
    ) catch |err| {
        log.critical("error during alloc driver {any}", .{err});

        return 0;
    };

    return @intFromPtr(d);
}

export fn freeDriver(
    d_ptr: usize,
) void {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.deinit();
}

export fn openDriver(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.open() catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during driver open {any}",
            .{err},
        );

        return 1;
    };

    switch (d.real_driver) {
        .cli => {
            operation_id.* = d.queueOperation(
                ffi_operations.OperationOptions{
                    .id = 0,
                    .operation = .{
                        .cli = .{
                            .open = .{
                                .cancel = cancel,
                            },
                        },
                    },
                },
            ) catch |err| {
                d.log(
                    logging.LogLevel.critical,
                    "error during queue open {any}",
                    .{err},
                );

                return 1;
            };
        },
        .netconf => {
            operation_id.* = d.queueOperation(
                ffi_operations.OperationOptions{
                    .id = 0,
                    .operation = .{
                        .netconf = .{
                            .open = .{
                                .cancel = cancel,
                            },
                        },
                    },
                },
            ) catch |err| {
                d.log(
                    logging.LogLevel.critical,
                    "error during queue open {any}",
                    .{err},
                );

                return 1;
            };
        },
    }

    return 0;
}

/// Closes the driver, does *not* free/deinit.
export fn closeDriver(
    d_ptr: usize,
    cancel: *bool,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.close(cancel) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during driver close {any}",
            .{err},
        );

        return 1;
    };

    return 0;
}
