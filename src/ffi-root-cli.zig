// zlinter-disable no_panic - ignoring as we do panic on things that *really* should not happen
const std = @import("std");

const cli = @import("cli.zig");
const errors = @import("errors.zig");
const ffi_args_to_options = @import("ffi-args-to-cli-options.zig");
const ffi_common = @import("ffi-common.zig");
const ffi_driver = @import("ffi-driver.zig");
const ffi_operations = @import("ffi-operations.zig");

/// For forcing inclusion in the ffi-root.zig entrypoint we use for the ffi layer.
pub const noop = true;

/// writes the ntc template platform from the driver's definition into the character slice at
/// `ntc_template_platform` -- this slice should be pre populated w/ sufficient size (lets say
/// 256?). while unused in zig, ntc templates platform is useful in python land.
export fn ls_cli_get_ntc_templates_platform(
    d_ptr: *ffi_common.LsDriver,
    ntc_template_platform: *[]u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    switch (d.real_driver) {
        .cli => |rd| {
            if (rd.definition.ntc_templates_platform == null) {
                return @intFromEnum(ffi_common.FfiResult.success);
            }

            for (0.., rd.definition.ntc_templates_platform.?) |idx, char| {
                ntc_template_platform.*[idx] = char;
            }

            return @intFromEnum(ffi_common.FfiResult.success);
        },
        else => {
            return @intFromEnum(ffi_common.FfiResult.invalid_argument);
        },
    }
}

/// writes the genie platform from the driver's definition into the character slice at
/// `genie_platform` -- this slice should be pre populated w/ sufficient size (lets say
/// 256?). while unused in zig, genie platform/parser is useful in python land.
export fn ls_cli_get_genie_platform(
    d_ptr: *ffi_common.LsDriver,
    genie_platform: *[]u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    switch (d.real_driver) {
        .cli => |rd| {
            if (rd.definition.genie_platform == null) {
                return @intFromEnum(ffi_common.FfiResult.success);
            }

            for (0.., rd.definition.genie_platform.?) |idx, char| {
                genie_platform.*[idx] = char;
            }

            return @intFromEnum(ffi_common.FfiResult.success);
        },
        else => {
            return @intFromEnum(ffi_common.FfiResult.invalid_argument);
        },
    }
}

