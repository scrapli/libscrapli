// zlinter-disable no_panic - ignoring as we do panic on things that *really* should not happen
const std = @import("std");

const bytes = @import("bytes.zig");
const cli = @import("cli.zig");
const errors = @import("errors.zig");
const ffi_args_to_options = @import("ffi-args-to-cli-options.zig");
const ffi_common = @import("ffi-common.zig");
const ffi_driver = @import("ffi-driver.zig");
const ffi_operations = @import("ffi-operations.zig");

/// For forcing inclusion in the ffi-root.zig entrypoint we use for the ffi layer.
pub const noop = true;

/// Get the "real" cli driver or log an error. The error case should basically not ever happen
/// unless somebody is doing silly stuff w/ the ffi.
fn getRealCliDriver(d: *ffi_driver.FfiDriver) ?*cli.Driver {
    switch (d.real_driver) {
        .cli => |rd| return rd,
        .netconf => {
            // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
            errors.wrapCriticalError(
                errors.ScrapliError.Operation,
                @src(),
                d.getLogger(),
                "ffi: attempting to access non cli driver as cli",
                .{},
            ) catch {};

            return null;
        },
    }
}

/// writes the ntc template platform from the driver's definition into the character slice at
/// `ntc_template_platform` -- this slice should be pre populated w/ sufficient size (lets say
/// 256?). while unused in zig, ntc templates platform is useful in python land.
export fn ls_cli_get_ntc_templates_platform(
    d_ptr: *ffi_common.LsDriver,
    ntc_template_platform: *[]u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const rd = getRealCliDriver(d) orelse {
        return @backingInt(ffi_common.FfiResult.invalid_argument);
    };

    if (rd.definition.ntc_templates_platform == null) {
        return @backingInt(ffi_common.FfiResult.success);
    }

    for (0.., rd.definition.ntc_templates_platform.?) |idx, char| {
        ntc_template_platform.*[idx] = char;
    }

    return @backingInt(ffi_common.FfiResult.success);
}

/// writes the genie platform from the driver's definition into the character slice at
/// `genie_platform` -- this slice should be pre populated w/ sufficient size (lets say
/// 256?). while unused in zig, genie platform/parser is useful in python land.
export fn ls_cli_get_genie_platform(
    d_ptr: *ffi_common.LsDriver,
    genie_platform: *[]u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const rd = getRealCliDriver(d) orelse {
        return @backingInt(ffi_common.FfiResult.invalid_argument);
    };

    if (rd.definition.genie_platform == null) {
        return @backingInt(ffi_common.FfiResult.success);
    }

    for (0.., rd.definition.genie_platform.?) |idx, char| {
        genie_platform.*[idx] = char;
    }

    return @backingInt(ffi_common.FfiResult.success);
}

export fn ls_cli_open(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

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

    _ = getRealCliDriver(d) orelse {
        return @backingInt(ffi_common.FfiResult.invalid_argument);
    };

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

        d.io.sleep(
            .{
                .nanoseconds = ffi_driver.operation_thread_ready_sleep,
            },
            .awake,
        ) catch |err| {
            d.getLogger().warn(
                "ffirootcli ls_cli_open: sleep error '{}', ignoring",
                .{err},
            );
        };
    }

    return @backingInt(ffi_common.FfiResult.success);
}

export fn ls_cli_close(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    force: bool,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    _ = getRealCliDriver(d) orelse {
        return @backingInt(ffi_common.FfiResult.invalid_argument);
    };

    operation_id.* = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .cli = .{
                    .close = .{
                        .cancel = cancel,
                        .force = force,
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

    return @backingInt(ffi_common.FfiResult.success);
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
    operation_last_error_size: *usize,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

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
        operation_last_error_size.* = ret.last_error.len;
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

                return @backingInt(ffi_common.FfiResult.invalid_argument);
            },
        };

        const sizes = d.getCliResultLens(dret);

        operation_count.* = @intCast(sizes.operation_count);
        operation_input_size.* = sizes.operation_input_size;
        operation_result_raw_size.* = sizes.operation_result_raw_size;
        operation_result_size.* = sizes.operation_result_size;
        operation_failure_indicator_size.* = sizes.operation_failure_indicator_size;
        operation_error_size.* = 0;
        operation_last_error_size.* = 0;
    }

    return @backingInt(ffi_common.FfiResult.success);
}

