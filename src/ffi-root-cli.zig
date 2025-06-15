const std = @import("std");

const bytes = @import("bytes.zig");
const ffi_driver = @import("ffi-driver.zig");
const ffi_operations = @import("ffi-operations.zig");
const ffi_args_to_options = @import("ffi-args-to-cli-options.zig");
const cli = @import("cli.zig");

const logging = @import("logging.zig");

// for forcing inclusion in the ffi-root.zig entrypoint we use for the ffi layer
pub const noop = true;

/// writes the ntc template platform from the driver's definition into the character slice at
/// `ntc_template_platform` -- this slice should be pre populated w/ sufficient size (lets say
/// 256?). while unused in zig, ntc templates platform is useful in python land.
export fn ls_cli_get_ntc_templates_platform(
    d_ptr: usize,
    ntc_template_platform: *[]u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            if (rd.definition.ntc_templates_platform == null) {
                return 0;
            }

            for (0.., rd.definition.ntc_templates_platform.?) |idx, char| {
                ntc_template_platform.*[idx] = char;
            }

            return 0;
        },
        else => {
            return 1;
        },
    }
}

/// writes the genie platform from the driver's definition into the character slice at
/// `genie_platform` -- this slice should be pre populated w/ sufficient size (lets say
/// 256?). while unused in zig, genie platform/parser is useful in python land.
export fn ls_cli_get_genie_platform(
    d_ptr: usize,
    genie_platform: *[]u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            if (rd.definition.genie_platform == null) {
                return 0;
            }

            for (0.., rd.definition.genie_platform.?) |idx, char| {
                genie_platform.*[idx] = char;
            }

            return 0;
        },
        else => {
            return 1;
        },
    }

    return 0;
}

export fn ls_cli_open(
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
            d.log(
                logging.LogLevel.critical,
                "attempting to open non cli driver",
                .{},
            );

            return 1;
        },
    }

    while (true) {
        // weve already waited for the operation loop to start in the queue operation function,
        // but we also need to ensure we wait for the open operation to actually get put into
        // the queue before continuing
        d.operation_lock.lock();
        defer d.operation_lock.unlock();

        const op = d.operation_results.get(operation_id.*);
        if (op != null) {
            break;
        }

        std.time.sleep(ffi_driver.operation_thread_ready_sleep);
    }

    return 0;
}

export fn ls_cli_close(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => {
            operation_id.* = d.queueOperation(
                ffi_operations.OperationOptions{
                    .id = 0,
                    .operation = .{
                        .cli = .{
                            .close = .{
                                .cancel = cancel,
                            },
                        },
                    },
                },
            ) catch |err| {
                d.log(
                    logging.LogLevel.critical,
                    "error during queue close {any}",
                    .{err},
                );

                return 1;
            };
        },
        .netconf => {
            d.log(
                logging.LogLevel.critical,
                "attempting to close non cli driver",
                .{},
            );

            return 1;
        },
    }

    return 0;
}

export fn ls_cli_fetch_operation_sizes(
    d_ptr: usize,
    operation_id: u32,
    operation_count: *u32,
    operation_input_size: *u64,
    operation_result_raw_size: *u64,
    operation_result_size: *u64,
    operation_failure_indicator_size: *u64,
    operation_error_size: *u64,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const ret = d.dequeueOperation(operation_id, false) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during poll operation {any}",
            .{err},
        );

        return 1;
    };

    if (ret.err != null) {
        const err_name = @errorName(ret.err.?);

        operation_result_size.* = 0;
        operation_error_size.* = err_name.len;
    } else {
        const dret = switch (ret.result) {
            .cli => |r| r.?,
            else => @panic("attempting to access non cli result from cli type"),
        };

        operation_count.* = @intCast(dret.results.items.len);

        operation_input_size.* = dret.getInputLen(
            .{ .delimiter = bytes.libscrapli_delimiter },
        );
        operation_result_raw_size.* = dret.getResultRawLen(
            .{ .delimiter = bytes.libscrapli_delimiter },
        );
        operation_result_size.* = dret.getResultLen(
            .{ .delimiter = bytes.libscrapli_delimiter },
        );
        operation_failure_indicator_size.* = 0;
        operation_error_size.* = 0;

        if (dret.result_failure_indicated) {
            operation_failure_indicator_size.* = dret.failed_indicators.?.items[@intCast(dret.result_failure_indicator)].len;
        }
    }

    return 0;
}

