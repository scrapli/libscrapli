// zlint-disable suppressed-errors, no-undefined, unsafe-undefined
// note: disabling because tests can have unreachable blocks
// note: disabling because of driver/file setup in tests and its fine
const std = @import("std");

const scrapli = @import("scrapli");
const cli = scrapli.cli;
const operation = scrapli.cli_operation;
const mode = scrapli.cli_mode;
const flags = scrapli.flags;
const ascii = scrapli.ascii;
const errors = scrapli.errors;
const result = scrapli.cli_result;
const helper = scrapli.test_helper;

const arista_eos_platform_path_from_project_root = "src/tests/fixtures/platform_arista_eos_no_open_close_callbacks.yaml";

fn eosOnOpen(
    d: *cli.Driver,
    allocator: std.mem.Allocator,
    cancel: ?*bool,
) anyerror!*result.Result {
    return d.sendInputs(
        allocator,
        .{
            .cancel = cancel,
            .inputs = &[_][]const u8{ "term len 0", "term width 32767" },
            .retain_input = true,
            .retain_trailing_prompt = true,
            .requested_mode = "privileged_exec",
        },
    );
}

fn GetRecordTestDriver(record_path: []const u8) !*cli.Driver {
    return cli.Driver.init(
        std.testing.allocator,
        std.testing.io,
        "localhost",
        .{
            .definition = .{
                .file = "src/tests/fixtures/platform_arista_eos_no_open_close_callbacks.yaml",
            },
            .port = 22022,
            .auth = .{
                .username = "admin",
                .password = "admin",
                .lookups = .init(
                    &.{
                        .{ .key = "enable", .value = "libscrapli" },
                    },
                ),
            },
            .session = .{
                .record_destination = .{
                    .f = record_path,
                },
            },
        },
    );
}

fn GetTestDriver(f: []const u8) !*cli.Driver {
    return cli.Driver.init(
        std.testing.allocator,
        std.testing.io,
        "dummy",
        .{
            .definition = .{
                .file = "src/tests/fixtures/platform_arista_eos_no_open_close_callbacks.yaml",
            },
            .port = 22022,
            .auth = .{
                .username = "admin",
                .password = "admin",
            },
            .session = .{
                .read_size = 1,
            },
            .transport = .{
                .test_ = .{
                    .f = f,
                },
            },
        },
    );
}

fn runDriverOpenInThread(
    d: *cli.Driver,
    cancelled: *bool,
    allocator: std.mem.Allocator,
    options: operation.OpenOptions,
) !void {
    try std.testing.expectError(
        error.Cancelled,
        d.open(allocator, options),
    );

    cancelled.* = true;
}

fn runDriverGetPromptInThread(
    d: *cli.Driver,
    cancelled: *bool,
    allocator: std.mem.Allocator,
    options: operation.GetPromptOptions,
) !void {
    try std.testing.expectError(
        error.Cancelled,
        d.getPrompt(allocator, options),
    );

    cancelled.* = true;
}

fn runDriverEnterModeInThread(
    d: *cli.Driver,
    cancelled: *bool,
    allocator: std.mem.Allocator,
    options: operation.EnterModeOptions,
) !void {
    try std.testing.expectError(
        error.Cancelled,
        d.enterMode(allocator, options),
    );

    cancelled.* = true;
}

fn runDriverSendInputInThread(
    d: *cli.Driver,
    cancelled: *bool,
    allocator: std.mem.Allocator,
    options: operation.SendInputOptions,
) !void {
    try std.testing.expectError(
        error.Cancelled,
        d.sendInput(allocator, options),
    );

    cancelled.* = true;
}

fn runDriverSendInputsInThread(
    d: *cli.Driver,
    cancelled: *bool,
    allocator: std.mem.Allocator,
    options: operation.SendInputsOptions,
) !void {
    try std.testing.expectError(
        error.Cancelled,
        d.sendInputs(allocator, options),
    );

    cancelled.* = true;
}

