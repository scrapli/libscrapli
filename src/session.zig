const std = @import("std");
const transport = @import("transport.zig");
const re = @import("re.zig");
const bytes = @import("bytes.zig");
const operation = @import("operation.zig");
const logger = @import("logger.zig");
const ascii = @import("ascii.zig");
const lookup = @import("lookup.zig");

const pcre2 = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

const default_read_size: usize = 4_096;
const default_read_delay_min_ns: u64 = 1_000;
const default_read_delay_max_ns: u64 = 1_000_000;
const default_read_delay_backoff_factor: u8 = 2;
const default_return_char: []const u8 = "\n";
const default_username_pattern: []const u8 = "^(.*username:)|(.*login:)\\s?$";
const default_password_pattern: []const u8 = "(.*@.*)?password:\\s?$";
const default_passphrase_pattern: []const u8 = "enter passphrase for key";
const default_operation_timeout_ns: u64 = 10_000_000_000;
const default_operation_max_search_depth: u64 = 512;

const ReadThreadState = enum(u8) {
    Uninitialized,
    Run,
    Stop,
};

fn NewReadArgs() ReadArgs {
    return ReadArgs{
        .pattern = null,
        .patterns = null,
        .actual = null,
    };
}

const ReadArgs = struct {
    pattern: ?*pcre2.pcre2_code_8,
    patterns: ?[]?*pcre2.pcre2_code_8,
    actual: ?[]const u8,
};

fn NewReadBufs(allocator: std.mem.Allocator) ReadBufs {
    return ReadBufs{
        .raw = std.ArrayList(u8).init(allocator),
        .processed = std.ArrayList(u8).init(allocator),
    };
}

const ReadBufs = struct {
    raw: std.ArrayList(u8),
    processed: std.ArrayList(u8),

    fn deinit(self: *ReadBufs) void {
        self.raw.deinit();
        self.processed.deinit();
    }

    fn appendSliceBoth(self: *ReadBufs, buf: []const u8) !void {
        try self.raw.appendSlice(buf);
        try self.processed.appendSlice(buf);
    }

    /// returns array of raw and processed bufs, including doing a final trimming of whitespace
    /// on the processed buf
    fn toOwnedSlices(self: *ReadBufs, allocator: std.mem.Allocator) ![2][]const u8 {
        const processed = try self.processed.toOwnedSlice();
        defer allocator.free(processed);

        return [2][]const u8{
            try self.raw.toOwnedSlice(),
            try trimWhitespace(allocator, processed),
        };
    }
};

const MatchPositions = struct {
    start: usize,
    end: usize,

    fn len(self: *MatchPositions) usize {
        if (self.end == 0) {
            return 0;
        }

        return self.end - self.start + 1;
    }
};

pub fn NewOptions() Options {
    return Options{
        .read_size = default_read_size,
        .read_delay_min_ns = default_read_delay_min_ns,
        .read_delay_max_ns = default_read_delay_max_ns,
        .read_delay_backoff_factor = default_read_delay_backoff_factor,
        .return_char = default_return_char,
        .username_pattern = default_username_pattern,
        .password_pattern = default_password_pattern,
        .passphrase_pattern = default_passphrase_pattern,
        .auth_bypass = false,
        .operation_timeout_ns = default_operation_timeout_ns,
        .operation_max_search_depth = default_operation_max_search_depth,
        .recorder = null,
    };
}

pub const Options = struct {
    read_size: usize,

    read_delay_min_ns: u64,
    read_delay_max_ns: u64,
    read_delay_backoff_factor: u8,

    return_char: []const u8,

    username_pattern: []const u8,
    password_pattern: []const u8,
    passphrase_pattern: []const u8,

    auth_bypass: bool,

    operation_timeout_ns: u64,
    operation_max_search_depth: u64,

    recorder: ?std.fs.File.Writer,
};

pub fn NewSession(
    allocator: std.mem.Allocator,
    log: logger.Logger,
    prompt_pattern: []const u8,
    options: Options,
    transport_options: transport.Options,
) !*Session {
    const t = try transport.Factory(
        allocator,
        log,
        transport_options,
    );

    const s = try allocator.create(Session);

    s.* = Session{
        .allocator = allocator,
        .log = log,
        .options = options,
        .transport = t,
        .read_thread = null,
        .read_stop = std.atomic.Value(ReadThreadState).init(ReadThreadState.Uninitialized),
        .read_lock = std.Thread.Mutex{},
        .read_queue = std.fifo.LinearFifo(u8, std.fifo.LinearFifoBufferType.Dynamic).init(allocator),
        .compiled_username_pattern = null,
        .compiled_password_pattern = null,
        .compiled_passphrase_pattern = null,
        .prompt_pattern = prompt_pattern,
        .compiled_prompt_pattern = null,
        .last_consumed_prompt = std.ArrayList(u8).init(allocator),
    };

    return s;
}

