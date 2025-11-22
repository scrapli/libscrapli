const std = @import("std");

const yaml = @import("yaml");

const cli = @import("cli.zig");
const file = @import("file.zig");
const mode = @import("cli-mode.zig");
const operation = @import("cli-operation.zig");
const result = @import("cli-result.zig");
const strings = @import("strings.zig");

pub const OnXCallback = *const fn (
    d: *cli.Driver,
    allocator: std.mem.Allocator,
    cancel: ?*bool,
) anyerror!*result.Result;

// this is uniquely its own thing because modes (which have similar things) dont support
// "enter-mode" because duh.
pub const BoundOnXCallbackInstruction = union(enum) {
    write: struct {
        write: struct {
            input: []const u8,
        },
    },
    enter_mode: struct {
        enter_mode: struct {
            requested_mode: []const u8,
        },
    },
    send_input: struct {
        send_input: struct {
            input: []const u8,
        },
    },
    send_prompted_input: struct {
        send_prompted_input: struct {
            input: []const u8,
            prompt_exact: ?[]const u8 = null,
            prompt_pattern: ?[]const u8 = null,
            response: []const u8,
        },
    },
};

pub const BoundOnXCallback = struct {
    allocator: std.mem.Allocator,
    kind: operation.Kind,
    instructions: []BoundOnXCallbackInstruction,

    pub fn init(
        allocator: std.mem.Allocator,
        kind: operation.Kind,
        instructions: []BoundOnXCallbackInstruction,
    ) !*BoundOnXCallback {
        const cb = try allocator.create(BoundOnXCallback);

        cb.* = BoundOnXCallback{
            .allocator = allocator,
            .kind = kind,
            .instructions = try allocator.alloc(
                BoundOnXCallbackInstruction,
                instructions.len,
            ),
        };

        for (0.., instructions) |idx, instr| {
            switch (instr) {
                .write => {
                    cb.instructions[idx] = BoundOnXCallbackInstruction{
                        .write = .{
                            .write = .{
                                .input = try allocator.dupe(
                                    u8,
                                    instr.write.write.input,
                                ),
                            },
                        },
                    };
                },
                .enter_mode => {
                    cb.instructions[idx] = BoundOnXCallbackInstruction{
                        .enter_mode = .{
                            .enter_mode = .{
                                .requested_mode = try allocator.dupe(
                                    u8,
                                    instr.enter_mode.enter_mode.requested_mode,
                                ),
                            },
                        },
                    };
                },
                .send_input => {
                    cb.instructions[idx] = BoundOnXCallbackInstruction{
                        .send_input = .{
                            .send_input = .{
                                .input = try allocator.dupe(
                                    u8,
                                    instr.send_input.send_input.input,
                                ),
                            },
                        },
                    };
                },
                .send_prompted_input => {
                    var o = BoundOnXCallbackInstruction{
                        .send_prompted_input = .{
                            .send_prompted_input = .{
                                .input = try allocator.dupe(
                                    u8,
                                    instr.send_prompted_input.send_prompted_input.input,
                                ),
                                .response = try allocator.dupe(
                                    u8,
                                    instr.send_prompted_input.send_prompted_input.response,
                                ),
                            },
                        },
                    };

                    if (instr.send_prompted_input.send_prompted_input.prompt_exact) |prompt| {
                        o.send_prompted_input.send_prompted_input.prompt_exact = try allocator.dupe(
                            u8,
                            prompt,
                        );
                    }

                    if (instr.send_prompted_input.send_prompted_input.prompt_pattern) |prompt_pattern| {
                        o.send_prompted_input.send_prompted_input.prompt_pattern = try allocator.dupe(
                            u8,
                            prompt_pattern,
                        );
                    }

                    cb.instructions[idx] = o;
                },
            }
        }

        return cb;
    }

    pub fn deinit(self: *BoundOnXCallback) void {
        for (self.instructions) |instr| {
            switch (instr) {
                .write => {
                    self.allocator.free(instr.write.write.input);
                },
                .enter_mode => {
                    self.allocator.free(instr.enter_mode.enter_mode.requested_mode);
                },
                .send_input => {
                    self.allocator.free(instr.send_input.send_input.input);
                },
                .send_prompted_input => {
                    self.allocator.free(instr.send_prompted_input.send_prompted_input.input);

                    if (instr.send_prompted_input.send_prompted_input.prompt_exact) |prompt| {
                        self.allocator.free(prompt);
                    }

                    if (instr.send_prompted_input.send_prompted_input.prompt_pattern) |prompt_pattern| {
                        self.allocator.free(prompt_pattern);
                    }

                    self.allocator.free(instr.send_prompted_input.send_prompted_input.response);
                },
            }
        }

        self.allocator.free(self.instructions);

        self.allocator.destroy(self);
    }

    pub fn callback(
        self: *BoundOnXCallback,
        allocator: std.mem.Allocator,
        d: *cli.Driver,
        cancel: ?*bool,
    ) !*result.Result {
        const res = try d.newResult(allocator, self.kind);
        errdefer res.deinit();

        for (self.instructions) |instr| {
            switch (instr) {
                .write => {
                    try d.session.writeAndReturn(instr.write.write.input, false);
                },
                .enter_mode => {
                    try res.recordExtend(
                        try d.enterMode(
                            allocator,
                            .{
                                .cancel = cancel,
                                .requested_mode = instr.enter_mode.enter_mode.requested_mode,
                            },
                        ),
                    );
                },
                .send_input => {
                    try res.recordExtend(
                        try d.sendInput(
                            allocator,
                            .{
                                .cancel = cancel,
                                .input = instr.send_input.send_input.input,
                                .retain_input = true,
                                .retain_trailing_prompt = true,
                            },
                        ),
                    );
                },
                .send_prompted_input => {
                    try res.recordExtend(
                        try d.sendPromptedInput(
                            allocator,
                            .{
                                .cancel = cancel,
                                .input = instr.send_prompted_input.send_prompted_input.input,
                                .prompt_exact = instr.send_prompted_input.send_prompted_input.prompt_exact,
                                .prompt_pattern = instr.send_prompted_input.send_prompted_input.prompt_pattern,
                                .response = instr.send_prompted_input.send_prompted_input.response,
                            },
                        ),
                    );
                },
            }
        }

        return res;
    }
};

