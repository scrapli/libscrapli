const std = @import("std");

const ffi_options = @import("ffi-options.zig");
const ffi_driver = @import("ffi-driver.zig");
const operation = @import("operation.zig");
const driver = @import("driver.zig");
const netconf_ffi_options = @import("ffi-options-netconf.zig");
const netconf_ffi_driver = @import("ffi-driver-netconf.zig");
const netconf_operation = @import("operation-netconf.zig");
const logger = @import("logger.zig");
const mode = @import("mode.zig");
const ascii = @import("ascii.zig");

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
            .scope = .parse,
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

export fn allocDriver(
    definition_file_path: [*c]const u8,
    definition_string: [*c]const u8,
    variant_name: [*c]const u8,
    logger_callback: ?*const fn (level: u8, message: *[]u8) callconv(.C) void,
    host: [*c]const u8,
    port: u16,
    username: [*c]const u8,
    password: [*c]const u8,

    // session things
    read_size: u64,
    read_delay_min_ns: u64,
    read_delay_max_ns: u64,
    read_delay_backoff_factor: u8,
    return_char: []const u8,
    username_pattern: []const u8,
    password_pattern: []const u8,
    passphrase_pattern: []const u8,
    in_session_auth_bypass: bool,
    operation_timeout_ns: u64,
    operation_max_search_depth: u64,

    // in native zig we just pass a tagged union of the transport implementation options, but
    // we'll pass this explicitly from go/py so we know which args to use/set
    transport_kind: [*c]const u8,

    // general transport things
    term_width: u16,
    term_height: u16,

    // TODO bin/ssh/telnet args
    // bin_transport_bin: []const u8,
    // bin_transport_extra_open_args: []const []const u8,
    // bin_transport_override_open_args: []const []const u8,
    // bin_transport_bin: []const u8,
) usize {
    var log = logger.Logger{ .allocator = allocator, .f = null };

    if (logger_callback != null) {
        log = logger.Logger{ .allocator = allocator, .f = logger_callback.? };
    }

    const options = ffi_options.NewDriverOptionsFromAlloc(
        variant_name,
        log,
        // generic bits
        transport_kind,
        port,
        username,
        password,
        // session
        read_size,
        read_delay_min_ns,
        read_delay_max_ns,
        read_delay_backoff_factor,
        return_char,
        username_pattern,
        password_pattern,
        passphrase_pattern,
        in_session_auth_bypass,
        operation_timeout_ns,
        operation_max_search_depth,
        operation_timeout_ns,
        // transport
        transport_kind,
        term_width,
        term_height,
    );

    const host_slice = std.mem.span(host);
    const definition_file_path_slice = std.mem.span(definition_file_path);
    const definition_string_slice = std.mem.span(definition_string);

    // SAFETY: will always be set (or we'll have exited)
    const real_driver: driver.Driver = undefined;

    if (definition_file_path_slice.len > 0) {
        real_driver = driver.NewDriverFromYaml(
            allocator,
            definition_file_path_slice,
            host_slice,
            options,
        ) catch |err| {
            log.critical("error during NewDriverFromYaml: {any}", .{err});

            return 0;
        };
    } else {
        // we'll (in scrapli/scrapligo at least) always get one of these being populated
        // so we'll let stuff crash out downstream if for some reason it wasnt
        real_driver = driver.NewDriverFromYamlString(
            allocator,
            definition_string_slice,
            host_slice,
            options,
        ) catch |err| {
            log.critical("error during NewDriverFromYamlString: {any}", .{err});

            return 0;
        };
    }

    const d = ffi_driver.NewFfiDriver(
        allocator,
        real_driver,
    ) catch |err| {
        log.critical("error during NewFfiDriver: {any}", .{err});

        return 0;
    };

    d.init() catch |err| {
        log.critical("error during driver init: {any}", .{err});

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
        d.real_driver.log.critical("error during driver open {any}", .{err});

        return 1;
    };

    const _operation_id = d.queueOperation(ffi_driver.OperationOptions{
        .Open = ffi_driver.OpenOperation{
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
            operation_failure_indicator_size.* = ret.result.?.input_failed_when_contains.?.items[@intCast(ret.result.?.result_failure_indicator)].len;
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
                operation_failure_indicator_size.* = ret.result.?.input_failed_when_contains.?.items[@intCast(ret.result.?.result_failure_indicator)].len;
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
            @memcpy(operation_result_failed_indicator.*, _ret.input_failed_when_contains.?.items[@intCast(_ret.result_failure_indicator)]);
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
        .EnterMode = ffi_driver.EnterModeOperation{
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
        .GetPrompt = ffi_driver.GetPromptOperation{
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
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(ffi_driver.OperationOptions{
        .SendInput = ffi_driver.SendInputOperation{
            .id = 0,
            .input = std.mem.span(input),
            .options = operation.SendInputOptions{
                .cancel = cancel,
                .input_handling = operation.InputHandling.Fuzzy,
                .retain_input = false,
                .retain_trailing_prompt = false,
                .requested_mode = mode.default_mode,
                .stop_on_indicated_failure = true,
            },
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
    response: [*c]const u8,
    hidden_response: bool,
    abort_input: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(ffi_driver.OperationOptions{
        .SendPromptedInput = ffi_driver.SendPromptedInputOperation{
            .id = 0,
            .input = std.mem.span(input),
            .prompt = std.mem.span(prompt),
            .response = std.mem.span(response),
            .options = operation.SendPromptedInputOptions{
                .cancel = cancel,
                .requested_mode = mode.default_mode,
                .input_handling = operation.InputHandling.Fuzzy,
                .hidden_response = hidden_response,
                .retain_trailing_prompt = false,
                .abort_input = std.mem.span(abort_input),
            },
        },
    }) catch |err| {
        d.real_driver.log.critical("error during queue sendPromptedInput {any}", .{err});

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfAllocDriver(
    logger_callback: ?*const fn (level: u8, message: *[]u8) callconv(.C) void,
    host: [*c]const u8,
    transport_kind: [*c]const u8,
    port: u16,
    username: [*c]const u8,
    password: [*c]const u8,
    session_timeout_ns: u64,
    // TODO all the other opts
) usize {
    var log = logger.Logger{ .allocator = allocator, .f = null };

    if (logger_callback != null) {
        log = logger.Logger{ .allocator = allocator, .f = logger_callback.? };
    }

    const host_slice = std.mem.span(host);

    const opts = netconf_ffi_options.NewDriverOptionsFromAlloc(
        log,
        transport_kind,
        port,
        username,
        password,
        session_timeout_ns,
    );

    const d = netconf_ffi_driver.NewFfiDriver(
        allocator,
        host_slice,
        opts,
    ) catch |err| {
        log.critical("error during alloc driver {any}", .{err});

        return 0;
    };

    d.init() catch |err| {
        d.real_driver.log.critical("error during init driver {any}", .{err});

        return 1;
    };

    return @intFromPtr(d);
}

export fn netconfFreeDriver(
    d_ptr: usize,
) void {
    const d: *netconf_ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.deinit();
}

export fn netconfOpenDriver(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) u8 {
    var d: *netconf_ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.open() catch |err| {
        d.real_driver.log.critical("error during driver open {any}", .{err});

        return 1;
    };

    const _operation_id = d.queueOperation(netconf_ffi_driver.OperationOptions{
        .Open = netconf_ffi_driver.OpenOperation{
            .id = 0,
            .options = netconf_operation.OpenOptions{
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
    var d: *netconf_ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

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
    var d: *netconf_ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

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
    var d: *netconf_ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

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
    var d: *netconf_ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

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
    const d: *netconf_ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    var opts = netconf_operation.NewGetConfigOptions();
    opts.cancel = cancel;

    const _operation_id = d.queueOperation(netconf_ffi_driver.OperationOptions{
        .GetConfig = netconf_ffi_driver.GetConfigOperation{
            .id = 0,
            .options = opts,
        },
    }) catch |err| {
        d.real_driver.log.critical("error during queue getConfig {any}", .{err});

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}