pub const Session = struct {
    allocator: std.mem.Allocator,
    log: logger.Logger,
    options: Options,
    transport: *transport.Transport,

    read_thread: ?std.Thread,
    read_stop: std.atomic.Value(ReadThreadState),
    read_lock: std.Thread.Mutex,
    read_queue: std.fifo.LinearFifo(u8, std.fifo.LinearFifoBufferType.Dynamic),

    compiled_username_pattern: ?*pcre2.pcre2_code_8,
    compiled_password_pattern: ?*pcre2.pcre2_code_8,
    compiled_passphrase_pattern: ?*pcre2.pcre2_code_8,

    prompt_pattern: []const u8,
    compiled_prompt_pattern: ?*pcre2.pcre2_code_8,

    last_consumed_prompt: std.ArrayList(u8),

    pub fn init(self: *Session) !void {
        self.compiled_username_pattern = re.pcre2Compile(self.options.username_pattern);
        if (self.compiled_username_pattern == null) {
            self.log.critical("failed compling username pattern {s}", .{self.options.username_pattern});

            return error.InitFailed;
        }

        self.compiled_password_pattern = re.pcre2Compile(self.options.password_pattern);
        if (self.compiled_password_pattern == null) {
            self.log.critical("failed compling password pattern {s}", .{self.options.password_pattern});

            return error.InitFailed;
        }

        self.compiled_passphrase_pattern = re.pcre2Compile(self.options.passphrase_pattern);
        if (self.compiled_passphrase_pattern == null) {
            self.log.critical("failed compling passphrase pattern {s}", .{self.options.passphrase_pattern});

            return error.InitFailed;
        }

        self.compiled_prompt_pattern = re.pcre2Compile(self.prompt_pattern);
        if (self.compiled_prompt_pattern == null) {
            self.log.critical("failed compling prompt pattern {s}", .{self.prompt_pattern});

            return error.InitFailed;
        }

        try self.transport.init();
    }

    pub fn deinit(self: *Session) void {
        self.last_consumed_prompt.deinit();

        if (self.read_stop.load(std.builtin.AtomicOrder.acquire) == ReadThreadState.Run) {
            // if for whatever reason (likely because a call to driver.open failed causing a defer
            // close to *not* trigger) the session didnt get "closed", ensure we do that...
            self.close();
        }

        if (self.compiled_username_pattern != null) {
            re.pcre2Free(self.compiled_username_pattern.?);
        }

        if (self.compiled_password_pattern != null) {
            re.pcre2Free(self.compiled_password_pattern.?);
        }

        if (self.compiled_passphrase_pattern != null) {
            re.pcre2Free(self.compiled_passphrase_pattern.?);
        }

        if (self.compiled_prompt_pattern != null) {
            re.pcre2Free(self.compiled_prompt_pattern.?);
        }

        self.transport.deinit();
        self.read_queue.deinit();
        self.allocator.destroy(self);
    }

    fn getReadDelay(self: *Session, cur_read_delay_ns: u64) u64 {
        var new_read_delay_ns: u64 = cur_read_delay_ns;

        new_read_delay_ns *= self.options.read_delay_backoff_factor;
        if (new_read_delay_ns > self.options.read_delay_max_ns) {
            new_read_delay_ns = self.options.read_delay_max_ns;
        }

        return new_read_delay_ns;
    }

    pub fn open(
        self: *Session,
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        username: ?[]const u8,
        password: ?[]const u8,
        passphrase: ?[]const u8,
        lookup_fn: lookup.LookupFn,
        options: operation.OpenOptions,
    ) ![2][]const u8 {
        var timer = std.time.Timer.start() catch |err| {
            self.log.critical("failed initializing open/authentication timer, err: {}", .{err});

            return error.AuthenicationFailed;
        };

        try self.transport.open(
            &timer,
            options.cancel,
            self.options.operation_timeout_ns,
            host,
            port,
            username,
            password,
            passphrase,
            lookup_fn,
        );

        self.read_stop.store(ReadThreadState.Run, std.builtin.AtomicOrder.unordered);

        // start read thread
        self.read_thread = std.Thread.spawn(
            .{},
            Session.readLoop,
            .{self},
        ) catch |err| {
            self.log.critical("failed spawning read thread, err: {}", .{err});

            return error.OpenFailed;
        };

        const is_in_session_auth = self.transport.isInSessionAuth();

        // check if we have auth bypass or the transport handles auth for us -- if yes we are done
        if (self.options.auth_bypass or !is_in_session_auth) {
            // TODO does trying to free this cause an issue?
            return [2][]const u8{ "", "" };
        }

        return self.authenticate(
            allocator,
            &timer,
            options.cancel,
            host,
            port,
            username,
            password,
            passphrase,
            lookup_fn,
        );
    }

    pub fn close(self: *Session) void {
        self.read_stop.store(ReadThreadState.Stop, std.builtin.AtomicOrder.unordered);

        if (self.read_thread != null) {
            self.read_thread.?.join();
        }

        self.transport.close();
    }

    fn readLoop(self: *Session) !void {
        self.log.info("read thread started", .{});

        var buf = try self.allocator.alloc(u8, self.options.read_size);
        defer self.allocator.free(buf);

        var cur_read_delay_ns: u64 = self.options.read_delay_min_ns;

        while (self.read_stop.load(std.builtin.AtomicOrder.acquire) != ReadThreadState.Stop) {
            defer std.time.sleep(cur_read_delay_ns);

            const n = try self.transport.read(buf);

            if (n == 0) {
                cur_read_delay_ns = self.getReadDelay(cur_read_delay_ns);

                continue;
            } else {
                cur_read_delay_ns = self.options.read_delay_min_ns;
            }

            if (self.options.recorder != null) {
                try self.options.recorder.?.writeAll(buf[0..n]);
            }

            self.read_lock.lock();
            defer self.read_lock.unlock();
            try self.read_queue.write(buf[0..n]);
        }

        self.log.info("read thread stopped", .{});
    }

    pub fn read(self: *Session, buf: []u8) usize {
        self.read_lock.lock();
        defer self.read_lock.unlock();

        return self.read_queue.read(buf);
    }

    pub fn write(self: *Session, buf: []const u8, redacted: bool) !void {
        if (!redacted) {
            self.log.debug("channel write: '{s}'", .{buf});
        }

        try self.transport.write(buf);
    }

    pub fn writeReturn(self: *Session) !void {
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

    fn getBufSearchView(
        self: *Session,
        buf: []u8,
    ) []u8 {
        // TODO use this in the readTimeout func!
        const depth = self.options.operation_max_search_depth;

        if (buf.len < depth) {
            return buf[0..];
        }

        return buf[buf.len - depth ..];
    }

    fn authenticate(
        self: *Session,
        allocator: std.mem.Allocator,
        timer: *std.time.Timer,
        cancel: ?*bool,
        host: []const u8,
        port: u16,
        username: ?[]const u8,
        password: ?[]const u8,
        passphrase: ?[]const u8,
        lookup_fn: lookup.LookupFn,
    ) ![2][]const u8 {
        self.log.info("in channel authentication starting...", .{});

        var cur_read_delay_ns: u64 = self.options.read_delay_min_ns;

        var bufs = NewReadBufs(allocator);
        defer bufs.deinit();

        var cur_check_start_idx: usize = 0;

        var auth_prompt_seen_count: u8 = 0;

        var buf = try self.allocator.alloc(u8, self.options.read_size);
        defer self.allocator.free(buf);

        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return error.Cancelled;
            }

            const elapsed_time = timer.read();

            if ((elapsed_time + cur_read_delay_ns) > self.options.operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return error.AuthenicationTimeoutExceeded;
            }

            defer std.time.sleep(cur_read_delay_ns);

            const n = self.read(buf);

            if (n == 0) {
                cur_read_delay_ns = self.getReadDelay(cur_read_delay_ns);

                continue;
            } else {
                cur_read_delay_ns = self.options.read_delay_min_ns;
            }

            try bufs.appendSliceBoth(buf[0..n]);

            if (std.mem.indexOf(u8, buf[0..n], &[_]u8{ascii.control_chars.esc}) != null) {
                // same as readTimeout other than we dont bother limiting the search depth here
                // see readTimeout for some more info
                const new_size = ascii.stripAsciiAndAnsiControlCharsInPlace(
                    bufs.processed.items,
                    bufs.processed.items.len - n,
                );
                try bufs.processed.resize(new_size);

                try openMessageHandler(self.allocator, bufs.processed.items);
            }

            const searchable_buf = self.getBufSearchView(bufs.processed.items[cur_check_start_idx..]);

            const prompt_match = try re.pcre2Find(
                self.compiled_prompt_pattern.?,
                searchable_buf,
            );
            if (prompt_match.len > 0) {
                return bufs.toOwnedSlices(allocator);
            }

            const password_match = try re.pcre2Find(
                self.compiled_password_pattern.?,
                searchable_buf,
            );
            if (password_match.len > 0) {
                if (password == null) {
                    self.log.critical(
                        "password prompt seen but no password set",
                        .{},
                    );

                    return error.AuthenicationFailed;
                }

                auth_prompt_seen_count += 1;

                if (auth_prompt_seen_count > 3) {
                    self.log.critical(
                        "password prompt seen multiple times, assuming authentication failed",
                        .{},
                    );

                    return error.AuthenicationFailed;
                }

                try self.writeAndReturn(
                    try lookup.resolveValue(
                        host,
                        port,
                        password.?,
                        lookup_fn,
                    ),
                    true,
                );

                cur_check_start_idx = bufs.processed.items.len;

                auth_prompt_seen_count = 0;

                continue;
            }

            const username_match = try re.pcre2Find(
                self.compiled_username_pattern.?,
                searchable_buf,
            );
            if (username_match.len > 0) {
                if (username == null) {
                    self.log.critical(
                        "username prompt seen but no username set",
                        .{},
                    );

                    return error.AuthenicationFailed;
                }

                auth_prompt_seen_count += 1;

                if (auth_prompt_seen_count > 3) {
                    self.log.critical(
                        "username prompt seen multiple times, assuming authentication failed",
                        .{},
                    );

                    return error.AuthenicationFailed;
                }

                try self.writeAndReturn(username.?, true);

                cur_check_start_idx = bufs.processed.items.len;

                auth_prompt_seen_count = 0;

                continue;
            }

            const passphrase_match = try re.pcre2Find(
                self.compiled_passphrase_pattern.?,
                searchable_buf,
            );
            if (passphrase_match.len > 0) {
                if (passphrase == null) {
                    self.log.critical(
                        "private key passphrase prompt seen but no passphrase set",
                        .{},
                    );

                    return error.AuthenicationFailed;
                }

                auth_prompt_seen_count += 1;

                if (auth_prompt_seen_count > 3) {
                    self.log.critical(
                        "private key passphrase prompt seen multiple times, assuming authentication failed",
                        .{},
                    );

                    return error.AuthenicationFailed;
                }

                try self.writeAndReturn(
                    try lookup.resolveValue(
                        host,
                        port,
                        passphrase.?,
                        lookup_fn,
                    ),
                    true,
                );

                cur_check_start_idx = bufs.processed.items.len;

                auth_prompt_seen_count = 0;
            }
        }
    }

    fn readTimeout(
        self: *Session,
        timer: *std.time.Timer,
        cancel: ?*bool,
        check_read_operation_done: fn (buf: []u8, args: ReadArgs) anyerror!MatchPositions,
        args: ReadArgs,
        bufs: *ReadBufs,
    ) !MatchPositions {
        var cur_read_delay_ns: u64 = self.options.read_delay_min_ns;

        // to ensure the check_read_operation_done function doesnt think we are done "early" by
        // finding a match from an earlier prompt we snag the len of the processed buf then we
        // just send that to the end of the buffer to the check func, we have to make sure we
        // increase the found start/end positions by this value too!
        const op_processed_buf_starting_len = bufs.processed.items.len;

        var buf = try self.allocator.alloc(u8, self.options.read_size);
        defer self.allocator.free(buf);

        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return error.Cancelled;
            }

            const elapsed_time = timer.read();

            // if timeout is 0 we dont timeout -- we do this to let users 1) disable it but also
            // 2) to let the ffi layer via (go) context control it for example
            if (self.options.operation_timeout_ns != 0 and
                (elapsed_time + cur_read_delay_ns) > self.options.operation_timeout_ns)
            {
                self.log.critical("op timeout exceeded", .{});

                return error.Timeout;
            }

            defer std.time.sleep(cur_read_delay_ns);

            const n = self.read(buf);

            if (n == 0) {
                cur_read_delay_ns = self.getReadDelay(cur_read_delay_ns);

                continue;
            } else {
                cur_read_delay_ns = self.options.read_delay_min_ns;
            }

            try bufs.appendSliceBoth(buf[0..n]);

            if (std.mem.indexOf(u8, buf[0..n], &[_]u8{ascii.control_chars.esc}) != null) {
                // if ESC in the new buf look at last n of processed buf to replace if
                // necessary; this *feels* bad like we may miss sequences (if our read gets part
                // of a sequence, then a subsequent read gets the rest), however this has never
                // happened in 5+ years of scrapli/scrapligo only checking/cleaning the read buf
                // so we are going to roll with it and hope :)
                const new_size = ascii.stripAsciiAndAnsiControlCharsInPlace(
                    bufs.processed.items,
                    bufs.processed.items.len - n,
                );
                try bufs.processed.resize(new_size);
            }

            var search_depth: u64 = self.options.operation_max_search_depth;

            if (bufs.processed.items[op_processed_buf_starting_len..].len < search_depth) {
                search_depth = bufs.processed.items[op_processed_buf_starting_len..].len;
            }

            var match_indexes = try check_read_operation_done(
                bufs.processed.items[bufs.processed.items.len - search_depth ..],
                args,
            );

            if (!(match_indexes.start == 0 and match_indexes.end == 0)) {
                match_indexes.start += (bufs.processed.items.len - search_depth);
                match_indexes.end += (bufs.processed.items.len - search_depth);
                return match_indexes;
            }
        }
    }

    pub fn getPrompt(
        self: *Session,
        allocator: std.mem.Allocator,
        options: operation.GetPromptOptions,
    ) ![2][]const u8 {
        self.log.info("get prompt requested", .{});

        var args = NewReadArgs();

        args.pattern = self.compiled_prompt_pattern;

        try self.writeReturn();

        var bufs = NewReadBufs(allocator);
        defer bufs.deinit();

        var timer = try std.time.Timer.start();

        _ = try self.readTimeout(
            &timer,
            options.cancel,
            readUntilPatternCheckDone,
            args,
            &bufs,
        );

        // pcre2Find returns a slice from the haystack, so we need to persist that in memory
        // through that function call (cant just return pcre2Find)
        const found_prompt = try re.pcre2Find(
            self.compiled_prompt_pattern.?,
            bufs.processed.items,
        );

        const owned_found_prompt = try allocator.alloc(u8, found_prompt.len);
        @memcpy(owned_found_prompt, found_prompt);

        // we want to ensure we are storing the last consumed prompt so that our send_input
        // buf is always "correct" when "retain_input" is true
        try self.last_consumed_prompt.resize(0);
        try self.last_consumed_prompt.appendSlice(
            owned_found_prompt,
        );

        return [2][]const u8{ try bufs.raw.toOwnedSlice(), owned_found_prompt };
    }

    fn _sendInput(
        self: *Session,
        timer: *std.time.Timer,
        cancel: ?*bool,
        input: []const u8,
        input_handling: operation.InputHandling,
        bufs: *ReadBufs,
    ) !MatchPositions {
        var args = NewReadArgs();

        args.pattern = self.compiled_prompt_pattern;
        args.actual = input;

        try self.write(input, false);

        // SAFETY: will always be set or we'll error
        var match_indexes: MatchPositions = undefined;

        switch (input_handling) {
            operation.InputHandling.Exact => {
                match_indexes = try self.readTimeout(
                    timer,
                    cancel,
                    readUntilExactCheckDone,
                    args,
                    bufs,
                );
            },
            operation.InputHandling.Fuzzy => {
                match_indexes = try self.readTimeout(
                    timer,
                    cancel,
                    readUntilFuzzyCheckDone,
                    args,
                    bufs,
                );
            },
            operation.InputHandling.Ignore => {
                // ignore, not reading input
            },
        }

        try self.writeReturn();

        return match_indexes;
    }

    pub fn sendInput(
        self: *Session,
        allocator: std.mem.Allocator,
        input: []const u8,
        options: operation.SendInputOptions,
    ) ![2][]const u8 {
        self.log.info("send input requested", .{});

        var timer = try std.time.Timer.start();

        var bufs = NewReadBufs(allocator);
        defer bufs.deinit();

        if (self.last_consumed_prompt.items.len != 0) {
            // if we had some prompt consumed, stuff it on the raw and processed buffers and then
            // re-zeroize
            try bufs.appendSliceBoth(self.last_consumed_prompt.items);
            try self.last_consumed_prompt.resize(0);
        }

        _ = try self._sendInput(
            &timer,
            options.cancel,
            input,
            options.input_handling,
            &bufs,
        );

        if (!options.retain_input) {
            // if we dont want to retain inputs, just resize the processed buffer to 0
            try bufs.processed.resize(0);
        }

        var args = NewReadArgs();

        args.pattern = self.compiled_prompt_pattern;
        args.actual = input;

        var prompt_indexes = try self.readTimeout(
            &timer,
            options.cancel,
            readUntilPatternCheckDone,
            args,
            &bufs,
        );

        try self.last_consumed_prompt.appendSlice(
            bufs.processed.items[prompt_indexes.start .. prompt_indexes.end + 1],
        );

        if (!options.retain_trailing_prompt) {
            // using the prompt indexes, replace that range holding the trailing prompt out
            // of the processed buf
            try bufs.processed.replaceRange(prompt_indexes.start, prompt_indexes.len(), "");
        }

        return bufs.toOwnedSlices(allocator);
    }

    pub fn sendPromptedInput(
        self: *Session,
        allocator: std.mem.Allocator,
        input: []const u8,
        prompt: []const u8,
        response: []const u8,
        options: operation.SendPromptedInputOptions,
    ) ![2][]const u8 {
        self.log.info("send prompted input requested", .{});

        var timer = try std.time.Timer.start();

        if (options.abort_input.len != 0) {
            errdefer {
                self.writeAndReturn(options.abort_input, false) catch |err| {
                    self.log.critical(
                        "failed sending abort sequence after error in prompted input, err: {}",
                        .{err},
                    );
                };
            }
        }

        var bufs = NewReadBufs(allocator);
        defer bufs.deinit();

        if (self.last_consumed_prompt.items.len != 0) {
            // if we had some prompt consumed, stuff it on the raw and processed buffers and then
            // re-zeroize
            try bufs.appendSliceBoth(self.last_consumed_prompt.items);
            try self.last_consumed_prompt.resize(0);
        }

        _ = try self._sendInput(
            &timer,
            options.cancel,
            input,
            options.input_handling,
            &bufs,
        );

        var args = NewReadArgs();

        args.pattern = self.compiled_prompt_pattern;
        args.actual = prompt;

        _ = try self.readTimeout(
            &timer,
            options.cancel,
            readUntilExactCheckDone,
            args,
            &bufs,
        );

        if (!options.hidden_response) {
            try self.writeAndReturn(response, true);
        } else {
            _ = try self._sendInput(
                &timer,
                options.cancel,
                input,
                options.input_handling,
                &bufs,
            );
        }

        var prompt_indexes = try self.readTimeout(
            &timer,
            options.cancel,
            readUntilPatternCheckDone,
            args,
            &bufs,
        );

        try self.last_consumed_prompt.appendSlice(
            bufs.processed.items[prompt_indexes.start..prompt_indexes.end],
        );

        if (!options.retain_trailing_prompt) {
            // using the prompt indexes, replace that range holding the trailing prompt out
            // of the processed buf
            try bufs.processed.replaceRange(prompt_indexes.start, prompt_indexes.len(), "");
        }

        return bufs.toOwnedSlices(allocator);
    }
};