fn runDriverSendPromptedInputInThread(
    d: *cli.Driver,
    cancelled: *bool,
    allocator: std.mem.Allocator,
    options: operation.SendPromptedInputOptions,
) !void {
    try std.testing.expectError(
        error.Cancelled,
        d.sendPromptedInput(
            allocator,
            options,
        ),
    );

    cancelled.* = true;
}

test "driver open" {
    const test_name = "driver-open";

    const cases = [_]struct {
        name: []const u8,
        onOpenCallback: ?*const fn (
            d: *cli.Driver,
            allocator: std.mem.Allocator,
            cancel: ?*bool,
        ) anyerror!*result.Result,
    }{
        .{
            .name = "simple",
            .onOpenCallback = null,
        },
        .{
            .name = "with-callback",
            .onOpenCallback = eosOnOpen,
        },
    };

    for (cases) |case| {
        const record = helper.parseCustomFlag("--record", false);

        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/golden/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(golden_filename);

        var d: *cli.Driver = undefined;

        if (record) {
            d = try GetRecordTestDriver(fixture_filename);
        } else {
            d = try GetTestDriver(fixture_filename);
        }

        d.definition.onOpenCallback = case.onOpenCallback;

        defer d.deinit();

        const actual_res = try d.open(std.testing.allocator, .{});
        defer actual_res.deinit();

        defer {
            const close_res = d.close(
                std.testing.allocator,
                .{},
            ) catch unreachable;
            close_res.deinit();
        }

        const actual = try actual_res.getResult(std.testing.allocator, .{});
        defer std.testing.allocator.free(actual);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual,
        );
    }
}

test "driver open-timeout" {
    const test_name = "driver-open-timeout";

    const fixture_filename = try std.fmt.allocPrint(
        std.testing.allocator,
        "src/tests/integration/fixtures/driver/{s}.txt",
        .{test_name},
    );
    defer std.testing.allocator.free(fixture_filename);

    var d = try GetTestDriver(fixture_filename);

    // open is more time than others just for setup and such
    d.session.options.operation_timeout_ns = 500_000;

    defer d.deinit();

    try std.testing.expectError(
        errors.ScrapliError.TimeoutExceeded,
        d.open(std.testing.allocator, .{}),
    );
}

test "driver open-cancellation" {
    const test_name = "driver-open-cancellation";

    const fixture_filename = try std.fmt.allocPrint(
        std.testing.allocator,
        "src/tests/integration/fixtures/driver/{s}.txt",
        .{test_name},
    );
    defer std.testing.allocator.free(fixture_filename);

    const golden_filename = try std.fmt.allocPrint(
        std.testing.allocator,
        "src/tests/integration/golden/driver/{s}.txt",
        .{test_name},
    );
    defer std.testing.allocator.free(golden_filename);

    var d = try GetTestDriver(fixture_filename);

    defer d.deinit();
    const cancel_ptr = try std.testing.allocator.create(bool);
    defer std.testing.allocator.destroy(cancel_ptr);

    cancel_ptr.* = false;

    const cancelled_ptr = try std.testing.allocator.create(bool);
    defer std.testing.allocator.destroy(cancelled_ptr);

    cancelled_ptr.* = false;

    var open_thread = try std.Thread.spawn(
        .{},
        runDriverOpenInThread,
        .{
            d,
            cancelled_ptr,
            std.testing.allocator,
            operation.OpenOptions{ .cancel = cancel_ptr },
        },
    );

    cancel_ptr.* = true;
    open_thread.join();

    // if the helper thread catches a error.Cancelled, then it sets this to true, so we know
    // we did in fact return early due to cancellation
    try std.testing.expect(cancelled_ptr.*);
}

