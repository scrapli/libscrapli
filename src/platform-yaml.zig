const std = @import("std");
const driver = @import("driver.zig");
const platform = @import("platform.zig");
const mode = @import("mode.zig");
const operation = @import("operation.zig");
const file = @import("file.zig");
const yaml = @import("zig-yaml");
const result = @import("result.zig");

pub const default_variant = "default";

pub const Operation = enum {
    Write,
    EnterMode,
    SendInput,
    SendPromptedInput,
};

pub const OperationInstruction = union(Operation) {
    Write: struct {
        write: struct {
            input: []const u8,
        },
    },
    EnterMode: struct {
        enter_mode: struct {
            requested_mode: []const u8,
        },
    },
    SendInput: struct {
        send_input: struct {
            input: []const u8,
        },
    },
    SendPromptedInput: struct {
        send_prompted_input: struct {
            input: []const u8,
            prompt: []const u8,
            response: []const u8,
        },
    },
};

pub fn DefinitionFromFilePath(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    variant_name: ?[]const u8,
) !DefinitionFromYaml {
    const definition_string = try file.readFromPath(allocator, file_path);
    defer allocator.free(definition_string);

    const definition = try definitionFromYamlString(
        allocator,
        definition_string,
        variant_name,
    );

    return definition;
}

pub fn DefinitionFromYamlString(
    allocator: std.mem.Allocator,
    definition_string: []const u8,
    variant_name: ?[]const u8,
) !DefinitionFromYaml {
    return definitionFromYamlString(
        allocator,
        definition_string,
        variant_name,
    );
}

fn definitionFromYamlString(
    allocator: std.mem.Allocator,
    definition_string: []const u8,
    variant_name: ?[]const u8,
) !DefinitionFromYaml {
    var untyped = try yaml.Yaml.load(allocator, definition_string);
    errdefer untyped.deinit(allocator);

    // variations needs to escape to the heap -- if it doesnt then the fields in our chosen
    // definition will segfault since they'll be pointing to stack scoped (and gone) memory for
    // things like prompt pattern etc!
    const variations = try allocator.create(Variations);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    variations.* = try untyped.parse(arena.allocator(), Variations);

    if (variant_name == null or std.mem.eql(u8, default_variant, variant_name.?)) {
        return DefinitionFromYaml{
            .allocator = allocator,
            .untyped = untyped,
            .variations = variations,
            .definition = try variations.default.ToDefinition(allocator),
        };
    }

    if (variations.variants == null or variations.variants.?.len == 0) {
        return error.NoVariants;
    }

    for (variations.variants.?) |variant| {
        if (std.mem.eql(u8, variant.name, variant_name.?)) {
            var mut_variant = variant;

            return DefinitionFromYaml{
                .allocator = allocator,
                .untyped = untyped,
                .variations = variations,
                .definition = try mut_variant.definition.ToDefinition(allocator),
            };
        }
    }

    return error.VariantNotFound;
}

pub const DefinitionFromYaml = struct {
    allocator: std.mem.Allocator,
    untyped: yaml.Yaml,
    variations: *Variations,
    definition: platform.Definition,

    pub fn deinit(self: *DefinitionFromYaml) void {
        self.allocator.destroy(self.variations);
        self.untyped.deinit(self.allocator);
    }
};

const Variations = struct {
    kind: []const u8,
    default: Definition,
    variants: ?[]struct {
        name: []const u8,
        definition: Definition,
    },
};

