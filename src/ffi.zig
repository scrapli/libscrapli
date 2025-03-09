const std = @import("std");

const ffi_driver = @import("ffi-driver.zig");
const ffi_driver_netconf = @import("ffi-driver-netconf.zig");
const ffi_operation = @import("ffi-operation.zig");
const operation = @import("operation.zig");
const operation_netconf = @import("operation-netconf.zig");
const logging = @import("logging.zig");
const ascii = @import("ascii.zig");
const transport = @import("transport.zig");

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

// std page allocator
// const allocator = std.heap.page_allocator;

// gpa for testing allocs
var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa_allocator.allocator();

export fn assertNoLeaks() bool {
    switch (gpa_allocator.deinit()) {
        .leak => return false,
        .ok => return true,
    }
}

fn getTransport(transport_kind: []const u8) transport.Kind {
    if (std.mem.eql(u8, transport_kind, @tagName(transport.Kind.bin))) {
        return transport.Kind.bin;
    } else if (std.mem.eql(u8, transport_kind, @tagName(transport.Kind.telnet))) {
        return transport.Kind.telnet;
    } else if (std.mem.eql(u8, transport_kind, @tagName(transport.Kind.ssh2))) {
        return transport.Kind.ssh2;
    } else {
        @panic("unsupported transport");
    }
}