export fn ls_cli_fetch_operation(
    d_ptr: *ffi_common.LsDriver,
    operation_id: u32,
    operation_start_time: *u64,
    operation_splits: *[]u64,
    operation_input: *[]u8,
    operation_input_lens: *[]u64,
    operation_result_raw: *[]u8,
    operation_result_raw_lens: *[]u64,
    operation_result: *[]u8,
    operation_result_lens: *[]u64,
    operation_result_failed_indicator: *[]u8,
    operation_error: *[]u8,
    operation_last_error: *[]u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

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

    defer ret.deinit(d.allocator);

    if (ret.err) |ret_err| {
        const err_name = @errorName(ret_err);

        @memcpy(operation_error.*, err_name);
        @memcpy(operation_last_error.*, ret.last_error);
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

                return @backingInt(ffi_common.FfiResult.invalid_argument);
            },
        };

        d.getCliResults(
            dret,
            operation_start_time,
            operation_splits,
            operation_input,
            operation_input_lens,
            operation_result_raw,
            operation_result_raw_lens,
            operation_result,
            operation_result_lens,
            operation_result_failed_indicator,
            operation_error,
        );
    }

    return @backingInt(ffi_common.FfiResult.success);
}

/// Get the size of the buffer needed to rebuild a single result entry's raw into -- cli results
/// are per entry (one per input), so the (result, journal) pair here is one entry's slice of the
/// packed buffers returned by ls_cli_fetch_operation.
export fn ls_cli_get_reconstructed_result_raw_size(
    operation_result: *[]u8,
    operation_result_raw_journal: *[]u8,
    raw_size: *usize,
) callconv(.c) u8 {
    raw_size.* = bytes.reconstructedRawLen(
        operation_result_raw_journal.*,
        operation_result.*.len,
    ) catch |err| {
        return ffi_common.toFfiResult(err);
    };

    return @backingInt(ffi_common.FfiResult.success);
}

/// Reconstructs a single result entry's raw from its (result, journal) pair into the caller
/// provided (and owned) buf (sized via ls_cli_get_reconstructed_result_raw_size).
export fn ls_cli_get_reconstructed_result_raw(
    operation_result: *[]u8,
    operation_result_raw_journal: *[]u8,
    operation_result_raw: *[]u8,
) callconv(.c) u8 {
    bytes.reconstructRawInto(
        operation_result_raw_journal.*,
        operation_result.*,
        operation_result_raw.*,
    ) catch |err| {
        return ffi_common.toFfiResult(err);
    };

    return @backingInt(ffi_common.FfiResult.success);
}

