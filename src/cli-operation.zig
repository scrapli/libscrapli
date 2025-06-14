const mode = @import("cli-mode.zig");

pub const Kind = enum {
    open,
    on_open,
    on_close,
    close,
    enter_mode,
    get_prompt,
    send_input,
    send_prompted_input,
};

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

pub const EnterModeOptions = struct {
    cancel: ?*bool = null,
    requested_mode: []const u8,
};

pub const SendInputOptions = struct {
    cancel: ?*bool = null,
    input: []const u8,
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

pub const SendInputsOptions = struct {
    cancel: ?*bool = null,
    inputs: []const []const u8,
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
    input: []const u8,
    prompt_exact: ?[]const u8 = null,
    prompt_pattern: ?[]const u8 = null,
    response: []const u8,
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

pub const ReadCallbackOptions = struct {
    name: []const u8,
    // contains/contains_pattern are mutually exclusive -- if contains is set we use/check that
    contains: ?[]const u8 = null,
    contains_pattern: ?[]const u8 = null,
    // not contains is checked in both string match and pattern match modes
    not_contains: ?[]const u8 = null,
    // trigger this callback only once
    only_once: bool = false,
    // reset the operation timer or no -- for long running things obviously you dont want to just
    // have a "single" operations worht of timer govern what could be a zilliondy callbacks that
    // should run for a long time
    reset_timer: bool = false,
    // indicates we are done with the readWithCallbacks call
    completes: bool = false,
};

pub const ReadWithCallbacksOptions = struct {
    cancel: ?*bool = null,
    initial_input: ?[]const u8 = null,
};