test "driver get-prompt" {
    const test_name = "driver-get-prompt";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "simple",
        },
    };

    for (cases) |case| {
        const record = helper.parseCustomFlag("--record", false);

        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/golden/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(golden_filename);

        var d: *cli.Driver = undefined;

        if (record) {
            d = try GetRecordTestDriver(fixture_filename);
        } else {
            d = try GetTestDriver(fixture_filename);
        }

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        defer {
            const close_res = d.close(
                std.testing.allocator,
                .{},
            ) catch unreachable;
            close_res.deinit();
        }

        const res = try d.getPrompt(
            std.testing.allocator,
            .{},
        );
        defer res.deinit();

        const actual = try res.getResult(std.testing.allocator, .{});
        defer std.testing.allocator.free(actual);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual,
        );
    }
}

test "driver get-prompt-timeout" {
    const test_name = "driver-get-prompt-timeout";

    const fixture_filename = try std.fmt.allocPrint(
        std.testing.allocator,
        "src/tests/integration/fixtures/driver/{s}.txt",
        .{test_name},
    );
    defer std.testing.allocator.free(fixture_filename);

    const golden_filename = try std.fmt.allocPrint(
        std.testing.allocator,
        "src/tests/integration/golden/driver/{s}.txt",
        .{test_name},
    );
    defer std.testing.allocator.free(golden_filename);

    const d = try GetTestDriver(fixture_filename);

    defer d.deinit();

    const open_res = try d.open(std.testing.allocator, .{});
    defer open_res.deinit();

    defer {
        const close_res = d.close(
            std.testing.allocator,
            .{},
        ) catch unreachable;
        close_res.deinit();
    }

    d.session.options.operation_timeout_ns = 100_000;

    try std.testing.expectError(
        errors.ScrapliError.TimeoutExceeded,
        d.getPrompt(
            std.testing.allocator,
            .{},
        ),
    );
}

test "driver get-prompt-cancellation" {
    const test_name = "driver-get-prompt-cancellation";

    const fixture_filename = try std.fmt.allocPrint(
        std.testing.allocator,
        "src/tests/integration/fixtures/driver/{s}.txt",
        .{test_name},
    );
    defer std.testing.allocator.free(fixture_filename);

    const golden_filename = try std.fmt.allocPrint(
        std.testing.allocator,
        "src/tests/integration/golden/driver/{s}.txt",
        .{test_name},
    );
    defer std.testing.allocator.free(golden_filename);

    const d = try GetTestDriver(fixture_filename);

    defer d.deinit();

    const open_res = try d.open(std.testing.allocator, .{});
    defer open_res.deinit();

    const cancel_ptr = try std.testing.allocator.create(bool);
    defer std.testing.allocator.destroy(cancel_ptr);

    cancel_ptr.* = false;

    const cancelled_ptr = try std.testing.allocator.create(bool);
    defer std.testing.allocator.destroy(cancelled_ptr);

    cancelled_ptr.* = false;

    var get_prompt_thread = try std.Thread.spawn(
        .{},
        runDriverGetPromptInThread,
        .{
            d,
            cancelled_ptr,
            std.testing.allocator,
            operation.GetPromptOptions{ .cancel = cancel_ptr },
        },
    );

    cancel_ptr.* = true;
    get_prompt_thread.join();

    // if the helper thread catches a error.Cancelled, then it sets this to true, so we know
    // we did in fact return early due to cancellation
    try std.testing.expect(cancelled_ptr.*);
}

test "driver enter-mode" {
    const test_name = "driver-enter-mode";

    const cases = [_]struct {
        name: []const u8,
        requested_mode: []const u8,
    }{
        .{
            .name = "no-change",
            .requested_mode = "exec",
        },
        .{
            .name = "priv-exec-to-priv-exec",
            .requested_mode = "privileged_exec",
        },
        .{
            .name = "exec-to-configuration",
            .requested_mode = "configuration",
        },
    };

    for (cases) |case| {
        const record = helper.parseCustomFlag("--record", false);

        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/golden/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(golden_filename);

        var d: *cli.Driver = undefined;

        if (record) {
            d = try GetRecordTestDriver(fixture_filename);
        } else {
            d = try GetTestDriver(fixture_filename);
        }

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        defer {
            const close_res = d.close(
                std.testing.allocator,
                .{},
            ) catch unreachable;
            close_res.deinit();
        }

        const res = try d.enterMode(
            std.testing.allocator,
            .{ .requested_mode = case.requested_mode },
        );
        defer res.deinit();

        const actual = try res.getResult(std.testing.allocator, .{});
        defer std.testing.allocator.free(actual);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual,
        );
    }
}