export fn ls_cli_enter_mode(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    requested_mode: [*c]const u8,
) callconv(.c) u8 {
    if (requested_mode == null) {
        return @backingInt(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const spanned_requested_mode = std.mem.span(requested_mode);
    const owned_requested_mode = d.allocator.dupe(u8, spanned_requested_mode) catch |err| {
        return ffi_common.toFfiResult(err);
    };

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .cli = .{
                    .enter_mode = .{
                        .cancel = cancel,
                        .requested_mode = owned_requested_mode,
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

    return @backingInt(ffi_common.FfiResult.success);
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

    return @backingInt(ffi_common.FfiResult.success);
}

export fn ls_cli_send_input(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    input: [*c]const u8,
    requested_mode: [*c]const u8,
    input_handling: ?*u8,
    retain_input: bool,
    retain_trailing_prompt: bool,
) callconv(.c) u8 {
    if (input == null or requested_mode == null) {
        return @backingInt(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffi_args_to_options.sendInputOptionsFromArgs(
        d.allocator,
        cancel,
        input,
        requested_mode,
        input_handling,
        retain_input,
        retain_trailing_prompt,
    ) catch |err| {
        return ffi_common.toFfiResult(err);
    };

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

    return @backingInt(ffi_common.FfiResult.success);
}

export fn ls_cli_send_inputs(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    inputs: *[]u8,
    input_lens: *[]u64,
    requested_mode: [*c]const u8,
    input_handling: ?*u8,
    retain_input: bool,
    retain_trailing_prompt: bool,
    stop_on_indicated_failure: bool,
) callconv(.c) u8 {
    if (requested_mode == null) {
        return @backingInt(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffi_args_to_options.sendInputsOptionsFromArgs(
        d.allocator,
        cancel,
        inputs.*,
        input_lens.*,
        requested_mode,
        input_handling,
        retain_input,
        retain_trailing_prompt,
        stop_on_indicated_failure,
    ) catch |err| {
        return ffi_common.toFfiResult(err);
    };

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

    return @backingInt(ffi_common.FfiResult.success);
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
    input_handling: ?*u8,
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
        return @backingInt(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffi_args_to_options.sendPromptedInputOptionsFromArgs(
        d.allocator,
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
    ) catch |err| {
        return ffi_common.toFfiResult(err);
    };

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

    return @backingInt(ffi_common.FfiResult.success);
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

    return @backingInt(ffi_common.FfiResult.success);
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
        return @backingInt(ffi_common.FfiResult.invalid_argument);
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

    return @backingInt(ffi_common.FfiResult.success);
}

export fn ls_cli_replace_definition(
    d_ptr: *ffi_common.LsDriver,
    definition_string: [*c]const u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    if (definition_string == null) {
        return @backingInt(ffi_common.FfiResult.invalid_argument);
    }

    const rd = getRealCliDriver(d) orelse {
        return @backingInt(ffi_common.FfiResult.invalid_argument);
    };

    rd.replaceDefinition(
        .{
            .string = std.mem.span(definition_string),
        },
    ) catch |err| {
        return ffi_common.toFfiResult(err);
    };

    return @backingInt(ffi_common.FfiResult.success);
}

test "ffi: ls_cli_enter_mode null requested_mode" {
    var op_id: u32 = 0;
    var cancel: bool = false;
    const result = ls_cli_enter_mode(@ptrFromInt(0xDEADBEEF), &op_id, &cancel, null);
    try std.testing.expectEqual(@backingInt(ffi_common.FfiResult.invalid_argument), result);
}

test "ffi: ls_cli_send_input null arguments" {
    var op_id: u32 = 0;
    var cancel: bool = false;

    try std.testing.expectEqual(
        @backingInt(ffi_common.FfiResult.invalid_argument),
        ls_cli_send_input(
            @ptrFromInt(0xDEADBEEF),
            &op_id,
            &cancel,
            null,
            "mode",
            null,
            false,
            false,
        ),
    );

    try std.testing.expectEqual(
        @backingInt(ffi_common.FfiResult.invalid_argument),
        ls_cli_send_input(
            @ptrFromInt(0xDEADBEEF),
            &op_id,
            &cancel,
            "input",
            null,
            null,
            false,
            false,
        ),
    );
}

test "ffi: ls_cli_send_inputs null arguments" {
    var op_id: u32 = 0;
    var cancel: bool = false;

    var inputs_buf = "show version".*;
    var inputs: []u8 = &inputs_buf;

    var input_lens_buf = [_]u64{12};
    var input_lens: []u64 = &input_lens_buf;

    try std.testing.expectEqual(
        @backingInt(ffi_common.FfiResult.invalid_argument),
        ls_cli_send_inputs(
            @ptrFromInt(0xDEADBEEF),
            &op_id,
            &cancel,
            &inputs,
            &input_lens,
            null,
            null,
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
        @backingInt(ffi_common.FfiResult.invalid_argument),
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
            null,
            false,
            false,
        ),
    );

    try std.testing.expectEqual(
        @backingInt(ffi_common.FfiResult.invalid_argument),
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
            null,
            false,
            false,
        ),
    );
}

test "ffi: ls_cli_read_callback_should_execute null arguments" {
    var execute: bool = false;

    try std.testing.expectEqual(
        @backingInt(ffi_common.FfiResult.invalid_argument),
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
        @backingInt(ffi_common.FfiResult.invalid_argument),
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
    var operation_last_error_size: usize = 0;

    const ret = ls_cli_fetch_operation_sizes(
        @ptrCast(d),
        operation_id,
        &operation_count,
        &operation_input_size,
        &operation_result_raw_size,
        &operation_result_size,
        &operation_failure_indicator_size,
        &operation_error_size,
        &operation_last_error_size,
    );

    try std.testing.expectEqual(@backingInt(ffi_common.FfiResult.operation), ret);
}
