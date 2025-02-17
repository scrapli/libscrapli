const std = @import("std");
const re = @import("re.zig");
const hashmaps = @import("hashmaps.zig");
const arrays = @import("arrays.zig");

const pcre2 = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

pub const unknown_mode = "__unknown__";
pub const default_mode = "__default__";

pub const Instruction = enum {
    SendInput,
    SendPromptedInput,
};

pub const Operation = union(Instruction) {
    SendInput: SendInput,
    SendPromptedInput: SendPromptedInput,
};

pub const SendInput = struct {
    input: []const u8,
};

pub const SendPromptedInput = struct {
    input: []const u8,
    prompt: []const u8,
    response: []const u8,
};

pub fn NewMode(
    allocator: std.mem.Allocator,
    prompt_exact: ?[]const u8,
    prompt_pattern: ?[]const u8,
    prompt_excludes: ?std.ArrayList([]const u8),
    accessible_modes: ?std.StringHashMap(Operation),
) !Mode {
    var m = Mode{
        .allocator = allocator,
        .prompt_exact = "",
        .prompt_pattern = "",
        .compiled_prompt_pattern = null,
        .prompt_excludes = std.ArrayList([]const u8).init(allocator),
        .accessible_modes = std.StringHashMap(Operation).init(allocator),
    };

    if (prompt_exact != null) {
        m.prompt_exact = prompt_exact.?;
    }

    if (prompt_pattern != null) {
        const compiled = re.pcre2Compile(prompt_pattern.?);
        if (compiled == null) {
            return error.RegexError;
        }

        m.compiled_prompt_pattern = compiled;
    }

    if (prompt_excludes != null) {
        m.prompt_excludes.deinit();
        m.prompt_excludes = prompt_excludes.?;
    }

    if (accessible_modes != null) {
        m.accessible_modes.deinit();
        m.accessible_modes = accessible_modes.?;
    }

    return m;
}

pub const Mode = struct {
    allocator: std.mem.Allocator,

    prompt_exact: []const u8,
    prompt_pattern: []const u8,
    compiled_prompt_pattern: ?*pcre2.pcre2_code_8,
    prompt_excludes: std.ArrayList([]const u8),

    accessible_modes: std.StringHashMap(Operation),

    pub fn deinit(self: *Mode) void {
        if (self.compiled_prompt_pattern != null) {
            re.pcre2Free(self.compiled_prompt_pattern.?);
        }

        self.prompt_excludes.deinit();
        self.accessible_modes.deinit();
    }
};

pub fn determineMode(
    modes: std.StringHashMap(Mode),
    current_prompt: []const u8,
) ![]const u8 {
    var modes_iterator = modes.iterator();

    while (modes_iterator.next()) |mode_def| {
        if (mode_def.value_ptr.prompt_exact.len > 0) {
            if (std.mem.eql(u8, current_prompt, mode_def.value_ptr.prompt_exact)) {
                for (mode_def.value_ptr.prompt_excludes.items) |exclusion| {
                    if (std.mem.indexOf(u8, current_prompt, exclusion) != 0) {
                        continue;
                    }
                }

                return mode_def.key_ptr.*;
            }
        }

        const match = try re.pcre2Find(
            mode_def.value_ptr.compiled_prompt_pattern.?,
            current_prompt,
        );
        if (match.len > 0) {
            var is_excluded = false;

            for (mode_def.value_ptr.prompt_excludes.items) |exclusion| {
                if (std.mem.indexOf(u8, current_prompt, exclusion) != null) {
                    is_excluded = true;
                    break;
                }
            }

            if (is_excluded) {
                continue;
            }

            return mode_def.key_ptr.*;
        }
    }

    return error.UnknownMode;
}