test "driver enter-mode-timeout" {
    const test_name = "driver-enter-mode-timeout";

    const fixture_filename = try std.fmt.allocPrint(
        std.testing.allocator,
        "src/tests/integration/fixtures/driver/{s}.txt",
        .{test_name},
    );
    defer std.testing.allocator.free(fixture_filename);

    var d = try GetTestDriver(fixture_filename);

    defer d.deinit();

    const open_res = try d.open(std.testing.allocator, .{});
    defer open_res.deinit();

    d.session.options.operation_timeout_ns = 100_000;

    try std.testing.expectError(
        errors.ScrapliError.TimeoutExceeded,
        d.enterMode(
            std.testing.allocator,
            .{ .requested_mode = "configuration" },
        ),
    );
}

test "driver enter-mode-cancellation" {
    const test_name = "driver-enter-mode-cancellation";

    const fixture_filename = try std.fmt.allocPrint(
        std.testing.allocator,
        "src/tests/integration/fixtures/driver/{s}.txt",
        .{test_name},
    );
    defer std.testing.allocator.free(fixture_filename);

    const golden_filename = try std.fmt.allocPrint(
        std.testing.allocator,
        "src/tests/integration/golden/driver/{s}.txt",
        .{test_name},
    );
    defer std.testing.allocator.free(golden_filename);

    const d = try GetTestDriver(fixture_filename);

    defer d.deinit();

    const open_res = try d.open(std.testing.allocator, .{});
    defer open_res.deinit();

    const cancel_ptr = try std.testing.allocator.create(bool);
    defer std.testing.allocator.destroy(cancel_ptr);

    cancel_ptr.* = false;

    const cancelled_ptr = try std.testing.allocator.create(bool);
    defer std.testing.allocator.destroy(cancelled_ptr);

    cancelled_ptr.* = false;

    var enter_mode_thread = try std.Thread.spawn(
        .{},
        runDriverEnterModeInThread,
        .{
            d,
            cancelled_ptr,
            std.testing.allocator,
            operation.EnterModeOptions{
                .cancel = cancel_ptr,
                .requested_mode = "configuration",
            },
        },
    );

    cancel_ptr.* = true;
    enter_mode_thread.join();

    // if the helper thread catches a error.Cancelled, then it sets this to true, so we know
    // we did in fact return early due to cancellation
    try std.testing.expect(cancelled_ptr.*);
}