export fn ls_cli_open(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
) callconv(.c) u8 {
    var d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    d.open() catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during driver open {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
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
                // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
                errors.wrapCriticalError(
                    errors.ScrapliError.Operation,
                    @src(),
                    d.getLogger(),
                    "ffi: error during queue open {any}",
                    .{err},
                ) catch {};

                return ffi_common.toFfiResult(err);
            };
        },
        .netconf => {
            // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
            errors.wrapCriticalError(
                errors.ScrapliError.Operation,
                @src(),
                d.getLogger(),
                "ffi: attempting to open non cli driver",
                .{},
            ) catch {};

            return @intFromEnum(ffi_common.FfiResult.invalid_argument);
        },
    }

    while (true) {
        // weve already waited for the operation loop to start in the queue operation function,
        // but we also need to ensure we wait for the open operation to actually get put into
        // the queue before continuing
        d.operation_lock.lock(d.io) catch |err| {
            return ffi_common.toFfiResult(err);
        };
        defer d.operation_lock.unlock(d.io);

        const op = d.operation_results.get(operation_id.*);
        if (op != null) {
            break;
        }

        std.Io.Clock.Duration.sleep(
            .{
                .clock = .awake,
                .raw = .fromNanoseconds(ffi_driver.operation_thread_ready_sleep),
            },
            d.io,
        ) catch |err| {
            d.getLogger().warn(
                "ffirootcli ls_cli_open: sleep error '{}', ignoring",
                .{err},
            );
        };
    }

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_cli_close(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
) callconv(.c) u8 {
    var d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

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
                // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
                errors.wrapCriticalError(
                    errors.ScrapliError.Operation,
                    @src(),
                    d.getLogger(),
                    "ffi: error during queue close {any}",
                    .{err},
                ) catch {};

                return ffi_common.toFfiResult(err);
            };
        },
        .netconf => {
            // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
            errors.wrapCriticalError(
                errors.ScrapliError.Operation,
                @src(),
                d.getLogger(),
                "ffi: attempting to close non cli driver",
                .{},
            ) catch {};

            return @intFromEnum(ffi_common.FfiResult.invalid_argument);
        },
    }

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_cli_fetch_operation_sizes(
    d_ptr: *ffi_common.LsDriver,
    operation_id: u32,
    operation_count: *u32,
    operation_input_size: *usize,
    operation_result_raw_size: *usize,
    operation_result_size: *usize,
    operation_failure_indicator_size: *usize,
    operation_error_size: *usize,
) callconv(.c) u8 {
    var d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const ret = d.dequeueOperation(operation_id, false) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during poll operation {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    if (ret.err != null) {
        const err_name = @errorName(ret.err.?);

        operation_result_size.* = 0;
        operation_error_size.* = err_name.len;
    } else {
        const dret = switch (ret.result) {
            .cli => |r| r.?,
            else => {
                // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
                errors.wrapCriticalError(
                    errors.ScrapliError.Operation,
                    @src(),
                    d.getLogger(),
                    "ffi: attempting to access non cli result from cli driver",
                    .{},
                ) catch {};

                return @intFromEnum(ffi_common.FfiResult.invalid_argument);
            },
        };

        const sizes = d.getCliResultLens(dret);
        operation_count.* = @intCast(sizes.operation_count);
        operation_input_size.* = sizes.operation_input_size;
        operation_result_raw_size.* = sizes.operation_result_raw_size;
        operation_result_size.* = sizes.operation_result_size;
        operation_failure_indicator_size.* = sizes.operation_failure_indicator_size;
        operation_error_size.* = 0;
    }

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_cli_fetch_operation(
    d_ptr: *ffi_common.LsDriver,
    operation_id: u32,
    operation_start_time: *u64,
    operation_splits: *[]u64,
    operation_input: *[]u8,
    operation_result_raw: *[]u8,
    operation_result: *[]u8,
    operation_result_failed_indicator: *[]u8,
    operation_error: *[]u8,
) callconv(.c) u8 {
    var d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const ret = d.dequeueOperation(operation_id, true) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during fetch operation {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    defer {
        const dret = switch (ret.result) {
            .cli => |r| r,
            else => @panic("ffi: attempting to access non cli result from cli type"),
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
            else => {
                // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
                errors.wrapCriticalError(
                    errors.ScrapliError.Operation,
                    @src(),
                    d.getLogger(),
                    "ffi: attempting to access non cli result from cli driver",
                    .{},
                ) catch {};

                return @intFromEnum(ffi_common.FfiResult.invalid_argument);
            },
        };

        d.getCliResults(
            dret,
            operation_start_time,
            operation_splits,
            operation_input,
            operation_result_raw,
            operation_result,
            operation_result_failed_indicator,
            operation_error,
        ) catch |err| {
            // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
            errors.wrapCriticalError(
                errors.ScrapliError.Operation,
                @src(),
                d.getLogger(),
                "ffi: error during fetch operation {any}",
                .{err},
            ) catch {};

            return ffi_common.toFfiResult(err);
        };
    }

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_cli_enter_mode(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    requested_mode: [*c]const u8,
) callconv(.c) u8 {
    if (requested_mode == null) {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

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
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue enterMode {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_cli_get_prompt(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

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
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue getPrompt {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_cli_send_input(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    input: [*c]const u8,
    requested_mode: [*c]const u8,
    input_handling: u8,
    retain_input: bool,
    retain_trailing_prompt: bool,
) callconv(.c) u8 {
    if (input == null or requested_mode == null) {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffi_args_to_options.sendInputOptionsFromArgs(
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
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue sendInput {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_cli_send_inputs(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    // inputs delimited on the libscrapli delim... annoying but simple/dumb
    inputs: [*c]const u8,
    requested_mode: [*c]const u8,
    input_handling: u8,
    retain_input: bool,
    retain_trailing_prompt: bool,
    stop_on_indicated_failure: bool,
) callconv(.c) u8 {
    if (inputs == null or requested_mode == null) {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffi_args_to_options.sendInputsOptionsFromArgs(
        cancel,
        inputs,
        requested_mode,
        input_handling,
        retain_input,
        retain_trailing_prompt,
        stop_on_indicated_failure,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .cli = .{
                    .send_inputs = options,
                },
            },
        },
    ) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue sendInputs {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_cli_send_prompted_input(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    input: [*c]const u8,
    prompt_exact: [*c]const u8,
    prompt_pattern: [*c]const u8,
    response: [*c]const u8,
    abort_input: [*c]const u8,
    requested_mode: [*c]const u8,
    input_handling: u8,
    hidden_response: bool,
    retain_trailing_prompt: bool,
) callconv(.c) u8 {
    if (input == null or
        prompt_exact == null or
        prompt_pattern == null or
        response == null or
        abort_input == null or
        requested_mode == null)
    {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffi_args_to_options.sendPromptedInputOptionsFromArgs(
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
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue sendPromptedInput {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_cli_read_any(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

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
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue readAny {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_cli_read_callback_should_execute(
    buf: [*c]const u8,
    name: [*c]const u8,
    contains: [*c]const u8,
    contains_pattern: [*c]const u8,
    not_contains: [*c]const u8,
    execute: *bool,
) callconv(.c) u8 {
    if (buf == null or
        name == null or
        contains == null or
        contains_pattern == null or
        not_contains == null)
    {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    var triggered_callbacks: std.ArrayList([]const u8) = .empty;

    const should_execute = cli.readCallbackShouldExecute(
        std.mem.span(buf),
        std.mem.span(name),
        if (std.mem.span(contains).len == 0) null else std.mem.span(contains),
        if (std.mem.span(contains_pattern).len == 0) null else std.mem.span(contains_pattern),
        if (std.mem.span(not_contains).len == 0) null else std.mem.span(not_contains),
        // py/go will be responsible for this check -- we are only really doing this whole
        // "should execute" thing in zig so we never have to rely on regex in py/go, but clearly
        // doing string contains is way easier there (certainly when considering passing things
        // over ffi), so yea... w/e this is zero allocation operation so just pass empty arraylist
        false,
        &triggered_callbacks,
    ) catch |err| {
        return ffi_common.toFfiResult(err);
    };

    if (should_execute) {
        execute.* = true;
    } else {
        execute.* = false;
    }

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_cli_replace_definition(
    d_ptr: *ffi_common.LsDriver,
    definition_string: [*c]const u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    switch (d.real_driver) {
        .cli => |rd| {
            rd.replaceDefinition(
                .{
                    .string = std.mem.span(definition_string),
                },
            ) catch |err| {
                return ffi_common.toFfiResult(err);
            };

            return @intFromEnum(ffi_common.FfiResult.success);
        },
        else => {
            return @intFromEnum(ffi_common.FfiResult.invalid_argument);
        },
    }
}

test "ffi: ls_cli_enter_mode null requested_mode" {
    var op_id: u32 = 0;
    var cancel: bool = false;
    const result = ls_cli_enter_mode(@ptrFromInt(0xDEADBEEF), &op_id, &cancel, null);
    try std.testing.expectEqual(@intFromEnum(ffi_common.FfiResult.invalid_argument), result);
}

test "ffi: ls_cli_send_input null arguments" {
    var op_id: u32 = 0;
    var cancel: bool = false;

    try std.testing.expectEqual(
        @intFromEnum(ffi_common.FfiResult.invalid_argument),
        ls_cli_send_input(
            @ptrFromInt(0xDEADBEEF),
            &op_id,
            &cancel,
            null,
            "mode",
            1,
            false,
            false,
        ),
    );

    try std.testing.expectEqual(
        @intFromEnum(ffi_common.FfiResult.invalid_argument),
        ls_cli_send_input(
            @ptrFromInt(0xDEADBEEF),
            &op_id,
            &cancel,
            "input",
            null,
            1,
            false,
            false,
        ),
    );
}

test "ffi: ls_cli_send_inputs null arguments" {
    var op_id: u32 = 0;
    var cancel: bool = false;

    try std.testing.expectEqual(
        @intFromEnum(ffi_common.FfiResult.invalid_argument),
        ls_cli_send_inputs(
            @ptrFromInt(0xDEADBEEF),
            &op_id,
            &cancel,
            null,
            "mode",
            1,
            false,
            false,
            false,
        ),
    );

    try std.testing.expectEqual(
        @intFromEnum(ffi_common.FfiResult.invalid_argument),
        ls_cli_send_inputs(
            @ptrFromInt(0xDEADBEEF),
            &op_id,
            &cancel,
            "inputs",
            null,
            1,
            false,
            false,
            false,
        ),
    );
}

test "ffi: ls_cli_send_prompted_input null arguments" {
    var op_id: u32 = 0;
    var cancel: bool = false;

    try std.testing.expectEqual(
        @intFromEnum(ffi_common.FfiResult.invalid_argument),
        ls_cli_send_prompted_input(
            @ptrFromInt(0xDEADBEEF),
            &op_id,
            &cancel,
            null,
            "exact",
            "pattern",
            "response",
            "abort",
            "mode",
            1,
            false,
            false,
        ),
    );

    try std.testing.expectEqual(
        @intFromEnum(ffi_common.FfiResult.invalid_argument),
        ls_cli_send_prompted_input(
            @ptrFromInt(0xDEADBEEF),
            &op_id,
            &cancel,
            "input",
            null,
            "pattern",
            "response",
            "abort",
            "mode",
            1,
            false,
            false,
        ),
    );
}

test "ffi: ls_cli_read_callback_should_execute null arguments" {
    var execute: bool = false;

    try std.testing.expectEqual(
        @intFromEnum(ffi_common.FfiResult.invalid_argument),
        ls_cli_read_callback_should_execute(
            null,
            "name",
            "contains",
            "pattern",
            "not_contains",
            &execute,
        ),
    );

    try std.testing.expectEqual(
        @intFromEnum(ffi_common.FfiResult.invalid_argument),
        ls_cli_read_callback_should_execute(
            "buf",
            null,
            "contains",
            "pattern",
            "not_contains",
            &execute,
        ),
    );
}

test "ffi: ls_cli_fetch_operation_sizes incomplete operation" {
    const d = try ffi_driver.FfiDriver.init(
        std.testing.allocator,
        std.testing.io,
        "dummy",
        .{
            .definition = .{
                .file = "src/tests/fixtures/platform_arista_eos_no_open_close_callbacks.yaml",
            },
        },
    );
    defer d.deinit();

    var cancel = false;
    const operation_id = try d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .cli = .{
                    .close = .{
                        .cancel = &cancel,
                    },
                },
            },
        },
    );

    var operation_count: u32 = 0;
    var operation_input_size: usize = 0;
    var operation_result_raw_size: usize = 0;
    var operation_result_size: usize = 0;
    var operation_failure_indicator_size: usize = 0;
    var operation_error_size: usize = 0;

    const ret = ls_cli_fetch_operation_sizes(
        @ptrCast(d),
        operation_id,
        &operation_count,
        &operation_input_size,
        &operation_result_raw_size,
        &operation_result_size,
        &operation_failure_indicator_size,
        &operation_error_size,
    );

    try std.testing.expectEqual(@intFromEnum(ffi_common.FfiResult.operation), ret);
}