const Definition = struct {
    prompt_pattern: []const u8,
    default_mode: []const u8,
    modes: []struct {
        name: []const u8,
        prompt_exact: ?[]const u8,
        prompt_pattern: ?[]const u8,
        prompt_excludes: ?[][]const u8,
        accessible_modes: []struct {
            name: []const u8,
            send_input: ?struct {
                input: []const u8,
            },
            send_prompted_input: ?struct {
                input: []const u8,
                prompt: []const u8,
                response: []const u8,
            },
        },
    },
    input_failed_when_contains: ?[][]const u8,
    on_open_instructions: []OperationInstruction,
    on_close_instructions: []OperationInstruction,

    fn ToDefinition(
        self: *Definition,
        allocator: std.mem.Allocator,
    ) !platform.Definition {
        var modes = std.StringHashMap(mode.Mode).init(allocator);

        for (self.modes) |m| {
            var prompt_excludes = std.ArrayList([]const u8).init(allocator);

            if (m.prompt_excludes != null) {
                for (m.prompt_excludes.?) |p| {
                    try prompt_excludes.append(p);
                }
            }

            var accessible_modes = std.StringHashMap(mode.Operation).init(allocator);

            for (m.accessible_modes) |am| {
                if (am.send_input != null) {
                    try accessible_modes.put(
                        am.name,
                        mode.Operation{
                            .SendInput = mode.SendInput{
                                .input = am.send_input.?.input,
                            },
                        },
                    );
                } else {
                    try accessible_modes.put(
                        am.name,
                        mode.Operation{
                            .SendPromptedInput = mode.SendPromptedInput{
                                .input = am.send_prompted_input.?.input,
                                .prompt = am.send_prompted_input.?.prompt,
                                .response = am.send_prompted_input.?.response,
                            },
                        },
                    );
                }
            }

            try modes.put(
                m.name,
                try mode.NewMode(
                    allocator,
                    m.prompt_exact orelse "",
                    m.prompt_pattern orelse "",
                    prompt_excludes,
                    accessible_modes,
                ),
            );
        }

        var failed_when_contains = std.ArrayList([]const u8).init(allocator);

        for (self.input_failed_when_contains.?) |f| {
            try failed_when_contains.append(f);
        }

        var def = platform.Definition{
            .allocator = allocator,
            .prompt_pattern = self.prompt_pattern,
            .default_mode = self.default_mode,
            .modes = modes,
            .input_failed_when_contains = failed_when_contains,
            .on_open_callback = null,
            .bound_on_open_callback = null,
            .on_close_callback = null,
            .bound_on_close_callback = null,
        };

        if (self.on_open_instructions.len > 0) {
            def.bound_on_open_callback = platform.BoundOnXCallback{
                .ptr = self,
                .callback = Definition.onOpen,
            };
        }

        if (self.on_close_instructions.len > 0) {
            def.bound_on_close_callback = platform.BoundOnXCallback{
                .ptr = self,
                .callback = Definition.onClose,
            };
        }

        return def;
    }

    pub fn onOpen(
        self_ptr: *anyopaque,
        d: *driver.Driver,
        allocator: std.mem.Allocator,
        cancel: ?*bool,
    ) anyerror!*result.Result {
        const self: *Definition = @ptrCast(@alignCast(self_ptr));

        const res = try d.NewResult(allocator, result.OperationKind.OnOpen);
        errdefer res.deinit();

        for (self.on_open_instructions) |instr| {
            switch (instr) {
                Operation.Write => {
                    try d.session.writeAndReturn(instr.Write.write.input, false);
                },
                Operation.EnterMode => {
                    var opts = operation.NewEnterModeOptions();
                    opts.cancel = cancel;

                    try res.recordExtend(
                        try d.enterMode(
                            allocator,
                            instr.EnterMode.enter_mode.requested_mode,
                            opts,
                        ),
                    );
                },
                Operation.SendInput => {
                    var opts = operation.NewSendInputOptions();
                    opts.cancel = cancel;

                    opts.retain_input = true;
                    opts.retain_trailing_prompt = true;

                    try res.recordExtend(
                        try d.sendInput(
                            allocator,
                            instr.SendInput.send_input.input,
                            opts,
                        ),
                    );
                },
                Operation.SendPromptedInput => {
                    var opts = operation.NewSendPromptedInputOptions();
                    opts.cancel = cancel;

                    try res.recordExtend(
                        try d.sendPromptedInput(
                            allocator,
                            instr.SendPromptedInput.send_prompted_input.input,
                            instr.SendPromptedInput.send_prompted_input.prompt,
                            instr.SendPromptedInput.send_prompted_input.response,
                            opts,
                        ),
                    );
                },
            }
        }

        return res;
    }

    pub fn onClose(
        self_ptr: *anyopaque,
        d: *driver.Driver,
        allocator: std.mem.Allocator,
        cancel: ?*bool,
    ) anyerror!*result.Result {
        const self: *Definition = @ptrCast(@alignCast(self_ptr));

        const res = try d.NewResult(allocator, result.OperationKind.OnClose);
        errdefer res.deinit();

        for (self.on_close_instructions) |instr| {
            switch (instr) {
                Operation.Write => {
                    try d.session.writeAndReturn(instr.Write.write.input, false);
                },
                Operation.EnterMode => {
                    var opts = operation.NewEnterModeOptions();
                    opts.cancel = cancel;

                    try res.recordExtend(
                        try d.enterMode(
                            allocator,
                            instr.EnterMode.enter_mode.requested_mode,
                            opts,
                        ),
                    );
                },
                Operation.SendInput => {
                    var opts = operation.NewSendInputOptions();
                    opts.cancel = cancel;

                    try res.recordExtend(
                        try d.sendInput(
                            allocator,
                            instr.SendInput.send_input.input,
                            opts,
                        ),
                    );
                },
                Operation.SendPromptedInput => {
                    var opts = operation.NewSendPromptedInputOptions();
                    opts.cancel = cancel;

                    try res.recordExtend(
                        try d.sendPromptedInput(
                            allocator,
                            instr.SendPromptedInput.send_prompted_input.input,
                            instr.SendPromptedInput.send_prompted_input.prompt,
                            instr.SendPromptedInput.send_prompted_input.response,
                            opts,
                        ),
                    );
                },
            }
        }

        return res;
    }
};