test "driver send-input" {
    const test_name = "driver-send-input";

    const cases = [_]struct {
        name: []const u8,
        input: []const u8,
        retain_input: bool,
        retain_trailing_prompt: bool,
        requested_mode: []const u8,
    }{
        .{
            .name = "simple",
            .input = "show ip route",
            // default retention behavior
            .retain_input = false,
            .retain_trailing_prompt = false,
            .requested_mode = mode.default_mode,
        },
        .{
            .name = "retain-input",
            .input = "show ip route",
            .retain_input = true,
            .retain_trailing_prompt = false,
            .requested_mode = mode.default_mode,
        },
        .{
            .name = "retain-prompt",
            .input = "show ip route",
            .retain_input = false,
            .retain_trailing_prompt = true,
            .requested_mode = mode.default_mode,
        },
        .{
            .name = "retain-all",
            .input = "show ip route",
            .retain_input = true,
            .retain_trailing_prompt = true,
            .requested_mode = mode.default_mode,
        },
        .{
            .name = "change-priv-level",
            .input = "do show ip route",
            .retain_input = true,
            .retain_trailing_prompt = true,
            .requested_mode = "configuration",
        },
    };

    for (cases) |case| {
        const record = helper.parseCustomFlag("--record", false);

        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/golden/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(golden_filename);

        var d: *cli.Driver = undefined;

        if (record) {
            d = try GetRecordTestDriver(fixture_filename);
        } else {
            d = try GetTestDriver(fixture_filename);
        }

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        defer {
            const close_res = d.close(
                std.testing.allocator,
                .{},
            ) catch unreachable;
            close_res.deinit();
        }

        const res = try d.sendInput(
            std.testing.allocator,
            .{
                .input = case.input,
                .retain_input = case.retain_input,
                .retain_trailing_prompt = case.retain_trailing_prompt,
                .requested_mode = case.requested_mode,
            },
        );
        defer res.deinit();

        const actual = try res.getResult(std.testing.allocator, .{});
        defer std.testing.allocator.free(actual);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual,
        );
    }
}

test "driver send-input-timeout" {
    const test_name = "driver-send-input-timeout";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "cant-find-initial-prompt",
        },
        .{
            .name = "cant-find-input",
        },
        .{
            .name = "cant-find-final-prompt",
        },
    };

    for (cases) |case| {
        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        var d = try GetTestDriver(fixture_filename);

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        d.session.options.operation_timeout_ns = 100_000;

        try std.testing.expectError(
            errors.ScrapliError.TimeoutExceeded,
            d.sendInput(
                std.testing.allocator,
                .{
                    .input = "show run int vlan 1",
                },
            ),
        );
    }
}

test "driver send-input-cancellation" {
    const test_name = "driver-send-input-cancellation";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "at-find-initial-prompt",
        },
        .{
            .name = "at-find-input",
        },
        .{
            .name = "at-find-final-prompt",
        },
    };

    for (cases) |case| {
        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        var d = try GetTestDriver(fixture_filename);

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const cancel_ptr = try std.testing.allocator.create(bool);
        defer std.testing.allocator.destroy(cancel_ptr);

        const cancelled_ptr = try std.testing.allocator.create(bool);
        defer std.testing.allocator.destroy(cancelled_ptr);

        cancelled_ptr.* = false;

        var send_input_thread = try std.Thread.spawn(
            .{},
            runDriverSendInputInThread,
            .{
                d,
                cancelled_ptr,
                std.testing.allocator,
                operation.SendInputOptions{
                    .cancel = cancel_ptr,
                    .input = "show ip route",
                },
            },
        );

        cancel_ptr.* = true;
        send_input_thread.join();

        // if the helper thread catches a error.Cancelled, then it sets this to true, so we know
        // we did in fact return early due to cancellation
        try std.testing.expect(cancelled_ptr.*);
    }
}

