const std = @import("std");

const auth = @import("auth.zig");
const bytes = @import("bytes.zig");
const bytes_check = @import("bytes-check.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const mode = @import("cli-mode.zig");
const operation = @import("cli-operation.zig");
const platform = @import("cli-platform.zig");
const re = @import("re.zig");
const result = @import("cli-result.zig");
const session = @import("session.zig");
const transport = @import("transport.zig");

const default_ssh_port: u16 = 22;
const default_telnet_port: u16 = 23;

pub const DefinitionSource = union(enum) {
    string: []const u8,
    file: []const u8,
    definition: *platform.Definition,
};

pub const Config = struct {
    logger: ?logging.Logger = null,
    definition: DefinitionSource,
    port: ?u16 = null,
    auth: auth.OptionsInputs = .{},
    session: session.OptionsInputs = .{},
    transport: transport.OptionsInputs = .{
        .bin = .{},
    },
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    logger: ?logging.Logger,
    port: ?u16,
    auth: *auth.Options,
    session: *session.Options,
    transport: *transport.Options,

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Options {
        const o = try allocator.create(Options);
        errdefer allocator.destroy(o);

        o.* = Options{
            .allocator = allocator,
            .logger = config.logger,
            .port = config.port,
            .auth = try auth.Options.init(allocator, config.auth),
            .session = try session.Options.init(allocator, config.session),
            .transport = try transport.Options.init(
                allocator,
                config.transport,
            ),
        };

        return o;
    }

    pub fn deinit(self: *Options) void {
        self.auth.deinit();
        self.session.deinit();
        self.transport.deinit();
        self.allocator.destroy(self);
    }
};

pub const Driver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log: logging.Logger,
    definition: *platform.Definition,
    host: []const u8,
    port: u16,
    options: *Options,
    session: *session.Session,
    current_mode: []const u8 = mode.unknown_mode,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        host: []const u8,
        config: Config,
    ) !*Driver {
        const opts = try Options.init(allocator, config);
        errdefer opts.deinit();

        const log = opts.logger orelse logging.Logger{
            .allocator = allocator,
        };

        logging.traceWithSrc(log, @src(), "cli.Driver initializing", .{});

        const definition = switch (config.definition) {
            .string => |d| try platform.YamlDefinition.toDefinition(
                allocator,
                io,
                .{
                    .string = d,
                },
            ),
            .file => |d| try platform.YamlDefinition.toDefinition(
                allocator,
                io,
                .{
                    .file = d,
                },
            ),
            .definition => |d| d,
        };

        const d = try allocator.create(Driver);

        d.* = Driver{
            .allocator = allocator,
            .io = io,
            .log = log,
            .definition = definition,
            .host = host,
            .port = 0,
            .options = opts,
            .session = try session.Session.init(
                allocator,
                io,
                log,
                definition.prompt_pattern,
                opts.session,
                opts.auth,
                opts.transport,
            ),
        };

        if (opts.port == null) {
            switch (opts.transport.*) {
                transport.Kind.telnet => {
                    d.port = default_telnet_port;
                },
                else => {
                    d.port = default_ssh_port;
                },
            }
        } else {
            d.port = opts.port.?;
        }

        return d;
    }

    pub fn deinit(self: *Driver) void {
        logging.traceWithSrc(self.log, @src(), "cli.Driver deinitializing", .{});

        self.session.deinit();
        self.definition.deinit();
        self.options.deinit();
        self.allocator.destroy(self);
    }

    pub fn newResult(
        self: *Driver,
        allocator: std.mem.Allocator,
        operation_kind: operation.Kind,
    ) !*result.Result {
        self.log.debug(
            "cli.Driver creating new Result object for operation {s}",
            .{@tagName(operation_kind)},
        );

        return result.Result.init(
            allocator,
            self.io,
            self.host,
            self.port,
            operation_kind,
            self.definition.failure_indicators,
        );
    }

    pub fn open(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.OpenOptions,
    ) !*result.Result {
        self.log.info("cli.Driver open requested", .{});

        var res = try self.newResult(
            allocator,
            operation.Kind.open,
        );
        errdefer res.deinit();

        try res.record(
            .{
                .rets = try self.session.open(
                    allocator,
                    self.host,
                    self.port,
                    options.cancel,
                ),
            },
        );

        // getting prompt also ensures we vacuum up anything in the buffer from after login (matters
        // for in channel auth stuff). we *dont* try to acquire default priv mode because there may
        // be things in on open that need to happen first, so let that do that!
        try res.recordExtend(
            try self.getPrompt(
                allocator,
                .{
                    .cancel = options.cancel,
                },
            ),
        );

        if (self.definition.onOpenCallback != null or
            self.definition.bound_on_open_callback != null)
        {
            self.log.info("cli.Driver open: on open callback set, executing...", .{});

            if (self.definition.onOpenCallback) |cb| {
                try res.recordExtend(
                    try cb(
                        self,
                        allocator,
                        options.cancel,
                    ),
                );
            } else {
                try res.recordExtend(
                    try self.definition.bound_on_open_callback.?.callback(
                        allocator,
                        self,
                        options.cancel,
                    ),
                );
            }
        }

        return res;
    }

    pub fn close(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CloseOptions,
    ) !*result.Result {
        self.log.info("cli.Driver close requested", .{});

        var res = try self.newResult(
            allocator,
            operation.Kind.open,
        );
        errdefer res.deinit();

        var op_buf = std.array_list.Managed(u8).init(allocator);
        defer op_buf.deinit();

        if (self.definition.onCloseCallback != null or
            self.definition.bound_on_close_callback != null)
        {
            self.log.info("cli.Driver close: on close callback set, executing...", .{});

            if (self.definition.onCloseCallback) |cb| {
                try res.recordExtend(
                    try cb(
                        self,
                        allocator,
                        options.cancel,
                    ),
                );
            } else {
                try res.recordExtend(
                    try self.definition.bound_on_close_callback.?.callback(
                        allocator,
                        self,
                        options.cancel,
                    ),
                );
            }
        }

        try self.session.close();

        return res;
    }

    pub fn getPrompt(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.GetPromptOptions,
    ) !*result.Result {
        self.log.info("cli.Driver getPrompt requested", .{});

        var res = try self.newResult(
            allocator,
            operation.Kind.get_prompt,
        );
        errdefer res.deinit();

        try res.record(
            .{
                .rets = try self.session.getPrompt(allocator, options),
            },
        );

        return res;
    }

    pub fn enterMode(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.EnterModeOptions,
    ) anyerror!*result.Result {
        self.log.info("cli.Driver enterMode requested", .{});
        self.log.debug(
            "cli.Driver enterMode: mode '{s}', current mode '{s}'",
            .{ options.requested_mode, self.current_mode },
        );

        if (!self.definition.modes.contains(options.requested_mode)) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Operation,
                @src(),
                self.log,
                "cli.Driver no mode '{s}' in definition",
                .{self.current_mode},
            );
        }

        var res = try self.newResult(
            allocator,
            operation.Kind.enter_mode,
        );
        errdefer res.deinit();

        if (std.mem.eql(u8, self.current_mode, options.requested_mode)) {
            return res;
        }

        try res.recordExtend(
            try self.getPrompt(
                allocator,
                .{
                    .cancel = options.cancel,
                },
            ),
        );

        self.current_mode = mode.determineMode(
            self.definition.modes,
            res.results.items[0],
        ) catch |err| {
            return errors.wrapCriticalError(
                err,
                @src(),
                self.log,
                "cli.Driver enterMode: failed determining prompt from '{s}' | {X}",
                .{
                    res.results.items[0],
                    res.results.items[0],
                },
            );
        };

        if (std.mem.eql(u8, self.current_mode, options.requested_mode)) {
            self.log.info(
                "cli.Driver enterMode: current mode is requested mode, nothing to do",
                .{},
            );

            return res;
        }

        var visited = std.StringHashMap(bool).init(self.allocator);
        defer visited.deinit();

        var steps = try mode.getPathToMode(
            self.allocator,
            self.definition.modes,
            self.current_mode,
            options.requested_mode,
            &visited,
        );
        defer steps.deinit(self.allocator);

        for (0.., steps.items) |step_idx, step| {
            self.log.debug(
                "cli.Driver enterMode: determined next step to requested mode '{s}' is: '{s}'",
                .{ options.requested_mode, step },
            );

            if (step_idx == steps.items.len - 1) {
                break;
            }

            const step_mode = self.definition.modes.get(step);
            if (step_mode == null) {
                return errors.wrapCriticalError(
                    errors.ScrapliError.Operation,
                    @src(),
                    self.log,
                    "cli.Driver enterMode: no mode '{s}' in definition",
                    .{step},
                );
            }

            const next_mode_name = steps.items[step_idx + 1];

            const next_operation = step_mode.?.accessible_modes.get(next_mode_name);
            if (next_operation == null) {
                return errors.wrapCriticalError(
                    errors.ScrapliError.Operation,
                    @src(),
                    self.log,
                    "cli.Driver enterMode: mode '{s}' not accessible from current mode '{s}'",
                    .{ next_mode_name, self.current_mode },
                );
            }

            for (next_operation.?) |op| {
                switch (op) {
                    .send_input => {
                        try res.recordExtend(
                            try self.sendInput(
                                allocator,
                                .{
                                    .cancel = options.cancel,
                                    .input = op.send_input.send_input.input,
                                    .requested_mode = self.current_mode,
                                    .retain_input = true,
                                    .retain_trailing_prompt = true,
                                },
                            ),
                        );
                    },
                    .send_prompted_input => {
                        var response: []const u8 = "";

                        if (self.options.auth.resolveAuthValue(
                            op.send_prompted_input.send_prompted_input.response,
                        )) |resolved_response| {
                            response = resolved_response;
                        } else |err| switch (err) {
                            else => {},
                        }

                        if (response.len == 0) {
                            // no "response" (usually "enable"/escalation type password), so we will
                            // log it and just try a send input rather than "prompted" input
                            self.log.warn(
                                "cli.Driver enterMode: prompted input requested to change to  " ++
                                    "mode '{s}', but no response found, trying standard send input",
                                .{options.requested_mode},
                            );

                            try res.recordExtend(
                                try self.sendInput(
                                    allocator,
                                    .{
                                        .cancel = options.cancel,
                                        .input = op.send_prompted_input.send_prompted_input.input,
                                        .requested_mode = self.current_mode,
                                        .retain_input = true,
                                        .retain_trailing_prompt = true,
                                    },
                                ),
                            );
                        } else {
                            try res.recordExtend(
                                try self.sendPromptedInput(
                                    allocator,
                                    .{
                                        .cancel = options.cancel,
                                        .input = op.send_prompted_input.send_prompted_input.input,
                                        .prompt_exact = op.send_prompted_input.send_prompted_input.prompt_exact,
                                        .prompt_pattern = op.send_prompted_input.send_prompted_input.prompt_pattern,
                                        .response = response,
                                        .requested_mode = self.current_mode,
                                        .retain_trailing_prompt = true,
                                    },
                                ),
                            );
                        }
                    },
                }
            }
        }

        self.current_mode = self.definition.modes.getKey(options.requested_mode).?;

        return res;
    }

    pub fn sendInput(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.SendInputOptions,
    ) !*result.Result {
        self.log.info("cli.Driver sendInput requested", .{});
        self.log.debug(
            "cli.Driver sendInput: input '{s}'",
            .{options.input},
        );

        var res = try self.newResult(
            allocator,
            operation.Kind.send_input,
        );
        errdefer res.deinit();

        var target_mode = options.requested_mode;

        if (std.mem.eql(u8, target_mode, mode.default_mode)) {
            target_mode = self.definition.default_mode;
        }

        if (!std.mem.eql(u8, target_mode, self.current_mode)) {
            const ret = try self.enterMode(
                allocator,
                .{
                    .cancel = options.cancel,
                    .requested_mode = target_mode,
                },
            );
            ret.deinit();
        }

        try res.record(
            .{
                .input = options.input,
                .rets = try self.session.sendInput(allocator, options),
            },
        );

        return res;
    }

    pub fn sendInputs(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.SendInputsOptions,
    ) !*result.Result {
        self.log.info("cli.Driver sendInputs requested", .{});
        self.log.debug(
            "cli.Driver sendInputs: inputs '{any}'",
            .{options.inputs},
        );

        var target_mode = options.requested_mode;

        if (std.mem.eql(u8, target_mode, mode.default_mode)) {
            target_mode = self.definition.default_mode;
        }

        if (!std.mem.eql(u8, target_mode, self.current_mode)) {
            const ret = try self.enterMode(
                allocator,
                .{
                    .cancel = options.cancel,
                    .requested_mode = target_mode,
                },
            );
            ret.deinit();
        }

        var res = try self.newResult(
            allocator,
            operation.Kind.send_inputs,
        );
        errdefer res.deinit();

        for (options.inputs) |input| {
            try res.record(
                .{
                    .input = input,
                    .rets = try self.session.sendInput(
                        allocator,
                        .{
                            .cancel = options.cancel,
                            .input = input,
                            .requested_mode = options.requested_mode,
                            .input_handling = options.input_handling,
                            .retain_input = options.retain_input,
                            .retain_trailing_prompt = options.retain_trailing_prompt,
                        },
                    ),
                },
            );

            if (options.stop_on_indicated_failure and res.result_failure_indicated) {
                return res;
            }
        }

        return res;
    }

    pub fn sendPromptedInput(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.SendPromptedInputOptions,
    ) !*result.Result {
        self.log.info("cli.Driver sendPromptedInput requested", .{});
        self.log.debug(
            "cli.Driver sendPromptedInput: input '{s}', response '{s}'",
            .{ options.input, options.response },
        );

        var res = try self.newResult(
            allocator,
            operation.Kind.send_prompted_input,
        );
        errdefer res.deinit();

        var target_mode = options.requested_mode;

        if (std.mem.eql(u8, target_mode, mode.default_mode)) {
            target_mode = self.definition.default_mode;
        }

        if (!std.mem.eql(u8, target_mode, self.current_mode)) {
            const ret = try self.enterMode(
                allocator,
                .{
                    .cancel = options.cancel,
                    .requested_mode = target_mode,
                },
            );
            ret.deinit();
        }

        try res.record(
            .{
                .input = options.input,
                .rets = try self.session.sendPromptedInput(
                    allocator,
                    options,
                ),
            },
        );

        return res;
    }

    // safely reads any bytes from the session with the deafult timeout handling. "nicer" than just
    // directly reading from the session since timeouts are handled and ascii/ansi things are
    // stripped if present, however no whitespace is trimmed! this is because we dont want to chomp
    // off a newline that actually matters to output, and since we are not reading to "well known"
    // places (i.e. the next prompt) we have no idea what we've read so we better not faff w/ it.
    pub fn readAny(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.ReadAnyOptions,
    ) !*result.Result {
        self.log.info("cli.Driver readAny requested", .{});

        var res = try self.newResult(
            allocator,
            operation.Kind.read_any,
        );
        errdefer res.deinit();

        try res.record(
            .{
                .rets = try self.session.readAny(allocator, options),
                .trim_processed = false,
            },
        );

        return res;
    }

    fn innerReadWithCallbacks(
        self: *Driver,
        timer: *std.time.Timer,
        cancel: ?*bool,
        callbacks: []const operation.ReadCallback,
        bufs: *bytes.ProcessedBuf,
        buf_pos: usize,
        triggered_callbacks: *std.array_list.Managed([]const u8),
    ) !void {
        while (true) {
            _ = try self.session.readTimeout(
                timer,
                cancel,
                bytes_check.nonZeroBuf,
                .{},
                bufs,
            );

            for (callbacks) |callback| {
                self.log.debug(
                    "cli.Driver readWithCallbacks: checking if callback '{s}' should execute " ++
                        "based on current buffer '{s}'",
                    .{
                        callback.options.name,
                        bufs.processed.items[buf_pos..],
                    },
                );

                const execute = readCallbackShouldExecute(
                    // we look from the last "pos" -> the end
                    bufs.processed.items[buf_pos..],
                    callback.options.name,
                    callback.options.contains,
                    callback.options.contains_pattern,
                    callback.options.not_contains,
                    callback.options.only_once,
                    triggered_callbacks,
                ) catch |err| {
                    return errors.wrapCriticalError(
                        err,
                        @src(),
                        self.log,
                        "cli.Driver readWithCallbacks: failed compling contains pattern '{s}'",
                        .{callback.options.contains_pattern},
                    );
                };

                if (!execute) {
                    self.log.debug(
                        "cli.Driver readWithCallbacks: callback '{s}' skipped...",
                        .{
                            callback.options.name,
                        },
                    );

                    continue;
                }

                self.log.debug(
                    "cli.Driver readWithCallbacks: callback '{s}' matched, executing...",
                    .{callback.options.name},
                );

                try callback.callback(self);

                if (callback.options.completes) {
                    self.log.debug(
                        "cli.Driver readWithCallbacks: callback '{s}' completes...",
                        .{
                            callback.options.name,
                        },
                    );

                    return;
                }

                if (callback.options.reset_timer) {
                    timer.reset();
                }

                try triggered_callbacks.append(callback.options.name);

                return self.innerReadWithCallbacks(
                    timer,
                    cancel,
                    callbacks,
                    bufs,
                    // pass the end of the current buf so we dont re-read old stuff
                    bufs.processed.items.len,
                    triggered_callbacks,
                );
            }
        }
    }

    pub fn readWithCallbacks(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.ReadWithCallbacksOptions,
    ) !*result.Result {
        self.log.info("cli.Driver readWithCallbacks requested", .{});
        self.log.debug(
            "cli.Driver readWithCallbacks: initial_input '{s}'",
            .{options.initial_input},
        );

        var res = try self.newResult(
            allocator,
            operation.Kind.read_with_callbacks,
        );
        errdefer res.deinit();

        var t = try std.time.Timer.start();

        if (options.initial_input) |initial_input| {
            try self.session.writeAndReturn(initial_input, false);
        }

        var bufs = bytes.ProcessedBuf.init(allocator);
        defer bufs.deinit();

        var triggered_callbacks = std.array_list.Managed([]const u8).init(allocator);
        defer triggered_callbacks.deinit();

        try self.innerReadWithCallbacks(
            &t,
            options.cancel,
            options.callbacks,
            &bufs,
            0,
            &triggered_callbacks,
        );

        try res.record(
            .{
                .input = options.initial_input orelse "",
                .rets = try bufs.toOwnedSlices(),
                // this may be the only place we *dont* want to trim whitespace
                // .trim_processed = false,
            },
        );

        return res;
    }
};