const openMessageErrorSubstrings = [_][]const u8{
    "host key verification failed",
    "no matching key exchange",
    "no matching host key",
    "no matching cipher",
    "operation timed out",
    "connection timed out",
    "no route to host",
    "bad configuration",
    "could not resolve hostname",
    "permission denied",
    "unprotected private key file",
};

fn openMessageHandler(allocator: std.mem.Allocator, buf: []const u8) !void {
    const copied_buf = allocator.alloc(u8, buf.len) catch {
        return error.OpenFailedMessageHandler;
    };
    defer allocator.free(copied_buf);

    @memcpy(copied_buf, buf);

    bytes.toLower(copied_buf);

    for (openMessageErrorSubstrings) |needle| {
        if (std.mem.indexOf(u8, copied_buf, needle) != null) {
            return error.OpenFailedMessageHandler;
        }
    }
}

test "openMessageHandler" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        expect_error: bool,
    }{
        .{
            .name = "no error",
            .haystack = "",
            .expect_error = false,
        },
        .{
            .name = "host key verification failed",
            .haystack = "blah: host key verification failed",
            .expect_error = true,
        },
        .{
            .name = "no matching key exchange",
            .haystack = "blah: no matching key exchange",
            .expect_error = true,
        },
        .{
            .name = "no matching host key",
            .haystack = "blah: no matching host key",
            .expect_error = true,
        },
        .{
            .name = "no matching cipher",
            .haystack = "blah: no matching cipher",
            .expect_error = true,
        },
        .{
            .name = "operation timed out",
            .haystack = "blah: operation timed out",
            .expect_error = true,
        },
        .{
            .name = "connection timed out",
            .haystack = "blah: connection timed out",
            .expect_error = true,
        },
        .{
            .name = "no route to host",
            .haystack = "blah: no route to host",
            .expect_error = true,
        },
        .{
            .name = "bad configuration",
            .haystack = "blah: bad configuration",
            .expect_error = true,
        },
        .{
            .name = "could not resolve hostname",
            .haystack = "blah: could not resolve hostname",
            .expect_error = true,
        },
        .{
            .name = "permission denied",
            .haystack = "blah: permission denied",
            .expect_error = true,
        },
        .{
            .name = "unprotected private key file",
            .haystack = "blah: unprotected private key file",
            .expect_error = true,
        },
    };

    for (cases) |case| {
        if (case.expect_error) {
            try std.testing.expectError(
                error.OpenFailedMessageHandler,
                openMessageHandler(
                    std.testing.allocator,
                    case.haystack,
                ),
            );
        } else {
            try openMessageHandler(std.testing.allocator, case.haystack);
        }
    }
}

