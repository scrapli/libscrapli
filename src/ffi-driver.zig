// zlinter-disable no_panic - ignoring as we do panic on things that *really* should not happen
const std = @import("std");

const cli = @import("cli.zig");
const errors = @import("errors.zig");
const ffi_operations = @import("ffi-operations.zig");
const logging = @import("logging.zig");
const netconf = @import("netconf.zig");
const platform = @import("cli-platform.zig");
const queue = @import("queue.zig");
const result = @import("cli-result.zig");
const result_netconf = @import("netconf-result.zig");

/// The static sleep duration for waiting for the ffi driver operation thread to be running.
pub const operation_thread_ready_sleep: u64 = 2_500;

/// An enum representing a "real" (non ffi) cli or netconf driver.
pub const RealDriver = union(enum) {
    cli: *cli.Driver,
    netconf: *netconf.Driver,
};

/// The "ffi driver" is the thing that drives the "normal" zig libscrapli drivers and exposes things
/// via the ffi/shared object interface.
pub const FfiDriver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    host: []const u8,

    real_driver: RealDriver,

    poll_fds: [2]std.posix.fd_t = .{ -1, -1 },

    operation_id_counter: u32,
    operation_thread: ?std.Thread,
    operation_ready: std.atomic.Value(bool),
    operation_stop: std.atomic.Value(bool),
    operation_lock: std.Io.Mutex,
    operation_condition: std.Io.Condition,
    operation_predicate: u32,
    operation_queue: queue.LinearFifo(ffi_operations.OperationOptions),
    operation_results: std.AutoHashMap(
        u32,
        ffi_operations.OperationResult,
    ),

    fn setPollFds(self: *FfiDriver) !void {
        switch (std.posix.errno(std.c.pipe(&self.poll_fds))) {
            .SUCCESS => return,
            .INVAL => unreachable, // Invalid parameters to pipe()
            .FAULT => unreachable, // Invalid fds pointer
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return errors.ScrapliError.Session,
        }
    }

    /// Initialize the FfiDriver for cli (ssh/telnet) operations.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        host: []const u8,
        options: cli.Options,
    ) !*FfiDriver {
        const owned_host = try allocator.dupe(u8, host);
        errdefer allocator.free(owned_host);

        const real_driver = try cli.Driver.init(
            allocator,
            io,
            owned_host,
            options,
        );

        errdefer real_driver.deinit();

        const ffi_driver = try allocator.create(FfiDriver);

        ffi_driver.* = FfiDriver{
            .allocator = allocator,
            .io = io,
            .host = owned_host,
            .real_driver = .{
                .cli = real_driver,
            },
            .operation_id_counter = 0,
            .operation_thread = null,
            .operation_ready = std.atomic.Value(bool).init(false),
            .operation_stop = std.atomic.Value(bool).init(false),
            .operation_lock = std.Io.Mutex.init,
            .operation_condition = std.Io.Condition.init,
            .operation_predicate = 0,
            .operation_queue = queue.LinearFifo(ffi_operations.OperationOptions).init(allocator),
            .operation_results = std.AutoHashMap(
                u32,
                ffi_operations.OperationResult,
            ).init(allocator),
        };

        errdefer ffi_driver.deinit();

        try ffi_driver.setPollFds();

        return ffi_driver;
    }

    /// Initialize the FfiDriver for netconf operations.
    pub fn initNetconf(
        allocator: std.mem.Allocator,
        io: std.Io,
        host: []const u8,
        options: netconf.Options,
    ) !*FfiDriver {
        const owned_host = try allocator.dupe(u8, host);
        errdefer allocator.free(owned_host);

        const real_driver = try netconf.Driver.init(
            allocator,
            io,
            owned_host,
            options,
        );

        errdefer real_driver.deinit();

        const ffi_driver = try allocator.create(FfiDriver);

        ffi_driver.* = FfiDriver{
            .allocator = allocator,
            .io = io,
            .host = owned_host,
            .real_driver = .{
                .netconf = real_driver,
            },
            .operation_id_counter = 0,
            .operation_thread = null,
            .operation_ready = std.atomic.Value(bool).init(false),
            .operation_stop = std.atomic.Value(bool).init(false),
            .operation_lock = std.Io.Mutex.init,
            .operation_condition = std.Io.Condition.init,
            .operation_predicate = 0,
            .operation_queue = queue.LinearFifo(ffi_operations.OperationOptions).init(allocator),
            .operation_results = std.AutoHashMap(
                u32,
                ffi_operations.OperationResult,
            ).init(allocator),
        };

        errdefer ffi_driver.deinit();

        try ffi_driver.setPollFds();

        return ffi_driver;
    }

    /// Deinitialize the FfiDriver and its underlying "real" driver.
    pub fn deinit(self: *FfiDriver) void {
        // signal to the operation thread to iterate, it should then catch the stored stop condition
        // do this while holding the lock so there is no chance it can be missed
        // zlinter-disable-next-line no_swallow_error - standard lock should "never" fail
        self.operation_lock.lock(self.io) catch {};
        self.operation_stop.store(true, std.lang.AtomicOrder.release);
        self.operation_condition.signal(self.io);
        self.operation_lock.unlock(self.io);

        if (self.operation_thread) |ot| {
            ot.join();
        }

        var operation_results_iter = self.operation_results.iterator();
        while (operation_results_iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }

        // drain any any ops in the queue
        while (self.operation_queue.readItem()) |op| {
            ffi_operations.freeOperationOwnedStrings(self.allocator, op);
        }

        self.operation_queue.deinit();
        self.operation_results.deinit();

        switch (self.real_driver) {
            .cli => |d| {
                d.deinit();
            },
            .netconf => |d| {
                d.deinit();
            },
        }

        // the real drivers borrow the host buffer we own, so it must outlive their deinit
        self.allocator.free(self.host);

        if (self.poll_fds[0] >= 0) {
            _ = std.c.close(self.poll_fds[0]);
        }

        if (self.poll_fds[1] >= 0) {
            _ = std.c.close(self.poll_fds[1]);
        }

        self.allocator.destroy(self);
    }

    /// Get the logger of the underlying "real" driver.
    pub fn getLogger(self: *FfiDriver) logging.Logger {
        const logger = switch (self.real_driver) {
            .cli => |d| d.log,
            .netconf => |d| d.log,
        };

        return logger;
    }

    /// Open the underlying "real" driver and begin the ffi driver operation loop.
    pub fn open(self: *FfiDriver) !void {
        switch (self.real_driver) {
            .cli => {
                self.operation_thread = std.Thread.spawn(
                    .{},
                    FfiDriver.operationLoop,
                    .{self},
                ) catch |err| {
                    return errors.wrapCriticalError(
                        err,
                        @src(),
                        self.getLogger(),
                        "ffi: failed spawning operation thread",
                        .{},
                    );
                };
            },
            .netconf => {
                self.operation_thread = std.Thread.spawn(
                    .{},
                    FfiDriver.operationLoopNetconf,
                    .{self},
                ) catch |err| {
                    return errors.wrapCriticalError(
                        err,
                        @src(),
                        self.getLogger(),
                        "ffi: failed spawning operation thread",
                        .{},
                    );
                };
            },
        }

        while (true) {
            // this blocks us until the operation thread is ready and processing before we continue
            const ready = self.operation_ready.load(std.lang.AtomicOrder.acquire);
            if (ready) {
                break;
            }

            self.io.sleep(
                .{
                    .nanoseconds = operation_thread_ready_sleep,
                },
                .awake,
            ) catch |err| {
                self.getLogger().warn(
                    "ffi-driver.FfiDriver open: sleep error '{}', ignoring",
                    .{err},
                );
            };
        }
    }

    fn writePollWakeUp(self: *FfiDriver) !void {
        const rc = std.c.write(self.poll_fds[1], "x", 1);
        if (rc != 1) {
            return errors.ScrapliError.Operation;
        }
    }

    /// The operation loop is the "thing" that actually invokes user requested functions by popping
    /// the requested operations from the operation queue. This ensures that all operations are done
    /// sequentially (and in theory this is more or less thread safe?). The loop idea itself came
    /// from basically needing a way to expose the driver to higher level languages (py/go) in a
    /// semi async fashion -- in this way the ffi layer can submit jobs to the queue then the caller
    /// can periodically poll (or poll and block) until completion. Without this loop/queue users
    /// could submit a bunch of jobs and we would potentially be stomping all over inputs by just
    /// writing what we can when we can. So, while this is extra overhead, it seems like a good
    /// way to address that problem.
    fn operationLoop(self: *FfiDriver) void {
        self.getLogger().info("ffi-driver.FfiDriver: operation thread started", .{});

        self.operation_ready.store(true, std.lang.AtomicOrder.unordered);

        while (true) {
            self.operation_lock.lock(self.io) catch {
                @panic("failed acquiring operation lock");
            };

            while (self.operation_queue.count == 0 and
                !self.operation_stop.load(std.lang.AtomicOrder.acquire))
            {
                // nothing in the queue to process, wait for the signal
                self.operation_condition.wait(self.io, &self.operation_lock) catch {
                    @panic(
                        "ffi-driver.FfiDriver: failed waiting for signal to unblock operation loop",
                    );
                };
            }

            var maybe_op: ?ffi_operations.OperationOptions = null;

            {
                defer self.operation_lock.unlock(self.io);

                if (self.operation_stop.load(std.lang.AtomicOrder.acquire)) {
                    break;
                }

                maybe_op = self.operation_queue.readItem();
            }

            const op = maybe_op orelse continue;

            // free any owned strings when the op is done
            defer ffi_operations.freeOperationOwnedStrings(self.allocator, op);

            var ret_ok: ?*result.Result = null;
            var ret_err: ?anyerror = null;

            const rd = switch (self.real_driver) {
                .cli => |d| d,
                else => unreachable,
            };

            switch (op.operation.cli) {
                inline else => |o, tag| {
                    const method_name = comptime switch (tag) {
                        .open => "open",
                        .close => "close",
                        .enter_mode => "enterMode",
                        .get_prompt => "getPrompt",
                        .send_input => "sendInput",
                        .send_inputs => "sendInputs",
                        .send_prompted_input => "sendPromptedInput",
                        .read_any => "readAny",
                    };

                    if (@field(@TypeOf(rd.*), method_name)(rd, self.allocator, o)) |ret| {
                        ret_ok = ret;
                    } else |err| {
                        ret_err = err;
                    }
                },
            }

            self.operation_lock.lock(self.io) catch {
                @panic("failed acquiring operation lock");
            };

            if (ret_err != null) {
                self.operation_results.put(
                    op.id,
                    ffi_operations.OperationResult{
                        .done = true,
                        .result = .{
                            .cli = null,
                        },
                        .err = ret_err,
                        .last_error = self.allocator.dupe(u8, rd.getLastError()) catch "",
                    },
                ) catch {
                    @panic(
                        "ffi-driver.FfiDriver: failed storing operation result, " ++
                            "this should not happen",
                    );
                };
            } else {
                self.operation_results.put(
                    op.id,
                    ffi_operations.OperationResult{
                        .done = true,
                        .result = .{
                            .cli = ret_ok,
                        },
                        .err = null,
                    },
                ) catch {
                    @panic(
                        "ffi-driver.FfiDriver: failed storing operation result, " ++
                            "this should not happen",
                    );
                };
            }

            self.operation_lock.unlock(self.io);

            self.writePollWakeUp() catch {
                @panic("ffi-driver.FfiDriver: failed writing to wakeup fd, cannot proceed");
            };
        }

        self.getLogger().info("ffi-driver.FfiDriver: operation thread stopped", .{});
    }

    fn operationLoopNetconf(self: *FfiDriver) void {
        self.getLogger().info("ffi-driver.FfiDriver: operation thread started", .{});

        self.operation_ready.store(true, std.lang.AtomicOrder.unordered);

        while (true) {
            self.operation_lock.lock(self.io) catch {
                @panic("ffi-driver.FfiDriver: failed acquiring operation lock");
            };

            while (self.operation_queue.count == 0 and
                !self.operation_stop.load(std.lang.AtomicOrder.acquire))
            {
                // nothing in the queue to process, wait for the signal
                self.operation_condition.wait(self.io, &self.operation_lock) catch {
                    @panic(
                        "ffi-driver.FfiDriver: failed waiting for signal to unblock operation loop",
                    );
                };
            }

            var maybe_op: ?ffi_operations.OperationOptions = null;

            {
                defer self.operation_lock.unlock(self.io);

                if (self.operation_stop.load(std.lang.AtomicOrder.acquire)) {
                    break;
                }

                maybe_op = self.operation_queue.readItem();
            }

            const op = maybe_op orelse continue;

            // free any owned strings when the op is done
            defer ffi_operations.freeOperationOwnedStrings(self.allocator, op);

            var ret_ok: ?*result_netconf.Result = null;
            var ret_err: ?anyerror = null;

            const rd = switch (self.real_driver) {
                .netconf => |d| d,
                else => unreachable,
            };

            switch (op.operation.netconf) {
                inline else => |o, tag| {
                    const method_name = comptime switch (tag) {
                        .open => "open",
                        .close => "close",
                        .raw_rpc => "rawRpc",
                        .get_config => "getConfig",
                        .edit_config => "editConfig",
                        .copy_config => "copyConfig",
                        .delete_config => "deleteConfig",
                        .lock => "lock",
                        .unlock => "unlock",
                        .get => "get",
                        .close_session => "closeSession",
                        .kill_session => "killSession",
                        .commit => "commit",
                        .discard => "discard",
                        .cancel_commit => "cancelCommit",
                        .validate => "validate",
                        .get_schema => "getSchema",
                        .get_data => "getData",
                        .edit_data => "editData",
                        .action => "action",
                    };

                    if (@field(@TypeOf(rd.*), method_name)(
                        rd,
                        self.allocator,
                        o,
                    )) |ret| {
                        ret_ok = ret;
                    } else |err| {
                        ret_err = err;
                    }
                },
            }

            self.operation_lock.lock(self.io) catch {
                @panic("ffi-driver.FfiDriver: failed acquiring operation lock");
            };

            if (ret_err != null) {
                self.operation_results.put(
                    op.id,
                    ffi_operations.OperationResult{
                        .done = true,
                        .result = .{
                            .netconf = null,
                        },
                        .err = ret_err,
                        .last_error = self.allocator.dupe(u8, rd.getLastError()) catch "",
                    },
                ) catch {
                    @panic(
                        "ffi-driver.FfiDriver: failed storing operation result, " ++
                            "this should not happen",
                    );
                };
            } else {
                self.operation_results.put(
                    op.id,
                    ffi_operations.OperationResult{
                        .done = true,
                        .result = .{
                            .netconf = ret_ok,
                        },
                        .err = null,
                    },
                ) catch {
                    @panic(
                        "ffi-driver.FfiDriver: failed storing operation result, " ++
                            "this should not happen",
                    );
                };
            }

            self.operation_lock.unlock(self.io);

            self.writePollWakeUp() catch {
                @panic("ffi-driver.FfiDriver: failed writing to wakeup fd, cannot proceed");
            };
        }

        self.getLogger().info("ffi-driver.FfiDriver: operation thread stopped", .{});
    }

    /// Queue an operation based on the given operation options.
    pub fn queueOperation(
        self: *FfiDriver,
        options: ffi_operations.OperationOptions,
    ) !u32 {
        var mut_options = options;

        try self.operation_lock.lock(self.io);
        errdefer self.operation_lock.unlock(self.io);

        self.operation_id_counter += 1;

        const operation_id = self.operation_id_counter;
        mut_options.id = operation_id;

        errdefer ffi_operations.freeOperationOwnedStrings(self.allocator, mut_options);

        const pending_result: ffi_operations.Result = switch (options.operation) {
            .cli => .{ .cli = null },
            .netconf => .{ .netconf = null },
        };

        try self.operation_results.put(
            operation_id,
            ffi_operations.OperationResult{
                .done = false,
                .result = pending_result,
                .err = null,
            },
        );

        errdefer _ = self.operation_results.remove(operation_id);

        try self.operation_queue.writeItem(mut_options);

        self.operation_lock.unlock(self.io);

        // signal to unblock the operation loop (we do this so we dont have to do some sleep in the
        // loop between checking for operations)
        self.operation_condition.signal(self.io);

        return operation_id;
    }

    /// Dequeues the the given operation id from the operation queue if present, if remove is false
    /// only "get" it, don't "remove" it from the queue.
    pub fn dequeueOperation(
        self: *FfiDriver,
        operation_id: u32,
        remove: bool,
    ) !ffi_operations.OperationResult {
        try self.operation_lock.lock(self.io);
        defer self.operation_lock.unlock(self.io);

        if (!self.operation_results.contains(operation_id)) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                self.getLogger(),
                "bad operation id",
                .{},
            );
        }

        const ret = self.operation_results.get(operation_id);
        if (ret == null) {
            // unreachable because we already checked if the id is present
            unreachable;
        }

        if (!ret.?.done) {
            return errors.ScrapliError.Operation;
        }

        if (remove) {
            // clean it up
            _ = self.operation_results.remove(operation_id);
        }

        return ret.?;
    }

    /// A conveinence function to get result sizes for cli operations. Note that all sizes are
    /// "packed" sizes -- each buffer holds the per result entries back-to-back w/ *no* delimiters,
    /// the fetch call fills per entry length arrays the caller uses to slice things back apart.
    /// The raw size is the size of the packed raw *journals* -- raw itself is never stored (or
    /// shipped over the ffi boundary), callers reconstruct on demand. No options anywhere --
    /// normalization already happened at append time in the session's ProcessedBuf.
    pub fn getCliResultLens(
        self: *FfiDriver,
        r: *result.Result,
    ) ffi_operations.CliOperationSizes {
        _ = self;

        var sizes = ffi_operations.CliOperationSizes{
            .operation_count = r.results.items.len,
            .operation_input_size = r.getInputsPackedLen(),
            .operation_result_raw_size = r.getResultsRawJournalPackedLen(),
            .operation_result_size = r.getResultsPackedLen(),
            .operation_failure_indicator_size = 0,
        };

        if (r.result_failure_indicator >= 0) {
            const failure_size = r.failed_indicators.?[@intCast(r.result_failure_indicator)].len;
            sizes.operation_failure_indicator_size = failure_size;
        }

        return sizes;
    }

    /// A conveinence function to get results for cli operations. All buffers are "packed" -- per
    /// result entries back-to-back -- w/ each entry's length recorded into the corresponding lens
    /// array so the caller can slice things back apart. The raw buffer holds the packed raw
    /// *journals* -- callers reconstruct actual raw on demand w/ the
    /// ls_cli_get_reconstructed_result_raw exports.
    pub fn getCliResults(
        self: *FfiDriver,
        r: *result.Result,
        operation_start_time: *u64,
        operation_splits: *[]u64,
        operation_input: *[]u8,
        operation_input_lens: *[]u64,
        operation_result_raw: *[]u8,
        operation_result_raw_lens: *[]u64,
        operation_result: *[]u8,
        operation_result_lens: *[]u64,
        operation_result_failed_indicator: *[]u8,
        operation_error: *[]u8,
    ) void {
        _ = self;

        if (r.splits_ns.items.len > 0) {
            operation_start_time.* = @intCast(r.start_time_ns);
            for (0.., r.splits_ns.items) |idx, split| {
                operation_splits.*[idx] = @intCast(split);
            }
        } else {
            // was a noop -- like enterMode but where mode didn't change
            operation_start_time.* = @intCast(r.start_time_ns);
        }

        r.packInputs(operation_input.*, operation_input_lens.*);
        r.packResultsRawJournal(operation_result_raw.*, operation_result_raw_lens.*);
        r.packResults(operation_result.*, operation_result_lens.*);

        if (r.result_failure_indicated) {
            @memcpy(
                operation_result_failed_indicator.*,
                r.failed_indicators.?[@intCast(r.result_failure_indicator)],
            );
        }

        operation_error.* = "";
    }
};

