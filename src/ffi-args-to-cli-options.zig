const std = @import("std");

const operation = @import("cli-operation.zig");

/// Return SendInputOptions from ffi provided arguments.
pub fn sendInputOptionsFromArgs(
    cancel: *bool,
    input: [*c]const u8,
    requested_mode: [*c]const u8,
    input_handling: u8,
    retain_input: bool,
    retain_trailing_prompt: bool,
) operation.SendInputOptions {
    var options = operation.SendInputOptions{
        .cancel = cancel,
        .input = std.mem.span(input),
        .input_handling = @as(operation.InputHandling, @enumFromInt(input_handling)),
        .retain_input = retain_input,
        .retain_trailing_prompt = retain_trailing_prompt,
    };

    const _requested_mode = std.mem.span(requested_mode);
    if (_requested_mode.len > 0) {
        options.requested_mode = _requested_mode;
    }

    return options;
}

/// Return SendInputsOptions from ffi provided arguments.
pub fn sendInputsOptionsFromArgs(
    cancel: *bool,
    inputs: [*c]const u8,
    requested_mode: [*c]const u8,
    input_handling: u8,
    retain_input: bool,
    retain_trailing_prompt: bool,
    stop_on_indicated_failure: bool,
) operation.SendInputsOptions {
    var options = operation.SendInputsOptions{
        .cancel = cancel,
        .inputs = &[_][]const u8{},
        ._ffi_inputs = std.mem.span(inputs),
        .input_handling = @as(operation.InputHandling, @enumFromInt(input_handling)),
        .retain_input = retain_input,
        .retain_trailing_prompt = retain_trailing_prompt,
        .stop_on_indicated_failure = stop_on_indicated_failure,
    };

    const _requested_mode = std.mem.span(requested_mode);
    if (_requested_mode.len > 0) {
        options.requested_mode = _requested_mode;
    }

    return options;
}

/// Return SendPromptedInputOptions from ffi provided arguments.
pub fn sendPromptedInputOptionsFromArgs(
    cancel: *bool,
    input: [*c]const u8,
    prompt_exact: [*c]const u8,
    prompt_pattern: [*c]const u8,
    response: [*c]const u8,
    hidden_response: bool,
    abort_input: [*c]const u8,
    requested_mode: [*c]const u8,
    input_handling: u8,
    retain_trailing_prompt: bool,
) operation.SendPromptedInputOptions {
    var options = operation.SendPromptedInputOptions{
        .cancel = cancel,
        .input = std.mem.span(input),
        .prompt_exact = std.mem.span(prompt_exact),
        .prompt_pattern = std.mem.span(prompt_pattern),
        .response = std.mem.span(response),
        .input_handling = @as(operation.InputHandling, @enumFromInt(input_handling)),
        .hidden_response = hidden_response,
        .retain_trailing_prompt = retain_trailing_prompt,
        .abort_input = std.mem.span(abort_input),
    };

    const _requested_mode = std.mem.span(requested_mode);
    if (_requested_mode.len > 0) {
        options.requested_mode = _requested_mode;
    }

    return options;
}