test "driver send-inputs" {
    const test_name = "driver-send-inputs";

    const cases = [_]struct {
        name: []const u8,
        inputs: []const []const u8,
        retain_input: bool,
        retain_trailing_prompt: bool,
        requested_mode: []const u8,
    }{
        .{
            .name = "simple",
            .inputs = &[_][]const u8{ "show ip route", "show run | i hostname" },
            // default retention behavior
            .retain_input = false,
            .retain_trailing_prompt = false,
            .requested_mode = mode.default_mode,
        },
        .{
            .name = "retain-input",
            .inputs = &[_][]const u8{ "show ip route", "show run | i hostname" },
            .retain_input = true,
            .retain_trailing_prompt = false,
            .requested_mode = mode.default_mode,
        },
        .{
            .name = "retain-prompt",
            .inputs = &[_][]const u8{ "show ip route", "show run | i hostname" },
            .retain_input = false,
            .retain_trailing_prompt = true,
            .requested_mode = mode.default_mode,
        },
        .{
            .name = "retain-all",
            .inputs = &[_][]const u8{ "show ip route", "show run | i hostname" },
            .retain_input = true,
            .retain_trailing_prompt = true,
            .requested_mode = mode.default_mode,
        },
        .{
            .name = "change-priv-level",
            .inputs = &[_][]const u8{ "do show ip route", "do show run | i hostname" },
            // retain input and prompt so we see what happened, otherwise we just have whitespace
            .retain_input = true,
            .retain_trailing_prompt = true,
            .requested_mode = "configuration",
        },
    };

    for (cases) |case| {
        const record = helper.parseCustomFlag("--record", false);

        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/golden/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(golden_filename);

        var d: *cli.Driver = undefined;

        if (record) {
            d = try GetRecordTestDriver(fixture_filename);
        } else {
            d = try GetTestDriver(fixture_filename);
        }

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        defer {
            const close_res = d.close(
                std.testing.allocator,
                .{},
            ) catch unreachable;
            close_res.deinit();
        }

        const res = try d.sendInputs(
            std.testing.allocator,
            .{
                .inputs = case.inputs,
                .retain_input = case.retain_input,
                .retain_trailing_prompt = case.retain_trailing_prompt,
                .requested_mode = case.requested_mode,
            },
        );
        defer res.deinit();

        const actual = try res.getResult(std.testing.allocator, .{});
        defer std.testing.allocator.free(actual);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual,
        );
    }
}

test "driver send-inputs-timeout" {
    const test_name = "driver-send-inputs-timeout";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "cant-find-initial-prompt",
        },
        .{
            .name = "cant-find-input",
        },
        .{
            .name = "cant-find-final-prompt",
        },
    };

    for (cases) |case| {
        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        var d = try GetTestDriver(fixture_filename);

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        d.session.options.operation_timeout_ns = 100_000;

        try std.testing.expectError(
            errors.ScrapliError.TimeoutExceeded,
            d.sendInputs(
                std.testing.allocator,
                .{
                    .inputs = &[_][]const u8{
                        "show run int vlan 1",
                        "show run | i hostname",
                    },
                },
            ),
        );
    }
}

test "driver send-inputs-cancellation" {
    const test_name = "driver-send-inputs-cancellation";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "at-find-initial-prompt",
        },
        .{
            .name = "at-find-input",
        },
        .{
            .name = "at-find-final-prompt",
        },
    };

    for (cases) |case| {
        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        var d = try GetTestDriver(fixture_filename);

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const cancel_ptr = try std.testing.allocator.create(bool);
        defer std.testing.allocator.destroy(cancel_ptr);

        cancel_ptr.* = false;

        const cancelled_ptr = try std.testing.allocator.create(bool);
        defer std.testing.allocator.destroy(cancelled_ptr);

        cancelled_ptr.* = false;

        var send_inputs_thread = try std.Thread.spawn(
            .{},
            runDriverSendInputsInThread,
            .{
                d,
                cancelled_ptr,
                std.testing.allocator,
                operation.SendInputsOptions{
                    .cancel = cancel_ptr,
                    .inputs = &[_][]const u8{ "show run int vlan 1", "show run | i hostname" },
                },
            },
        );

        cancel_ptr.* = true;
        send_inputs_thread.join();

        // if the helper thread catches a error.Cancelled, then it sets this to true, so we know
        // we did in fact return early due to cancellation
        try std.testing.expect(cancelled_ptr.*);
    }
}