fn ffiDriverInitForTests(definition: *platform.Definition) !*FfiDriver {
    return FfiDriver.init(
        std.testing.allocator,
        std.testing.io,
        "localhost",
        .{
            .definition = .{
                .definition = definition,
            },
        },
    );
}

fn queueCloseOperationForTests(d: *FfiDriver) !u32 {
    // close against a never (network) opened driver completes basically instantly (and close is
    // explicitly safe pre-open), so it makes a nice no-network op to exercise the queue/loop with
    return d.queueOperation(
        .{
            .id = 0,
            .operation = .{
                .cli = .{
                    .close = .{},
                },
            },
        },
    );
}

fn waitForOperationResultForTests(
    d: *FfiDriver,
    operation_id: u32,
) !ffi_operations.OperationResult {
    var attempts: usize = 0;

    while (true) {
        const ret = d.dequeueOperation(operation_id, true) catch |err| switch (err) {
            errors.ScrapliError.Operation => {
                // not done yet; an op against a never opened driver should complete (or fail)
                // near instantly, so if we approach this ~10s ceiling the operation loop is
                // hung or a wakeup was lost
                attempts += 1;

                try std.testing.expect(attempts < 10_000);

                try std.testing.io.sleep(
                    .{
                        .nanoseconds = std.time.ns_per_ms,
                    },
                    .awake,
                );

                continue;
            },
            else => return err,
        };

        return ret;
    }
}

