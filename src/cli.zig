const std = @import("std");
const logging = @import("logging.zig");
const session = @import("session.zig");
const auth = @import("auth.zig");
const transport = @import("transport.zig");
const platform = @import("cli-platform.zig");
const operation = @import("cli-operation.zig");
const mode = @import("cli-mode.zig");
const result = @import("cli-result.zig");
const errors = @import("errors.zig");

const default_ssh_port: u16 = 22;
const default_telnet_port: u16 = 23;

pub const DeinitCallback = struct {
    f: *const fn (*anyopaque) void,
    context: *anyopaque,
};

pub const DefinitionSource = union(enum) {
    string: []const u8,
    file: []const u8,
    definition: *platform.Definition,
};

pub const Config = struct {
    definition: DefinitionSource,
    logger: ?logging.Logger = null,
    port: ?u16 = null,
    auth: auth.OptionsInputs = .{},
    session: session.OptionsInputs = .{},
    transport: transport.OptionsInputs = .{ .bin = .{} },
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
    log: logging.Logger,
    definition: *platform.Definition,
    host: []const u8,
    port: u16,
    options: *Options,
    session: *session.Session,
    current_mode: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        host: []const u8,
        config: Config,
    ) !*Driver {
        const opts = try Options.init(allocator, config);
        errdefer opts.deinit();

        const log = opts.logger orelse logging.Logger{
            .allocator = allocator,
            .f = logging.noopLogf,
        };

        const definition = switch (config.definition) {
            .string => |d| try platform.YamlDefinition.ToDefinition(
                allocator,
                .{
                    .string = d,
                },
            ),
            .file => |d| try platform.YamlDefinition.ToDefinition(
                allocator,
                .{
                    .file = d,
                },
            ),
            .definition => |d| d,
        };

        const d = try allocator.create(Driver);

        d.* = Driver{
            .allocator = allocator,
            .log = log,
            .definition = definition,
            .host = host,
            .port = 0,
            .options = opts,
            .session = try session.Session.init(
                allocator,
                log,
                definition.prompt_pattern,
                opts.session,
                opts.auth,
                opts.transport,
            ),
            .current_mode = mode.unknown_mode,
        };

        if (opts.port == null) {
            switch (opts.transport.*) {
                transport.Kind.bin, transport.Kind.ssh2, transport.Kind.test_ => {
                    d.port = default_ssh_port;
                },
                transport.Kind.telnet => {
                    d.port = default_telnet_port;
                },
            }
        } else {
            d.port = opts.port.?;
        }

        return d;
    }

    pub fn deinit(self: *Driver) void {
        self.session.deinit();
        self.definition.deinit();
        self.options.deinit();
        self.allocator.destroy(self);
    }

    pub fn NewResult(
        self: *Driver,
        allocator: std.mem.Allocator,
        operation_kind: operation.Kind,
    ) !*result.Result {
        return result.Result.init(
            allocator,
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
        var res = try self.NewResult(
            allocator,
            operation.Kind.open,
        );
        errdefer res.deinit();

        try res.record(
            "", // no "input" for opening
            try self.session.open(
                allocator,
                self.host,
                self.port,
                options.cancel,
            ),
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

        if (self.definition.on_open_callback != null or
            self.definition.bound_on_open_callback != null)
        {
            self.log.info("on open callback set, executing...", .{});

            if (self.definition.on_open_callback != null) {
                try res.recordExtend(
                    try self.definition.on_open_callback.?(
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
        var res = try self.NewResult(
            allocator,
            operation.Kind.open,
        );
        errdefer res.deinit();

        var op_buf = std.ArrayList(u8).init(allocator);
        defer op_buf.deinit();

        if (self.definition.on_close_callback != null or
            self.definition.bound_on_close_callback != null)
        {
            self.log.info("on close callback set, executing...", .{});

            if (self.definition.on_open_callback != null) {
                try res.recordExtend(
                    try self.definition.on_close_callback.?(
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
        self.log.info("requested getPrompt", .{});

        var res = try self.NewResult(
            allocator,
            operation.Kind.get_prompt,
        );
        errdefer res.deinit();

        try res.record(
            "",
            try self.session.getPrompt(allocator, options),
        );

        return res;
    }

    pub fn enterMode(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.EnterModeOptions,
    ) anyerror!*result.Result {
        self.log.info(
            "requested enterMode to mode '{s}', current mode '{s}'",
            .{ options.requested_mode, self.current_mode },
        );

        if (!self.definition.modes.contains(options.requested_mode)) {
            self.log.info(
                "no mode '{s}' in definition",
                .{self.current_mode},
            );

            return errors.ScrapliError.UnsupportedOperation;
        }

        var res = try self.NewResult(
            allocator,
            operation.Kind.enter_mode,
        );
        errdefer res.deinit();

        if (std.mem.eql(u8, self.current_mode, options.requested_mode)) {
            // even though its a noop, record a result so we know how long it took and such
            // try res.record("", [2][]const u8{ "", "" });
            // std.debug.print("res start/end > {d} {d}\n", .{ res.start_time_ns, res.splits_ns.items[0] });

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
            self.log.critical(
                "failed determining prompt from '{s}' | {d}\n",
                .{
                    res.results.items[0],
                    res.results.items[0],
                },
            );

            return err;
        };

        if (std.mem.eql(u8, self.current_mode, options.requested_mode)) {
            return res;
        }

        var visited = std.StringHashMap(bool).init(self.allocator);
        defer visited.deinit();

        const steps = try mode.getPathToMode(
            self.allocator,
            self.definition.modes,
            self.current_mode,
            options.requested_mode,
            &visited,
        );
        defer steps.deinit();

        for (0.., steps.items) |step_idx, step| {
            if (step_idx == steps.items.len - 1) {
                break;
            }

            const step_mode = self.definition.modes.get(step);
            if (step_mode == null) {
                return errors.ScrapliError.UnknownMode;
            }

            const next_mode_name = steps.items[step_idx + 1];

            const next_operation = step_mode.?.accessible_modes.get(next_mode_name);
            if (next_operation == null) {
                return errors.ScrapliError.UnknownMode;
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
                                "prompted input requested to change to mode '{s}', but no response found, trying standard send input",
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
        var res = try self.NewResult(
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
            options.input,
            try self.session.sendInput(allocator, options),
        );

        return res;
    }

    pub fn sendInputs(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.SendInputsOptions,
    ) !*result.Result {
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

        var res = try self.NewResult(
            allocator,
            operation.Kind.send_input,
        );
        errdefer res.deinit();

        for (options.inputs) |input| {
            try res.record(
                input,
                try self.session.sendInput(
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
        var res = try self.NewResult(
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
            options.input,
            try self.session.sendPromptedInput(
                allocator,
                options,
            ),
        );

        return res;
    }

    pub fn readWithCallbacks(
        self: *Driver,
    ) void {
        // TODO obviuosly :)
        _ = self;
    }
};