test "driver send-prompted-input" {
    const test_name = "driver-send-prompted-input";

    const cases = [_]struct {
        name: []const u8,
        input: []const u8,
        prompt: []const u8,
        response: []const u8,
        retain_trailing_prompt: bool,
        requested_mode: []const u8,
    }{
        .{
            .name = "simple",
            .input = "write erase",
            .prompt = "Proceed with erasing startup configuration? [confirm]",
            .response = &[_]u8{ascii.control_chars.etx},
            // default retention behavior
            .retain_trailing_prompt = false,
            .requested_mode = mode.default_mode,
        },
        // note: no option to not retain input for send prompted input because output would be
        // super weird!
        .{
            .name = "retain-prompt",
            .input = "write erase",
            .prompt = "Proceed with erasing startup configuration? [confirm]",
            .response = &[_]u8{ascii.control_chars.etx},
            .retain_trailing_prompt = true,
            .requested_mode = mode.default_mode,
        },
        .{
            .name = "change-priv-level",
            .input = "write erase",
            .prompt = "Proceed with erasing startup configuration? [confirm]",
            .response = &[_]u8{ascii.control_chars.etx},
            .retain_trailing_prompt = true,
            .requested_mode = "configuration",
        },
    };

    for (cases) |case| {
        const record = helper.parseCustomFlag("--record", false);

        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/golden/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(golden_filename);

        var d: *cli.Driver = undefined;

        if (record) {
            d = try GetRecordTestDriver(fixture_filename);
        } else {
            d = try GetTestDriver(fixture_filename);
        }

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        defer {
            const close_res = d.close(
                std.testing.allocator,
                .{},
            ) catch unreachable;
            close_res.deinit();
        }

        const res = try d.sendPromptedInput(
            std.testing.allocator,
            .{
                .input = case.input,
                .prompt_exact = case.prompt,
                .response = case.response,
                .retain_trailing_prompt = case.retain_trailing_prompt,
                .requested_mode = case.requested_mode,
            },
        );
        defer res.deinit();

        const actual = try res.getResult(std.testing.allocator, .{});
        defer std.testing.allocator.free(actual);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual,
        );
    }
}

test "driver send-prompted-input-timeout" {
    const test_name = "driver-send-prompted-input-timeout";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "at-find-initial-prompt",
        },
        .{
            .name = "at-find-input",
        },
        .{
            .name = "at-find-prompt",
        },
        .{
            .name = "at-find-final-prompt",
        },
    };

    for (cases) |case| {
        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        var d = try GetTestDriver(fixture_filename);

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const cancel_ptr = try std.testing.allocator.create(bool);
        defer std.testing.allocator.destroy(cancel_ptr);

        cancel_ptr.* = false;

        const cancelled_ptr = try std.testing.allocator.create(bool);
        defer std.testing.allocator.destroy(cancelled_ptr);

        cancelled_ptr.* = false;

        var send_inputs_thread = try std.Thread.spawn(
            .{},
            runDriverSendPromptedInputInThread,
            .{
                d,
                cancelled_ptr,
                std.testing.allocator,
                operation.SendPromptedInputOptions{
                    .cancel = cancel_ptr,
                    .input = "write erase",
                    .prompt_exact = "Proceed with erasing startup configuration? [confirm]",
                    .response = "",
                },
            },
        );

        cancel_ptr.* = true;
        send_inputs_thread.join();

        // if the helper thread catches a error.Cancelled, then it sets this to true, so we know
        // we did in fact return early due to cancellation
        try std.testing.expect(cancelled_ptr.*);
    }
}

test "driver send-prompted-input-cancellation" {
    const test_name = "driver-send-prompted-input-cancellation";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "at-find-initial-prompt",
        },
        .{
            .name = "at-find-input",
        },
        .{
            .name = "at-find-prompt",
        },
        .{
            .name = "at-find-final-prompt",
        },
    };

    for (cases) |case| {
        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/driver/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        var d = try GetTestDriver(fixture_filename);

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        d.session.options.operation_timeout_ns = 100_000;

        try std.testing.expectError(
            errors.ScrapliError.TimeoutExceeded,
            d.sendPromptedInput(
                std.testing.allocator,
                .{
                    .input = "clear logging",
                    .prompt_exact = "Clear logging buffer [confirm]",
                    .response = "",
                },
            ),
        );
    }
}
