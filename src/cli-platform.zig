const std = @import("std");

const yaml = @import("yaml");

const cli = @import("cli.zig");
const file = @import("file.zig");
const mode = @import("cli-mode.zig");
const operation = @import("cli-operation.zig");
const result = @import("cli-result.zig");
const strings = @import("strings.zig");

/// OnXCallback is a type of a on open/close callback.
pub const OnXCallback = *const fn (
    d: *cli.Driver,
    allocator: std.mem.Allocator,
    cancel: ?*bool,
) anyerror!*result.Result;

/// BoundOnXCallbackInstruction is a taggged union of available options that a yaml definition can
/// turn into a on open/close callback. This is uniquely its own thing because modes (which have
/// similar things) dont support "enter-mode" because duh.
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

/// BoundonXCallback is a wrapper for "on x" (open/close) callbacks that gives users a way to sorta
/// kinda have their callback be a method of the cli driver.
pub const BoundOnXCallback = struct {
    allocator: std.mem.Allocator,
    kind: operation.Kind,
    instructions: []BoundOnXCallbackInstruction,

    /// Initialize the bound "on x" (open/close) callback.
    pub fn init(
        allocator: std.mem.Allocator,
        kind: operation.Kind,
        instructions: []BoundOnXCallbackInstruction,
    ) !*BoundOnXCallback {
        const cb = try allocator.create(BoundOnXCallback);
        errdefer allocator.destroy(cb);

        cb.* = BoundOnXCallback{
            .allocator = allocator,
            .kind = kind,
            .instructions = try allocator.alloc(
                BoundOnXCallbackInstruction,
                instructions.len,
            ),
        };
        errdefer allocator.free(cb.instructions);

        var built: usize = 0;
        errdefer for (cb.instructions[0..built]) |built_instr| {
            BoundOnXCallback.freeInstruction(allocator, built_instr);
        };

        for (0.., instructions) |idx, instr| {
            cb.instructions[idx] = try BoundOnXCallback.dupeInstruction(allocator, instr);
            built = idx + 1;
        }

        return cb;
    }

    fn dupeInstruction(
        allocator: std.mem.Allocator,
        instr: BoundOnXCallbackInstruction,
    ) !BoundOnXCallbackInstruction {
        switch (instr) {
            .write => {
                return BoundOnXCallbackInstruction{
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
                return BoundOnXCallbackInstruction{
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
                return BoundOnXCallbackInstruction{
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
                const src = instr.send_prompted_input.send_prompted_input;

                const input = try allocator.dupe(u8, src.input);
                errdefer allocator.free(input);

                const response = try allocator.dupe(u8, src.response);
                errdefer allocator.free(response);

                var o = BoundOnXCallbackInstruction{
                    .send_prompted_input = .{
                        .send_prompted_input = .{
                            .input = input,
                            .response = response,
                        },
                    },
                };

                if (src.prompt_exact) |prompt| {
                    o.send_prompted_input.send_prompted_input.prompt_exact = try allocator.dupe(
                        u8,
                        prompt,
                    );
                }

                errdefer if (o.send_prompted_input.send_prompted_input.prompt_exact) |prompt| {
                    allocator.free(prompt);
                };

                if (src.prompt_pattern) |prompt_pattern| {
                    o.send_prompted_input.send_prompted_input.prompt_pattern = try allocator.dupe(
                        u8,
                        prompt_pattern,
                    );
                }

                return o;
            },
        }
    }

    fn freeInstruction(
        allocator: std.mem.Allocator,
        instr: BoundOnXCallbackInstruction,
    ) void {
        switch (instr) {
            .write => {
                allocator.free(instr.write.write.input);
            },
            .enter_mode => {
                allocator.free(instr.enter_mode.enter_mode.requested_mode);
            },
            .send_input => {
                allocator.free(instr.send_input.send_input.input);
            },
            .send_prompted_input => {
                allocator.free(instr.send_prompted_input.send_prompted_input.input);

                if (instr.send_prompted_input.send_prompted_input.prompt_exact) |prompt| {
                    allocator.free(prompt);
                }

                if (instr.send_prompted_input.send_prompted_input.prompt_pattern) |prompt_pattern| {
                    allocator.free(prompt_pattern);
                }

                allocator.free(instr.send_prompted_input.send_prompted_input.response);
            },
        }
    }

    /// Deinitialize the bound "on x" (open/close) callback.
    pub fn deinit(self: *BoundOnXCallback) void {
        for (self.instructions) |instr| {
            BoundOnXCallback.freeInstruction(self.allocator, instr);
        }

        self.allocator.free(self.instructions);

        self.allocator.destroy(self);
    }

    /// Execute the callback.
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

fn dupeStringSlice(
    allocator: std.mem.Allocator,
    src: []const []const u8,
) ![]const []const u8 {
    const owned = try allocator.alloc([]const u8, src.len);
    errdefer allocator.free(owned);

    // only ever free the strings actually duped so a failure partway through cannot free
    // uninitialized slots
    var duped: usize = 0;
    errdefer for (owned[0..duped]) |s| {
        allocator.free(s);
    };

    for (0.., src) |idx, s| {
        owned[idx] = try allocator.dupe(u8, s);
        duped = idx + 1;
    }

    return owned;
}

fn freeStringSlice(
    allocator: std.mem.Allocator,
    src: []const []const u8,
) void {
    for (src) |s| {
        allocator.free(s);
    }

    allocator.free(src);
}

/// Definition is a cli "definition" -- that is the information that helps libscrapli drive a cli
/// connection to some device, it holds callbacks and information about available "modes" etc..
pub const Definition = struct {
    prompt_pattern: []const u8,
    prompt_excludes: ?[]const []const u8 = null,
    default_mode: []const u8,
    modes: std.StringHashMapUnmanaged(*mode.Mode) = .empty,
    failure_indicators: ?[]const []const u8 = null,
    on_open_callback: ?OnXCallback = null,
    // nothing but yaml -> Definition should use bound callbacks, but if you did for some weird
    // reason, Definition expects a heap allocated struct that we will call deinit for (which
    // will destroy that memory)
    bound_on_open_callback: ?*BoundOnXCallback = null,
    on_close_callback: ?OnXCallback = null,
    bound_on_close_callback: ?*BoundOnXCallback = null,
    force_in_session_auth: bool = false,
    bypass_in_session_auth: bool = false,
    ntc_templates_platform: ?[]const u8 = null,
    genie_platform: ?[]const u8 = null,

    /// Initialize the cli definition object. Ownership note: the bound on open/close
    /// callbacks and modes in options transfer to the Definition only on *success* -- on failure
    /// this function does not touch them (the caller cleans them up), because deinit would free
    /// them and the caller's own errdefers would then double free.
    pub fn init(allocator: std.mem.Allocator, options: Definition) !Definition {
        var d = options;

        // reset owned fields so a failure only ever frees memory this init duped;
        // adopted fields (modes, bound callbacks) are attached at the *end*
        d.prompt_pattern = "";
        d.prompt_excludes = null;
        d.modes = .empty;
        d.failure_indicators = null;
        d.bound_on_open_callback = null;
        d.bound_on_close_callback = null;
        d.ntc_templates_platform = null;
        d.genie_platform = null;

        if (options.default_mode.ptr != mode.default_mode.ptr) {
            d.default_mode = mode.default_mode;
        }

        errdefer d.deinit(allocator);

        d.prompt_pattern = try allocator.dupe(u8, options.prompt_pattern);

        if (options.prompt_excludes) |prompt_excludes| {
            d.prompt_excludes = try dupeStringSlice(allocator, prompt_excludes);
        }

        if (options.default_mode.ptr != mode.default_mode.ptr) {
            d.default_mode = try allocator.dupe(u8, options.default_mode);
        }

        if (options.ntc_templates_platform) |ntc_templates_platform| {
            d.ntc_templates_platform = try allocator.dupe(u8, ntc_templates_platform);
        }

        if (options.genie_platform) |genie_platform| {
            d.genie_platform = try allocator.dupe(u8, genie_platform);
        }

        if (options.failure_indicators) |failure_indicators| {
            d.failure_indicators = try dupeStringSlice(allocator, failure_indicators);
        }

        d.modes = options.modes;
        d.bound_on_open_callback = options.bound_on_open_callback;
        d.bound_on_close_callback = options.bound_on_close_callback;

        return d;
    }

    /// Deinitialize the cli defintion object.
    pub fn deinit(self: *Definition, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt_pattern);

        if (self.prompt_excludes) |prompt_excludes| {
            freeStringSlice(allocator, prompt_excludes);
        }

        if (self.default_mode.ptr != mode.default_mode.ptr) {
            allocator.free(self.default_mode);
        }

        var mode_iter = self.modes.iterator();

        while (mode_iter.next()) |m| {
            allocator.free(m.key_ptr.*);
            m.value_ptr.*.deinit();
        }

        self.modes.deinit(allocator);

        if (self.failure_indicators) |failure_indicators| {
            freeStringSlice(allocator, failure_indicators);
        }

        if (self.bound_on_open_callback) |cb| {
            cb.deinit();
        }

        if (self.bound_on_close_callback) |cb| {
            cb.deinit();
        }

        if (self.ntc_templates_platform) |s| {
            allocator.free(s);
        }

        if (self.genie_platform) |s| {
            allocator.free(s);
        }
    }
};

/// YamlSource is a tagged union holding either the content or a filename of the yaml that will
/// form a YamlDefinition.
pub const YamlSource = union(enum) {
    string: []const u8,
    file: []const u8,
};

/// YamlDefinition represents a definition in yaml form and contains a method to return the
/// "normal" zig Definition object from the yaml source.
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

    /// Return a Definition object from the loaded yaml.
    pub fn toDefinition(
        allocator: std.mem.Allocator,
        io: std.Io,
        source: YamlSource,
    ) !Definition {
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

        var on_open_callback: ?*BoundOnXCallback = null;
        errdefer if (on_open_callback) |ocb| {
            ocb.deinit();
        };

        if (parsed_definition.on_open_instructions) |instr| {
            on_open_callback = try BoundOnXCallback.init(
                allocator,
                operation.Kind.on_open,
                instr,
            );
        }

        var on_close_callback: ?*BoundOnXCallback = null;
        errdefer if (on_close_callback) |ccb| {
            ccb.deinit();
        };

        if (parsed_definition.on_close_instructions) |instr| {
            on_close_callback = try BoundOnXCallback.init(
                allocator,
                operation.Kind.on_close,
                instr,
            );
        }

        var modes: std.StringHashMapUnmanaged(*mode.Mode) = .empty;

        errdefer {
            var modes_iter = modes.iterator();

            while (modes_iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit();
            }

            modes.deinit(allocator);
        }

        for (parsed_definition.modes) |m| {
            const owned_name = try allocator.dupe(u8, m.name);
            errdefer allocator.free(owned_name);

            const mode_obj = try mode.Mode.init(allocator, m);
            errdefer mode_obj.deinit();

            try modes.put(allocator, owned_name, mode_obj);
        }

        return Definition.init(
            allocator,
            .{
                .prompt_pattern = parsed_definition.prompt_pattern,
                .default_mode = parsed_definition.default_mode,
                .modes = modes,
                .failure_indicators = parsed_definition.failure_indicators,
                .bound_on_open_callback = on_open_callback,
                .bound_on_close_callback = on_close_callback,
                .force_in_session_auth = parsed_definition.force_in_session_auth orelse false,
                .bypass_in_session_auth = parsed_definition.bypass_in_session_auth orelse false,
                .ntc_templates_platform = parsed_definition.ntc_templates_platform,
                .genie_platform = parsed_definition.genie_platform,
            },
        );
    }
};

fn definitionInitForAllocFailures(allocator: std.mem.Allocator) !void {
    // definition w/ all duped fields populated so allocation failures at any point during the
    // copy exercise the partial-failure cleanup path (and would catch any invalid free of
    // caller owned memory or leak of partially duped state); modes and bound callbacks are
    // deliberately left empty/null -- those are adopted rather than duped and on failure
    // remain caller owned
    var d = try Definition.init(
        allocator,
        .{
            .prompt_pattern = "^some-prompt>\\s?$",
            .prompt_excludes = &[_][]const u8{
                "not-this-prompt",
                "or-this-one",
            },
            .default_mode = "some-custom-default-mode",
            .failure_indicators = &[_][]const u8{
                "% Invalid input",
                "% Error",
            },
            .ntc_templates_platform = "some_ntc_platform",
            .genie_platform = "some_genie_platform",
        },
    );

    d.deinit(allocator);
}

test "definitionInitAllocationFailures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        definitionInitForAllocFailures,
        .{},
    );
}
