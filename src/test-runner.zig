// zlint-disable suppressed-errors
// note: disabling because tests can have unreachable blocks
// https://gist.githubusercontent.com/karlseguin/ \
// c6bea5b35e4e8d26af6f81c22cb5d76b/raw/cf9f21131e439f266e360477fa60b89431d67920/test_runner.zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const scrapli = @import("scrapli");
const test_helper = scrapli.test_helper;

const border = "=" ** 80;

// yaml is verrrry noisy
pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{
            .scope = .yaml,
            .level = .err,
        },
        .{
            .scope = .tokenizer,
            .level = .err,
        },
        .{
            .scope = .parser,
            .level = .err,
        },
    },
};

// used in custom panic handler
var current_test: ?[]const u8 = null;

pub fn main(init: std.process.Init) !void {
    test_helper.args = init.minimal.args;

    const unit_tests = test_helper.parseCustomFlag(
        "--unit",
        true,
    );
    const integration_tests = test_helper.parseCustomFlag(
        "--integration",
        false,
    );
    const functional_tests = test_helper.parseCustomFlag(
        "--functional",
        false,
    );

    var mem: [8_192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);

    const allocator = fba.allocator();

    const env = Env.init(init.environ_map);

    var slowest = SlowTracker.init(allocator, init.io, 5);
    defer slowest.deinit();

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    const printer = Printer.init();
    printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

    for (builtin.test_functions) |t| {
        if (isSetup(t)) {
            current_test = friendlyName(t.name);
            t.func() catch |err| {
                printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    for (builtin.test_functions) |t| {
        if (isSetup(t) or isTeardown(t)) {
            continue;
        }

        if (!isIntegration(t) and !unit_tests) {
            continue;
        }

        if (isIntegration(t) and !integration_tests) {
            continue;
        }

        if (isFunctional(t) and !functional_tests) {
            continue;
        }

        var status = Status.pass;
        slowest.startTiming();

        const is_unnamed_test = isUnnamed(t);

        if (is_unnamed_test) {
            continue;
        }

        if (env.filter) |f| {
            if (!is_unnamed_test and std.mem.indexOf(u8, t.name, f) == null) {
                continue;
            }
        }

        std.testing.allocator_instance = .{};

        const friendly_name = friendlyName(t.name);

        current_test = friendly_name;
        const result = t.func();
        current_test = null;

        const ns_taken = slowest.endTiming(friendly_name);

        if (std.testing.allocator_instance.deinit() == .leak) {
            leak += 1;
            printer.status(
                .fail,
                "\n{s}\n\"{s}\" - Memory Leak\n{s}\n",
                .{ border, friendly_name, border },
            );
        }

        if (result) |_| {
            pass += 1;
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                status = .skip;
            },
            else => {
                status = .fail;
                fail += 1;
                printer.status(
                    .fail,
                    "\n{s}\n\"{s}\" - {s}\n{s}\n",
                    .{ border, friendly_name, @errorName(err), border },
                );
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace);
                }
                if (env.fail_first) {
                    break;
                }
            },
        }

        if (env.verbose) {
            const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
            printer.status(status, "{s} ({d:.2}ms)\n", .{ friendly_name, ms });
        } else {
            printer.status(status, ".", .{});
        }
    }

    for (builtin.test_functions) |t| {
        if (isTeardown(t)) {
            current_test = friendlyName(t.name);
            t.func() catch |err| {
                printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    const total_tests = pass + fail;
    const status = if (fail == 0) Status.pass else Status.fail;

    printer.status(
        status,
        "\n{d} of {d} test{s} passed\n",
        .{ pass, total_tests, if (total_tests != 1) "s" else "" },
    );

    if (skip > 0) {
        printer.status(
            .skip,
            "{d} test{s} skipped\n",
            .{ skip, if (skip != 1) "s" else "" },
        );
    }
    if (leak > 0) {
        printer.status(
            .fail,
            "{d} test{s} leaked\n",
            .{ leak, if (leak != 1) "s" else "" },
        );
    }

    printer.fmt("\n", .{});
    try slowest.display(printer);
    printer.fmt("\n", .{});

    std.process.exit(if (fail == 0) 0 else 1);
}

fn friendlyName(name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |value| {
        if (std.mem.eql(u8, value, "test")) {
            const rest = it.rest();
            return if (rest.len > 0) rest else name;
        }
    }
    return name;
}

const Printer = struct {
    f: std.Io.File,

    fn init() Printer {
        return .{
            .f = std.Io.File.stdout(),
        };
    }

    fn fmt(self: Printer, comptime format: []const u8, args: anytype) void {
        var stdout_buffer: [1024]u8 = undefined;
        var out = self.f.writer(std.testing.io, &stdout_buffer);
        const writer = &out.interface;
        writer.print(format, args) catch unreachable;
        writer.flush() catch {};
    }

    fn status(self: Printer, s: Status, comptime format: []const u8, args: anytype) void {
        const color = switch (s) {
            .pass => "\x1b[32m",
            .fail => "\x1b[31m",
            .skip => "\x1b[33m",
            else => "",
        };

        var stdout_buffer: [1024]u8 = undefined;
        var out = self.f.writer(std.testing.io, &stdout_buffer);
        const writer = &out.interface;

        writer.printAscii(color, .{}) catch unreachable;
        writer.print(format, args) catch unreachable;
        writer.print("\x1b[0m", .{}) catch unreachable;
        writer.flush() catch {};
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const SlowTracker = struct {
    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);

    io: std.Io,
    max: usize,
    slowest: SlowestQueue,
    timer: std.Io.Timestamp,

    fn init(allocator: Allocator, io: std.Io, count: u32) SlowTracker {
        var slowest = SlowestQueue.init(allocator, {});
        slowest.ensureTotalCapacity(count) catch @panic("OOM");
        return .{
            .io = io,
            .max = count,
            .timer = std.Io.Timestamp.now(io, .real),
            .slowest = slowest,
        };
    }

    const TestInfo = struct {
        ns: u64,
        name: []const u8,
    };

    fn deinit(self: SlowTracker) void {
        self.slowest.deinit();
    }

    fn startTiming(self: *SlowTracker) void {
        self.timer = std.Io.Timestamp.now(self.io, .real);
    }

    fn endTiming(self: *SlowTracker, test_name: []const u8) u64 {
        const ns: u64 = @intCast(self.timer.untilNow(self.io, .real).nanoseconds);

        var slowest = &self.slowest;

        if (slowest.count() < self.max) {
            // Capacity is fixed to the # of slow tests we want to track
            // If we've tracked fewer tests than this capacity, than always add
            slowest.add(
                TestInfo{
                    .ns = ns,
                    .name = test_name,
                },
            ) catch @panic("failed to track test timing");

            return ns;
        }

        {
            // Optimization to avoid shifting the dequeue for the common case
            // where the test isn't one of our slowest.
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                // the test was faster than our fastest slow test, don't add
                return ns;
            }
        }

        // the previous fastest of our slow tests, has been pushed off.
        _ = slowest.removeMin();

        slowest.add(
            TestInfo{
                .ns = ns,
                .name = test_name,
            },
        ) catch @panic("failed to track test timing");

        return ns;
    }

    fn display(self: *SlowTracker, printer: Printer) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        printer.fmt("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (slowest.removeMinOrNull()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            printer.fmt("  {d:.2}ms\t{s}\n", .{ ms, info.name });
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

const Env = struct {
    verbose: bool,
    fail_first: bool,
    filter: ?[]const u8,

    fn init(
        environ_map: *std.process.Environ.Map,
    ) Env {
        var verbose = true;
        if (environ_map.get("TEST_VERBOSE") != null) {
            verbose = false;
        }

        var fail_first = false;
        if (environ_map.get("TEST_FAIL_FIRST") != null) {
            fail_first = true;
        }

        return .{
            .verbose = verbose,
            .fail_first = fail_first,
            .filter = environ_map.get("TEST_FILTER"),
        };
    }
};

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isTeardown(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}

fn isIntegration(t: std.builtin.TestFn) bool {
    return std.mem.startsWith(u8, t.name, "tests.integration");
}

fn isFunctional(t: std.builtin.TestFn) bool {
    return std.mem.startsWith(u8, t.name, "tests.functional");
}
