const std = @import("std");

const cli = @import("cli.zig");
const netconf = @import("netconf.zig");
const result = @import("result.zig");
const result_netconf = @import("netconf-result.zig");
const logging = @import("logging.zig");

const ffi_operations = @import("ffi-operations.zig");

const operation_thread_ready_sleep: u64 = 250;
const poll_operation_sleep: u64 = 250_000;

pub const RealDriver = union(enum) {
    cli: *cli.Driver,
    netconf: *netconf.Driver,
};

pub const FfiDriver = struct {
    allocator: std.mem.Allocator,

    real_driver: RealDriver,

    operation_id_counter: u32,
    operation_thread: ?std.Thread,
    operation_ready: std.atomic.Value(bool),
    operation_stop: std.atomic.Value(bool),
    operation_lock: std.Thread.Mutex,
    operation_condition: std.Thread.Condition,
    operation_predicate: u32,
    operation_queue: std.fifo.LinearFifo(
        ffi_operations.OperationOptions,
        std.fifo.LinearFifoBufferType.Dynamic,
    ),
    operation_results: std.AutoHashMap(
        u32,
        ffi_operations.OperationResult,
    ),

    pub fn init(
        allocator: std.mem.Allocator,
        host: []const u8,
        config: cli.Config,
    ) !*FfiDriver {
        const ffi_driver = try allocator.create(FfiDriver);

        ffi_driver.* = FfiDriver{
            .allocator = allocator,
            .real_driver = RealDriver{
                .cli = try cli.Driver.init(
                    allocator,
                    host,
                    config,
                ),
            },
            .operation_id_counter = 0,
            .operation_thread = null,
            .operation_ready = std.atomic.Value(bool).init(false),
            .operation_stop = std.atomic.Value(bool).init(false),
            .operation_lock = std.Thread.Mutex{},
            .operation_condition = std.Thread.Condition{},
            .operation_predicate = 0,
            .operation_queue = std.fifo.LinearFifo(
                ffi_operations.OperationOptions,
                std.fifo.LinearFifoBufferType.Dynamic,
            ).init(allocator),
            .operation_results = std.AutoHashMap(
                u32,
                ffi_operations.OperationResult,
            ).init(allocator),
        };

        return ffi_driver;
    }

    pub fn init_netconf(
        allocator: std.mem.Allocator,
        host: []const u8,
        config: netconf.Config,
    ) !*FfiDriver {
        const ffi_driver = try allocator.create(FfiDriver);

        ffi_driver.* = FfiDriver{
            .allocator = allocator,
            .real_driver = RealDriver{
                .netconf = try netconf.Driver.init(
                    allocator,
                    host,
                    config,
                ),
            },
            .operation_id_counter = 0,
            .operation_thread = null,
            .operation_ready = std.atomic.Value(bool).init(false),
            .operation_stop = std.atomic.Value(bool).init(false),
            .operation_lock = std.Thread.Mutex{},
            .operation_condition = std.Thread.Condition{},
            .operation_predicate = 0,
            .operation_queue = std.fifo.LinearFifo(
                ffi_operations.OperationOptions,
                std.fifo.LinearFifoBufferType.Dynamic,
            ).init(allocator),
            .operation_results = std.AutoHashMap(
                u32,
                ffi_operations.OperationResult,
            ).init(allocator),
        };

        return ffi_driver;
    }

    pub fn deinit(self: *FfiDriver) void {
        // signal to the operation thread to stop, cant defer unlock because it obviously needs
        // to be unlocked for us to join on the thread or the thread would block waiting to acquire
        self.operation_lock.lock();
        self.operation_condition.signal();
        self.operation_lock.unlock();

        self.operation_stop.store(true, std.builtin.AtomicOrder.unordered);

        if (self.operation_thread != null) {
            self.operation_thread.?.join();
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

        self.allocator.destroy(self);
    }

    pub fn log(
        self: *FfiDriver,
        level: logging.LogLevel,
        comptime format: []const u8,
        args: anytype,
    ) void {
        const logger = switch (self.real_driver) {
            .cli => |d| d.log,
            .netconf => |d| d.log,
        };

        switch (level) {
            .debug => {
                logger.debug(format, args);
            },
            .info => {
                logger.info(format, args);
            },
            .warn => {
                logger.warn(format, args);
            },
            .critical => {
                logger.critical(format, args);
            },
            .fatal => {
                logger.fatal(format, args);
            },
        }
    }

    pub fn open(self: *FfiDriver) !void {
        switch (self.real_driver) {
            .cli => {
                self.operation_thread = std.Thread.spawn(
                    .{},
                    FfiDriver.operationLoop,
                    .{self},
                ) catch |err| {
                    self.log(
                        logging.LogLevel.critical,
                        "failed spawning operation thread, err: {}",
                        .{err},
                    );

                    return error.OpenFailed;
                };
            },
            .netconf => {
                self.operation_thread = std.Thread.spawn(
                    .{},
                    FfiDriver.operationLoopNetconf,
                    .{self},
                ) catch |err| {
                    self.log(
                        logging.LogLevel.critical,
                        "failed spawning operation thread, err: {}",
                        .{err},
                    );

                    return error.OpenFailed;
                };
            },
        }

        while (!self.operation_ready.load(std.builtin.AtomicOrder.acquire)) {
            // this blocks us until the operation thread is ready and processing, otherwise the
            // submit open will never get picked up
            std.time.sleep(operation_thread_ready_sleep);
        }
    }

    pub fn close(self: *FfiDriver, cancel: *bool) !void {
        // TODO this is no longer the case i think, we *should* be returning the result data from
        //   a close operation.
        // in ffi land the wrapper (py/go/whatever) deals with on open/close so in the case of close
        // there is no point sending any string content back because there will be none (this is
        // in contrast to open where there may be login/auth content!)
        switch (self.real_driver) {
            .cli => |d| {
                const close_res = try d.close(
                    self.allocator,
                    .{ .cancel = cancel },
                );
                close_res.deinit();
            },
            .netconf => |d| {
                const close_res = try d.close(
                    self.allocator,
                    .{ .cancel = cancel },
                );
                close_res.deinit();
            },
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
        self.log(logging.LogLevel.info, "operation thread started", .{});

        self.operation_ready.store(true, std.builtin.AtomicOrder.unordered);

        while (!self.operation_stop.load(std.builtin.AtomicOrder.acquire)) {
            self.operation_lock.lock();

            self.operation_condition.wait(&self.operation_lock);

            const op = self.operation_queue.readItem();

            self.operation_lock.unlock();

            if (op == null) {
                continue;
            }

            var operation_id: u32 = 0;
            var ret_ok: ?*result.Result = null;
            var ret_err: ?anyerror = null;

            const rd = switch (self.real_driver) {
                .cli => |d| d,
                else => {
                    @panic("netconf operation loop executed, but driver is not netconf");
                },
            };

            switch (op.?.cli) {
                .open => |o| {
                    operation_id = o.id;

                    ret_ok = rd.open(
                        self.allocator,
                        o.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .enter_mode => |o| {
                    operation_id = o.id;

                    ret_ok = rd.enterMode(
                        self.allocator,
                        o.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .get_prompt => |o| {
                    operation_id = o.id;

                    ret_ok = rd.getPrompt(
                        self.allocator,
                        o.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .send_input => |o| {
                    operation_id = o.id;

                    ret_ok = rd.sendInput(
                        self.allocator,
                        o.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .send_prompted_input => |o| {
                    operation_id = o.id;

                    ret_ok = rd.sendPromptedInput(
                        self.allocator,
                        o.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
            }

            self.operation_lock.lock();

            if (ret_err != null) {
                self.operation_results.put(
                    operation_id,
                    ffi_operations.OperationResult{
                        .done = true,
                        .result = .{
                            .cli = null,
                        },
                        .err = ret_err,
                    },
                ) catch {
                    @panic("failed storing operation result, this should not happen");
                };
            } else {
                self.operation_results.put(
                    operation_id,
                    ffi_operations.OperationResult{
                        .done = true,
                        .result = .{
                            .cli = ret_ok,
                        },
                        .err = null,
                    },
                ) catch {
                    @panic("failed storing operation result, this should not happen");
                };
            }

            self.operation_lock.unlock();
        }

        self.log(logging.LogLevel.info, "operation thread stopped", .{});
    }

    fn operationLoopNetconf(self: *FfiDriver) void {
        self.log(logging.LogLevel.info, "operation thread started", .{});

        self.operation_ready.store(true, std.builtin.AtomicOrder.unordered);

        while (!self.operation_stop.load(std.builtin.AtomicOrder.acquire)) {
            self.operation_lock.lock();

            self.operation_condition.wait(&self.operation_lock);

            const op = self.operation_queue.readItem();

            self.operation_lock.unlock();

            if (op == null) {
                continue;
            }

            var operation_id: u32 = 0;
            var ret_ok: ?*result_netconf.Result = null;
            var ret_err: ?anyerror = null;

            const rd = switch (self.real_driver) {
                .netconf => |d| d,
                else => {
                    @panic("netconf operation loop executed, but driver is not netconf");
                },
            };

            switch (op.?.netconf) {
                .open => |o| {
                    operation_id = o.id;

                    ret_ok = rd.open(
                        self.allocator,
                        o.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .get_config => |o| {
                    operation_id = o.id;

                    ret_ok = rd.getConfig(
                        self.allocator,
                        o.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .edit_config => |o| {
                    operation_id = o.id;

                    ret_ok = rd.editConfig(
                        self.allocator,
                        o.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .copy_config => |o| {
                    operation_id = o.id;

                    ret_ok = rd.copyConfig(
                        self.allocator,
                        o.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .delete_config => |o| {
                    operation_id = o.id;

                    ret_ok = rd.deleteConfig(
                        self.allocator,
                        o.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .lock => |o| {
                    operation_id = o.id;

                    ret_ok = rd.lock(
                        self.allocator,
                        o.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .unlock => |o| {
                    operation_id = o.id;

                    ret_ok = rd.unlock(
                        self.allocator,
                        o.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .get => |o| {
                    operation_id = o.id;

                    ret_ok = rd.get(
                        self.allocator,
                        o.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .close_session => |o| {
                    operation_id = o.id;

                    ret_ok = rd.closeSession(
                        self.allocator,
                        o.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                .kill_session => |o| {
                    operation_id = o.id;

                    ret_ok = rd.killSession(
                        self.allocator,
                        o.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
            }

            self.operation_lock.lock();

            if (ret_err != null) {
                self.operation_results.put(
                    operation_id,
                    ffi_operations.OperationResult{
                        .done = true,
                        .result = .{
                            .netconf = null,
                        },
                        .err = ret_err,
                    },
                ) catch {
                    @panic("failed storing operation result, this should not happen");
                };
            } else {
                self.operation_results.put(
                    operation_id,
                    ffi_operations.OperationResult{
                        .done = true,
                        .result = .{
                            .netconf = ret_ok,
                        },
                        .err = null,
                    },
                ) catch {
                    @panic("failed storing operation result, this should not happen");
                };
            }

            self.operation_lock.unlock();
        }

        self.log(logging.LogLevel.info, "operation thread stopped", .{});
    }

    /// Poll the result hash for the presence of a "done" result for the given operation id.
    pub fn pollOperation(
        self: *FfiDriver,
        operation_id: u32,
        remove: bool,
    ) !ffi_operations.OperationResult {
        self.operation_lock.lock();
        defer self.operation_lock.unlock();

        if (!self.operation_results.contains(operation_id)) {
            return error.BadId;
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

    /// Wait for an enqueued operation to complete.
    pub fn waitOperation(
        self: *FfiDriver,
        operation_id: u32,
        poll_interval: u64,
    ) !void {
        var sleep_interval = poll_operation_sleep;
        if (poll_interval > 0) {
            sleep_interval = poll_interval;
        }

        while (true) {
            const ret = try self.pollOperation(
                operation_id,
                false,
            );

            if (!ret.done) {
                std.time.sleep(sleep_interval);
                continue;
            }

            return;
        }
    }

    pub fn queueOperation(
        self: *FfiDriver,
        options: ffi_operations.OperationOptions,
    ) !u32 {
        var mut_options = options;

        self.operation_lock.lock();
        defer self.operation_lock.unlock();

        self.operation_id_counter += 1;

        const operation_id = self.operation_id_counter;

        switch (options) {
            .cli => |doptions| {
                try self.operation_results.put(
                    operation_id,
                    ffi_operations.OperationResult{
                        .done = false,
                        .result = .{ .cli = null },
                        .err = null,
                    },
                );

                switch (doptions) {
                    .open => {
                        mut_options.cli.open.id = operation_id;
                    },
                    .enter_mode => {
                        mut_options.cli.enter_mode.id = operation_id;
                    },
                    .get_prompt => {
                        mut_options.cli.get_prompt.id = operation_id;
                    },
                    .send_input => {
                        mut_options.cli.send_input.id = operation_id;
                    },
                    .send_prompted_input => {
                        mut_options.cli.send_prompted_input.id = operation_id;
                    },
                }

                try self.operation_queue.writeItem(mut_options);
            },
            .netconf => |noptions| {
                try self.operation_results.put(
                    operation_id,
                    ffi_operations.OperationResult{
                        .done = false,
                        .result = .{ .netconf = null },
                        .err = null,
                    },
                );

                switch (noptions) {
                    .open => {
                        mut_options.netconf.open.id = operation_id;
                    },
                    .get_config => {
                        mut_options.netconf.get_config.id = operation_id;
                    },
                    .edit_config => {
                        mut_options.netconf.edit_config.id = operation_id;
                    },
                    .copy_config => {
                        mut_options.netconf.copy_config.id = operation_id;
                    },
                    .delete_config => {
                        mut_options.netconf.delete_config.id = operation_id;
                    },
                    .lock => {
                        mut_options.netconf.lock.id = operation_id;
                    },
                    .unlock => {
                        mut_options.netconf.unlock.id = operation_id;
                    },
                    .get => {
                        mut_options.netconf.get.id = operation_id;
                    },
                    .close_session => {
                        mut_options.netconf.close_session.id = operation_id;
                    },
                    .kill_session => {
                        mut_options.netconf.kill_session.id = operation_id;
                    },
                }

                try self.operation_queue.writeItem(mut_options);
            },
        }

        // signal to unblock the operation loop (we do this so we dont have to do some sleep in the
        // loop between checking for operations)
        self.operation_condition.signal();

        return operation_id;
    }
};