fn readUntilPatternCheckDone(buf: []const u8, args: ReadArgs) !MatchPositions {
    if (buf.len == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    const match_indexes = try re.pcre2FindIndex(args.pattern.?, buf);
    if (!(match_indexes[0] == 0 and match_indexes[1] == 0)) {
        return MatchPositions{ .start = match_indexes[0], .end = match_indexes[1] - 1 };
    }

    return MatchPositions{ .start = 0, .end = 0 };
}

test "readUntilPatternCheckDone" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        read_args: ReadArgs,
        expected: MatchPositions,
    }{
        .{
            .name = "not done",
            .haystack = "",
            .read_args = ReadArgs{
                .pattern = re.pcre2Compile("foo"),
                .patterns = null,
                .actual = null,
            },
            .expected = MatchPositions{ .start = 0, .end = 0 },
        },
        .{
            .name = "simple match",
            .haystack = "foo",
            .read_args = ReadArgs{
                .pattern = re.pcre2Compile("foo"),
                .patterns = null,
                .actual = null,
            },
            .expected = MatchPositions{ .start = 0, .end = 2 },
        },
        .{
            .name = "simple not from start",
            .haystack = "abcfoo",
            .read_args = ReadArgs{
                .pattern = re.pcre2Compile("foo"),
                .patterns = null,
                .actual = null,
            },
            .expected = MatchPositions{ .start = 3, .end = 5 },
        },
    };

    defer {
        for (cases) |case| {
            re.pcre2Free(case.read_args.pattern.?);
        }
    }

    for (cases) |case| {
        const actual = try readUntilPatternCheckDone(case.haystack, case.read_args);

        try std.testing.expectEqual(case.expected, actual);
    }
}