// spin up a driver, queue a close (because its a safe op that doesnt require a device since close
// on session is effectively a noop -- there are things happening (recorder/transport shutdown etc,
// but nothing that requires a device/connection, and the cli driver has no close callbacks) -- we
// should assert that the op is done, its not an error, and we dont leak anything. this is
// basically happy path test.
test "ffiDriverOperationLifecycle" {
    var definition = platform.Definition{
        .prompt_pattern = "^.*[>#$]\\s?+$",
        .default_mode = "cli",
    };

    const d = try ffiDriverInitForTests(&definition);
    defer d.deinit();

    try d.open();

    const operation_id = try queueCloseOperationForTests(d);

    try std.testing.expect(operation_id != 0);

    const ret = try waitForOperationResultForTests(d, operation_id);

    try std.testing.expect(ret.done);
    try std.testing.expect(ret.err == null);

    ret.deinit(std.testing.allocator);
}

// the ffi driver always handles ops serially -- thats the only sensible mode for libscrapli
// since 1 connection is 1 connection (sorta kinda notwithstanding netconf subs/notifications,
// though even then ops are serial from the ffi perspective). this tests two things, first ping-pong
// -- queue one (noop-ish, see previous test comment) op, wait for its result, repeat -- every
// iteration forces the op loop to sleep and get rewoken, so a lost wakeup (see baed870) shows up
// here as a hang/timeout. then a burst -- queue a pile all at once, then collect; ids must be
// handed out in order and every op must complete w/ no errors/leaks in both cases.
test "ffiDriverOperationSerialProcessing" {
    var definition = platform.Definition{
        .prompt_pattern = "^.*[>#$]\\s?+$",
        .default_mode = "cli",
    };

    const d = try ffiDriverInitForTests(&definition);
    defer d.deinit();

    try d.open();

    var last_operation_id: u32 = 0;

    // ping-pong -- queue an op, wait for its result, repeat; every iteration requires the
    // operation loop to sleep then be woken again, so a lost wakeup (see baed870) shows up
    // here as a hang/timeout
    for (0..50) |_| {
        const operation_id = try queueCloseOperationForTests(d);

        // operation ids must be handed out monotonically, one at a time
        try std.testing.expect(operation_id == last_operation_id + 1);

        last_operation_id = operation_id;

        const ret = try waitForOperationResultForTests(d, operation_id);

        try std.testing.expect(ret.done);
        try std.testing.expect(ret.err == null);

        ret.deinit(std.testing.allocator);
    }

    // burst -- queue a pile of ops before collecting any results; all of them must eventually
    // be processed and every result must land in the results map
    var operation_ids: [10]u32 = undefined;

    for (&operation_ids) |*operation_id| {
        operation_id.* = try queueCloseOperationForTests(d);
    }

    for (operation_ids) |operation_id| {
        const ret = try waitForOperationResultForTests(d, operation_id);

        try std.testing.expect(ret.done);
        try std.testing.expect(ret.err == null);

        ret.deinit(std.testing.allocator);
    }
}

// tests that we dont hang on a deinit when we have operations queued, all ops have to be drained
// and freed, so testing allocator will be enforcing that for us.
test "ffiDriverDeinitWithQueuedOperations" {
    var definition = platform.Definition{
        .prompt_pattern = "^.*[>#$]\\s?+$",
        .default_mode = "cli",
    };

    const d = try ffiDriverInitForTests(&definition);

    try d.open();

    for (0..10) |_| {
        _ = try queueCloseOperationForTests(d);
    }

    d.deinit();
}

// just assert that even when not opened (no op thread) we close/deinit gracefully w/out hanging.
test "ffiDriverDeinitWithoutOpen" {
    var definition = platform.Definition{
        .prompt_pattern = "^.*[>#$]\\s?+$",
        .default_mode = "cli",
    };

    const d = try ffiDriverInitForTests(&definition);

    d.deinit();
}
