// zlint-disable suppressed-errors, no-undefined, unsafe-undefined
// note: disabling because tests can have unreachable blocks
// note: disabling because of driver/file setup in tests and its fine
const std = @import("std");

const driver = @import("../../driver.zig");
const operation = @import("../../operation.zig");
const mode = @import("../../mode.zig");
const flags = @import("../../flags.zig");
const ascii = @import("../../ascii.zig");
const file = @import("../../file.zig");
const result = @import("../../result.zig");

const helper = @import("../../test-helper.zig");

const arista_eos_platform_path_from_project_root = "src/tests/fixtures/platform_arista_eos_no_open_close_callbacks.yaml";

fn eosOnOpen(
    d: *driver.Driver,
    allocator: std.mem.Allocator,
    cancel: ?*bool,
) anyerror!*result.Result {
    var opts = operation.NewSendInputOptions();
    opts.cancel = cancel;
    opts.retain_input = true;
    opts.retain_trailing_prompt = true;
    opts.requested_mode = "privileged_exec";

    return d.sendInputs(
        allocator,
        &[_][]const u8{ "term len 0", "term width 32767" },
        opts,
    );
}

fn getPlatformPath(buf: []u8) !usize {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.posix.getcwd(&cwd_buf);

    var platform_path_len: usize = 0;

    @memcpy(buf[0..cwd.len], cwd[0..cwd.len]);
    platform_path_len += cwd.len;

    buf[platform_path_len] = "/"[0];
    platform_path_len += 1;

    @memcpy(
        buf[platform_path_len .. platform_path_len + arista_eos_platform_path_from_project_root.len],
        arista_eos_platform_path_from_project_root,
    );
    platform_path_len += arista_eos_platform_path_from_project_root.len;

    return platform_path_len;
}

fn GetRecordTestDriver(recorder: std.fs.File.Writer) !*driver.Driver {
    var platform_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const platform_path_len = try getPlatformPath(&platform_path_buf);

    return driver.Driver.init(
        std.testing.allocator,
        "localhost",
        .{
            .definition = .{
                .file = platform_path_buf[0..platform_path_len],
            },
            .port = 22022,
            .auth = .{
                .username = "admin",
                .password = "password",
            },
            .session = .{
                .recorder = recorder,
            },
        },
    );
}

