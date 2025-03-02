const std = @import("std");
const logger = @import("logger.zig");
const session = @import("session.zig");
const auth = @import("auth.zig");
const transport = @import("transport.zig");
const transport_bin = @import("transport-bin.zig");
const platform = @import("platform.zig");
const operation = @import("operation.zig");
const mode = @import("mode.zig");
const lookup = @import("lookup.zig");
const result = @import("result.zig");
const platform_yaml = @import("platform-yaml.zig");

const default_ssh_port: u16 = 22;
const default_telnet_port: u16 = 23;

pub const DeinitCallback = struct {
    f: *const fn (*anyopaque) void,
    context: *anyopaque,
};

pub fn NewOptions() Options {
    return Options{
        .variant_name = null,
        .logger = null,
        .port = null,
        .auth = auth.NewOptions(),
        .session = session.NewOptions(),
        .transport = transport_bin.NewOptions(),
    };
}

pub const Options = struct {
    variant_name: ?[]const u8,
    logger: ?logger.Logger,
    port: ?u16,
    auth: auth.Options,
    session: session.Options,
    transport: transport.Options,
};

pub fn NewDriverFromYaml(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    host: []const u8,
    options: Options,
) !*Driver {
    var yaml_definition = try platform_yaml.DefinitionFromFilePath(
        allocator,
        file_path,
        options.variant_name,
    );
    errdefer yaml_definition.deinit();

    var d = try NewDriver(
        allocator,
        host,
        yaml_definition.definition,
        options,
    );

    d.definition_source = yaml_definition;

    return d;
}

pub fn NewDriverFromYamlString(
    allocator: std.mem.Allocator,
    definition_string: []const u8,
    host: []const u8,
    options: Options,
) !*Driver {
    var yaml_definition = try platform_yaml.DefinitionFromYamlString(
        allocator,
        definition_string,
        options.variant_name,
    );
    errdefer yaml_definition.deinit();

    var d = try NewDriver(
        allocator,
        host,
        yaml_definition.definition,
        options,
    );

    d.definition_source = yaml_definition;

    return d;
}

pub fn NewDriver(
    allocator: std.mem.Allocator,
    host: []const u8,
    definition: platform.Definition,
    options: Options,
) !*Driver {
    const log = options.logger orelse logger.Logger{ .allocator = allocator, .f = logger.noopLogf };

    const sess = try session.NewSession(
        allocator,
        log,
        definition.prompt_pattern,
        options.session,
        options.auth,
        options.transport,
    );

    const d = try allocator.create(Driver);

    d.* = Driver{
        .allocator = allocator,
        .log = log,

        .deinit_callbacks = std.ArrayList(DeinitCallback).init(allocator),

        .definition_source = null,
        .definition = definition,

        .host = host,
        .port = 0,

        .options = options,

        .session = sess,

        .current_mode = mode.unknown_mode,
    };

    if (options.port == null) {
        switch (options.transport) {
            transport.Kind.Bin, transport.Kind.SSH2, transport.Kind.Test => {
                d.port = default_ssh_port;
            },
            transport.Kind.Telnet => {
                d.port = default_telnet_port;
            },
        }
    } else {
        d.port = options.port.?;
    }

    return d;
}

