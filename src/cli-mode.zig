const std = @import("std");

const errors = @import("errors.zig");
const hashmaps = @import("hashmaps.zig");
const re = @import("re.zig");

/// Simple const used to signify an "unknown" mode.
pub const unknown_mode = "__unknown__";
/// Simple const used to signify the default mode -- the definition should tell us what this is.
pub const default_mode = "__default__";

/// An enum of cli operations that can be used when dealing w/ cli modes.
pub const Operation = union(enum) {
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

/// Options used to configure a mode.
pub const Options = struct {
    name: []const u8,
    prompt_exact: ?[]const u8 = null,
    prompt_pattern: ?[]const u8 = null,
    prompt_excludes: ?[]const []const u8 = null,
    accessible_modes: ?[]const AccessibleMode = null,
};

/// A struct hodling the name of a mode and the slice of operations required in order to access it.
pub const AccessibleMode = struct {
    name: []const u8,
    instructions: []const Operation,
};

/// A mode -- or basically some type of config "level" on a cli device. In traditional network land
/// this means things like "privileged exec" or "config t" etc..
pub const Mode = struct {
    allocator: std.mem.Allocator,
    prompt_exact: ?[]const u8 = null,
    prompt_pattern: ?[]const u8 = null,
    compiled_prompt_pattern: ?*re.pcre2CompiledPattern = null,
    prompt_excludes: ?[]const []const u8 = null,
    accessible_modes: std.StringHashMap([]Operation),

    /// Initialize the mode object, compiles patterns and dupes user inputs for lifetime reasons.
    pub fn init(allocator: std.mem.Allocator, options: Options) !*Mode {
        const m = try allocator.create(Mode);

        m.* = Mode{
            .allocator = allocator,
            .accessible_modes = std.StringHashMap([]Operation).init(allocator),
        };
        errdefer m.deinit();

        if (options.prompt_exact) |pe| {
            m.prompt_exact = try allocator.dupe(u8, pe);
        }

        if (options.prompt_pattern) |pp| {
            m.prompt_pattern = try allocator.dupe(u8, pp);
        }

        if (m.prompt_pattern) |pattern| {
            const compiled = re.pcre2Compile(pattern);

            if (compiled == null) {
                return error.Regex;
            }

            m.compiled_prompt_pattern = compiled;
        }

        if (options.prompt_excludes) |prompt_excludes| {
            const owned_excludes = try allocator.alloc([]u8, prompt_excludes.len);
            errdefer allocator.free(owned_excludes);

            var duped: usize = 0;
            errdefer for (owned_excludes[0..duped]) |exclusion| {
                allocator.free(exclusion);
            };

            for (0.., prompt_excludes) |idx, exclusion| {
                owned_excludes[idx] = try allocator.dupe(u8, exclusion);
                duped = idx + 1;
            }

            m.prompt_excludes = owned_excludes;
        }

        if (options.accessible_modes) |accessible_modes| {
            for (accessible_modes) |am| {
                const instructions = try allocator.alloc(
                    Operation,
                    am.instructions.len,
                );
                errdefer allocator.free(instructions);

                var built: usize = 0;
                errdefer for (instructions[0..built]) |built_instr| {
                    Mode.freeInstruction(allocator, built_instr);
                };

                for (0.., am.instructions) |idx, instr| {
                    instructions[idx] = try Mode.dupeInstruction(allocator, instr);
                    built = idx + 1;
                }

                const owned_name = try allocator.dupe(u8, am.name);
                errdefer allocator.free(owned_name);

                try m.accessible_modes.put(owned_name, instructions);
            }
        }

        return m;
    }

    fn dupeInstruction(
        allocator: std.mem.Allocator,
        instr: Operation,
    ) !Operation {
        switch (instr) {
            .send_input => {
                return Operation{
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

                var o = Operation{
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
        instr: Operation,
    ) void {
        switch (instr) {
            .send_input => |op| {
                allocator.free(op.send_input.input);
            },
            .send_prompted_input => |op| {
                allocator.free(op.send_prompted_input.input);

                if (op.send_prompted_input.prompt_exact) |prompt| {
                    allocator.free(prompt);
                }

                if (op.send_prompted_input.prompt_pattern) |prompt_pattern| {
                    allocator.free(prompt_pattern);
                }

                allocator.free(op.send_prompted_input.response);
            },
        }
    }

    /// Deinit the mode object.
    pub fn deinit(self: *Mode) void {
        if (self.prompt_exact) |prompt_exact| {
            self.allocator.free(prompt_exact);
        }

        if (self.prompt_pattern) |prompt_pattern| {
            self.allocator.free(prompt_pattern);
        }

        if (self.compiled_prompt_pattern) |pattern| {
            re.pcre2Free(pattern);
        }

        if (self.prompt_excludes) |excludes| {
            for (excludes) |e| {
                self.allocator.free(e);
            }

            self.allocator.free(excludes);
        }

        var accessible_mode_iter = self.accessible_modes.iterator();

        while (accessible_mode_iter.next()) |m| {
            for (m.value_ptr.*) |instr| {
                Mode.freeInstruction(self.allocator, instr);
            }

            self.allocator.free(m.value_ptr.*);
            self.allocator.free(m.key_ptr.*);
        }

        self.accessible_modes.deinit();
        self.allocator.destroy(self);
    }
};

/// Given a map of Mode objects, determine the mode based on the current prompt output.
pub fn determineMode(
    modes: std.StringHashMapUnmanaged(*Mode),
    current_prompt: []const u8,
) ![]const u8 {
    var modes_iterator = modes.iterator();

    while (modes_iterator.next()) |mode_def| {
        if (mode_def.value_ptr.*.prompt_exact) |prompt_exact| {
            if (std.mem.eql(u8, current_prompt, prompt_exact)) {
                var is_excluded = false;

                if (mode_def.value_ptr.*.prompt_excludes) |prompt_excludes| {
                    for (prompt_excludes) |exclusion| {
                        if (std.mem.find(
                            u8,
                            current_prompt,
                            exclusion,
                        ) != null) {
                            is_excluded = true;
                            break;
                        }
                    }
                }

                if (is_excluded) {
                    continue;
                }

                return mode_def.key_ptr.*;
            }
        }

        if (mode_def.value_ptr.*.compiled_prompt_pattern) |compiled_prompt_pattern| {
            const match = try re.pcre2Find(
                compiled_prompt_pattern,
                current_prompt,
            );
            if (match != null) {
                var is_excluded = false;

                if (mode_def.value_ptr.*.prompt_excludes) |prompt_excludes| {
                    for (prompt_excludes) |exclusion| {
                        if (std.mem.find(
                            u8,
                            current_prompt,
                            exclusion,
                        ) != null) {
                            is_excluded = true;
                            break;
                        }
                    }
                }

                if (is_excluded) {
                    continue;
                }

                return mode_def.key_ptr.*;
            }
        }
    }

    return errors.ScrapliError.Driver;
}

test "determineMode" {
    const cases = [_]struct {
        name: []const u8,
        modes: std.StringHashMapUnmanaged(*Mode),
        current_prompt: []const u8,
        expected: []const u8,
        expect_fail: bool,
    }{
        .{
            .name = "simple-pattern",
            .modes = try hashmaps.inlineInitStringHashMap(
                std.testing.allocator,
                *Mode,
                &[_][]const u8{
                    "exec",
                    "privileged_exec",
                    "configuration",
                },
                &[_]*Mode{
                    try Mode.init(
                        std.testing.allocator,
                        .{
                            .name = "exec",
                            .prompt_pattern = "^.*>",
                        },
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        .{
                            .name = "privileged_exec",
                            .prompt_pattern = "^.*#",
                        },
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        .{
                            .name = "configuration",
                            .prompt_pattern = "^.*(config)#",
                        },
                    ),
                },
            ),
            .current_prompt = "router>",
            .expected = "exec",
            .expect_fail = false,
        },
        .{
            .name = "simple-exact",
            .modes = try hashmaps.inlineInitStringHashMap(
                std.testing.allocator,
                *Mode,
                &[_][]const u8{
                    "exec",
                    "privileged_exec",
                    "configuration",
                },
                &[_]*Mode{
                    try Mode.init(
                        std.testing.allocator,
                        .{
                            .name = "exec",
                            .prompt_pattern = "^.*>",
                        },
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        .{
                            .name = "privileged_exec",
                            .prompt_exact = "router#",
                        },
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        .{
                            .name = "configuration",
                            .prompt_pattern = "^.*(config)#",
                        },
                    ),
                },
            ),
            .current_prompt = "router#",
            .expected = "privileged_exec",
            .expect_fail = false,
        },
        .{
            .name = "check-exclusion",
            .modes = try hashmaps.inlineInitStringHashMap(
                std.testing.allocator,
                *Mode,
                &[_][]const u8{
                    "exec",
                    "privileged_exec",
                    "configuration",
                    "tclsh",
                },
                &[_]*Mode{
                    try Mode.init(
                        std.testing.allocator,
                        .{
                            .name = "exec",
                            .prompt_pattern = "^.*>",
                        },
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        .{
                            .name = "privileged_exec",
                            .prompt_pattern = "^.*#",
                            .prompt_excludes = &[_][]const u8{
                                "tcl)",
                            },
                        },
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        .{
                            .name = "configuration",
                            .prompt_pattern = "^.*(config)#",
                        },
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        .{
                            .name = "tclsh",
                            .prompt_pattern = "^.*\\(tcl\\)#",
                        },
                    ),
                },
            ),
            .current_prompt = "router(tcl)#",
            .expected = "tclsh",
            .expect_fail = false,
        },
    };

    defer {
        for (cases) |case| {
            var modes = case.modes;

            var modes_iterator = modes.valueIterator();

            while (modes_iterator.next()) |m| {
                m.*.deinit();
            }

            modes.deinit(std.testing.allocator);
        }
    }

    for (cases) |case| {
        const actual = try determineMode(
            case.modes,
            case.current_prompt,
        );

        if (case.expect_fail) {
            std.testing.expectEqual(case.expected, actual) catch {
                continue;
            };

            try std.testing.expect(false);
        } else {
            try std.testing.expectEqual(case.expected, actual);
        }
    }
}

/// Recursively find a path to a requestd mode from the current mode.
pub fn getPathToMode(
    allocator: std.mem.Allocator,
    modes: std.StringHashMapUnmanaged(*Mode),
    current_mode_name: []const u8,
    requested_mode_name: []const u8,
    visited: *std.StringHashMap(bool),
) !std.ArrayList([]const u8) {
    var steps: std.ArrayList([]const u8) = .empty;
    errdefer steps.deinit(allocator);

    if (std.mem.eql(u8, current_mode_name, requested_mode_name)) {
        try steps.append(allocator, current_mode_name);
        return steps;
    }

    _ = try visited.put(current_mode_name, true);

    const current_mode = modes.get(current_mode_name);
    if (current_mode == null) {
        return steps;
    }

    var possible_modes = current_mode.?.accessible_modes.iterator();

    while (possible_modes.next()) |possible_mode| {
        if (visited.contains(possible_mode.key_ptr.*)) {
            continue;
        }

        var sub_path = try getPathToMode(
            allocator,
            modes,
            possible_mode.key_ptr.*,
            requested_mode_name,
            visited,
        );

        defer sub_path.deinit(allocator);

        if (sub_path.items.len > 0) {
            try steps.append(allocator, current_mode_name);
            try steps.appendSlice(allocator, sub_path.items);
            break;
        }
    }

    return steps;
}

test "getPathToMode" {
    const exec_mode_options = Options{
        .name = "exec",
        .prompt_pattern = "^.*>",
        .accessible_modes = &[_]AccessibleMode{
            .{
                .name = "privileged_exec",
                .instructions = &[_]Operation{
                    Operation{
                        .send_prompted_input = .{
                            .send_prompted_input = .{
                                .input = "enable",
                                .prompt_exact = "Password:",
                                .response = "password",
                            },
                        },
                    },
                },
            },
        },
    };

    const privileged_exec_mode_options = Options{
        .name = "privileged_exec",
        .prompt_pattern = "^.*#",
        .accessible_modes = &[_]AccessibleMode{
            .{
                .name = "exec",
                .instructions = &[_]Operation{
                    .{
                        .send_input = .{
                            .send_input = .{
                                .input = "disable",
                            },
                        },
                    },
                },
            },
            .{
                .name = "configuration",
                .instructions = &[_]Operation{
                    .{
                        .send_input = .{
                            .send_input = .{
                                .input = "configure terminal",
                            },
                        },
                    },
                },
            },
            .{
                .name = "tclsh",
                .instructions = &[_]Operation{
                    .{
                        .send_input = .{
                            .send_input = .{
                                .input = "tclsh",
                            },
                        },
                    },
                },
            },
        },
    };

    const config_mode_options = Options{
        .name = "configuration",
        .prompt_pattern = "^.*(config)#",
        .accessible_modes = &[_]AccessibleMode{
            .{
                .name = "privileged_exec",
                .instructions = &[_]Operation{
                    .{
                        .send_input = .{
                            .send_input = .{
                                .input = "end",
                            },
                        },
                    },
                },
            },
        },
    };

    const cases = [_]struct {
        name: []const u8,
        modes: std.StringHashMapUnmanaged(*Mode),
        current_mode_name: []const u8,
        requested_mode_name: []const u8,
        expected: []const []const u8,
        expect_fail: bool,
    }{
        .{
            .name = "simple",
            .modes = try hashmaps.inlineInitStringHashMap(
                std.testing.allocator,
                *Mode,
                &[_][]const u8{
                    "exec",
                    "privileged_exec",
                    "configuration",
                },
                &[_]*Mode{
                    try Mode.init(
                        std.testing.allocator,
                        exec_mode_options,
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        privileged_exec_mode_options,
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        config_mode_options,
                    ),
                },
            ),
            .current_mode_name = "exec",
            .requested_mode_name = "configuration",
            .expected = &[_][]const u8{
                "exec",
                "privileged_exec",
                "configuration",
            },
            .expect_fail = false,
        },
        .{
            .name = "simple-backwards",
            .modes = try hashmaps.inlineInitStringHashMap(
                std.testing.allocator,
                *Mode,
                &[_][]const u8{
                    "exec",
                    "privileged_exec",
                    "configuration",
                },
                &[_]*Mode{
                    try Mode.init(
                        std.testing.allocator,
                        exec_mode_options,
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        privileged_exec_mode_options,
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        config_mode_options,
                    ),
                },
            ),
            .current_mode_name = "configuration",
            .requested_mode_name = "exec",
            .expected = &[_][]const u8{
                "configuration",
                "privileged_exec",
                "exec",
            },
            .expect_fail = false,
        },
        .{
            .name = "simple-short",
            .modes = try hashmaps.inlineInitStringHashMap(
                std.testing.allocator,
                *Mode,
                &[_][]const u8{
                    "exec",
                    "privileged_exec",
                    "configuration",
                },
                &[_]*Mode{
                    try Mode.init(
                        std.testing.allocator,
                        exec_mode_options,
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        privileged_exec_mode_options,
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        config_mode_options,
                    ),
                },
            ),
            .current_mode_name = "exec",
            .requested_mode_name = "privileged_exec",
            .expected = &[_][]const u8{
                "exec",
                "privileged_exec",
            },
            .expect_fail = false,
        },
        .{
            .name = "more steps",
            .modes = try hashmaps.inlineInitStringHashMap(
                std.testing.allocator,
                *Mode,
                &[_][]const u8{
                    "privileged_exec",
                    "configuration",
                    "shell",
                    "sudo",
                },
                &[_]*Mode{
                    try Mode.init(
                        std.testing.allocator,
                        privileged_exec_mode_options,
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        config_mode_options,
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        .{
                            .name = "shell",
                            .prompt_pattern = "^shell#",
                            .accessible_modes = &[_]AccessibleMode{
                                .{
                                    .name = "privileged_exec",
                                    .instructions = &[_]Operation{
                                        .{
                                            .send_input = .{
                                                .send_input = .{
                                                    .input = "quit",
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    ),
                    try Mode.init(
                        std.testing.allocator,
                        .{
                            .name = "sudo",
                            .prompt_pattern = "^shell(root)#",
                            .accessible_modes = &[_]AccessibleMode{
                                .{
                                    .name = "shell",
                                    .instructions = &[_]Operation{
                                        .{
                                            .send_input = .{
                                                .send_input = .{
                                                    .input = "quit",
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    ),
                },
            ),
            .current_mode_name = "sudo",
            .requested_mode_name = "configuration",
            .expected = &[_][]const u8{
                "sudo",
                "shell",
                "privileged_exec",
                "configuration",
            },
            .expect_fail = false,
        },
    };

    defer {
        for (cases) |case| {
            var modes = case.modes;

            var modes_iterator = modes.valueIterator();

            while (modes_iterator.next()) |m| {
                m.*.deinit();
            }

            modes.deinit(std.testing.allocator);
        }
    }

    for (cases) |case| {
        var visited = std.StringHashMap(bool).init(std.testing.allocator);
        defer visited.deinit();

        var actual = try getPathToMode(
            std.testing.allocator,
            case.modes,
            case.current_mode_name,
            case.requested_mode_name,
            &visited,
        );
        defer actual.deinit(std.testing.allocator);

        for (0.., case.expected) |idx, expected| {
            try std.testing.expectEqualStrings(expected, actual.items[idx]);
        }
    }
}
