const mode = @import("mode.zig");

pub const InputHandling = enum {
    exact,
    fuzzy,
    ignore,
};

pub const OpenOptions = struct {
    cancel: ?*bool = null,
};

pub const CloseOptions = struct {
    cancel: ?*bool = null,
};

pub const GetPromptOptions = struct {
    cancel: ?*bool = null,
};

pub const SendInputOptions = struct {
    cancel: ?*bool = null,
    // the mode (formerly "privilege level") to send the input at
    requested_mode: []const u8 = mode.default_mode,
    // how to handle the input -- do we ensure we read it off the channel before sending a return
    // (default), do we fuzzily read it before sending a return, or do we just ship it
    input_handling: InputHandling = .fuzzy,
    // retain the initial prompt and input, default=false
    retain_input: bool = false,
    // retain the prompt shown after the input, default=false.
    retain_trailing_prompt: bool = false,
    // stop on any indicated failure (default) or continue just shipping inputs. only relevant
    // when executing a plural send inputS operation of course.
    stop_on_indicated_failure: bool = true,
};

pub const SendPromptedInputOptions = struct {
    cancel: ?*bool = null,
    // the mode (formerly "privilege level") to send the input at
    requested_mode: []const u8 = mode.default_mode,
    // how to handle the input -- do we ensure we read it off the channel before sending a return
    // (default), do we fuzzily read it before sending a return, or do we just ship it
    input_handling: InputHandling = .fuzzy,
    hidden_response: bool = false,
    // retain the prompt shown after the input, default=false.
    retain_trailing_prompt: bool = false,
    // input to send to abort the SendPromptedInput if things timeout or are cancelled
    abort_input: ?[]const u8 = null,
};

pub const EnterModeOptions = struct {
    cancel: ?*bool = null,
};
