const std = @import("std");

const operation = @import("cli-operation.zig");

fn getInputHandling(input_handling: [*c]const u8) operation.InputHandling {
    const _input_handling = std.mem.span(input_handling);

    if (std.mem.eql(
        u8,
        @tagName(operation.InputHandling.exact),
        _input_handling,
    )) {
        return operation.InputHandling.exact;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.InputHandling.fuzzy),
        _input_handling,
    )) {
        return operation.InputHandling.fuzzy;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.InputHandling.ignore),
        _input_handling,
    )) {
        return operation.InputHandling.ignore;
    } else {
        return operation.InputHandling.fuzzy;
    }
}

/// Return SendInputOptions from ffi provided arguments.
pub fn sendInputOptionsFromArgs(
    cancel: *bool,
    input: [*c]const u8,
    requested_mode: [*c]const u8,
    input_handling: [*c]const u8,
    retain_input: bool,
    retain_trailing_prompt: bool,
) operation.SendInputOptions {
    var options = operation.SendInputOptions{
        .cancel = cancel,
        .input = std.mem.span(input),
        .input_handling = getInputHandling(input_handling),
        .retain_input = retain_input,
        .retain_trailing_prompt = retain_trailing_prompt,
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
    input_handling: [*c]const u8,
    retain_trailing_prompt: bool,
) operation.SendPromptedInputOptions {
    var options = operation.SendPromptedInputOptions{
        .cancel = cancel,
        .input = std.mem.span(input),
        .prompt_exact = std.mem.span(prompt_exact),
        .prompt_pattern = std.mem.span(prompt_pattern),
        .response = std.mem.span(response),
        .input_handling = getInputHandling(input_handling),
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