fn GetTestDriver(f: []const u8) !*driver.Driver {
    var platform_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const platform_path_len = try getPlatformPath(&platform_path_buf);

    return driver.Driver.init(
        std.testing.allocator,
        "dummy",
        .{
            .definition = .{
                .file = platform_path_buf[0..platform_path_len],
            },
            .port = 22022,
            .auth = .{
                .username = "admin",
                .password = "password",
            },
            .session = .{
                .read_size = 1,
                .read_delay_backoff_factor = 1,
                .read_delay_min_ns = 1,
                .read_delay_max_ns = 1,
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
    d: *driver.Driver,
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
    d: *driver.Driver,
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
    d: *driver.Driver,
    cancelled: *bool,
    allocator: std.mem.Allocator,
    requested_mode: []const u8,
    options: operation.EnterModeOptions,
) !void {
    try std.testing.expectError(
        error.Cancelled,
        d.enterMode(allocator, requested_mode, options),
    );

    cancelled.* = true;
}

fn runDriverSendInputInThread(
    d: *driver.Driver,
    cancelled: *bool,
    allocator: std.mem.Allocator,
    input: []const u8,
    options: operation.SendInputOptions,
) !void {
    try std.testing.expectError(
        error.Cancelled,
        d.sendInput(allocator, input, options),
    );

    cancelled.* = true;
}

fn runDriverSendInputsInThread(
    d: *driver.Driver,
    cancelled: *bool,
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    options: operation.SendInputOptions,
) !void {
    try std.testing.expectError(
        error.Cancelled,
        d.sendInputs(allocator, inputs, options),
    );

    cancelled.* = true;
}

fn runDriverSendPromptedInputInThread(
    d: *driver.Driver,
    cancelled: *bool,
    allocator: std.mem.Allocator,
    input: []const u8,
    prompt: []const u8,
    response: []const u8,
    options: operation.SendPromptedInputOptions,
) !void {
    try std.testing.expectError(
        error.Cancelled,
        d.sendPromptedInput(allocator, input, prompt, response, options),
    );

    cancelled.* = true;
}

test "driver open" {
    const test_name = "driver-open";

    const cases = [_]struct {
        name: []const u8,
        on_open_callback: ?*const fn (
            d: *driver.Driver,
            allocator: std.mem.Allocator,
            cancel: ?*bool,
        ) anyerror!*result.Result,
    }{
        .{
            .name = "simple",
            .on_open_callback = null,
        },
        .{
            .name = "with-callback",
            .on_open_callback = eosOnOpen,
        },
    };

    for (cases) |case| {
        const record = flags.parseCustomFlag("--record", false);

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

        var f: std.fs.File = undefined;

        defer {
            if (record) {
                f.close();

                var content = file.readFromPath(std.testing.allocator, fixture_filename) catch unreachable;
                defer std.testing.allocator.free(content);

                const new_size = ascii.stripAsciiAndAnsiControlCharsInPlace(content, 0);
                file.writeToPath(std.testing.allocator, fixture_filename, content[0..new_size]) catch unreachable;
            }
        }

        var d: *driver.Driver = undefined;

        if (record) {
            f = try std.fs.cwd().createFile(
                fixture_filename,
                .{},
            );

            d = try GetRecordTestDriver(f.writer());
        } else {
            d = try GetTestDriver(fixture_filename);
        }

        d.definition.on_open_callback = case.on_open_callback;

        defer d.deinit();

        const actual_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer actual_res.deinit();

        defer {
            const close_res = d.close(std.testing.allocator, operation.NewCloseOptions()) catch unreachable;
            close_res.deinit();
        }

        const actual = try actual_res.getResult(std.testing.allocator);
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
    d.session.options.operation_timeout_ns = 100_000;

    defer d.deinit();

    try std.testing.expectError(
        error.AuthenicationTimeoutExceeded,
        d.open(std.testing.allocator, operation.NewOpenOptions()),
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

    var open_options = operation.NewOpenOptions();

    const cancel_ptr = try std.testing.allocator.create(bool);
    defer std.testing.allocator.destroy(cancel_ptr);

    cancel_ptr.* = false;
    open_options.cancel = cancel_ptr;

    const cancelled_ptr = try std.testing.allocator.create(bool);
    defer std.testing.allocator.destroy(cancelled_ptr);

    cancelled_ptr.* = false;

    const start_time = std.time.microTimestamp();

    var open_thread = try std.Thread.spawn(
        .{},
        runDriverOpenInThread,
        .{ d, cancelled_ptr, std.testing.allocator, open_options },
    );

    std.time.sleep(1_000);

    cancel_ptr.* = true;
    open_thread.join();

    const done_time = std.time.microTimestamp();

    // time bits here to assert that the thread did join/finish quickly since we cancelled, also
    // check the cancelled_ptr to ensure the thread did in fact end up having the function call
    // cancelled
    try std.testing.expect(done_time - start_time < 5_000);
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
        const record = flags.parseCustomFlag("--record", false);

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

        var f: std.fs.File = undefined;

        defer {
            if (record) {
                f.close();

                var content = file.readFromPath(std.testing.allocator, fixture_filename) catch unreachable;
                defer std.testing.allocator.free(content);

                const new_size = ascii.stripAsciiAndAnsiControlCharsInPlace(content, 0);
                file.writeToPath(std.testing.allocator, fixture_filename, content[0..new_size]) catch unreachable;
            }
        }

        var d: *driver.Driver = undefined;

        if (record) {
            f = try std.fs.cwd().createFile(
                fixture_filename,
                .{},
            );

            d = try GetRecordTestDriver(f.writer());
        } else {
            d = try GetTestDriver(fixture_filename);
        }

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer open_res.deinit();

        defer {
            const close_res = d.close(std.testing.allocator, operation.NewCloseOptions()) catch unreachable;
            close_res.deinit();
        }

        const res = try d.getPrompt(
            std.testing.allocator,
            operation.NewGetPromptOptions(),
        );
        defer res.deinit();

        const actual = try res.getResult(std.testing.allocator);
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

    const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
    defer open_res.deinit();

    defer {
        const close_res = d.close(std.testing.allocator, operation.NewCloseOptions()) catch unreachable;
        close_res.deinit();
    }

    // so the test is faster of course
    d.session.options.operation_timeout_ns = 250 * std.time.ms_per_s;

    try std.testing.expectError(
        error.Timeout,
        d.getPrompt(
            std.testing.allocator,
            operation.NewGetPromptOptions(),
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

    const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
    defer open_res.deinit();

    var getPrompt_options = operation.NewGetPromptOptions();

    const cancel_ptr = try std.testing.allocator.create(bool);
    defer std.testing.allocator.destroy(cancel_ptr);

    cancel_ptr.* = false;
    getPrompt_options.cancel = cancel_ptr;

    const cancelled_ptr = try std.testing.allocator.create(bool);
    defer std.testing.allocator.destroy(cancelled_ptr);

    cancelled_ptr.* = false;

    const start_time = std.time.microTimestamp();

    var getPrompt_thread = try std.Thread.spawn(
        .{},
        runDriverGetPromptInThread,
        .{ d, cancelled_ptr, std.testing.allocator, getPrompt_options },
    );

    std.time.sleep(1_000);

    cancel_ptr.* = true;
    getPrompt_thread.join();

    const done_time = std.time.microTimestamp();

    // time bits here to assert that the thread did join/finish quickly since we cancelled, also
    // check the cancelled_ptr to ensure the thread did in fact end up having the function call
    // cancelled
    try std.testing.expect(done_time - start_time < 5_000);
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
        const record = flags.parseCustomFlag("--record", false);

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

        var f: std.fs.File = undefined;

        defer {
            if (record) {
                f.close();

                var content = file.readFromPath(std.testing.allocator, fixture_filename) catch unreachable;
                defer std.testing.allocator.free(content);

                const new_size = ascii.stripAsciiAndAnsiControlCharsInPlace(content, 0);
                file.writeToPath(std.testing.allocator, fixture_filename, content[0..new_size]) catch unreachable;
            }
        }

        var d: *driver.Driver = undefined;

        if (record) {
            f = try std.fs.cwd().createFile(
                fixture_filename,
                .{},
            );

            d = try GetRecordTestDriver(f.writer());
        } else {
            d = try GetTestDriver(fixture_filename);
        }

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer open_res.deinit();

        defer {
            const close_res = d.close(std.testing.allocator, operation.NewCloseOptions()) catch unreachable;
            close_res.deinit();
        }

        const opts = operation.NewEnterModeOptions();

        const res = try d.enterMode(
            std.testing.allocator,
            case.requested_mode,
            opts,
        );
        defer res.deinit();

        const actual = try res.getResult(std.testing.allocator);
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

    const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
    defer open_res.deinit();

    // so the test is faster of course
    d.session.options.operation_timeout_ns = 250 * std.time.ms_per_s;

    try std.testing.expectError(
        error.Timeout,
        d.enterMode(std.testing.allocator, "configuration", operation.NewEnterModeOptions()),
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

    const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
    defer open_res.deinit();

    var enterMode_options = operation.NewEnterModeOptions();

    const cancel_ptr = try std.testing.allocator.create(bool);
    defer std.testing.allocator.destroy(cancel_ptr);

    cancel_ptr.* = false;
    enterMode_options.cancel = cancel_ptr;

    const cancelled_ptr = try std.testing.allocator.create(bool);
    defer std.testing.allocator.destroy(cancelled_ptr);

    cancelled_ptr.* = false;

    const start_time = std.time.microTimestamp();

    var enterMode_thread = try std.Thread.spawn(
        .{},
        runDriverEnterModeInThread,
        .{ d, cancelled_ptr, std.testing.allocator, "configuration", enterMode_options },
    );

    std.time.sleep(1_000);

    cancel_ptr.* = true;
    enterMode_thread.join();

    const done_time = std.time.microTimestamp();

    // time bits here to assert that the thread did join/finish quickly since we cancelled, also
    // check the cancelled_ptr to ensure the thread did in fact end up having the function call
    // cancelled
    try std.testing.expect(done_time - start_time < 5_000);
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
        const record = flags.parseCustomFlag("--record", false);

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

        var f: std.fs.File = undefined;

        defer {
            if (record) {
                f.close();

                var content = file.readFromPath(std.testing.allocator, fixture_filename) catch unreachable;
                defer std.testing.allocator.free(content);

                const new_size = ascii.stripAsciiAndAnsiControlCharsInPlace(content, 0);
                file.writeToPath(std.testing.allocator, fixture_filename, content[0..new_size]) catch unreachable;
            }
        }

        var d: *driver.Driver = undefined;

        if (record) {
            f = try std.fs.cwd().createFile(
                fixture_filename,
                .{},
            );

            d = try GetRecordTestDriver(f.writer());
        } else {
            d = try GetTestDriver(fixture_filename);
        }

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer open_res.deinit();

        defer {
            const close_res = d.close(std.testing.allocator, operation.NewCloseOptions()) catch unreachable;
            close_res.deinit();
        }

        var opts = operation.NewSendInputOptions();
        opts.retain_input = case.retain_input;
        opts.retain_trailing_prompt = case.retain_trailing_prompt;
        opts.requested_mode = case.requested_mode;

        const res = try d.sendInput(
            std.testing.allocator,
            case.input,
            opts,
        );
        defer res.deinit();

        const actual = try res.getResult(std.testing.allocator);
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

        const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer open_res.deinit();

        // so the test is faster of course
        d.session.options.operation_timeout_ns = 250 * std.time.ms_per_s;

        try std.testing.expectError(
            error.Timeout,
            d.sendInput(
                std.testing.allocator,
                "show run int vlan 1",
                operation.NewSendInputOptions(),
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

        const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer open_res.deinit();

        var send_input_options = operation.NewSendInputOptions();

        const cancel_ptr = try std.testing.allocator.create(bool);
        defer std.testing.allocator.destroy(cancel_ptr);

        cancel_ptr.* = false;
        send_input_options.cancel = cancel_ptr;

        const cancelled_ptr = try std.testing.allocator.create(bool);
        defer std.testing.allocator.destroy(cancelled_ptr);

        cancelled_ptr.* = false;

        const start_time = std.time.microTimestamp();

        var send_input_thread = try std.Thread.spawn(
            .{},
            runDriverSendInputInThread,
            .{ d, cancelled_ptr, std.testing.allocator, "show ip route", send_input_options },
        );

        std.time.sleep(1_000);

        cancel_ptr.* = true;
        send_input_thread.join();

        const done_time = std.time.microTimestamp();

        // time bits here to assert that the thread did join/finish quickly since we cancelled, also
        // check the cancelled_ptr to ensure the thread did in fact end up having the function call
        // cancelled
        try std.testing.expect(done_time - start_time < 5_000);
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
        const record = flags.parseCustomFlag("--record", false);

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

        var f: std.fs.File = undefined;

        defer {
            if (record) {
                f.close();

                var content = file.readFromPath(std.testing.allocator, fixture_filename) catch unreachable;
                defer std.testing.allocator.free(content);

                const new_size = ascii.stripAsciiAndAnsiControlCharsInPlace(content, 0);
                file.writeToPath(std.testing.allocator, fixture_filename, content[0..new_size]) catch unreachable;
            }
        }

        var d: *driver.Driver = undefined;

        if (record) {
            f = try std.fs.cwd().createFile(
                fixture_filename,
                .{},
            );

            d = try GetRecordTestDriver(f.writer());
        } else {
            d = try GetTestDriver(fixture_filename);
        }

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer open_res.deinit();

        defer {
            const close_res = d.close(std.testing.allocator, operation.NewCloseOptions()) catch unreachable;
            close_res.deinit();
        }

        var opts = operation.NewSendInputOptions();
        opts.retain_input = case.retain_input;
        opts.retain_trailing_prompt = case.retain_trailing_prompt;
        opts.requested_mode = case.requested_mode;

        const res = try d.sendInputs(
            std.testing.allocator,
            case.inputs,
            opts,
        );
        defer res.deinit();

        const actual = try res.getResult(std.testing.allocator);
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

        const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer open_res.deinit();

        // so the test is faster of course
        d.session.options.operation_timeout_ns = 250 * std.time.ms_per_s;

        try std.testing.expectError(
            error.Timeout,
            d.sendInputs(
                std.testing.allocator,
                &[_][]const u8{ "show run int vlan 1", "show run | i hostname" },
                operation.NewSendInputOptions(),
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

        const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer open_res.deinit();

        var send_input_options = operation.NewSendInputOptions();

        const cancel_ptr = try std.testing.allocator.create(bool);
        defer std.testing.allocator.destroy(cancel_ptr);

        cancel_ptr.* = false;
        send_input_options.cancel = cancel_ptr;

        const cancelled_ptr = try std.testing.allocator.create(bool);
        defer std.testing.allocator.destroy(cancelled_ptr);

        cancelled_ptr.* = false;

        const start_time = std.time.microTimestamp();

        var send_inputs_thread = try std.Thread.spawn(
            .{},
            runDriverSendInputsInThread,
            .{
                d,
                cancelled_ptr,
                std.testing.allocator,
                &[_][]const u8{ "show run int vlan 1", "show run | i hostname" },
                send_input_options,
            },
        );

        std.time.sleep(1_000);

        cancel_ptr.* = true;
        send_inputs_thread.join();

        const done_time = std.time.microTimestamp();

        // time bits here to assert that the thread did join/finish quickly since we cancelled, also
        // check the cancelled_ptr to ensure the thread did in fact end up having the function call
        // cancelled
        try std.testing.expect(done_time - start_time < 5_000);
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
        const record = flags.parseCustomFlag("--record", false);

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

        var f: std.fs.File = undefined;

        defer {
            if (record) {
                f.close();

                var content = file.readFromPath(std.testing.allocator, fixture_filename) catch unreachable;
                defer std.testing.allocator.free(content);

                const new_size = ascii.stripAsciiAndAnsiControlCharsInPlace(content, 0);
                file.writeToPath(std.testing.allocator, fixture_filename, content[0..new_size]) catch unreachable;
            }
        }

        var d: *driver.Driver = undefined;

        if (record) {
            f = try std.fs.cwd().createFile(
                fixture_filename,
                .{},
            );

            d = try GetRecordTestDriver(f.writer());
        } else {
            d = try GetTestDriver(fixture_filename);
        }

        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer open_res.deinit();

        defer {
            const close_res = d.close(std.testing.allocator, operation.NewCloseOptions()) catch unreachable;
            close_res.deinit();
        }

        var opts = operation.NewSendPromptedInputOptions();
        opts.retain_trailing_prompt = case.retain_trailing_prompt;
        opts.requested_mode = case.requested_mode;

        const res = try d.sendPromptedInput(
            std.testing.allocator,
            case.input,
            case.prompt,
            case.response,
            opts,
        );
        defer res.deinit();

        const actual = try res.getResult(std.testing.allocator);
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

        const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer open_res.deinit();

        var send_prompted_input_options = operation.NewSendPromptedInputOptions();

        const cancel_ptr = try std.testing.allocator.create(bool);
        defer std.testing.allocator.destroy(cancel_ptr);

        cancel_ptr.* = false;
        send_prompted_input_options.cancel = cancel_ptr;

        const cancelled_ptr = try std.testing.allocator.create(bool);
        defer std.testing.allocator.destroy(cancelled_ptr);

        cancelled_ptr.* = false;

        const start_time = std.time.microTimestamp();

        var send_inputs_thread = try std.Thread.spawn(
            .{},
            runDriverSendPromptedInputInThread,
            .{
                d,
                cancelled_ptr,
                std.testing.allocator,
                "write erase",
                "Proceed with erasing startup configuration? [confirm]",
                "",
                send_prompted_input_options,
            },
        );

        std.time.sleep(1_000);

        cancel_ptr.* = true;
        send_inputs_thread.join();

        const done_time = std.time.microTimestamp();

        // time bits here to assert that the thread did join/finish quickly since we cancelled, also
        // check the cancelled_ptr to ensure the thread did in fact end up having the function call
        // cancelled
        try std.testing.expect(done_time - start_time < 5_000);
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

        const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer open_res.deinit();

        // so the test is faster of course
        d.session.options.operation_timeout_ns = 250 * std.time.ms_per_s;

        try std.testing.expectError(
            error.Timeout,
            d.sendPromptedInput(
                std.testing.allocator,
                "clear logging",
                "Clear logging buffer [confirm]",
                "",
                operation.NewSendPromptedInputOptions(),
            ),
        );
    }
}
