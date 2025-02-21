const std = @import("std");
const operation = @import("operation.zig");
const driver = @import("driver.zig");
const result = @import("result.zig");

const operation_thread_ready_sleep: u64 = 250;
const poll_operation_sleep: u64 = 250_000;

pub const OperationResult = struct {
    done: bool,
    result: ?*result.Result,
    err: ?anyerror,
};

pub const OperationKind = enum {
    Open,
    EnterMode,
    GetPrompt,
    SendInput,
    SendPromptedInput,
};

pub const OpenOperation = struct {
    id: u32,
    options: operation.OpenOptions,
};

pub const EnterModeOperation = struct {
    id: u32,
    requested_mode: []const u8,
    options: operation.EnterModeOptions,
};

pub const GetPromptOperation = struct {
    id: u32,
    options: operation.GetPromptOptions,
};

pub const SendInputOperation = struct {
    id: u32,
    input: []const u8,
    options: operation.SendInputOptions,
};

pub const SendPromptedInputOperation = struct {
    id: u32,
    input: []const u8,
    prompt: []const u8,
    response: []const u8,
    options: operation.SendPromptedInputOptions,
};

pub const OperationOptions = union(OperationKind) { Open: OpenOperation, EnterMode: EnterModeOperation, GetPrompt: GetPromptOperation, SendInput: SendInputOperation, SendPromptedInput: SendPromptedInputOperation };

pub fn NewFfiDriver(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    host: []const u8,
    options: driver.Options,
) !*FfiDriver {
    const real_driver = try driver.NewDriverFromYaml(
        allocator,
        file_path,
        host,
        options,
    );

    const ffi_driver = try allocator.create(FfiDriver);

    ffi_driver.* = FfiDriver{
        .allocator = allocator,
        .real_driver = real_driver,
        .operation_id_counter = 0,
        .operation_thread = null,
        .operation_ready = std.atomic.Value(bool).init(false),
        .operation_stop = std.atomic.Value(bool).init(false),
        .operation_lock = std.Thread.Mutex{},
        .operation_condition = std.Thread.Condition{},
        .operation_predicate = 0,
        .operation_queue = std.fifo.LinearFifo(
            OperationOptions,
            std.fifo.LinearFifoBufferType.Dynamic,
        ).init(allocator),
        .operation_results = std.AutoHashMap(
            u32,
            OperationResult,
        ).init(allocator),
    };

    return ffi_driver;
}