test "determineMode" {
    const cases = [_]struct {
        name: []const u8,
        modes: std.StringHashMap(Mode),
        current_prompt: []const u8,
        expected: []const u8,
        expect_fail: bool,
    }{
        .{
            .name = "simple-pattern",
            .modes = try hashmaps.inlineInitStringHashMap(
                std.testing.allocator,
                Mode,
                &[_][]const u8{
                    "exec",
                    "privileged_exec",
                    "configuration",
                },
                &[_]Mode{
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*>",
                        null,
                        null,
                    ),
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*#",
                        null,
                        null,
                    ),
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*(config)#",
                        null,
                        null,
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
                Mode,
                &[_][]const u8{
                    "exec",
                    "privileged_exec",
                    "configuration",
                },
                &[_]Mode{
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*>",
                        null,
                        null,
                    ),
                    try NewMode(
                        std.testing.allocator,
                        "router#",
                        null,
                        null,
                        null,
                    ),
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*(config)#",
                        null,
                        null,
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
                Mode,
                &[_][]const u8{
                    "exec",
                    "privileged_exec",
                    "configuration",
                    "tclsh",
                },
                &[_]Mode{
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*>",
                        null,
                        null,
                    ),
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*#",
                        try arrays.inlineInitArrayList(
                            std.testing.allocator,
                            []const u8,
                            &[_][]const u8{
                                "tcl)",
                            },
                        ),
                        null,
                    ),
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*(config)#",
                        null,
                        null,
                    ),
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*\\(tcl\\)#",
                        null,
                        null,
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

            while (modes_iterator.next()) |mode| {
                mode.deinit();
            }

            modes.deinit();
        }
    }

    for (cases) |case| {
        const actual = try determineMode(case.modes, case.current_prompt);

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

pub fn getPathToMode(
    allocator: std.mem.Allocator,
    modes: std.StringHashMap(Mode),
    current_mode_name: []const u8,
    requested_mode_name: []const u8,
    visited: *std.StringHashMap(bool),
) !std.ArrayList([]const u8) {
    var steps = std.ArrayList([]const u8).init(allocator);

    if (std.mem.eql(u8, current_mode_name, requested_mode_name)) {
        try steps.append(current_mode_name);
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
        defer sub_path.deinit();

        if (sub_path.items.len > 0) {
            try steps.append(current_mode_name);
            try steps.appendSlice(sub_path.items);
            break;
        }
    }

    return steps;
}

test "getPathToMode" {
    const cases = [_]struct {
        name: []const u8,
        modes: std.StringHashMap(Mode),
        current_mode_name: []const u8,
        requested_mode_name: []const u8,
        expected: std.ArrayList([]const u8),
        expect_fail: bool,
    }{
        .{
            .name = "simple",
            .modes = try hashmaps.inlineInitStringHashMap(
                std.testing.allocator,
                Mode,
                &[_][]const u8{
                    "exec",
                    "privileged_exec",
                    "configuration",
                },
                &[_]Mode{
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*>",
                        null,
                        try hashmaps.inlineInitStringHashMap(
                            std.testing.allocator,
                            Operation,
                            &[_][]const u8{
                                "privileged_exec",
                            },
                            &[_]Operation{
                                Operation{
                                    .SendPromptedInput = SendPromptedInput{
                                        .input = "enable",
                                        .prompt = "Password:",
                                        .response = "password",
                                    },
                                },
                            },
                        ),
                    ),
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*#",
                        null,
                        try hashmaps.inlineInitStringHashMap(
                            std.testing.allocator,
                            Operation,
                            &[_][]const u8{
                                "exec",
                                "configuration",
                                "tclsh",
                            },
                            &[_]Operation{
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "disable",
                                    },
                                },
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "configure terminal",
                                    },
                                },
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "tclsh",
                                    },
                                },
                            },
                        ),
                    ),
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*(config)#",
                        null,
                        try hashmaps.inlineInitStringHashMap(
                            std.testing.allocator,
                            Operation,
                            &[_][]const u8{
                                "privileged_exec",
                            },
                            &[_]Operation{
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "end",
                                    },
                                },
                            },
                        ),
                    ),
                },
            ),
            .current_mode_name = "exec",
            .requested_mode_name = "configuration",
            .expected = try arrays.inlineInitArrayList(
                std.testing.allocator,
                []const u8,
                &[_][]const u8{
                    "exec",
                    "privileged_exec",
                    "configuration",
                },
            ),
            .expect_fail = false,
        },
        .{
            .name = "simple-backwards",
            .modes = try hashmaps.inlineInitStringHashMap(
                std.testing.allocator,
                Mode,
                &[_][]const u8{
                    "exec",
                    "privileged_exec",
                    "configuration",
                },
                &[_]Mode{
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*>",
                        null,
                        try hashmaps.inlineInitStringHashMap(
                            std.testing.allocator,
                            Operation,
                            &[_][]const u8{
                                "privileged_exec",
                            },
                            &[_]Operation{
                                Operation{
                                    .SendPromptedInput = SendPromptedInput{
                                        .input = "enable",
                                        .prompt = "Password:",
                                        .response = "password",
                                    },
                                },
                            },
                        ),
                    ),
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*#",
                        null,
                        try hashmaps.inlineInitStringHashMap(
                            std.testing.allocator,
                            Operation,
                            &[_][]const u8{
                                "exec",
                                "configuration",
                                "tclsh",
                            },
                            &[_]Operation{
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "disable",
                                    },
                                },
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "configure terminal",
                                    },
                                },
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "tclsh",
                                    },
                                },
                            },
                        ),
                    ),
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*(config)#",
                        null,
                        try hashmaps.inlineInitStringHashMap(
                            std.testing.allocator,
                            Operation,
                            &[_][]const u8{
                                "privileged_exec",
                            },
                            &[_]Operation{
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "end",
                                    },
                                },
                            },
                        ),
                    ),
                },
            ),
            .current_mode_name = "configuration",
            .requested_mode_name = "exec",
            .expected = try arrays.inlineInitArrayList(
                std.testing.allocator,
                []const u8,
                &[_][]const u8{
                    "configuration",
                    "privileged_exec",
                    "exec",
                },
            ),
            .expect_fail = false,
        },
        .{
            .name = "simple-short",
            .modes = try hashmaps.inlineInitStringHashMap(
                std.testing.allocator,
                Mode,
                &[_][]const u8{
                    "exec",
                    "privileged_exec",
                    "configuration",
                },
                &[_]Mode{
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*>",
                        null,
                        try hashmaps.inlineInitStringHashMap(
                            std.testing.allocator,
                            Operation,
                            &[_][]const u8{
                                "privileged_exec",
                            },
                            &[_]Operation{
                                Operation{
                                    .SendPromptedInput = SendPromptedInput{
                                        .input = "enable",
                                        .prompt = "Password:",
                                        .response = "password",
                                    },
                                },
                            },
                        ),
                    ),
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*#",
                        null,
                        try hashmaps.inlineInitStringHashMap(
                            std.testing.allocator,
                            Operation,
                            &[_][]const u8{
                                "exec",
                                "configuration",
                                "tclsh",
                            },
                            &[_]Operation{
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "disable",
                                    },
                                },
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "configure terminal",
                                    },
                                },
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "tclsh",
                                    },
                                },
                            },
                        ),
                    ),
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*(config)#",
                        null,
                        try hashmaps.inlineInitStringHashMap(
                            std.testing.allocator,
                            Operation,
                            &[_][]const u8{
                                "privileged_exec",
                            },
                            &[_]Operation{
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "end",
                                    },
                                },
                            },
                        ),
                    ),
                },
            ),
            .current_mode_name = "exec",
            .requested_mode_name = "privileged_exec",
            .expected = try arrays.inlineInitArrayList(
                std.testing.allocator,
                []const u8,
                &[_][]const u8{
                    "exec",
                    "privileged_exec",
                },
            ),
            .expect_fail = false,
        },
        .{
            .name = "more steps",
            .modes = try hashmaps.inlineInitStringHashMap(
                std.testing.allocator,
                Mode,
                &[_][]const u8{
                    "privileged_exec",
                    "configuration",
                    "shell",
                    "sudo",
                },
                &[_]Mode{
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*#",
                        null,
                        try hashmaps.inlineInitStringHashMap(
                            std.testing.allocator,
                            Operation,
                            &[_][]const u8{
                                "exec",
                                "configuration",
                                "tclsh",
                            },
                            &[_]Operation{
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "disable",
                                    },
                                },
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "configure terminal",
                                    },
                                },
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "tclsh",
                                    },
                                },
                            },
                        ),
                    ),
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^.*(config)#",
                        null,
                        try hashmaps.inlineInitStringHashMap(
                            std.testing.allocator,
                            Operation,
                            &[_][]const u8{
                                "privileged_exec",
                            },
                            &[_]Operation{
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "end",
                                    },
                                },
                            },
                        ),
                    ),
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^shell#",
                        null,
                        try hashmaps.inlineInitStringHashMap(
                            std.testing.allocator,
                            Operation,
                            &[_][]const u8{
                                "privileged_exec",
                            },
                            &[_]Operation{
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "quit",
                                    },
                                },
                            },
                        ),
                    ),
                    try NewMode(
                        std.testing.allocator,
                        null,
                        "^shell(root)#",
                        null,
                        try hashmaps.inlineInitStringHashMap(
                            std.testing.allocator,
                            Operation,
                            &[_][]const u8{
                                "shell",
                            },
                            &[_]Operation{
                                Operation{
                                    .SendInput = SendInput{
                                        .input = "quit",
                                    },
                                },
                            },
                        ),
                    ),
                },
            ),
            .current_mode_name = "sudo",
            .requested_mode_name = "configuration",
            .expected = try arrays.inlineInitArrayList(
                std.testing.allocator,
                []const u8,
                &[_][]const u8{
                    "sudo",
                    "shell",
                    "privileged_exec",
                    "configuration",
                },
            ),
            .expect_fail = false,
        },
    };

    defer {
        for (cases) |case| {
            case.expected.deinit();

            var modes = case.modes;

            var modes_iterator = modes.valueIterator();

            while (modes_iterator.next()) |mode| {
                mode.deinit();
            }

            modes.deinit();
        }
    }

    for (cases) |case| {
        var visited = std.StringHashMap(bool).init(std.testing.allocator);
        defer visited.deinit();

        const actual = try getPathToMode(
            std.testing.allocator,
            case.modes,
            case.current_mode_name,
            case.requested_mode_name,
            &visited,
        );
        defer actual.deinit();

        try std.testing.expectEqualSlices([]const u8, case.expected.items, actual.items);
    }
}