pub fn readCallbackShouldExecute(
    buf: []const u8,
    name: []const u8,
    contains: ?[]const u8,
    contains_pattern: ?[]const u8,
    not_contains: ?[]const u8,
    only_once: bool,
    triggered_callbacks: *std.ArrayList([]const u8),
) !bool {
    if (only_once) {
        var skip = false;
        for (triggered_callbacks.items) |tcb| {
            if (std.mem.eql(u8, tcb, name)) {
                skip = true;
                break;
            }
        }

        if (skip) {
            return false;
        }
    }

    var callback_contains_or_pattern_matches = false;

    if (contains) |c| {
        if (std.mem.indexOf(u8, buf, c) != null) {
            callback_contains_or_pattern_matches = true;
        }
    } else if (contains_pattern) |cp| {
        const compiled_cp = re.pcre2Compile(cp);
        if (compiled_cp == null) {
            return errors.ScrapliError.Operation;
        }

        const match = try re.pcre2Find(
            compiled_cp.?,
            buf,
        );
        if (match != null) {
            callback_contains_or_pattern_matches = true;
        }
    }

    if (!callback_contains_or_pattern_matches) {
        return false;
    }

    if (not_contains) |nc| {
        // not contains applies regardless of string or pattern containment check
        if (std.mem.indexOf(u8, buf, nc) != null) {
            return false;
        }
    }

    return true;
}