fn readUntilAnyPatternCheckDone(buf: []const u8, args: ReadArgs) !MatchPositions {
    if (buf.len == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    for (args.patterns.?) |pattern| {
        const match_indexes = try re.pcre2FindIndex(pattern.?, buf);
        if (!(match_indexes[0] == 0 and match_indexes[1] == 0)) {
            return MatchPositions{ .start = match_indexes[0], .end = match_indexes[1] - 1 };
        }
    }

    return MatchPositions{ .start = 0, .end = 0 };
}

test "readUntilAnyPatternCheckDone" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        read_args: ReadArgs,
        expected: MatchPositions,
    }{
        .{
            .name = "not done",
            .haystack = "",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = try re.pcre2CompileMany(
                    std.testing.allocator,
                    &[_][]const u8{
                        "foo",
                        "bar",
                        "baz",
                    },
                ),
                .actual = null,
            },
            .expected = MatchPositions{ .start = 0, .end = 0 },
        },
        .{
            .name = "done first match",
            .haystack = "foo",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = try re.pcre2CompileMany(
                    std.testing.allocator,
                    &[_][]const u8{
                        "foo",
                        "bar",
                        "baz",
                    },
                ),
                .actual = null,
            },
            .expected = MatchPositions{ .start = 0, .end = 2 },
        },
        .{
            .name = "done last match",
            .haystack = "bar",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = try re.pcre2CompileMany(
                    std.testing.allocator,
                    &[_][]const u8{
                        "foo",
                        "bar",
                        "baz",
                    },
                ),
                .actual = null,
            },
            .expected = MatchPositions{ .start = 0, .end = 2 },
        },
    };

    defer {
        for (cases) |case| {
            for (case.read_args.patterns.?) |pattern| {
                re.pcre2Free(pattern.?);
            }

            std.testing.allocator.free(case.read_args.patterns.?);
        }
    }

    for (cases) |case| {
        const actual = try readUntilAnyPatternCheckDone(case.haystack, case.read_args);

        try std.testing.expectEqual(case.expected, actual);
    }
}

