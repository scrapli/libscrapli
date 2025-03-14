const std = @import("std");
const operation = @import("../operation.zig");

pub fn SendInputOptionsFromArgs(
    cancel: *bool,
    requested_mode: [*c]const u8,
    input_handling: [*c]const u8,
    retain_input: bool,
    retain_trailing_prompt: bool,
) operation.SendInputOptions {
    var options = operation.SendInputOptions{
        .cancel = cancel,
    };

    const _requested_mode = std.mem.span(requested_mode);
    if (_requested_mode.len > 0) {
        options.requested_mode = _requested_mode;
    }

    const _input_handling = std.mem.span(input_handling);

    if (std.mem.eql(u8, @tagName(operation.InputHandling.exact), _input_handling)) {
        options.input_handling = operation.InputHandling.exact;
    } else if (std.mem.eql(u8, @tagName(operation.InputHandling.fuzzy), _input_handling)) {
        options.input_handling = operation.InputHandling.fuzzy;
    } else if (std.mem.eql(u8, @tagName(operation.InputHandling.ignore), _input_handling)) {
        options.input_handling = operation.InputHandling.ignore;
    }

    options.retain_input = retain_input;
    options.retain_trailing_prompt = retain_trailing_prompt;

    return options;
}

pub fn SendPromptedInputOptionsFromArgs(
    cancel: *bool,
    hidden_response: bool,
    abort_input: [*c]const u8,
    requested_mode: [*c]const u8,
    input_handling: [*c]const u8,
    retain_trailing_prompt: bool,
) operation.SendPromptedInputOptions {
    var options = operation.SendPromptedInputOptions{
        .cancel = cancel,
    };

    const _requested_mode = std.mem.span(requested_mode);
    if (_requested_mode.len > 0) {
        options.requested_mode = _requested_mode;
    }

    const _input_handling = std.mem.span(input_handling);

    if (std.mem.eql(u8, @tagName(operation.InputHandling.exact), _input_handling)) {
        options.input_handling = operation.InputHandling.exact;
    } else if (std.mem.eql(u8, @tagName(operation.InputHandling.fuzzy), _input_handling)) {
        options.input_handling = operation.InputHandling.fuzzy;
    } else if (std.mem.eql(u8, @tagName(operation.InputHandling.ignore), _input_handling)) {
        options.input_handling = operation.InputHandling.ignore;
    }

    options.hidden_response = hidden_response;
    options.retain_trailing_prompt = retain_trailing_prompt;
    options.abort_input = std.mem.span(abort_input);

    return options;
}
