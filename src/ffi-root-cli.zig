const std = @import("std");

const ffi_driver = @import("ffi-driver.zig");
const ffi_operations = @import("ffi-operations.zig");
const ffi_args_to_options = @import("ffi-args-to-options.zig");

const logging = @import("logging.zig");
const ascii = @import("ascii.zig");
const time = @import("time.zig");

// for forcing inclusion in the ffi-root.zig entrypoint we use for the ffi layer
pub const noop = true;

const operation_delimiter = "__libscrapli__";

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

/// Poll a given operation id, if the operation is completed fill a result and error u64 pointer
/// so the caller can subsequenty call fetch with appropriately sized buffers.
export fn ls_cli_poll_operation(
    d_ptr: usize,
    operation_id: u32,
    operation_done: *bool,
    operation_count: *u32,
    operation_input_size: *u64,
    operation_result_raw_size: *u64,
    operation_result_size: *u64,
    operation_failure_indicator_size: *u64,
    operation_error_size: *u64,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const ret = d.pollOperation(operation_id, false) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during poll operation {any}",
            .{err},
        );

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
        const dret = switch (ret.result) {
            .cli => |r| r.?,
            else => @panic("attempting to access non cli result from cli type"),
        };

        operation_count.* = @intCast(dret.results.items.len);

        operation_input_size.* = dret.getInputLen(
            .{ .delimiter = operation_delimiter },
        );
        operation_result_raw_size.* = dret.getResultRawLen(
            .{ .delimiter = operation_delimiter },
        );
        operation_result_size.* = dret.getResultLen(
            .{ .delimiter = operation_delimiter },
        );
        operation_failure_indicator_size.* = 0;
        operation_error_size.* = 0;

        if (dret.result_failure_indicated) {
            operation_failure_indicator_size.* = dret.failed_indicators.?.items[@intCast(dret.result_failure_indicator)].len;
        }
    }

    return 0;
}

export fn ls_cli_wait_operation(
    d_ptr: usize,
    operation_id: u32,
    operation_done: *bool,
    operation_count: *u32,
    operation_input_size: *u64,
    operation_result_raw_size: *u64,
    operation_result_size: *u64,
    operation_failure_indicator_size: *u64,
    operation_error_size: *u64,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    var cur_read_delay_ns: u64 = d.real_driver.cli.session.options.read_delay_min_ns;

    while (true) {
        const ret = d.pollOperation(operation_id, false) catch |err| {
            d.log(
                logging.LogLevel.critical,
                "error during poll operation {any}",
                .{err},
            );

            return 1;
        };

        if (!ret.done) {
            cur_read_delay_ns = time.getBackoffValue(
                cur_read_delay_ns,
                d.real_driver.cli.session.options.read_delay_max_ns,
                d.real_driver.cli.session.options.read_delay_backoff_factor,
            );

            std.time.sleep(cur_read_delay_ns);

            continue;
        }

        operation_done.* = true;

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

            // TODO all of these would have to be the len + the len of inputs/results * the delim size i guess
            //   that way py/go can differentiate mutli line input/results to break them into sub
            //   inputs/results
            // TODO how would we deal w/ splits? its just an int so we could pass a pointer to array
            //   of them, but then we also have to return the count of results or w/e when we fetch
            operation_input_size.* = dret.getInputLen(
                .{ .delimiter = operation_delimiter },
            );
            operation_result_raw_size.* = dret.getResultRawLen(
                .{ .delimiter = operation_delimiter },
            );
            operation_result_size.* = dret.getResultLen(
                .{ .delimiter = operation_delimiter },
            );
            operation_failure_indicator_size.* = 0;
            operation_error_size.* = 0;

            if (dret.result_failure_indicated) {
                operation_failure_indicator_size.* = dret.failed_indicators.?.items[@intCast(dret.result_failure_indicator)].len;
            }
        }

        return 0;
    }
}

/// Fetches the result of the given operation id -- writing the result and error into the given
/// buffers. Must be preceeded by a `pollOperation` or `waitOperation` in order to get the sizes
/// of the result and error buffers.
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

    const ret = d.pollOperation(operation_id, true) catch |err| {
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
                for (operation_delimiter) |delimiter_char| {
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
                for (operation_delimiter) |delimiter_char| {
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
                for (operation_delimiter) |delimiter_char| {
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

    const options = ffi_args_to_options.SendPromptedInputOptionsFromArgs(
        cancel,
        input,
        prompt,
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