fn readUntilExactCheckDone(buf: []const u8, args: ReadArgs) !MatchPositions {
    if (buf.len == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    const match_start_index = std.mem.indexOf(u8, buf, args.actual.?);
    if (match_start_index != null) {
        return MatchPositions{ .start = match_start_index.?, .end = match_start_index.? + args.actual.?.len - 1 };
    }

    return MatchPositions{ .start = 0, .end = 0 };
}

test "readUntilExactCheckDone" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        read_args: ReadArgs,
        expected: MatchPositions,
    }{
        .{
            .name = "not done",
            .haystack = "",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = null,
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 0, .end = 0 },
        },
        .{
            .name = "simple match",
            .haystack = "foo",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = null,
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 0, .end = 2 },
        },
        .{
            .name = "simple not from start",
            .haystack = "abcfoo",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = null,
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 3, .end = 5 },
        },
    };

    for (cases) |case| {
        const actual = try readUntilExactCheckDone(case.haystack, case.read_args);

        try std.testing.expectEqual(case.expected, actual);
    }
}

fn readUntilFuzzyCheckDone(buf: []const u8, args: ReadArgs) !MatchPositions {
    const match_indexes = bytes.roughlyContains(buf, args.actual.?);

    if (match_indexes[0] == 0 and match_indexes[1] == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    return MatchPositions{ .start = match_indexes[0], .end = match_indexes[1] - 1 };
}

test "readUntilFuzzyCheckDone" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        read_args: ReadArgs,
        expected: MatchPositions,
    }{
        .{
            .name = "not done",
            .haystack = "",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = null,
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 0, .end = 0 },
        },
        .{
            .name = "simple match",
            .haystack = "f X o X o",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = null,
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 0, .end = 8 },
        },
        .{
            .name = "simple not from start",
            .haystack = "X o f X o X o",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = null,
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 4, .end = 12 },
        },
    };

    for (cases) |case| {
        const actual = try readUntilFuzzyCheckDone(case.haystack, case.read_args);

        try std.testing.expectEqual(case.expected, actual);
    }
}

