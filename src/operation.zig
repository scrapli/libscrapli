const mode = @import("mode.zig");

pub const OpenOptions = struct {
    cancel: ?*bool,
};

pub const CloseOptions = struct {
    cancel: ?*bool,
};

pub const GetPromptOptions = struct {
    cancel: ?*bool,
};

pub const InputHandling = enum {
    Exact,
    Fuzzy,
    Ignore,
};

pub const SendInputOptions = struct {
    cancel: ?*bool,

    // the mode (formerly "privilege level") to send the input at
    requested_mode: []const u8,
    // how to handle the input -- do we ensure we read it off the channel before sending a return
    // (default), do we fuzzily read it before sending a return, or do we just ship it
    input_handling: InputHandling,

    // retain the initial prompt and input, default=false
    retain_input: bool,
    // retain the prompt shown after the input, default=false.
    retain_trailing_prompt: bool,

    // stop on any indicated failure (default) or continue just shipping inputs. only relevant
    // when executing a plural send inputS operation of course.
    stop_on_indicated_failure: bool,
};

pub const SendPromptedInputOptions = struct {
    cancel: ?*bool,

    // the mode (formerly "privilege level") to send the input at
    requested_mode: []const u8,
    // how to handle the input -- do we ensure we read it off the channel before sending a return
    // (default), do we fuzzily read it before sending a return, or do we just ship it
    input_handling: InputHandling,

    hidden_response: bool,

    // retain the prompt shown after the input, default=false.
    retain_trailing_prompt: bool,

    // input to send to abort the SendPromptedInput if things timeout or are cancelled
    abort_input: []const u8,
};

pub const EnterModeOptions = struct {
    cancel: ?*bool,
};

pub fn NewOpenOptions() OpenOptions {
    return OpenOptions{
        .cancel = null,
    };
}

pub fn NewCloseOptions() CloseOptions {
    return CloseOptions{
        .cancel = null,
    };
}

pub fn NewGetPromptOptions() GetPromptOptions {
    return GetPromptOptions{
        .cancel = null,
    };
}

pub fn NewSendInputOptions() SendInputOptions {
    return SendInputOptions{
        .cancel = null,
        .requested_mode = mode.default_mode,
        .input_handling = InputHandling.Fuzzy,
        .retain_input = false,
        .retain_trailing_prompt = false,
        .stop_on_indicated_failure = true,
    };
}

pub fn NewSendPromptedInputOptions() SendPromptedInputOptions {
    return SendPromptedInputOptions{
        .cancel = null,
        .requested_mode = mode.default_mode,
        .input_handling = InputHandling.Fuzzy,
        .hidden_response = false,
        .retain_trailing_prompt = false,
        .abort_input = "",
    };
}

pub fn NewEnterModeOptions() EnterModeOptions {
    return EnterModeOptions{
        .cancel = null,
    };
}