pub const FfiDriver = struct {
    allocator: std.mem.Allocator,

    real_driver: *driver.Driver,

    operation_id_counter: u32,
    operation_thread: ?std.Thread,
    operation_ready: std.atomic.Value(bool),
    operation_stop: std.atomic.Value(bool),
    operation_lock: std.Thread.Mutex,
    operation_condition: std.Thread.Condition,
    operation_predicate: u32,
    operation_queue: std.fifo.LinearFifo(
        OperationOptions,
        std.fifo.LinearFifoBufferType.Dynamic,
    ),
    operation_results: std.AutoHashMap(
        u32,
        OperationResult,
    ),

    pub fn init(self: *FfiDriver) !void {
        return self.real_driver.init();
    }

    pub fn deinit(self: *FfiDriver) void {
        self.operation_queue.deinit();
        self.operation_results.deinit();
        self.real_driver.deinit();
        self.allocator.destroy(self);
    }

    pub fn open(self: *FfiDriver) !void {
        self.operation_thread = std.Thread.spawn(
            .{},
            FfiDriver.operationLoop,
            .{self},
        ) catch |err| {
            self.real_driver.log.critical("failed spawning operation thread, err: {}", .{err});

            return error.OpenFailed;
        };

        while (!self.operation_ready.load(std.builtin.AtomicOrder.acquire)) {
            // this blocks us until the operation thread is ready and processing, otherwise the
            // submit open will never get picked up
            std.time.sleep(operation_thread_ready_sleep);
        }
    }

    pub fn close(self: *FfiDriver, cancel: *bool) !void {
        // signal to the operation thread to stop, cant defer unlock because it obviously needs
        // to be unlocked for us to join on the thread or the thread would block waiting to acquire
        self.operation_lock.lock();
        self.operation_condition.signal();
        self.operation_lock.unlock();

        self.operation_stop.store(true, std.builtin.AtomicOrder.unordered);

        if (self.operation_thread != null) {
            self.operation_thread.?.join();
        }

        // in ffi land the wrapper (py/go/whatever) deals with on open/close so in the case of close
        // there is no point sending any string content back because there will be none (this is
        // in contrast to open where there may be login/auth content!)
        var opts = operation.NewCloseOptions();
        opts.cancel = cancel;

        const close_res = try self.real_driver.close(self.allocator, opts);
        close_res.deinit();
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
        self.real_driver.log.info("operation thread started", .{});

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

            switch (op.?) {
                OperationKind.Open => {
                    operation_id = op.?.Open.id;

                    ret_ok = self.real_driver.open(
                        self.allocator,
                        op.?.Open.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                OperationKind.EnterMode => {
                    operation_id = op.?.EnterMode.id;

                    ret_ok = self.real_driver.enterMode(
                        self.allocator,
                        op.?.EnterMode.requested_mode,
                        op.?.EnterMode.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                OperationKind.GetPrompt => {
                    operation_id = op.?.GetPrompt.id;

                    ret_ok = self.real_driver.getPrompt(
                        self.allocator,
                        op.?.GetPrompt.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                OperationKind.SendInput => {
                    operation_id = op.?.SendInput.id;

                    ret_ok = self.real_driver.sendInput(
                        self.allocator,
                        op.?.SendInput.input,
                        op.?.SendInput.options,
                    ) catch |err| blk: {
                        ret_err = err;
                        break :blk null;
                    };
                },
                OperationKind.SendPromptedInput => {
                    operation_id = op.?.SendPromptedInput.id;

                    ret_ok = self.real_driver.sendPromptedInput(
                        self.allocator,
                        op.?.SendPromptedInput.input,
                        op.?.SendPromptedInput.prompt,
                        op.?.SendPromptedInput.response,
                        op.?.SendPromptedInput.options,
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
                    OperationResult{
                        .done = true,
                        .result = null,
                        .err = ret_err,
                    },
                ) catch {
                    @panic("failed storing operation result, this should not happen");
                };
            } else {
                self.operation_results.put(
                    operation_id,
                    OperationResult{
                        .done = true,
                        .result = ret_ok,
                        .err = null,
                    },
                ) catch {
                    @panic("failed storing operation result, this should not happen");
                };
            }

            self.operation_lock.unlock();
        }

        self.real_driver.log.info("operation thread stopped", .{});
    }

    /// Poll the result hash for the presence of a "done" result for the given operation id.
    pub fn pollOperation(
        self: *FfiDriver,
        operation_id: u32,
        remove: bool,
    ) !OperationResult {
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
            const ret = try self.pollOperation(operation_id, false);

            if (!ret.done) {
                std.time.sleep(sleep_interval);
                continue;
            }

            return;
        }
    }

    pub fn queueOperation(
        self: *FfiDriver,
        options: OperationOptions,
    ) !u32 {
        var mut_options = options;

        self.operation_lock.lock();
        defer self.operation_lock.unlock();

        self.operation_id_counter += 1;

        const operation_id = self.operation_id_counter;

        try self.operation_results.put(operation_id, OperationResult{
            .done = false,
            .result = null,
            .err = null,
        });

        switch (options) {
            OperationKind.Open => {
                mut_options.Open.id = operation_id;
            },
            OperationKind.EnterMode => {
                mut_options.EnterMode.id = operation_id;
            },
            OperationKind.GetPrompt => {
                mut_options.GetPrompt.id = operation_id;
            },
            OperationKind.SendInput => {
                mut_options.SendInput.id = operation_id;
            },
            OperationKind.SendPromptedInput => {
                mut_options.SendPromptedInput.id = operation_id;
            },
        }

        try self.operation_queue.writeItem(mut_options);

        // signal to unblock the operation loop (we do this so we dont have to do some sleep in the
        // loop between checking for operations)
        self.operation_condition.signal();

        return operation_id;
    }
};