pub const Options = struct {
    prompt_pattern: []const u8,
    default_mode: []const u8,
    modes: ?[]mode.Options,
    failure_indicators: ?[][]const u8 = null,
    onOpenCallback: ?OnXCallback = null,
    bound_on_open_callback: ?*BoundOnXCallback = null,
    onCloseCallback: ?OnXCallback = null,
    bound_on_close_callback: ?*BoundOnXCallback = null,
    force_in_session_auth: bool = false,
    bypass_in_session_auth: bool = false,
    ntc_templates_platform: ?[]const u8 = null,
    genie_platform: ?[]const u8 = null,
};

pub const Definition = struct {
    allocator: std.mem.Allocator,
    prompt_pattern: []const u8,
    default_mode: []const u8,
    modes: std.StringHashMap(*mode.Mode),
    failure_indicators: std.array_list.Managed([]const u8),
    onOpenCallback: ?OnXCallback,
    // nothing but yaml -> Definition should use bound callbacks, but if you did for some weird
    // reason, Definition expects a heap allocated struct that we will call deinit for (which
    // will destroy that memory)
    bound_on_open_callback: ?*BoundOnXCallback,
    onCloseCallback: ?OnXCallback,
    bound_on_close_callback: ?*BoundOnXCallback,
    force_in_session_auth: bool,
    bypass_in_session_auth: bool,
    ntc_templates_platform: ?[]const u8,
    genie_platform: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, options: Options) !*Definition {
        const d = try allocator.create(Definition);

        d.* = Definition{
            .allocator = allocator,
            .prompt_pattern = try allocator.dupe(u8, options.prompt_pattern),
            .default_mode = options.default_mode,
            .modes = std.StringHashMap(*mode.Mode).init(allocator),
            .failure_indicators = std.array_list.Managed([]const u8).init(allocator),
            .onOpenCallback = options.onOpenCallback,
            .bound_on_open_callback = options.bound_on_open_callback,
            .onCloseCallback = options.onCloseCallback,
            .bound_on_close_callback = options.bound_on_close_callback,
            .force_in_session_auth = options.force_in_session_auth,
            .bypass_in_session_auth = options.bypass_in_session_auth,
            .ntc_templates_platform = if (options.ntc_templates_platform) |s|
                try allocator.dupe(u8, s)
            else
                null,
            .genie_platform = if (options.genie_platform) |s|
                try allocator.dupe(u8, s)
            else
                null,
        };

        if (&d.default_mode[0] != &mode.default_mode[0]) {
            d.default_mode = try d.allocator.dupe(u8, d.default_mode);
        }

        if (options.modes) |modes| {
            for (modes) |m| {
                try d.modes.put(
                    try allocator.dupe(u8, m.name),
                    try mode.Mode.init(allocator, m),
                );
            }
        }

        if (options.failure_indicators) |failure_indicators| {
            for (failure_indicators) |fi| {
                try d.failure_indicators.append(try allocator.dupe(u8, fi));
            }
        }

        return d;
    }

    pub fn deinit(self: *Definition) void {
        self.allocator.free(self.prompt_pattern);

        if (&self.default_mode[0] != &mode.default_mode[0]) {
            self.allocator.free(self.default_mode);
        }

        var mode_iter = self.modes.iterator();

        while (mode_iter.next()) |m| {
            self.allocator.free(m.key_ptr.*);
            m.value_ptr.*.deinit();
        }

        self.modes.deinit();

        for (self.failure_indicators.items) |fi| {
            self.allocator.free(fi);
        }

        self.failure_indicators.deinit();

        if (self.bound_on_open_callback) |cb| {
            cb.deinit();
        }

        if (self.bound_on_close_callback) |cb| {
            cb.deinit();
        }

        if (self.ntc_templates_platform) |s| {
            self.allocator.free(s);
        }

        if (self.genie_platform) |s| {
            self.allocator.free(s);
        }

        self.allocator.destroy(self);
    }
};

