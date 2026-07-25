const std = @import("std");

const ffi_operations = @import("ffi-operations.zig");
const mode = @import("cli-mode.zig");
const operation = @import("cli-operation.zig");

/// Return SendInputOptions from ffi provided arguments.
pub fn sendInputOptionsFromArgs(
    allocator: std.mem.Allocator,
    cancel: *bool,
    input: [*c]const u8,
    requested_mode: [*c]const u8,
    input_handling: ?*u8,
    retain_input: bool,
    retain_trailing_prompt: bool,
) !operation.SendInputOptions {
    var options = operation.SendInputOptions{
        .cancel = cancel,
        .input = try allocator.dupe(u8, std.mem.span(input)),
        .retain_input = retain_input,
        .retain_trailing_prompt = retain_trailing_prompt,
    };

    errdefer ffi_operations.freeOwnedStrings(allocator, options);

    if (input_handling) |inh| {
        options.input_handling = @fromBackingInt(@intCast(inh.*));
    }

    const spanned_requested_mode = std.mem.span(requested_mode);
    if (spanned_requested_mode.len > 0 and
        !std.mem.eql(
            u8,
            spanned_requested_mode,
            mode.default_mode,
        ))
    {
        options.requested_mode = try allocator.dupe(u8, spanned_requested_mode);
    }

    return options;
}

/// Return SendInputsOptions from ffi provided arguments.
pub fn sendInputsOptionsFromArgs(
    allocator: std.mem.Allocator,
    cancel: *bool,
    inputs: [*c]const u8,
    requested_mode: [*c]const u8,
    input_handling: ?*u8,
    retain_input: bool,
    retain_trailing_prompt: bool,
    stop_on_indicated_failure: bool,
) !operation.SendInputsOptions {
    var options = operation.SendInputsOptions{
        .cancel = cancel,
        .inputs = &[_][]const u8{},
        ._ffi_inputs = try allocator.dupe(u8, std.mem.span(inputs)),
        .retain_input = retain_input,
        .retain_trailing_prompt = retain_trailing_prompt,
        .stop_on_indicated_failure = stop_on_indicated_failure,
    };

    errdefer ffi_operations.freeOwnedStrings(allocator, options);

    if (input_handling) |inh| {
        options.input_handling = @fromBackingInt(@intCast(inh.*));
    }

    const spanned_requested_mode = std.mem.span(requested_mode);
    if (spanned_requested_mode.len > 0 and
        !std.mem.eql(
            u8,
            spanned_requested_mode,
            mode.default_mode,
        ))
    {
        options.requested_mode = try allocator.dupe(u8, spanned_requested_mode);
    }

    return options;
}

/// Return SendPromptedInputOptions from ffi provided arguments.
pub fn sendPromptedInputOptionsFromArgs(
    allocator: std.mem.Allocator,
    cancel: *bool,
    input: [*c]const u8,
    prompt_exact: [*c]const u8,
    prompt_pattern: [*c]const u8,
    response: [*c]const u8,
    hidden_response: bool,
    abort_input: [*c]const u8,
    requested_mode: [*c]const u8,
    input_handling: ?*u8,
    retain_trailing_prompt: bool,
) !operation.SendPromptedInputOptions {
    var options = operation.SendPromptedInputOptions{
        .cancel = cancel,
        .input = "",
        .response = "",
        .hidden_response = hidden_response,
        .retain_trailing_prompt = retain_trailing_prompt,
    };

    // string fields are duped one at a time below; if any dupe fails this frees whatever the
    // options owns up to that point
    errdefer ffi_operations.freeOwnedStrings(allocator, options);

    options.input = try allocator.dupe(u8, std.mem.span(input));
    options.prompt_exact = try allocator.dupe(u8, std.mem.span(prompt_exact));
    options.prompt_pattern = try allocator.dupe(u8, std.mem.span(prompt_pattern));
    options.response = try allocator.dupe(u8, std.mem.span(response));
    options.abort_input = try allocator.dupe(u8, std.mem.span(abort_input));

    if (input_handling) |inh| {
        options.input_handling = @fromBackingInt(@intCast(inh.*));
    }

    const spanned_requested_mode = std.mem.span(requested_mode);
    if (spanned_requested_mode.len > 0 and
        !std.mem.eql(
            u8,
            spanned_requested_mode,
            mode.default_mode,
        ))
    {
        options.requested_mode = try allocator.dupe(u8, spanned_requested_mode);
    }

    return options;
}
