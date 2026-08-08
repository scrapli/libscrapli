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

/// Return SendInputsOptions from ffi provided arguments. The inputs arrive packed back-to-back
/// w/ a lens array to slice them apart (same shape the fetch side uses for results) -- each
/// input is duped into an owned slice-of-slices that freeOwnedStrings knows how to clean up.
pub fn sendInputsOptionsFromArgs(
    allocator: std.mem.Allocator,
    cancel: *bool,
    inputs: []const u8,
    input_lens: []const u64,
    requested_mode: [*c]const u8,
    input_handling: ?*u8,
    retain_input: bool,
    retain_trailing_prompt: bool,
    stop_on_indicated_failure: bool,
) !operation.SendInputsOptions {
    const owned_inputs = try allocator.alloc([]const u8, input_lens.len);

    var owned_inputs_adopted: bool = false;
    var owned_inputs_populated: usize = 0;

    errdefer {
        if (!owned_inputs_adopted) {
            for (owned_inputs[0..owned_inputs_populated]) |owned_input| {
                allocator.free(owned_input);
            }

            allocator.free(owned_inputs);
        }
    }

    var cur: usize = 0;

    for (0.., input_lens) |idx, input_len| {
        const l: usize = @intCast(input_len);

        if (l > inputs.len - cur) {
            // lens claim more content than the packed buffer actually holds
            return error.LengthMismatch;
        }

        owned_inputs[idx] = try allocator.dupe(u8, inputs[cur..][0..l]);
        owned_inputs_populated += 1;

        cur += l;
    }

    var options = operation.SendInputsOptions{
        .cancel = cancel,
        .inputs = owned_inputs,
        .retain_input = retain_input,
        .retain_trailing_prompt = retain_trailing_prompt,
        .stop_on_indicated_failure = stop_on_indicated_failure,
    };

    owned_inputs_adopted = true;

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
