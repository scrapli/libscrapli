const std = @import("std");
const operation = @import("operation.zig");

pub fn SendInputOptionsFromArgs(
    cancel: *bool,
    requested_mode: [*c]const u8,
    input_handling: [*c]const u8,
    retain_input: bool,
    retain_trailing_prompt: bool,
) operation.SendInputOptions {
    var options = operation.NewSendInputOptions();

    options.cancel = cancel;

    const _requested_mode = std.mem.span(requested_mode);
    if (_requested_mode.len > 0) {
        options.requested_mode = _requested_mode;
    }

    const _input_handling = std.mem.span(input_handling);

    if (std.mem.eql(u8, @tagName(operation.InputHandling.Exact), _input_handling)) {
        options.input_handling = operation.InputHandling.Exact;
    } else if (std.mem.eql(u8, @tagName(operation.InputHandling.Fuzzy), _input_handling)) {
        options.input_handling = operation.InputHandling.Fuzzy;
    } else if (std.mem.eql(u8, @tagName(operation.InputHandling.Ignore), _input_handling)) {
        options.input_handling = operation.InputHandling.Ignore;
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
    var options = operation.NewSendPromptedInputOptions();

    options.cancel = cancel;

    const _requested_mode = std.mem.span(requested_mode);
    if (_requested_mode.len > 0) {
        options.requested_mode = _requested_mode;
    }

    const _input_handling = std.mem.span(input_handling);

    if (std.mem.eql(u8, @tagName(operation.InputHandling.Exact), _input_handling)) {
        options.input_handling = operation.InputHandling.Exact;
    } else if (std.mem.eql(u8, @tagName(operation.InputHandling.Fuzzy), _input_handling)) {
        options.input_handling = operation.InputHandling.Fuzzy;
    } else if (std.mem.eql(u8, @tagName(operation.InputHandling.Ignore), _input_handling)) {
        options.input_handling = operation.InputHandling.Ignore;
    }

    options.hidden_response = hidden_response;
    options.retain_trailing_prompt = retain_trailing_prompt;
    options.abort_input = std.mem.span(abort_input);

    return options;
}