export fn ls_cli_fetch_operation(
    d_ptr: usize,
    operation_id: u32,
    operation_start_time: *u64,
    operation_splits: *[]u64,
    operation_input: *[]u8,
    operation_result_raw: *[]u8,
    operation_result: *[]u8,
    operation_result_failed_indicator: *[]u8,
    operation_error: *[]u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const ret = d.dequeueOperation(operation_id, true) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during fetch operation {any}",
            .{err},
        );

        return 1;
    };

    defer {
        const dret = switch (ret.result) {
            .cli => |r| r,
            else => @panic("attempting to access non cli result from cli type"),
        };
        if (dret != null) {
            dret.?.deinit();
        }
    }

    if (ret.err != null) {
        const err_name = @errorName(ret.err.?);

        @memcpy(operation_error.*, err_name);
    } else {
        const dret = switch (ret.result) {
            .cli => |r| r.?,
            else => @panic("attempting to access non cli result from cli type"),
        };

        if (dret.splits_ns.items.len > 0) {
            operation_start_time.* = @intCast(dret.start_time_ns);
            for (0.., dret.splits_ns.items) |idx, split| {
                operation_splits.*[idx] = @intCast(split);
            }
        } else {
            // was a noop -- like enterMode but where mode didn't change
            operation_start_time.* = @intCast(dret.start_time_ns);
        }

        // to avoid a pointless allocation since we are already copying from the result into the
        // given string pointers, we'll do basically the same thing the result does in normal (zig)
        // operations in getResult/getResultRaw by iterating over the underlying array list and
        // copying from there, inserting newlines between results, into the given pointer(s)
        var cur: usize = 0;

        for (0.., dret.inputs.items) |idx, input| {
            @memcpy(operation_input.*[cur .. cur + input.len], input);
            cur += input.len;

            if (idx != dret.inputs.items.len - 1) {
                for (bytes.libscrapli_delimiter) |delimiter_char| {
                    operation_input.*[cur] = delimiter_char;
                    cur += 1;
                }
            }
        }

        cur = 0;

        for (0.., dret.results_raw.items) |idx, result_raw| {
            @memcpy(operation_result_raw.*[cur .. cur + result_raw.len], result_raw);
            cur += result_raw.len;

            if (idx != dret.results_raw.items.len - 1) {
                for (bytes.libscrapli_delimiter) |delimiter_char| {
                    operation_result_raw.*[cur] = delimiter_char;
                    cur += 1;
                }
            }
        }

        cur = 0;

        for (0.., dret.results.items) |idx, result| {
            @memcpy(operation_result.*[cur .. cur + result.len], result);
            cur += result.len;

            if (idx != dret.results.items.len - 1) {
                for (bytes.libscrapli_delimiter) |delimiter_char| {
                    operation_result.*[cur] = delimiter_char;
                    cur += 1;
                }
            }
        }

        if (dret.result_failure_indicated) {
            @memcpy(
                operation_result_failed_indicator.*,
                dret.failed_indicators.?.items[@intCast(dret.result_failure_indicator)],
            );
        }

        operation_error.* = "";
    }

    return 0;
}

export fn ls_cli_enter_mode(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    requested_mode: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .cli = .{
                    .enter_mode = .{
                        .cancel = cancel,
                        .requested_mode = std.mem.span(requested_mode),
                    },
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue enterMode {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_cli_get_prompt(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .cli = .{
                    .get_prompt = .{
                        .cancel = cancel,
                    },
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue getPrompt {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_cli_send_input(
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

    const options = ffi_args_to_options.SendInputOptionsFromArgs(
        cancel,
        input,
        requested_mode,
        input_handling,
        retain_input,
        retain_trailing_prompt,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .cli = .{
                    .send_input = options,
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue sendInput {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_cli_send_prompted_input(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    input: [*c]const u8,
    prompt_exact: [*c]const u8,
    prompt_pattern: [*c]const u8,
    response: [*c]const u8,
    abort_input: [*c]const u8,
    requested_mode: [*c]const u8,
    input_handling: [*c]const u8,
    hidden_response: bool,
    retain_trailing_prompt: bool,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_args_to_options.SendPromptedInputOptionsFromArgs(
        cancel,
        input,
        prompt_exact,
        prompt_pattern,
        response,
        hidden_response,
        abort_input,
        requested_mode,
        input_handling,
        retain_trailing_prompt,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .cli = .{
                    .send_prompted_input = options,
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue sendPromptedInput {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_cli_read_any(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .cli = .{
                    .read_any = .{
                        .cancel = cancel,
                    },
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue readAny {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_cli_read_callback_should_execute(
    buf: [*c]const u8,
    name: [*c]const u8,
    contains: [*c]const u8,
    contains_pattern: [*c]const u8,
    not_contains: [*c]const u8,
    only_once: bool,
    execute: *bool,
) u8 {
    var _triggered_callbacks = std.ArrayList([]const u8).init(std.heap.c_allocator);

    const should_execute = cli.readCallbackShouldExecute(
        std.mem.span(buf),
        std.mem.span(name),
        if (std.mem.span(contains).len == 0) null else std.mem.span(contains),
        if (std.mem.span(contains_pattern).len == 0) null else std.mem.span(contains_pattern),
        if (std.mem.span(not_contains).len == 0) null else std.mem.span(not_contains),
        only_once,
        // py/go will be responsible for this check -- we are only really doing this whole
        // "should execute" thing in zig so we never have to rely on regex in py/go, but clearly
        // doing string contains is way easier there (certainly when considering passing things
        // over ffi), so yea... w/e this is zero allocation operation so just pass empty arraylist
        &_triggered_callbacks,
    ) catch {
        return 1;
    };

    if (should_execute) {
        execute.* = true;
    } else {
        execute.* = false;
    }

    return 0;
}