pub const YamlSource = union(enum) {
    string: []const u8,
    file: []const u8,
};

pub const YamlDefinition = struct {
    prompt_pattern: []const u8,
    default_mode: []const u8,
    modes: []mode.Options,
    failure_indicators: ?[][]const u8,
    on_open_instructions: ?[]BoundOnXCallbackInstruction,
    on_close_instructions: ?[]BoundOnXCallbackInstruction,
    force_in_session_auth: ?bool,
    bypass_in_session_auth: ?bool,
    ntc_templates_platform: ?[]const u8,
    genie_platform: ?[]const u8,

    pub fn toDefinition(
        allocator: std.mem.Allocator,
        io: std.Io,
        source: YamlSource,
    ) !*Definition {
        var definition_string = switch (source) {
            .string => strings.MaybeHeapString{
                .allocator = null,
                .string = source.string,
            },
            .file => strings.MaybeHeapString{
                .allocator = allocator,
                .string = try file.readFromPath(
                    allocator,
                    io,
                    source.file,
                ),
            },
        };
        defer definition_string.deinit();

        var raw_definition: yaml.Yaml = .{
            .source = definition_string.string,
        };

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        try raw_definition.load(arena.allocator());
        const parsed_definition = try raw_definition.parse(
            arena.allocator(),
            YamlDefinition,
        );

        return Definition.init(
            allocator,
            .{
                .prompt_pattern = parsed_definition.prompt_pattern,
                .default_mode = parsed_definition.default_mode,
                .modes = parsed_definition.modes,
                .failure_indicators = parsed_definition.failure_indicators,
                .bound_on_open_callback = if (parsed_definition.on_open_instructions) |instr|
                    try BoundOnXCallback.init(
                        allocator,
                        operation.Kind.on_open,
                        instr,
                    )
                else
                    null,
                .bound_on_close_callback = if (parsed_definition.on_close_instructions) |instr| try BoundOnXCallback.init(
                    allocator,
                    operation.Kind.on_close,
                    instr,
                ) else null,
                .force_in_session_auth = parsed_definition.force_in_session_auth orelse false,
                .bypass_in_session_auth = parsed_definition.bypass_in_session_auth orelse false,
                .ntc_templates_platform = parsed_definition.ntc_templates_platform,
                .genie_platform = parsed_definition.genie_platform,
            },
        );
    }
};