fn trimWhitespace(
    allocator: std.mem.Allocator,
    buf: []const u8,
) ![]const u8 {
    const trimmed_buf = std.mem.trim(u8, buf, " \t\n\r");
    const owned_trimmed_buf = try allocator.alloc(u8, trimmed_buf.len);

    @memcpy(owned_trimmed_buf, trimmed_buf);

    return owned_trimmed_buf;
}

test "trimWhitespace" {
    const cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "nothing to trim",
            .input = "foo bar baz",
            .expected = "foo bar baz",
        },
        .{
            .name = "left trim newline",
            .input = "\nfoo bar baz",
            .expected = "foo bar baz",
        },
        .{
            .name = "left trim carriage return",
            .input = "\rfoo bar baz",
            .expected = "foo bar baz",
        },
        .{
            .name = "left trim carriage return newline",
            .input = "\r\nfoo bar baz",
            .expected = "foo bar baz",
        },
        .{
            .name = "left trim tab",
            .input = "\tfoo bar baz",
            .expected = "foo bar baz",
        },
        .{
            .name = "left trim spaces",
            .input = "  foo bar baz",
            .expected = "foo bar baz",
        },
        .{
            .name = "right trim newline",
            .input = "foo bar baz\n",
            .expected = "foo bar baz",
        },
        .{
            .name = "right trim carriage return",
            .input = "foo bar baz\r",
            .expected = "foo bar baz",
        },
        .{
            .name = "right trim carriage return newline",
            .input = "foo bar baz\r\n",
            .expected = "foo bar baz",
        },
        .{
            .name = "right trim tab",
            .input = "foo bar baz\t",
            .expected = "foo bar baz",
        },
        .{
            .name = "right trim spaces",
            .input = "foo bar baz  ",
            .expected = "foo bar baz",
        },
        .{
            .name = "trim all the things",
            .input = "\t \r\n foo bar baz\r\n \t ",
            .expected = "foo bar baz",
        },
    };

    for (cases) |case| {
        const actual = try trimWhitespace(
            std.testing.allocator,
            case.input,
        );
        defer std.testing.allocator.free(actual);

        try std.testing.expectEqualStrings(case.expected, actual);
    }
}