test "readCallbackShouldExecute" {
    const cases = [_]struct {
        name: []const u8,
        buf: []const u8,
        cb_name: []const u8,
        contains: ?[]const u8 = null,
        contains_pattern: ?[]const u8 = null,
        not_contains: ?[]const u8 = null,
        only_once: bool = false,
        triggered_callbacks: std.ArrayList([]const u8),
        expected: bool,
    }{
        .{
            .name = "no contains match",
            .buf = "foo bar baz",
            .cb_name = "cb1",
            .contains = "bloop",
            .triggered_callbacks = .{},
            .expected = false,
        },
        .{
            .name = "contains match",
            .buf = "foo bar baz",
            .cb_name = "cb1",
            .contains = "bar",
            .triggered_callbacks = .{},
            .expected = true,
        },
        .{
            .name = "contains match but has not contains",
            .buf = "foo bar baz",
            .cb_name = "cb1",
            .contains = "bar",
            .not_contains = "baz",
            .triggered_callbacks = .{},
            .expected = false,
        },
        .{
            .name = "contain pattern match",
            .buf = "foo bar baz",
            .cb_name = "cb1",
            .contains_pattern = "\\sbar\\s",
            .triggered_callbacks = .{},
            .expected = true,
        },
        .{
            .name = "contain pattern match but has not contains",
            .buf = "foo bar baz",
            .cb_name = "cb1",
            .contains_pattern = "\\sbar\\s",
            .not_contains = "baz",
            .triggered_callbacks = .{},
            .expected = false,
        },
    };

    for (cases) |case| {
        var triggered_callbacks = case.triggered_callbacks;

        const actual = try readCallbackShouldExecute(
            @constCast(case.buf),
            case.cb_name,
            case.contains,
            case.contains_pattern,
            case.not_contains,
            case.only_once,
            &triggered_callbacks,
        );

        try std.testing.expectEqual(case.expected, actual);
    }
}