export fn allocDriver(
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
                else => {
                    unreachable;
                },
            },
        },
    ) catch |err| {
        log.critical("error during FfiDriver.init: {any}", .{err});

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

/// writes the ntc template platform from the driver's definition into the character slice at
/// `ntc_template_platform` -- this slice should be pre populated w/ sufficient size (lets say
/// 256?). while unused in zig, ntc templates platform is useful in python land.
export fn getNtcTemplatePlatform(
    d_ptr: usize,
    ntc_template_platform: *[]u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    if (d.real_driver.definition.ntc_templates_platform == null) {
        return 0;
    }

    for (0.., d.real_driver.definition.ntc_templates_platform.?) |idx, char| {
        ntc_template_platform.*[idx] = char;
    }

    return 0;
}

/// writes the ntc template platform from the driver's definition into the character slice at
/// `genie_platform` -- this slice should be pre populated w/ sufficient size (lets say
/// 256?). while unused in zig, genie platform/parser is useful in python land.
export fn getGeniePlatform(
    d_ptr: usize,
    genie_platform: *[]u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    if (d.real_driver.definition.genie_platform == null) {
        return 0;
    }

    for (0.., d.real_driver.definition.genie_platform.?) |idx, char| {
        genie_platform.*[idx] = char;
    }

    return 0;
}

export fn openDriver(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.open() catch |err| {
        d.real_driver.log.critical("error during driver open {any}", .{err});

        return 1;
    };

    const _operation_id = d.queueOperation(ffi_driver.OperationOptions{
        .open = ffi_driver.OpenOperation{
            .id = 0,
            .options = operation.OpenOptions{
                .cancel = cancel,
            },
        },
    }) catch |err| {
        d.real_driver.log.critical("error during queue open {any}", .{err});

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

/// Closes the driver, does *not* free/deinit.
export fn closeDriver(
    d_ptr: usize,
    cancel: *bool,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.close(cancel) catch |err| {
        d.real_driver.log.critical("error during driver close {any}", .{err});

        return 1;
    };

    return 0;
}

/// Poll a given operation id, if the operation is completed fill a result and error u64 pointer
/// so the caller can subsequenty call fetch with appropriately sized buffers.
export fn pollOperation(
    d_ptr: usize,
    operation_id: u32,
    operation_done: *bool,
    operation_result_raw_size: *u64,
    operation_result_size: *u64,
    operation_failure_indicator_size: *u64,
    operation_error_size: *u64,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const ret = d.pollOperation(operation_id, false) catch |err| {
        d.real_driver.log.critical("error during poll operation {any}", .{err});

        return 1;
    };

    if (!ret.done) {
        operation_done.* = false;

        return 0;
    }

    operation_done.* = true;

    if (ret.err != null) {
        const err_name = @errorName(ret.err.?);

        operation_result_size.* = 0;
        operation_error_size.* = err_name.len;
    } else {
        operation_result_raw_size.* = ret.result.?.getResultRawLen();
        operation_result_size.* = ret.result.?.getResultLen();
        operation_failure_indicator_size.* = 0;
        operation_error_size.* = 0;

        if (ret.result.?.result_failure_indicated) {
            operation_failure_indicator_size.* = ret.result.?.failed_indicators.?.items[@intCast(ret.result.?.result_failure_indicator)].len;
        }
    }

    return 0;
}

/// Similar to `pollOperation`, but blocks until the specified operation is complete and obviously
/// does not require the bool pointer for done.
export fn waitOperation(
    d_ptr: usize,
    operation_id: u32,
    operation_result_raw_size: *u64,
    operation_result_size: *u64,
    operation_failure_indicator_size: *u64,
    operation_error_size: *u64,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    while (true) {
        const ret = d.pollOperation(operation_id, false) catch |err| {
            d.real_driver.log.critical("error during poll operation {any}", .{err});

            return 1;
        };

        if (!ret.done) {
            continue;
        }

        if (ret.err != null) {
            const err_name = @errorName(ret.err.?);

            operation_result_size.* = 0;
            operation_error_size.* = err_name.len;
        } else {
            operation_result_raw_size.* = ret.result.?.getResultRawLen();
            operation_result_size.* = ret.result.?.getResultLen();
            operation_failure_indicator_size.* = 0;
            operation_error_size.* = 0;

            if (ret.result.?.result_failure_indicated) {
                operation_failure_indicator_size.* = ret.result.?.failed_indicators.?.items[@intCast(ret.result.?.result_failure_indicator)].len;
            }
        }

        break;
    }

    return 0;
}

/// Fetches the result of the given operation id -- writing the result and error into the given
/// buffers. Must be preceeded by a `pollOperation` or `waitOperation` in order to get the sizes
/// of the result and error buffers.
export fn fetchOperation(
    d_ptr: usize,
    operation_id: u32,
    operation_start_time: *u64,
    operation_end_time: *u64,
    operation_result_raw: *[]u8,
    operation_result: *[]u8,
    operation_result_failed_indicator: *[]u8,
    operation_error: *[]u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const ret = d.pollOperation(operation_id, true) catch |err| {
        d.real_driver.log.critical("error during fetch operation {any}", .{err});

        return 1;
    };

    defer {
        if (ret.result != null) {
            ret.result.?.deinit();
        }
    }

    if (ret.err != null) {
        const err_name = @errorName(ret.err.?);

        @memcpy(operation_error.*.ptr, err_name);
    } else {
        const _ret = ret.result.?;

        operation_start_time.* = @intCast(_ret.start_time_ns);
        operation_end_time.* = @intCast(_ret.splits_ns.items[_ret.splits_ns.items.len - 1]);

        // to avoid a pointless allocation since we are already copying from the result into the
        // given string pointers, we'll do basically the same thing the result does in normal (zig)
        // operations in getResult/getResultRaw by iterating over the underlying array list and
        // copying from there, inserting newlines between results, into the given pointer(s)
        var cur: usize = 0;
        for (0.., _ret.results_raw.items) |idx, result_raw| {
            @memcpy(operation_result_raw.*[cur .. cur + result_raw.len], result_raw);
            cur += result_raw.len;

            if (idx != _ret.results_raw.items.len - 1) {
                operation_result_raw.*[cur] = ascii.control_chars.lf;
                cur += 1;
            }
        }

        cur = 0;

        for (0.., _ret.results.items) |idx, result| {
            @memcpy(operation_result.*[cur .. cur + result.len], result);
            cur += result.len;

            if (idx != _ret.results.items.len - 1) {
                operation_result.*[cur] = ascii.control_chars.lf;
                cur += 1;
            }
        }

        if (_ret.result_failure_indicated) {
            @memcpy(
                operation_result_failed_indicator.*,
                _ret.failed_indicators.?.items[@intCast(_ret.result_failure_indicator)],
            );
        }

        operation_error.* = "";
    }

    return 0;
}

export fn enterMode(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    requested_mode: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(ffi_driver.OperationOptions{
        .enter_mode = ffi_driver.EnterModeOperation{
            .id = 0,
            .requested_mode = std.mem.span(requested_mode),
            .options = operation.EnterModeOptions{
                .cancel = cancel,
            },
        },
    }) catch |err| {
        d.real_driver.log.critical("error during queue enterMode {any}", .{err});

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn getPrompt(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(ffi_driver.OperationOptions{
        .get_prompt = ffi_driver.GetPromptOperation{
            .id = 0,
            .options = operation.GetPromptOptions{
                .cancel = cancel,
            },
        },
    }) catch |err| {
        d.real_driver.log.critical("error during queue getPrompt {any}", .{err});

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn sendInput(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    input: [*c]const u8,
    requested_mode: [*c]const u8,
    input_handling: [*c]const u8,
    retain_input: bool,
    retain_trailing_prompt: bool,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_operation.SendInputOptionsFromArgs(
        cancel,
        requested_mode,
        input_handling,
        retain_input,
        retain_trailing_prompt,
    );

    const _operation_id = d.queueOperation(ffi_driver.OperationOptions{
        .send_input = ffi_driver.SendInputOperation{
            .id = 0,
            .input = std.mem.span(input),
            .options = options,
        },
    }) catch |err| {
        d.real_driver.log.critical("error during queue sendInput {any}", .{err});

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn sendPromptedInput(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    input: [*c]const u8,
    prompt: [*c]const u8,
    prompt_pattern: [*c]const u8,
    response: [*c]const u8,
    hidden_response: bool,
    abort_input: [*c]const u8,
    requested_mode: [*c]const u8,
    input_handling: [*c]const u8,
    retain_trailing_prompt: bool,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_operation.SendPromptedInputOptionsFromArgs(
        cancel,
        hidden_response,
        abort_input,
        requested_mode,
        input_handling,
        retain_trailing_prompt,
    );

    const _operation_id = d.queueOperation(ffi_driver.OperationOptions{
        .send_prompted_input = ffi_driver.SendPromptedInputOperation{
            .id = 0,
            .input = std.mem.span(input),
            .prompt = std.mem.span(prompt),
            .prompt_pattern = std.mem.span(prompt_pattern),
            .response = std.mem.span(response),
            .options = options,
        },
    }) catch |err| {
        d.real_driver.log.critical(
            "error during queue sendPromptedInput {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfAllocDriver(
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

    const d = ffi_driver_netconf.FfiDriver.init(
        allocator,
        std.mem.span(host),
        .{
            .logger = log,
            .port = port,
            .transport = switch (getTransport(std.mem.span(transport_kind))) {
                transport.Kind.bin => .{ .bin = .{} },
                transport.Kind.ssh2 => .{ .ssh2 = .{} },
                else => {
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

export fn netconfFreeDriver(
    d_ptr: usize,
) void {
    const d: *ffi_driver_netconf.FfiDriver = @ptrFromInt(d_ptr);

    d.deinit();
}

export fn netconfOpenDriver(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) u8 {
    var d: *ffi_driver_netconf.FfiDriver = @ptrFromInt(d_ptr);

    d.open() catch |err| {
        d.real_driver.log.critical("error during driver open {any}", .{err});

        return 1;
    };

    const _operation_id = d.queueOperation(ffi_driver_netconf.OperationOptions{
        .open = ffi_driver_netconf.OpenOperation{
            .id = 0,
            .options = operation_netconf.OpenOptions{
                .cancel = cancel,
            },
        },
    }) catch |err| {
        d.real_driver.log.critical("error during queue open {any}", .{err});

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfCloseDriver(
    d_ptr: usize,
    cancel: *bool,
) u8 {
    var d: *ffi_driver_netconf.FfiDriver = @ptrFromInt(d_ptr);

    d.close(cancel) catch |err| {
        d.real_driver.log.critical("error during driver close {any}", .{err});

        return 1;
    };

    return 0;
}

export fn netconfPollOperation(
    d_ptr: usize,
    operation_id: u32,
    operation_done: *bool,
    operation_result_raw_size: *u64,
    operation_result_size: *u64,
    operation_error_size: *u64,
) u8 {
    var d: *ffi_driver_netconf.FfiDriver = @ptrFromInt(d_ptr);

    const ret = d.pollOperation(operation_id, false) catch |err| {
        d.real_driver.log.critical("error during poll operation {any}", .{err});

        return 1;
    };

    if (!ret.done) {
        operation_done.* = false;

        return 0;
    }

    operation_done.* = true;

    if (ret.err != null) {
        const err_name = @errorName(ret.err.?);

        operation_result_size.* = 0;
        operation_error_size.* = err_name.len;
    } else {
        operation_result_raw_size.* = ret.result.?.getResultRawLen();
        operation_result_size.* = ret.result.?.getResultLen();
    }

    return 0;
}

export fn netconfWaitOperation(
    d_ptr: usize,
    operation_id: u32,
    operation_result_raw_size: *u64,
    operation_result_size: *u64,
    operation_error_size: *u64,
) u8 {
    var d: *ffi_driver_netconf.FfiDriver = @ptrFromInt(d_ptr);

    while (true) {
        const ret = d.pollOperation(operation_id, false) catch |err| {
            d.real_driver.log.critical("error during poll operation {any}", .{err});

            return 1;
        };

        if (!ret.done) {
            continue;
        }

        if (ret.err != null) {
            const err_name = @errorName(ret.err.?);

            operation_result_size.* = 0;
            operation_error_size.* = err_name.len;
        } else {
            operation_result_raw_size.* = ret.result.?.getResultRawLen();
            operation_result_size.* = ret.result.?.getResultLen();
        }

        break;
    }

    return 0;
}

export fn netconfFetchOperation(
    d_ptr: usize,
    operation_id: u32,
    operation_start_time: *u64,
    operation_end_time: *u64,
    operation_result_raw: *[]u8,
    operation_result: *[]u8,
    operation_error: *[]u8,
) u8 {
    var d: *ffi_driver_netconf.FfiDriver = @ptrFromInt(d_ptr);

    const ret = d.pollOperation(operation_id, true) catch |err| {
        d.real_driver.log.critical("error during fetch operation {any}", .{err});

        return 1;
    };

    defer {
        if (ret.result != null) {
            ret.result.?.deinit();
        }
    }

    if (ret.err != null) {
        const err_name = @errorName(ret.err.?);

        @memcpy(operation_error.*.ptr, err_name);
    } else {
        const _ret = ret.result.?;

        operation_start_time.* = @intCast(_ret.start_time_ns);
        operation_end_time.* = @intCast(_ret.splits_ns.items[_ret.splits_ns.items.len - 1]);

        // to avoid a pointless allocation since we are already copying from the result into the
        // given string pointers, we'll do basically the same thing the result does in normal (zig)
        // operations in getResult/getResultRaw by iterating over the underlying array list and
        // copying from there, inserting newlines between results, into the given pointer(s)
        var cur: usize = 0;
        for (0.., _ret.results_raw.items) |idx, result_raw| {
            @memcpy(operation_result_raw.*[cur .. cur + result_raw.len], result_raw);
            cur += result_raw.len;

            if (idx != _ret.results_raw.items.len - 1) {
                operation_result_raw.*[cur] = ascii.control_chars.lf;
                cur += 1;
            }
        }

        cur = 0;

        for (0.., _ret.results.items) |idx, result| {
            @memcpy(operation_result.*[cur .. cur + result.len], result);
            cur += result.len;

            if (idx != _ret.results.items.len - 1) {
                operation_result.*[cur] = ascii.control_chars.lf;
                cur += 1;
            }
        }

        operation_error.* = "";
    }

    return 0;
}

export fn netconfGetConfig(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) u8 {
    const d: *ffi_driver_netconf.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(ffi_driver_netconf.OperationOptions{
        .get_config = ffi_driver_netconf.GetConfigOperation{
            .id = 0,
            .options = .{
                .cancel = cancel,
            },
        },
    }) catch |err| {
        d.real_driver.log.critical("error during queue getConfig {any}", .{err});

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}
