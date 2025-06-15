const std = @import("std");
const bytes = @import("bytes.zig");
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

pub fn SendInputOptionsFromArgs(
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

pub fn SendPromptedInputOptionsFromArgs(
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

pub fn ReadWithCallbacksOptionsFromArgs(
    cancel: *bool,
    initial_input: [*c]const u8,
    names: [*c]const u8,
    callbacks: [*c]const *const fn () callconv(.C) u8,
    contains: [*c]const u8,
    contains_pattern: [*c]const u8,
    not_contains: [*c]const u8,
    only_once: [*c]const u8,
    reset_timer: [*c]const u8,
    completes: [*c]const u8,
) operation.ReadWithCallbacksOptions {
    var callbacks_slice: [
        operation.max_ffi_read_with_callbacks_callbacks
    ]operation.ReadCallback = undefined;

    var names_iterator = std.mem.splitSequence(
        u8,
        std.mem.span(names),
        bytes.libscrapli_delimiter,
    );

    var callback_count: usize = 0;

    while (names_iterator.next()) |name| {
        callbacks_slice[callback_count] = operation.ReadCallback{
            .options = .{
                .name = name,
            },
            .unbound_callback = callbacks[callback_count],
        };

        callback_count += 1;
    }

    var contains_iterator = std.mem.splitSequence(
        u8,
        std.mem.span(contains),
        bytes.libscrapli_delimiter,
    );

    var idx: usize = 0;

    while (contains_iterator.next()) |contain| {
        if (contain.len > 0) {
            callbacks_slice[idx].options.contains = contain;
        }

        idx += 1;
    }

    var contains_pattern_iterator = std.mem.splitSequence(
        u8,
        std.mem.span(contains_pattern),
        bytes.libscrapli_delimiter,
    );

    idx = 0;

    while (contains_pattern_iterator.next()) |contain_pattern| {
        if (contain_pattern.len > 0) {
            callbacks_slice[idx].options.contains_pattern = contain_pattern;
        }

        idx += 1;
    }

    var not_contains_iterator = std.mem.splitSequence(
        u8,
        std.mem.span(not_contains),
        bytes.libscrapli_delimiter,
    );

    idx = 0;

    while (not_contains_iterator.next()) |not_contain| {
        if (not_contain.len > 0) {
            callbacks_slice[idx].options.not_contains = not_contain;
        }

        idx += 1;
    }

    var only_once_iterator = std.mem.splitSequence(
        u8,
        std.mem.span(only_once),
        bytes.libscrapli_delimiter,
    );

    idx = 0;

    while (only_once_iterator.next()) |once| {
        if (std.mem.eql(u8, once, "true")) {
            callbacks_slice[idx].options.only_once = true;
        }

        idx += 1;
    }

    var reset_timer_iterator = std.mem.splitSequence(
        u8,
        std.mem.span(reset_timer),
        bytes.libscrapli_delimiter,
    );

    idx = 0;

    while (reset_timer_iterator.next()) |reset| {
        if (std.mem.eql(u8, reset, "true")) {
            callbacks_slice[idx].options.reset_timer = true;
        }

        idx += 1;
    }

    var completes_iterator = std.mem.splitSequence(
        u8,
        std.mem.span(completes),
        bytes.libscrapli_delimiter,
    );

    idx = 0;

    while (completes_iterator.next()) |compl| {
        if (std.mem.eql(u8, compl, "true")) {
            callbacks_slice[idx].options.completes = true;
        }

        idx += 1;
    }

    const options = operation.ReadWithCallbacksOptions{
        .cancel = cancel,
        .initial_input = std.mem.span(initial_input),
        .callbacks = &callbacks_slice,
        .callback_count = callback_count,
    };

    return options;
}
