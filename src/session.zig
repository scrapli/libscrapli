const std = @import("std");

const ascii = @import("ascii.zig");
const auth = @import("auth.zig");
const bytes = @import("bytes.zig");
const bytes_check = @import("bytes-check.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const operation = @import("cli-operation.zig");
const queue = @import("queue.zig");
const re = @import("re.zig");
const transport = @import("transport.zig");

const default_return_char: []const u8 = "\n";

const ReadThreadState = enum(u8) {
    uninitialized,
    run,
    stop,
};

pub const RecordDestination = union(enum) {
    writer: std.fs.File.Writer,
    f: []const u8,
};

pub const OptionsInputs = struct {
    read_size: u64 = 4_096,
    min_read_delay_ns: u64 = 5_000,
    max_read_delay_ns: u64 = 15_000_000,
    return_char: []const u8 = default_return_char,
    operation_timeout_ns: u64 = 10_000_000_000,
    operation_max_search_depth: u64 = 512,
    record_destination: ?RecordDestination = null,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    read_size: u64,
    min_read_delay_ns: u64,
    max_read_delay_ns: u64,
    return_char: []const u8,
    operation_timeout_ns: u64,
    operation_max_search_depth: u64,
    record_destination: ?RecordDestination,

    pub fn init(allocator: std.mem.Allocator, opts: OptionsInputs) !*Options {
        const o = try allocator.create(Options);
        errdefer allocator.destroy(o);

        o.* = Options{
            .allocator = allocator,
            .read_size = opts.read_size,
            .min_read_delay_ns = opts.min_read_delay_ns,
            .max_read_delay_ns = opts.max_read_delay_ns,
            .return_char = opts.return_char,
            .operation_timeout_ns = opts.operation_timeout_ns,
            .operation_max_search_depth = opts.operation_max_search_depth,
            .record_destination = opts.record_destination,
        };

        if (&o.return_char[0] != &default_return_char[0]) {
            o.return_char = try o.allocator.dupe(u8, o.return_char);
        }

        if (o.record_destination) |rd| {
            switch (rd) {
                .f => {
                    o.record_destination = RecordDestination{
                        .f = try o.allocator.dupe(u8, rd.f),
                    };
                },
                else => {},
            }
        }

        return o;
    }

    pub fn deinit(self: *Options) void {
        if (&self.return_char[0] != &default_return_char[0]) {
            self.allocator.free(self.return_char);
        }

        if (self.record_destination) |rd| {
            switch (rd) {
                .f => {
                    self.allocator.free(rd.f);
                },
                else => {},
            }
        }

        self.allocator.destroy(self);
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    log: logging.Logger,
    options: *Options,
    auth_options: *auth.Options,

    transport: *transport.Transport,

    read_thread: ?std.Thread,
    read_stop: std.atomic.Value(ReadThreadState),
    read_lock: std.Thread.Mutex,
    read_queue: queue.LinearFifo(
        u8,
        queue.LinearFifoBufferType.Dynamic,
    ),
    read_thread_errored: bool = false,

    recorder_buf: [1024]u8 = undefined,
    recorder: ?std.fs.File.Writer = null,

    compiled_username_pattern: ?*re.pcre2CompiledPattern = null,
    compiled_password_pattern: ?*re.pcre2CompiledPattern = null,
    compiled_private_key_passphrase_pattern: ?*re.pcre2CompiledPattern = null,

    prompt_pattern: []const u8,
    compiled_prompt_pattern: ?*re.pcre2CompiledPattern = null,

    last_consumed_prompt: std.ArrayList(u8),

    pub fn init(
        allocator: std.mem.Allocator,
        log: logging.Logger,
        prompt_pattern: []const u8,
        options: *Options,
        auth_options: *auth.Options,
        transport_options: *transport.Options,
    ) !*Session {
        logging.traceWithSrc(log, @src(), "session.Session initializing", .{});

        const t = try transport.Transport.init(
            allocator,
            log,
            transport_options,
        );
        errdefer t.deinit();

        const s = try allocator.create(Session);

        var recorder: ?std.fs.File.Writer = null;
        if (options.record_destination) |rd| {
            switch (rd) {
                .f => {
                    const out_f = try std.fs.cwd().createFile(
                        rd.f,
                        .{},
                    );

                    recorder = out_f.writer(&s.recorder_buf);
                },
                .writer => {
                    recorder = rd.writer;
                },
            }
        }

        s.* = Session{
            .allocator = allocator,
            .log = log,
            .options = options,
            .auth_options = auth_options,
            .transport = t,
            .read_thread = null,
            .read_stop = std.atomic.Value(ReadThreadState).init(ReadThreadState.uninitialized),
            .read_lock = std.Thread.Mutex{},
            .read_queue = queue.LinearFifo(
                u8,
                queue.LinearFifoBufferType.Dynamic,
            ).init(allocator),
            .recorder = recorder,
            .prompt_pattern = prompt_pattern,
            .last_consumed_prompt = .{},
        };
        errdefer s.deinit();

        s.compiled_username_pattern = re.pcre2Compile(s.auth_options.username_pattern);
        if (s.compiled_username_pattern == null) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                log,
                "session.Session init: failed compling username pattern {s}",
                .{s.auth_options.username_pattern},
            );
        }

        s.compiled_password_pattern = re.pcre2Compile(s.auth_options.password_pattern);
        if (s.compiled_password_pattern == null) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                log,
                "session.Session init: failed compling password pattern {s}",
                .{s.auth_options.password_pattern},
            );
        }

        s.compiled_private_key_passphrase_pattern = re.pcre2Compile(
            s.auth_options.private_key_passphrase_pattern,
        );
        if (s.compiled_private_key_passphrase_pattern == null) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                log,
                "session.Session init: failed compling passphrase pattern {s}",
                .{s.auth_options.private_key_passphrase_pattern},
            );
        }

        s.compiled_prompt_pattern = re.pcre2Compile(s.prompt_pattern);
        if (s.compiled_prompt_pattern == null) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                log,
                "session.Session init: failed compling prompt pattern {s}",
                .{s.prompt_pattern},
            );
        }

        return s;
    }

    pub fn deinit(self: *Session) void {
        logging.traceWithSrc(self.log, @src(), "session.Session deinitializing", .{});

        if (self.read_stop.load(std.builtin.AtomicOrder.acquire) == ReadThreadState.run) {
            // if for whatever reason (likely because a call to driver.open failed causing a defer
            // close to *not* trigger) the session didnt get "closed", ensure we do that...
            // but... we ignore errors here since we want deinit to return void and it really
            // shouldn't matter if something errors during close
            // zlint-disable-next-line suppressed-errors
            self.close() catch {};
        }

        self.last_consumed_prompt.deinit(self.allocator);

        if (self.compiled_username_pattern != null) {
            re.pcre2Free(self.compiled_username_pattern.?);
        }

        if (self.compiled_password_pattern != null) {
            re.pcre2Free(self.compiled_password_pattern.?);
        }

        if (self.compiled_private_key_passphrase_pattern != null) {
            re.pcre2Free(self.compiled_private_key_passphrase_pattern.?);
        }

        if (self.compiled_prompt_pattern != null) {
            re.pcre2Free(self.compiled_prompt_pattern.?);
        }

        self.transport.deinit();
        self.read_queue.deinit();

        self.allocator.destroy(self);
    }

    pub fn open(
        self: *Session,
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        cancel: ?*bool,
    ) ![2][]const u8 {
        self.log.info("session.Session open requested", .{});

        var timer = try std.time.Timer.start();

        try self.transport.open(
            &timer,
            cancel,
            self.options.operation_timeout_ns,
            host,
            port,
            self.auth_options,
        );

        self.read_stop.store(ReadThreadState.run, std.builtin.AtomicOrder.unordered);

        self.read_thread = std.Thread.spawn(
            .{},
            Session.readLoop,
            .{self},
        ) catch |err| {
            return errors.wrapCriticalError(
                err,
                @src(),
                self.log,
                "session.Session open: failed spawning read thread",
                .{},
            );
        };

        if (!self.auth_options.force_in_session_auth) {
            if (!self.transport.isInSessionAuth()) {
                // not forcing in session auth, and the transport is not requiring it, done
                return [2][]const u8{ "", "" };
            }

            if (self.auth_options.bypass_in_session_auth) {
                // not forcing, and user wants to bypass, done
                return [2][]const u8{ "", "" };
            }
        }

        return self.authenticate(
            allocator,
            &timer,
            cancel,
        );
    }

    pub fn close(self: *Session) !void {
        self.log.info("session.Session close requested", .{});

        self.read_stop.store(ReadThreadState.stop, std.builtin.AtomicOrder.unordered);

        while (self.read_stop.load(std.builtin.AtomicOrder.acquire) != ReadThreadState.stop) {
            std.Thread.sleep(self.options.min_read_delay_ns);
        }

        // need to unblock the transport waiter after signaling the read thread to stop, this will
        // break any blocking read, then the readloop can nicely exit
        try self.transport.unblock();

        if (self.read_thread) |t| {
            t.join();
        }

        if (self.options.record_destination) |rd| {
            switch (rd) {
                .f => {
                    // when just given a file path we'll "own" that lifecycle and close/cleanup
                    // as well as ensure we strip asci/ansi bits (so the file is easy to read etc.
                    // and especially for tests!); otherwise we'll leave it to the user
                    try self.recorder.?.interface.flush();
                    self.recorder.?.file.close();

                    try ascii.stripAsciiAndAnsiControlCharsInFile(rd.f);
                },
                else => {},
            }
        }

        self.transport.close();
    }

    fn readLoop(self: *Session) !void {
        self.log.info("session.Session read thread started", .{});

        errdefer self.read_thread_errored = true;

        var buf = try self.allocator.alloc(u8, self.options.read_size);
        defer self.allocator.free(buf);

        while (self.read_stop.load(std.builtin.AtomicOrder.acquire) != ReadThreadState.stop) {
            const n = self.transport.read(buf) catch {
                self.read_thread_errored = true;

                return;
            };

            if (n == 0) {
                continue;
            }

            self.read_lock.lock();
            try self.read_queue.write(buf[0..n]);
            self.read_lock.unlock();

            // log all the reads w/ ascii unprintables shown
            logging.traceWithSrc(
                self.log,
                @src(),
                "session.Session readLoop: raw read '{f}'",
                .{std.ascii.hexEscape(buf, .lower)},
            );

            if (self.recorder) |*recorder| {
                const r = &recorder.interface;
                try r.writeAll(buf[0..n]);
                try r.flush();
            }
        }

        self.log.info("session.Session read thread stopped", .{});
    }

    pub fn read(self: *Session, buf: []u8) !usize {
        self.read_lock.lock();
        defer self.read_lock.unlock();

        if (self.read_thread_errored and self.read_queue.readableLength() == 0) {
            // once the read thread is errored out and there is nothing else to
            // read
            return errors.ScrapliError.EOF;
        }

        return self.read_queue.read(buf);
    }

    pub fn write(self: *Session, buf: []const u8, redacted: bool) !void {
        self.log.info("session.Session write requested", .{});

        if (!redacted) {
            self.log.debug("session.Session write: '{f}'", .{std.ascii.hexEscape(buf, .lower)});
        } else {
            self.log.debug("session.Session write: <redacted>", .{});
        }

        try self.transport.write(buf);
    }

    pub fn writeReturn(self: *Session) !void {
        self.log.info("session.Session writeReturn requested", .{});

        try self.write(self.options.return_char, false);
    }

    pub fn writeAndReturn(
        self: *Session,
        buf: []const u8,
        redacted: bool,
    ) !void {
        try self.write(buf, redacted);
        try self.writeReturn();
    }

    fn authenticate(
        self: *Session,
        allocator: std.mem.Allocator,
        timer: *std.time.Timer,
        cancel: ?*bool,
    ) ![2][]const u8 {
        self.log.info("session.Session authenticate requested", .{});

        var bufs = bytes.ProcessedBuf.init(allocator);
        defer bufs.deinit();

        var cur_check_start_idx: usize = 0;

        var auth_username_prompt_seen_count: u8 = 0;
        var auth_password_prompt_seen_count: u8 = 0;
        var auth_passphrase_prompt_seen_count: u8 = 0;

        var buf = try allocator.alloc(u8, self.options.read_size);
        defer allocator.free(buf);

        // in the case of auth, if we error out, we almost certainly need to stop the read loop
        // as the transport is probably gone from under our feet anyway.
        errdefer self.read_stop.store(ReadThreadState.stop, std.builtin.AtomicOrder.unordered);

        while (true) {
            if (cancel != null and cancel.?.*) {
                return errors.wrapCriticalError(
                    errors.ScrapliError.Cancelled,
                    @src(),
                    self.log,
                    "session.Session authenticate: operation cancelled",
                    .{},
                );
            }

            const elapsed_time = timer.read();

            if (self.options.operation_timeout_ns != 0 and
                elapsed_time >= self.options.operation_timeout_ns)
            {
                return errors.wrapCriticalError(
                    errors.ScrapliError.TimeoutExceeded,
                    @src(),
                    self.log,
                    "session.Session authenticate: operation timeout exceeded",
                    .{},
                );
            }

            const n = self.read(buf) catch |err| {
                switch (err) {
                    errors.ScrapliError.EOF => {
                        // hitting eof in auth/open means we likely got a connection refused or
                        // something similar. we gotta slurp up the buffer to read it and check so
                        // we can *hopefully* return a decent error message to the user
                        const error_message = try auth.openMessageHandler(
                            allocator,
                            bufs.processed.items,
                        );

                        if (error_message) |msg| {
                            return errors.wrapCriticalError(
                                errors.ScrapliError.Transport,
                                @src(),
                                self.log,
                                "session.Session authenticate: open failed, error: '{s}'",
                                .{msg},
                            );
                        }

                        return errors.wrapCriticalError(
                            errors.ScrapliError.Transport,
                            @src(),
                            self.log,
                            "session.Session authenticate: open failed",
                            .{},
                        );
                    },
                    else => {
                        return err;
                    },
                }
            };

            if (n == 0) {
                continue;
            }

            try bufs.appendSlice(buf[0..n]);

            const searchable_buf = bytes.getBufSearchView(
                bufs.processed.items[cur_check_start_idx..],
                self.options.operation_max_search_depth,
            );

            const error_message = try auth.openMessageHandler(
                allocator,
                bufs.processed.items,
            );

            if (error_message) |msg| {
                return errors.wrapCriticalError(
                    errors.ScrapliError.Session,
                    @src(),
                    self.log,
                    "session.Session authenticate: open failed, error: '{s}'",
                    .{msg},
                );
            }

            const state = try auth.processSearchableAuthBuf(
                searchable_buf,
                self.compiled_prompt_pattern,
                self.compiled_username_pattern,
                self.compiled_password_pattern,
                self.compiled_private_key_passphrase_pattern,
            );

            switch (state) {
                .complete => {
                    return bufs.toOwnedSlices();
                },
                .username_prompted => {
                    if (self.auth_options.username == null) {
                        return errors.wrapCriticalError(
                            errors.ScrapliError.Session,
                            @src(),
                            self.log,
                            "session.Session authenticate: username prompt seen " ++
                                "but no username set",
                            .{},
                        );
                    }

                    auth_username_prompt_seen_count += 1;

                    if (auth_username_prompt_seen_count > 2) {
                        return errors.wrapCriticalError(
                            errors.ScrapliError.Session,
                            @src(),
                            self.log,
                            "session.Session authenticate: username prompt seen " ++
                                "multiple times, assuming authentication failed",
                            .{},
                        );
                    }

                    try self.writeAndReturn(self.auth_options.username.?, true);

                    cur_check_start_idx = bufs.processed.items.len;

                    continue;
                },
                .password_prompted => {
                    if (self.auth_options.password == null) {
                        return errors.wrapCriticalError(
                            errors.ScrapliError.Session,
                            @src(),
                            self.log,
                            "session.Session authenticate: password prompt seen " ++
                                "but no password set",
                            .{},
                        );
                    }

                    auth_password_prompt_seen_count += 1;

                    if (auth_password_prompt_seen_count > 2) {
                        return errors.wrapCriticalError(
                            errors.ScrapliError.Session,
                            @src(),
                            self.log,
                            "session.Session authenticate: password prompt seen multiple times, " ++
                                "assuming authentication failed",
                            .{},
                        );
                    }

                    try self.writeAndReturn(
                        self.auth_options.resolveAuthValue(
                            self.auth_options.password.?,
                        ) catch |err| {
                            return errors.wrapCriticalError(
                                err,
                                @src(),
                                self.log,
                                "session.Session authenticate: failed resolving auth " ++
                                    "lookup value '{s}'",
                                .{self.auth_options.password.?},
                            );
                        },
                        true,
                    );

                    cur_check_start_idx = bufs.processed.items.len;

                    continue;
                },
                .passphrase_prompted => {
                    if (self.auth_options.private_key_passphrase == null) {
                        return errors.wrapCriticalError(
                            errors.ScrapliError.Session,
                            @src(),
                            self.log,
                            "session.Session authenticate: private key passphrase prompt " ++
                                "seen but no passphrase set",
                            .{},
                        );
                    }

                    auth_passphrase_prompt_seen_count += 1;

                    if (auth_passphrase_prompt_seen_count > 2) {
                        return errors.wrapCriticalError(
                            errors.ScrapliError.Session,
                            @src(),
                            self.log,
                            "session.Session authenticate: private key passphrase prompt " ++
                                "seen multiple times, assuming authentication failed",
                            .{},
                        );
                    }

                    try self.writeAndReturn(
                        self.auth_options.resolveAuthValue(
                            self.auth_options.private_key_passphrase.?,
                        ) catch |err| {
                            return errors.wrapCriticalError(
                                err,
                                @src(),
                                self.log,
                                "session.Session authenticate: failed resolving auth " ++
                                    "lookup value '{s}'",
                                .{self.auth_options.password.?},
                            );
                        },
                        true,
                    );

                    cur_check_start_idx = bufs.processed.items.len;
                },
                ._continue => {},
            }
        }
    }

    fn getReadBackoff(
        cur_val: u64,
        max_val: u64,
    ) u64 {
        var new_val: u64 = cur_val;

        new_val *= 2;
        if (new_val > max_val) {
            new_val = max_val;
        }

        return new_val;
    }

    pub fn readTimeout(
        self: *Session,
        timer: *std.time.Timer,
        cancel: ?*bool,
        checkf: bytes_check.CheckF,
        checkargs: bytes_check.CheckArgs,
        bufs: *bytes.ProcessedBuf,
        search_depth: u64,
    ) !bytes_check.MatchPositions {
        self.log.info("session.Session readTimeout requested", .{});

        var cur_read_delay_ns: u64 = self.options.min_read_delay_ns;

        // to ensure the check_read_operation_done function doesnt think we are done "early" by
        // finding a match from an earlier prompt we snag the len of the processed buf then we
        // just send that to the end of the buffer to the check func, we have to make sure we
        // increase the found start/end positions by this value too!
        const op_processed_buf_starting_len = bufs.processed.items.len;

        var buf = try self.allocator.alloc(u8, self.options.read_size);
        defer self.allocator.free(buf);

        while (true) {
            if (cancel != null and cancel.?.*) {
                return errors.wrapCriticalError(
                    errors.ScrapliError.Cancelled,
                    @src(),
                    self.log,
                    "session.Session readTimeout: operation cancelled",
                    .{},
                );
            }

            const elapsed_time = timer.read();

            // if timeout is 0 we dont timeout -- we do this to let users 1) disable it but also
            // 2) to let the ffi layer via (go) context control it for example
            if (self.options.operation_timeout_ns != 0 and
                (elapsed_time + cur_read_delay_ns) >= self.options.operation_timeout_ns)
            {
                return errors.wrapCriticalError(
                    errors.ScrapliError.TimeoutExceeded,
                    @src(),
                    self.log,
                    "session.Session readTimeout: operation timeout exceeded",
                    .{},
                );
            }

            defer std.Thread.sleep(cur_read_delay_ns);

            const n = try self.read(buf);

            if (n == 0) {
                cur_read_delay_ns = Session.getReadBackoff(
                    cur_read_delay_ns,
                    self.options.max_read_delay_ns,
                );

                continue;
            } else {
                cur_read_delay_ns = self.options.min_read_delay_ns;
            }

            try bufs.appendSlice(buf[0..n]);

            // weve logged "raw" reads in the readloop, now that we have processed something
            // (ProcessedBuf handles ascii filtering on appendSlice) we can show the processed bits
            logging.traceWithSrc(
                self.log,
                @src(),
                "session.Session readTimeout: processed read: '{s}'",
                .{bufs.processed.items},
            );

            const searchable_buf = bytes.getBufSearchView(
                bufs.processed.items[op_processed_buf_starting_len..],
                search_depth,
            );

            var match_indexes = try checkf(checkargs, searchable_buf);

            if (!(match_indexes.start == 0 and match_indexes.end == 0)) {
                match_indexes.start += (bufs.processed.items.len - searchable_buf.len);
                match_indexes.end += (bufs.processed.items.len - searchable_buf.len) + 1;

                return match_indexes;
            }
        }
    }

    pub fn readAny(
        self: *Session,
        allocator: std.mem.Allocator,
        options: operation.ReadAnyOptions,
    ) ![2][]const u8 {
        self.log.info("session.Session readAny requested", .{});

        var bufs = bytes.ProcessedBuf.init(allocator);
        defer bufs.deinit();

        var timer = try std.time.Timer.start();

        _ = try self.readTimeout(
            &timer,
            options.cancel,
            bytes_check.nonZeroBuf,
            .{},
            &bufs,
            self.options.operation_max_search_depth,
        );

        return bufs.toOwnedSlices();
    }

    pub fn getPrompt(
        self: *Session,
        allocator: std.mem.Allocator,
        options: operation.GetPromptOptions,
    ) ![2][]const u8 {
        self.log.info("session.Session getPrompt requested", .{});

        try self.writeReturn();

        var bufs = bytes.ProcessedBuf.init(allocator);
        defer bufs.deinit();

        var timer = try std.time.Timer.start();

        _ = try self.readTimeout(
            &timer,
            options.cancel,
            bytes_check.patternInBuf,
            .{
                .pattern = self.compiled_prompt_pattern,
            },
            &bufs,
            self.options.operation_max_search_depth,
        );

        // pcre2Find returns a slice from the haystack, so we need to persist that in memory
        // through that function call (cant just return pcre2Find)
        const found_prompt = try re.pcre2Find(
            self.compiled_prompt_pattern.?,
            bufs.processed.items,
        );

        if (found_prompt == null) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                self.log,
                "session.Session getPrompt: no prompt found matching prompt pattern '{s}' in '{s}'",
                .{ self.prompt_pattern, bufs.processed.items },
            );
        }

        const owned_found_prompt = try allocator.alloc(u8, found_prompt.?.len);
        @memcpy(owned_found_prompt, found_prompt.?);

        // we want to ensure we are storing the last consumed prompt so that our send_input
        // buf is always "correct" when "retain_input" is true
        try self.last_consumed_prompt.resize(self.allocator, 0);
        try self.last_consumed_prompt.appendSlice(
            self.allocator,
            owned_found_prompt,
        );

        return [2][]const u8{ try bufs.raw.toOwnedSlice(self.allocator), owned_found_prompt };
    }

    fn _sendInput(
        self: *Session,
        timer: *std.time.Timer,
        cancel: ?*bool,
        input: []const u8,
        input_handling: operation.InputHandling,
        bufs: *bytes.ProcessedBuf,
    ) !bytes_check.MatchPositions {
        const checkArgs = bytes_check.CheckArgs{
            .pattern = self.compiled_prompt_pattern,
            .actual = input,
        };

        try self.write(input, false);

        // SAFETY: will always be set or we'll error
        var match_indexes: bytes_check.MatchPositions = undefined;

        var search_depth = self.options.operation_max_search_depth;
        if (input.len >= search_depth) {
            // if/when a user has an enormous input we obviously need to have a searchable buf that
            // is larger than that, but we *probably* also will end up having the device writing
            // backspace chars into what we read back from the device so we need to account for that
            // if this still doesnt work users can always set a really high max search depth *or*
            // use ignore input handling
            search_depth = input.len * 4;
        }

        switch (input_handling) {
            .exact => {
                match_indexes = try self.readTimeout(
                    timer,
                    cancel,
                    bytes_check.exactInBuf,
                    checkArgs,
                    bufs,
                    search_depth,
                );
            },
            .fuzzy => {
                match_indexes = try self.readTimeout(
                    timer,
                    cancel,
                    bytes_check.fuzzyInBuf,
                    checkArgs,
                    bufs,
                    search_depth,
                );
            },
            .ignore => {
                // ignore, not reading input; to not break our saftey rule above we return here
                // when in "ignore" handling mode
                try self.writeReturn();

                return bytes_check.MatchPositions{ .start = 0, .end = 0 };
            },
        }

        try self.writeReturn();

        return match_indexes;
    }

    pub fn sendInput(
        self: *Session,
        allocator: std.mem.Allocator,
        options: operation.SendInputOptions,
    ) ![2][]const u8 {
        self.log.info("session.Session sendInput requested", .{});
        self.log.debug("session.Session sendInput: input '{s}'", .{options.input});

        var timer = try std.time.Timer.start();

        var bufs = bytes.ProcessedBuf.init(allocator);
        defer bufs.deinit();

        if (self.last_consumed_prompt.items.len != 0) {
            // if we had some prompt consumed, stuff it on the raw and processed buffers and then
            // re-zeroize
            try bufs.appendSlice(self.last_consumed_prompt.items);
            try self.last_consumed_prompt.resize(self.allocator, 0);
        }

        _ = try self._sendInput(
            &timer,
            options.cancel,
            options.input,
            options.input_handling,
            &bufs,
        );

        if (!options.retain_input) {
            // if we dont want to retain inputs, just resize the processed buffer to 0
            try bufs.processed.resize(self.allocator, 0);
        }

        const checkArgs = bytes_check.CheckArgs{
            .pattern = self.compiled_prompt_pattern,
            .actual = options.input,
        };

        var prompt_indexes = try self.readTimeout(
            &timer,
            options.cancel,
            bytes_check.patternInBuf,
            checkArgs,
            &bufs,
            self.options.operation_max_search_depth,
        );

        try self.last_consumed_prompt.appendSlice(
            self.allocator,
            bufs.processed.items[prompt_indexes.start..prompt_indexes.end],
        );

        if (!options.retain_trailing_prompt) {
            // using the prompt indexes, replace that range holding the trailing prompt out
            // of the processed buf
            try bufs.processed.replaceRange(
                self.allocator,
                prompt_indexes.start,
                prompt_indexes.len(),
                "",
            );
        }

        return bufs.toOwnedSlices();
    }

    pub fn sendPromptedInput(
        self: *Session,
        allocator: std.mem.Allocator,
        options: operation.SendPromptedInputOptions,
    ) ![2][]const u8 {
        self.log.info("session.Session sendPromptedInput requested", .{});
        self.log.debug(
            "session.Session sendPromptedInput: input '{s}', response '{s}'",
            .{ options.input, options.response },
        );

        var timer = try std.time.Timer.start();

        var compiled_pattern: ?*re.pcre2CompiledPattern = null;

        if (options.prompt_pattern) |pattern| {
            if (pattern.len > 0) {
                compiled_pattern = re.pcre2Compile(pattern);
                if (compiled_pattern == null) {
                    return errors.wrapCriticalError(
                        errors.ScrapliError.Driver,
                        @src(),
                        self.log,
                        "session.Session sendPromptedInput: failed compiling pattern '{s}'",
                        .{pattern},
                    );
                }
            }
        }

        defer {
            if (compiled_pattern) |p| {
                re.pcre2Free(p);
            }
        }

        if (options.abort_input) |abort_input| {
            errdefer {
                self.writeAndReturn(abort_input, false) catch |err| {
                    self.log.critical(
                        "session.Session sendPromptedInput: failed sending abort sequence " ++
                            "after error in prompted input, err: {}",
                        .{err},
                    );
                };
            }
        }

        var bufs = bytes.ProcessedBuf.init(allocator);
        defer bufs.deinit();

        if (self.last_consumed_prompt.items.len != 0) {
            // if we had some prompt consumed, stuff it on the raw and processed buffers and then
            // re-zeroize
            try bufs.appendSlice(self.last_consumed_prompt.items);
            try self.last_consumed_prompt.resize(self.allocator, 0);
        }

        _ = try self._sendInput(
            &timer,
            options.cancel,
            options.input,
            options.input_handling,
            &bufs,
        );

        var checkArgs = bytes_check.CheckArgs{
            .actual = options.prompt_exact,
        };

        if (compiled_pattern) |cp| {
            checkArgs.patterns = &[_]?*re.pcre2CompiledPattern{
                self.compiled_prompt_pattern,
                cp,
            };
        } else {
            checkArgs.pattern = self.compiled_prompt_pattern;
        }

        _ = try self.readTimeout(
            &timer,
            options.cancel,
            bytes_check.exactInBuf,
            checkArgs,
            &bufs,
            self.options.operation_max_search_depth,
        );

        if (!options.hidden_response) {
            try self.writeAndReturn(options.response, true);
        } else {
            _ = try self._sendInput(
                &timer,
                options.cancel,
                options.input,
                options.input_handling,
                &bufs,
            );
        }

        var prompt_indexes = try self.readTimeout(
            &timer,
            options.cancel,
            bytes_check.patternInBuf,
            checkArgs,
            &bufs,
            self.options.operation_max_search_depth,
        );

        try self.last_consumed_prompt.appendSlice(
            self.allocator,
            bufs.processed.items[prompt_indexes.start..prompt_indexes.end],
        );

        if (!options.retain_trailing_prompt) {
            // using the prompt indexes, replace that range holding the trailing prompt out
            // of the processed buf
            try bufs.processed.replaceRange(
                self.allocator,
                prompt_indexes.start,
                prompt_indexes.len(),
                "",
            );
        }

        return bufs.toOwnedSlices();
    }
};

test "sessionInit" {
    const o = try Options.init(std.testing.allocator, .{});
    const a_o = try auth.Options.init(std.testing.allocator, .{});
    const t_o = try transport.Options.init(std.testing.allocator, .{ .ssh2 = .{} });

    const s = try Session.init(
        std.testing.allocator,
        logging.Logger{
            .allocator = std.testing.allocator,
        },
        ">",
        o,
        a_o,
        t_o,
    );

    s.deinit();
    o.deinit();
    a_o.deinit();
    t_o.deinit();
}