pub const Driver = struct {
    allocator: std.mem.Allocator,
    log: logger.Logger,

    deinit_callbacks: std.ArrayList(DeinitCallback),

    definition_source: ?platform_yaml.DefinitionFromYaml,
    definition: platform.Definition,

    host: []const u8,
    port: u16,

    options: Options,

    session: *session.Session,

    current_mode: []const u8,

    pub fn init(self: *Driver) !void {
        self.deinit_callbacks = std.ArrayList(DeinitCallback).init(self.allocator);

        return self.session.init();
    }

    // lets us register things that should be deinit'd when the driver is deinit'd
    pub fn registerDeinitCallback(
        self: *Driver,
        ptr: anytype,
        comptime deinitFn: fn (arg: @TypeOf(ptr)) void,
    ) !void {
        const Ptr = @TypeOf(ptr);
        const Wrapper = struct {
            fn wrapped(ctx: *anyopaque) void {
                const typed_ptr = @as(Ptr, @ptrFromInt(@intFromPtr(ctx)));
                deinitFn(typed_ptr);
            }
        };

        try self.deinit_callbacks.append(.{
            .f = &Wrapper.wrapped,
            .context = @ptrFromInt(@intFromPtr(ptr)),
        });
    }

    pub fn deinit(self: *Driver) void {
        self.session.deinit();
        self.definition.deinit();

        var i: usize = self.deinit_callbacks.items.len;
        while (i > 0) {
            i -= 1;
            const callback = self.deinit_callbacks.items[i];
            callback.f(callback.context);
        }

        self.deinit_callbacks.deinit();

        if (self.definition_source != null) {
            self.definition_source.?.deinit();
        }

        self.allocator.destroy(self);
    }

    pub fn NewResult(
        self: *Driver,
        allocator: std.mem.Allocator,
        operation_kind: result.OperationKind,
    ) !*result.Result {
        return result.NewResult(
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
        var res = try self.NewResult(allocator, result.OperationKind.Open);
        errdefer res.deinit();

        try res.record(
            "", // no "input" for opening
            try self.session.open(
                allocator,
                self.host,
                self.port,
                options,
            ),
        );

        // getting prompt also ensures we vacuum up anything in the buffer from after login (matters
        // for in channel auth stuff). we *dont* try to acquire default priv mode because there may
        // be things in on open that need to happen first, so let that do that!
        var get_prompt_options = operation.NewGetPromptOptions();
        get_prompt_options.cancel = options.cancel;

        try res.recordExtend(
            try self.getPrompt(
                allocator,
                get_prompt_options,
            ),
        );

        if (self.definition.on_open_callback != null or
            self.definition.bound_on_open_callback != null)
        {
            self.log.info("on open callback set, executing...", .{});

            var on_open_res: ?*result.Result = null;

            if (self.definition.on_open_callback != null) {
                on_open_res = try self.definition.on_open_callback.?(
                    self,
                    allocator,
                    options.cancel,
                );
            } else {
                on_open_res = try self.definition.bound_on_open_callback.?.callback(
                    self.definition.bound_on_open_callback.?.ptr,
                    self,
                    allocator,
                    options.cancel,
                );
            }

            // cant be null if we get here
            try res.recordExtend(on_open_res.?);
        }

        return res;
    }

    pub fn close(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CloseOptions,
    ) !*result.Result {
        var res = try self.NewResult(allocator, result.OperationKind.Open);
        errdefer res.deinit();

        var op_buf = std.ArrayList(u8).init(allocator);
        defer op_buf.deinit();

        if (self.definition.on_close_callback != null or
            self.definition.bound_on_close_callback != null)
        {
            self.log.info("on close callback set, executing...", .{});

            var on_close_res: ?*result.Result = null;

            if (self.definition.on_open_callback != null) {
                on_close_res = try self.definition.on_close_callback.?(
                    self,
                    allocator,
                    options.cancel,
                );
            } else {
                on_close_res = try self.definition.bound_on_close_callback.?.callback(
                    self.definition.bound_on_open_callback.?.ptr,
                    self,
                    allocator,
                    options.cancel,
                );
            }

            // cant be null if we get here
            try res.recordExtend(on_close_res.?);
        }

        self.session.close();

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
            result.OperationKind.GetPrompt,
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
        requested_mode_name: []const u8,
        options: operation.EnterModeOptions,
    ) anyerror!*result.Result {
        self.log.info(
            "requested enterMode to mode '{s}', current mode '{s}'",
            .{ requested_mode_name, self.current_mode },
        );

        var res = try self.NewResult(
            allocator,
            result.OperationKind.EnterMode,
        );
        errdefer res.deinit();

        if (std.mem.eql(u8, self.current_mode, requested_mode_name)) {
            return res;
        }

        var get_prompt_options = operation.NewGetPromptOptions();
        get_prompt_options.cancel = options.cancel;

        try res.recordExtend(
            try self.getPrompt(
                allocator,
                get_prompt_options,
            ),
        );

        self.current_mode = try mode.determineMode(
            self.definition.modes,
            res.results.items[0],
        );

        if (std.mem.eql(u8, self.current_mode, requested_mode_name)) {
            return res;
        }

        var visited = std.StringHashMap(bool).init(self.allocator);
        defer visited.deinit();

        const steps = try mode.getPathToMode(
            self.allocator,
            self.definition.modes,
            self.current_mode,
            requested_mode_name,
            &visited,
        );
        defer steps.deinit();

        for (0.., steps.items) |step_idx, step| {
            if (step_idx == steps.items.len - 1) {
                break;
            }

            const step_mode = self.definition.modes.get(step);
            if (step_mode == null) {
                return error.UnknownMode;
            }

            const next_mode_name = steps.items[step_idx + 1];

            const next_operation = step_mode.?.accessible_modes.get(next_mode_name);
            if (next_operation == null) {
                return error.UnknownMode;
            }

            switch (next_operation.?) {
                .SendInput => {
                    var opts = operation.NewSendInputOptions();

                    opts.cancel = options.cancel;
                    opts.requested_mode = self.current_mode;
                    opts.retain_input = true;
                    opts.retain_trailing_prompt = true;

                    try res.recordExtend(
                        try self.sendInput(
                            allocator,
                            next_operation.?.SendInput.input,
                            opts,
                        ),
                    );
                },
                .SendPromptedInput => {
                    var response: []const u8 = "";

                    if (lookup.resolveValue(
                        self.host,
                        self.port,
                        next_operation.?.SendPromptedInput.response,
                        self.options.auth.lookup_fn,
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
                            .{requested_mode_name},
                        );

                        var opts = operation.NewSendInputOptions();

                        opts.cancel = options.cancel;
                        opts.requested_mode = self.current_mode;
                        opts.retain_input = true;
                        opts.retain_trailing_prompt = true;

                        try res.recordExtend(
                            try self.sendInput(
                                allocator,
                                next_operation.?.SendPromptedInput.input,
                                opts,
                            ),
                        );
                    } else {
                        var opts = operation.NewSendPromptedInputOptions();

                        opts.cancel = options.cancel;
                        opts.requested_mode = self.current_mode;
                        opts.retain_trailing_prompt = true;

                        try res.recordExtend(
                            try self.sendPromptedInput(
                                allocator,
                                next_operation.?.SendPromptedInput.input,
                                next_operation.?.SendPromptedInput.prompt,
                                response,
                                opts,
                            ),
                        );
                    }
                },
            }
        }

        return res;
    }

    pub fn sendInput(
        self: *Driver,
        allocator: std.mem.Allocator,
        input: []const u8,
        options: operation.SendInputOptions,
    ) !*result.Result {
        var res = try self.NewResult(allocator, result.OperationKind.SendInput);
        errdefer res.deinit();

        var target_mode = options.requested_mode;

        if (std.mem.eql(u8, target_mode, mode.default_mode)) {
            target_mode = self.definition.default_mode;
        }

        if (!std.mem.eql(u8, target_mode, self.current_mode)) {
            var opts = operation.NewEnterModeOptions();

            opts.cancel = options.cancel;

            const ret = try self.enterMode(allocator, target_mode, opts);
            ret.deinit();
        }

        try res.record(
            input,
            try self.session.sendInput(allocator, input, options),
        );

        return res;
    }

    pub fn sendInputs(
        self: *Driver,
        allocator: std.mem.Allocator,
        inputs: []const []const u8,
        options: operation.SendInputOptions,
    ) !*result.Result {
        var target_mode = options.requested_mode;

        if (std.mem.eql(u8, target_mode, mode.default_mode)) {
            target_mode = self.definition.default_mode;
        }

        if (!std.mem.eql(u8, target_mode, self.current_mode)) {
            var opts = operation.NewEnterModeOptions();

            opts.cancel = options.cancel;

            const ret = try self.enterMode(allocator, target_mode, opts);
            ret.deinit();
        }

        var res = try self.NewResult(
            allocator,
            result.OperationKind.SendInput,
        );
        errdefer res.deinit();

        for (inputs) |input| {
            try res.record(input, try self.session.sendInput(allocator, input, options));

            if (options.stop_on_indicated_failure and res.result_failure_indicated) {
                return res;
            }
        }

        return res;
    }

    pub fn sendPromptedInput(
        self: *Driver,
        allocator: std.mem.Allocator,
        input: []const u8,
        prompt: []const u8,
        response: []const u8,
        options: operation.SendPromptedInputOptions,
    ) !*result.Result {
        var res = try self.NewResult(allocator, result.OperationKind.SendPromptedInput);
        errdefer res.deinit();

        var target_mode = options.requested_mode;

        if (std.mem.eql(u8, target_mode, mode.default_mode)) {
            target_mode = self.definition.default_mode;
        }

        if (!std.mem.eql(u8, target_mode, self.current_mode)) {
            var opts = operation.NewEnterModeOptions();

            opts.cancel = options.cancel;

            const ret = try self.enterMode(allocator, target_mode, opts);
            ret.deinit();
        }

        try res.record(
            input,
            try self.session.sendPromptedInput(
                allocator,
                input,
                prompt,
                response,
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
