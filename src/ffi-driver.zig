// zlinter-disable no_panic - ignoring as we do panic on things that *really* should not happen
const std = @import("std");

const bytes = @import("bytes.zig");
const cli = @import("cli.zig");
const errors = @import("errors.zig");
const ffi_operations = @import("ffi-operations.zig");
const logging = @import("logging.zig");
const netconf = @import("netconf.zig");
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

    real_driver: RealDriver,

    poll_fds: [2]std.posix.fd_t = .{ -1, -1 },

    operation_id_counter: u32,
    operation_thread: ?std.Thread,
    operation_ready: std.atomic.Value(bool),
    operation_stop: std.atomic.Value(bool),
    operation_lock: std.Io.Mutex,
    operation_condition: std.Io.Condition,
    operation_predicate: u32,
    operation_queue: queue.LinearFifo(
        ffi_operations.OperationOptions,
        .dynamic,
    ),
    operation_results: std.AutoHashMap(
        u32,
        ffi_operations.OperationResult,
    ),

    cli_get_results_options: result.GetResultOptions = .{
        .delimiter = bytes.libscrapli_delimiter,
    },

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
        config: cli.Config,
    ) !*FfiDriver {
        const real_driver = try cli.Driver.init(
            allocator,
            io,
            host,
            config,
        );

        const ffi_driver = allocator.create(FfiDriver) catch |err| {
            real_driver.deinit();

            return err;
        };

        ffi_driver.* = FfiDriver{
            .allocator = allocator,
            .io = io,
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
            .operation_queue = queue.LinearFifo(
                ffi_operations.OperationOptions,
                .dynamic,
            ).init(allocator),
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
        config: netconf.Config,
    ) !*FfiDriver {
        const real_driver = try netconf.Driver.init(
            allocator,
            io,
            host,
            config,
        );

        const ffi_driver = allocator.create(FfiDriver) catch |err| {
            real_driver.deinit();

            return err;
        };

        ffi_driver.* = FfiDriver{
            .allocator = allocator,
            .io = io,
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
            .operation_queue = queue.LinearFifo(
                ffi_operations.OperationOptions,
                .dynamic,
            ).init(allocator),
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
        self.operation_stop.store(true, std.builtin.AtomicOrder.unordered);

        // signal to the operation thread to iterate, it should then catch the stored stop condition
        // zlinter-disable-next-line no_swallow_error - standard lock should "never" fail
        self.operation_lock.lock(self.io) catch {};
        self.operation_condition.signal(self.io);
        self.operation_lock.unlock(self.io);

        if (self.operation_thread) |ot| {
            ot.join();
        }

        var operation_results_iter = self.operation_results.iterator();
        while (operation_results_iter.next()) |entry| {
            switch (entry.value_ptr.*.result) {
                .cli => |r| {
                    if (r) |result_ptr| {
                        result_ptr.deinit();
                    }
                },
                .netconf => |r| {
                    if (r) |result_ptr| {
                        result_ptr.deinit();
                    }
                },
            }
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
            const ready = self.operation_ready.load(std.builtin.AtomicOrder.acquire);
            if (ready) {
                break;
            }

            std.Io.Clock.Duration.sleep(
                .{
                    .clock = .awake,
                    .raw = .fromNanoseconds(operation_thread_ready_sleep),
                },
                self.io,
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

        self.operation_ready.store(true, std.builtin.AtomicOrder.unordered);

        while (true) {
            const stop = self.operation_stop.load(std.builtin.AtomicOrder.acquire);
            if (stop) {
                break;
            }

            self.operation_lock.lock(self.io) catch {
                @panic("failed acquiring operation lock");
            };

            if (self.operation_queue.count == 0) {
                // nothing in the queue to process, wait for the signal
                self.operation_condition.wait(self.io, &self.operation_lock) catch {
                    @panic(
                        "ffi-driver.FfiDriver: failed waiting for signal to unblock operation loop",
                    );
                };
            }

            const op = self.operation_queue.readItem();

            self.operation_lock.unlock(self.io);

            if (op == null) {
                continue;
            }

            var ret_ok: ?*result.Result = null;
            var ret_err: ?anyerror = null;

            const rd = switch (self.real_driver) {
                .cli => |d| d,
                else => {
                    @panic(
                        "ffi-driver.FfiDriver: cli operation loop executed, but driver is not cli",
                    );
                },
            };

            switch (op.?.operation.cli) {
                .open => |o| {
                    ret_ok = rd.open(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .close => |o| {
                    ret_ok = rd.close(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .enter_mode => |o| {
                    ret_ok = rd.enterMode(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .get_prompt => |o| {
                    ret_ok = rd.getPrompt(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .send_input => |o| {
                    ret_ok = rd.sendInput(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .send_inputs => |o| {
                    ret_ok = rd.sendInputs(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .send_prompted_input => |o| {
                    ret_ok = rd.sendPromptedInput(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .read_any => |o| {
                    ret_ok = rd.readAny(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
            }

            self.operation_lock.lock(self.io) catch {
                @panic("failed acquiring operation lock");
            };

            if (ret_err != null) {
                self.operation_results.put(
                    op.?.id,
                    ffi_operations.OperationResult{
                        .done = true,
                        .result = .{
                            .cli = null,
                        },
                        .err = ret_err,
                    },
                ) catch {
                    @panic(
                        "ffi-driver.FfiDriver: failed storing operation result, " ++
                            "this should not happen",
                    );
                };
            } else {
                self.operation_results.put(
                    op.?.id,
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

        self.operation_ready.store(true, std.builtin.AtomicOrder.unordered);

        while (true) {
            const stop = self.operation_stop.load(std.builtin.AtomicOrder.acquire);
            if (stop) {
                break;
            }

            self.operation_lock.lock(self.io) catch {
                @panic("ffi-driver.FfiDriver: failed acquiring operation lock");
            };

            if (self.operation_queue.count == 0) {
                // nothing in the queue to process, wait for the signal
                self.operation_condition.wait(self.io, &self.operation_lock) catch {
                    @panic(
                        "ffi-driver.FfiDriver: failed waiting for signal to unblock operation loop",
                    );
                };
            }

            const op = self.operation_queue.readItem();

            self.operation_lock.unlock(self.io);

            if (op == null) {
                continue;
            }

            var ret_ok: ?*result_netconf.Result = null;
            var ret_err: ?anyerror = null;

            const rd = switch (self.real_driver) {
                .netconf => |d| d,
                else => {
                    @panic(
                        "ffi-driver.FfiDriver: netconf operation loop executed, " ++
                            "but driver is not netconf",
                    );
                },
            };

            switch (op.?.operation.netconf) {
                .open => |o| {
                    ret_ok = rd.open(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .close => |o| {
                    ret_ok = rd.close(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .raw_rpc => |o| {
                    ret_ok = rd.rawRpc(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .get_config => |o| {
                    ret_ok = rd.getConfig(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .edit_config => |o| {
                    ret_ok = rd.editConfig(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .copy_config => |o| {
                    ret_ok = rd.copyConfig(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .delete_config => |o| {
                    ret_ok = rd.deleteConfig(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .lock => |o| {
                    ret_ok = rd.lock(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .unlock => |o| {
                    ret_ok = rd.unlock(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .get => |o| {
                    ret_ok = rd.get(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .close_session => |o| {
                    ret_ok = rd.closeSession(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .kill_session => |o| {
                    ret_ok = rd.killSession(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .commit => |o| {
                    ret_ok = rd.commit(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .discard => |o| {
                    ret_ok = rd.discard(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .cancel_commit => |o| {
                    ret_ok = rd.cancelCommit(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .validate => |o| {
                    ret_ok = rd.validate(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .get_schema => |o| {
                    ret_ok = rd.getSchema(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .get_data => |o| {
                    ret_ok = rd.getData(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .edit_data => |o| {
                    ret_ok = rd.editData(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .action => |o| {
                    ret_ok = rd.action(
                        self.allocator,
                        o,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
            }

            self.operation_lock.lock(self.io) catch {
                @panic("ffi-driver.FfiDriver: failed acquiring operation lock");
            };

            if (ret_err != null) {
                self.operation_results.put(
                    op.?.id,
                    ffi_operations.OperationResult{
                        .done = true,
                        .result = .{
                            .netconf = null,
                        },
                        .err = ret_err,
                    },
                ) catch {
                    @panic(
                        "ffi-driver.FfiDriver: failed storing operation result, " ++
                            "this should not happen",
                    );
                };
            } else {
                self.operation_results.put(
                    op.?.id,
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

        switch (options.operation) {
            .cli => {
                try self.operation_results.put(
                    operation_id,
                    ffi_operations.OperationResult{
                        .done = false,
                        .result = .{ .cli = null },
                        .err = null,
                    },
                );

                try self.operation_queue.writeItem(mut_options);
            },
            .netconf => {
                try self.operation_results.put(
                    operation_id,
                    ffi_operations.OperationResult{
                        .done = false,
                        .result = .{ .netconf = null },
                        .err = null,
                    },
                );

                try self.operation_queue.writeItem(mut_options);
            },
        }

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

        if (remove) {
            // clean it up
            _ = self.operation_results.remove(operation_id);
        }

        return ret.?;
    }

    /// A conveinence function to get result sizes for cli operations -- shimmed in so we can ensure
    /// that we do *not* process line endings for read any operations.
    pub fn getCliResultLens(
        self: *FfiDriver,
        r: *result.Result,
    ) ffi_operations.CliOperationSizes {
        const get_options = self.getCliResultOptions(r);

        var sizes = ffi_operations.CliOperationSizes{
            .operation_count = r.results.items.len,
            .operation_input_size = r.getInputLen(get_options),
            .operation_result_raw_size = r.getResultRawLen(get_options),
            .operation_result_size = r.getResultLen(get_options),
            .operation_failure_indicator_size = 0,
        };

        if (r.result_failure_indicator >= 0) {
            const failure_size = r.failed_indicators.?.items[@intCast(r.result_failure_indicator)].len;
            sizes.operation_failure_indicator_size = failure_size;
        }

        return sizes;
    }

    /// A conveinence function to get results for cli operations.
    pub fn getCliResults(
        self: *FfiDriver,
        r: *result.Result,
        operation_start_time: *u64,
        operation_splits: *[]u64,
        operation_input: *[]u8,
        operation_result_raw: *[]u8,
        operation_result: *[]u8,
        operation_result_failed_indicator: *[]u8,
        operation_error: *[]u8,
    ) !void {
        const get_options = self.getCliResultOptions(r);

        if (r.splits_ns.items.len > 0) {
            operation_start_time.* = @intCast(r.start_time_ns);
            for (0.., r.splits_ns.items) |idx, split| {
                operation_splits.*[idx] = @intCast(split);
            }
        } else {
            // was a noop -- like enterMode but where mode didn't change
            operation_start_time.* = @intCast(r.start_time_ns);
        }

        // to avoid a pointless allocation since we are already copying from the result into the
        // given string pointers, we'll do basically the same thing the result does in normal (zig)
        // operations in getResult/getResultRaw by iterating over the underlying array list and
        // copying from there, inserting newlines between results, into the given pointer(s)
        var cur: usize = 0;

        for (0.., r.inputs.items) |idx, input| {
            @memcpy(operation_input.*[cur .. cur + input.len], input);
            cur += input.len;

            if (idx != r.inputs.items.len - 1) {
                for (bytes.libscrapli_delimiter) |delimiter_char| {
                    operation_input.*[cur] = delimiter_char;
                    cur += 1;
                }
            }
        }

        try r.getResultRawPreAllocated(operation_result_raw.*, get_options);
        try r.getResultPreAllocated(operation_result.*, get_options);

        if (r.result_failure_indicated) {
            @memcpy(
                operation_result_failed_indicator.*,
                r.failed_indicators.?.items[@intCast(r.result_failure_indicator)],
            );
        }

        operation_error.* = "";
    }

    fn getCliResultOptions(
        self: *FfiDriver,
        r: *result.Result,
    ) result.GetResultOptions {
        // zlinter-disable require_exhaustive_enum_switch
        return switch (r.operation_kind) {
            // read any is bypassing "normal" things so we never want to process line ends
            // or anything like that since that will almost certainly be unexpected for users
            .read_any => .{
                .delimiter = bytes.libscrapli_delimiter,
                .normalize_line_feeds = false,
                .normalize_trailing_whitespace = false,
            },
            else => self.cli_get_results_options,
        };
    }
};
