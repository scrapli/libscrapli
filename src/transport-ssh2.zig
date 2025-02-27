const std = @import("std");
const transport = @import("transport.zig");
const logger = @import("logger.zig");
const lookup = @import("lookup.zig");

const c = @cImport({
    @cDefine("_XOPEN_SOURCE", "500");
    @cInclude("stdlib.h");
});

const ssh2 = @cImport({
    @cInclude("libssh2.h");
});

const LIBSSH2_ERROR_EAGAIN = -37;

const open_eagain_delay_ns: u64 = 100_000;

var ssh2_initialized = false;

fn ssh2InitializeOnce() c_int {
    if (!ssh2_initialized) {
        // 0 is normal initialization, only other thing we can do here is tell it to *not*
        // initialize crypto libraries, which we obviously want it to be doing, so just pass 0
        const rc = ssh2.libssh2_init(0);

        if (rc != 0) {
            return rc;
        }

        ssh2_initialized = true;
    }

    return 0;
}

// translate the untranslatable macro bits in the libssh2 upstream
// https://ziggit.dev/t/libssh2-issue/7020
fn libssh2ChannelOpenSession(session: ?*ssh2.LIBSSH2_SESSION) ?*ssh2.LIBSSH2_CHANNEL {
    const channel_type = "session";

    return ssh2.libssh2_channel_open_ex(
        session,
        channel_type.ptr,
        channel_type.len,
        ssh2.LIBSSH2_CHANNEL_WINDOW_DEFAULT,
        ssh2.LIBSSH2_CHANNEL_PACKET_DEFAULT,
        null,
        0,
    );
}

// another untranslatable macro one
fn libssh2_channel_request_pty(channel: ?*ssh2.LIBSSH2_CHANNEL) c_int {
    const term_type = "xterm";

    // this seems to have no affect on at least on iosxe test box but... want to have echo
    // enabled always (servers can allegedly not honor this though...)
    // see rfc4254
    const term_modes = [_]u8{
        53, // echo
        0, 0, 0, 1, // uint32 (four bytes) set to 1 for enable
        0, // end modes
    };

    return ssh2.libssh2_channel_request_pty_ex(
        channel,
        term_type.ptr,
        term_type.len,
        &term_modes[0],
        term_modes.len,
        ssh2.LIBSSH2_TERM_WIDTH,
        ssh2.LIBSSH2_TERM_HEIGHT,
        ssh2.LIBSSH2_TERM_WIDTH_PX,
        ssh2.LIBSSH2_TERM_HEIGHT_PX,
    );
}

// another untranslatable macro one
fn libssh2ChannelProcessStartup(channel: ?*ssh2.LIBSSH2_CHANNEL, netconf: bool) c_int {
    var request: []const u8 = "shell";
    var message: [*c]const u8 = null;
    var message_len: usize = 0;

    if (netconf) {
        request = "subsystem";
        message = "netconf";
        message_len = 7;
    }

    return ssh2.libssh2_channel_process_startup(
        channel,
        request.ptr,
        @intCast(request.len),
        message,
        @intCast(message_len),
    );
}

const AuthCallbackData = struct {
    password: [:0]u8,
};

pub fn NewOptions() transport.Options {
    return transport.Options{
        .SSH2 = Options{
            .private_key_path = null,
            .private_key_passphrase = null,
            .libssh2_trace = false,
            .netconf = false,
        },
    };
}

pub const Options = struct {
    private_key_path: ?[]const u8,
    private_key_passphrase: ?[]const u8,
    libssh2_trace: bool,
    netconf: bool,
};

pub fn NewTransport(
    allocator: std.mem.Allocator,
    log: logger.Logger,
    options: Options,
) !*Transport {
    const t = try allocator.create(Transport);
    const a = try allocator.create(AuthCallbackData);

    a.* = AuthCallbackData{
        // SAFETY: used in C callback, so think this is expected/fine
        .password = undefined,
    };

    t.* = Transport{
        .allocator = allocator,
        .log = log,

        .options = options,

        .auth_callback_data = a,

        .session_lock = std.Thread.Mutex{},

        .socket = null,
        .session = null,
        .channel = null,
    };

    return t;
}

pub const Transport = struct {
    allocator: std.mem.Allocator,
    log: logger.Logger,

    options: Options,

    auth_callback_data: *AuthCallbackData,

    session_lock: std.Thread.Mutex,

    socket: ?std.posix.socket_t,
    session: ?*ssh2.struct__LIBSSH2_SESSION,
    channel: ?*ssh2.struct__LIBSSH2_CHANNEL,

    pub fn init(self: *Transport) !void {
        const rc = ssh2InitializeOnce();
        if (rc != 0) {
            self.log.critical("failed initializing ssh2", .{});

            return error.OpenFailed;
        }
    }

    pub fn deinit(self: *Transport) void {
        if (self.session != null) {
            while (true) {
                const rc = ssh2.libssh2_session_free(self.session);

                if (rc == 0) {
                    break;
                } else if (rc == LIBSSH2_ERROR_EAGAIN) {
                    std.time.sleep(open_eagain_delay_ns);

                    continue;
                } else {
                    self.log.critical("failed freeing ssh2 session", .{});

                    break;
                }
            }
        }

        // any data set in this obj will be freed during auth itself
        self.allocator.destroy(self.auth_callback_data);

        self.allocator.destroy(self);
    }

    pub fn open(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        host: []const u8,
        port: u16,
        username: ?[]const u8,
        password: ?[]const u8,
        lookup_fn: lookup.LookupFn,
    ) !void {
        try self.initSocket(host, port);
        try self.initSession(timer, cancel, operation_timeout_ns);

        // TODO known hosts things
        // https://github.com/libssh2/libssh2/blob/master/example/ssh2_exec.c#L161-L197

        try self.authenticate(
            timer,
            cancel,
            operation_timeout_ns,
            host,
            port,
            username,
            password,
            lookup_fn,
        );
        self.log.info("authentication complete", .{});

        try self.openChannel(timer, cancel, operation_timeout_ns);
        try self.requestPty(timer, cancel, operation_timeout_ns);
        try self.requestShell(timer, cancel, operation_timeout_ns);

        // all the open things are sequential/single-threaded, any read/write operation past this
        // point must acquire the lock to operate against the session!
    }

    fn initSocket(
        self: *Transport,
        host: []const u8,
        port: u16,
    ) !void {
        // doing this here rather than init because it feels more "open-y" than "init-y"
        const resolved_addresses = std.net.getAddressList(
            self.allocator,
            host,
            port,
        ) catch |err| {
            self.log.critical("failed initializing resolved addresses, err: {}", .{err});

            return error.OpenFailed;
        };
        defer resolved_addresses.deinit();

        if (resolved_addresses.addrs.len == 0) {
            self.log.critical("failed resolving any address for host '{s}'", .{host});

            return error.OpenFailed;
        }

        // TODO should try all address families/resolved addresses at some point -- we do this in
        // og scrapli
        self.socket = std.posix.socket(
            resolved_addresses.addrs[0].un.family,
            std.posix.SOCK.STREAM,
            0,
        ) catch |err| {
            self.log.critical("failed initializing socket, err: {}", .{err});

            return error.OpenFailed;
        };

        std.posix.connect(
            self.socket.?,
            @ptrCast(&resolved_addresses.addrs[0]),
            resolved_addresses.addrs[0].getOsSockLen(),
        ) catch |err| {
            self.log.critical("failed connecting socket, err: {}", .{err});

            return error.OpenFailed;
        };
    }

    fn initSession(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
    ) !void {
        self.session = ssh2.libssh2_session_init_ex(
            null,
            null,
            null,
            self.auth_callback_data,
        );
        if (self.session == null) {
            self.log.critical("failed creating libssh2 session", .{});

            return error.OpenFailed;
        }

        // set blocking status (0 non-block, 1 block)
        ssh2.libssh2_session_set_blocking(self.session, 0);

        if (self.options.libssh2_trace) {
            // best effort, but probably wont fail anyway :p
            _ = ssh2.libssh2_trace(
                self.session,
                ssh2.LIBSSH2_TRACE_PUBLICKEY |
                    ssh2.LIBSSH2_TRACE_CONN |
                    ssh2.LIBSSH2_TRACE_ERROR |
                    ssh2.LIBSSH2_TRACE_SOCKET |
                    ssh2.LIBSSH2_TRACE_TRANS |
                    ssh2.LIBSSH2_TRACE_KEX |
                    ssh2.LIBSSH2_TRACE_AUTH,
            );
        }

        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return error.Cancelled;
            }

            const elapsed_time = timer.read();

            if (elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return error.OpenTimeoutExceeded;
            }

            const rc = ssh2.libssh2_session_handshake(self.session, self.socket.?);

            if (rc == 0) {
                break;
            } else if (rc == LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            }

            self.log.critical("failed session handshake", .{});

            return error.OpenFailed;
        }
    }

    fn authenticate(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        host: []const u8,
        port: u16,
        username: ?[]const u8,
        password: ?[]const u8,
        lookup_fn: lookup.LookupFn,
    ) !void {
        const _username = self.allocator.dupeZ(u8, username.?) catch |err| {
            self.log.critical("failed casting username to c string, err: {}", .{err});

            return error.OpenFailed;
        };
        defer self.allocator.free(_username);

        if (self.options.private_key_path != null) {
            self.handlePrivateKeyAuth(
                timer,
                cancel,
                operation_timeout_ns,
                _username,
            ) catch blk: {
                // we can still try to auth with a password if the user provided it, so we continue
                break :blk;
            };

            if (try self.isAuthenticated(
                timer,
                cancel,
                operation_timeout_ns,
            )) {
                return;
            }
        }

        if (username != null and password != null) {
            const _password = self.allocator.dupeZ(
                u8,
                try lookup.resolveValue(
                    host,
                    port,
                    password.?,
                    lookup_fn,
                ),
            ) catch |err| {
                self.log.critical("failed casting password to c string, err: {}", .{err});

                return error.OpenFailed;
            };
            defer self.allocator.free(_password);
            self.auth_callback_data.password = _password;

            self.handlePasswordAuth(
                timer,
                cancel,
                operation_timeout_ns,
                _username,
                _password,
            ) catch blk: {
                // password auth failed but we can still try kbdinteractive, in the future we could
                // /should check auth list before doing this but for now this is ok
                break :blk;
            };

            if (try self.isAuthenticated(timer, cancel, operation_timeout_ns)) {
                return;
            }

            try self.handleKeyboardInteractiveAuth(timer, cancel, operation_timeout_ns, _username);
            if (try self.isAuthenticated(timer, cancel, operation_timeout_ns)) {
                return;
            }
        }

        return error.NoMoreAuthenticationmethods;
    }

    fn isAuthenticated(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
    ) !bool {
        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return error.Cancelled;
            }

            const elapsed_time = timer.read();

            if (elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return error.OpenTimeoutExceeded;
            }

            const rc = ssh2.libssh2_userauth_authenticated(self.session);

            // 1 for auth, 0 for not, including EAGAIN just in case, but unclear if needed
            if (rc == 1) {
                return true;
            } else if (rc == LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            } else {
                return false;
            }
        }
    }

    fn handlePrivateKeyAuth(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        username: [:0]u8,
    ) !void {
        const _private_key_path = self.allocator.dupeZ(
            u8,
            self.options.private_key_path.?,
        ) catch |err| {
            self.log.critical("failed casting private key path to c string, err: {}", .{err});

            return error.OpenFailed;
        };
        defer self.allocator.free(_private_key_path);

        // SAFETY: will be set always, but this possibly saves us an allocation
        var _passphrase: [:0]u8 = undefined;

        if (self.options.private_key_passphrase != null) {
            _passphrase = try self.allocator.dupeZ(
                u8,
                self.options.private_key_passphrase.?,
            );
        } else {
            _passphrase = try std.fmt.allocPrintZ(
                self.allocator,
                "",
                .{},
            );
        }

        defer self.allocator.free(_passphrase);

        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return error.Cancelled;
            }

            const elapsed_time = timer.read();

            if (elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return error.OpenTimeoutExceeded;
            }

            // -18 rc == "failed" (key auth not supported)
            // -19 rc == "unverified" (auth failed)
            const rc = ssh2.libssh2_userauth_publickey_fromfile_ex(
                self.session,
                username,
                @intCast(username.len),
                null, // would be public key if not using openssl as libssh2 crypto engine
                _private_key_path,
                _passphrase,
            );

            if (rc == 0) {
                break;
            } else if (rc == LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            }

            self.log.critical("failed private key authentication", .{});

            return error.OpenFailed;
        }
    }

    fn handleKeyboardInteractiveAuth(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        username: [:0]u8,
    ) !void {
        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return error.Cancelled;
            }

            const elapsed_time = timer.read();

            if (elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return error.OpenTimeoutExceeded;
            }

            const rc = ssh2.libssh2_userauth_keyboard_interactive_ex(
                self.session,
                username,
                @intCast(username.len),
                kbdInteractiveCallback,
            );

            if (rc == 0) {
                break;
            } else if (rc == LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            }

            self.log.critical("failed keyboard interactive authentication", .{});

            return error.OpenFailed;
        }
    }

    fn handlePasswordAuth(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        username: [:0]u8,
        password: [:0]u8,
    ) !void {
        // note: calling the converted c func instead of zig style due to typing issue similar
        // to -> https://github.com/ziglang/zig/issues/18824
        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return error.Cancelled;
            }

            const elapsed_time = timer.read();

            if (elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return error.OpenTimeoutExceeded;
            }

            const rc = ssh2.libssh2_userauth_password_ex(
                self.session,
                username,
                @intCast(username.len),
                password,
                @intCast(password.len),
                null,
            );

            if (rc == 0) {
                break;
            } else if (rc == LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            }

            self.log.critical("failed password authentication, will try keyboard interactive", .{});

            return error.OpenFailed;
        }
    }

    fn openChannel(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
    ) !void {
        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return error.Cancelled;
            }

            const elapsed_time = timer.read();

            if (elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return error.OpenTimeoutExceeded;
            }

            const channel = libssh2ChannelOpenSession(self.session);

            if (channel != null) {
                self.channel = channel;

                break;
            }

            const rc = ssh2.libssh2_session_last_errno(self.session.?);

            if (rc == LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            }

            self.log.critical("failed opening session channel", .{});

            return error.OpenFailed;
        }
    }

    fn requestPty(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
    ) !void {
        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return error.Cancelled;
            }

            const elapsed_time = timer.read();

            if (elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return error.OpenTimeoutExceeded;
            }

            const rc = libssh2_channel_request_pty(self.channel);

            if (rc == 0) {
                break;
            } else if (rc == LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            }

            self.log.critical("failed requesting pty", .{});

            return error.OpenFailed;
        }
    }

    fn requestShell(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
    ) !void {
        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return error.Cancelled;
            }

            const elapsed_time = timer.read();

            if (elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return error.OpenTimeoutExceeded;
            }

            const rc = libssh2ChannelProcessStartup(self.channel, self.options.netconf);

            if (rc == 0) {
                break;
            } else if (rc == LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            }

            self.log.critical("failed requesting shell", .{});

            return error.OpenFailed;
        }
    }

    pub fn close(self: *Transport) void {
        self.session_lock.lock();
        defer self.session_lock.unlock();

        if (self.session != null) {
            const rc = ssh2.libssh2_session_disconnect(self.session, "deinit");
            if (rc != 0) {
                self.log.critical("failed disconnecting ssh2 session", .{});
            }
        }
    }

    pub fn write(self: *Transport, buf: []const u8) !void {
        self.session_lock.lock();
        defer self.session_lock.unlock();

        const n = ssh2.libssh2_channel_write_ex(self.channel, 0, buf.ptr, buf.len);

        if (n == LIBSSH2_ERROR_EAGAIN) {
            // would block
            return self.write(buf);
        }

        if (n < 0) {
            return error.WriteFailed;
        }

        if (n != buf.len) {
            self.log.critical("wrote {d} bytes, expected to write {d}", .{ n, buf.len });

            return error.WriteFailed;
        }
    }

    pub fn read(self: *Transport, buf: []u8) !usize {
        self.session_lock.lock();
        defer self.session_lock.unlock();

        const n = ssh2.libssh2_channel_read_ex(
            self.channel.?,
            @as(c_int, 0),
            &buf[0],
            @intCast(buf.len),
        );

        if (n == LIBSSH2_ERROR_EAGAIN) {
            // would block
            return 0;
        }

        if (n < 0) {
            return error.ReadFailed;
        }

        return @intCast(n);
    }
};

fn kbdInteractiveCallback(
    name: [*c]const u8,
    name_len: c_int,
    instruction: [*c]const u8,
    instruction_len: c_int,
    num_prompts: c_int,
    prompts: [*c]const ssh2.LIBSSH2_USERAUTH_KBDINT_PROMPT,
    responses: [*c]ssh2.LIBSSH2_USERAUTH_KBDINT_RESPONSE,
    abstract: [*c]?*anyopaque,
) callconv(.c) void {
    _ = name;
    _ = name_len;
    _ = instruction;
    _ = instruction_len;
    _ = prompts;

    if (num_prompts == 1) {
        if (abstract) |abstract_ptr| {
            const auth_callback_data_ptr: *AuthCallbackData = @ptrCast(@alignCast(abstract_ptr.*));

            const password_copy = @as([*c]u8, @ptrCast(c.malloc(auth_callback_data_ptr.password.len + 1)));

            @memcpy(
                password_copy[0..auth_callback_data_ptr.password.len],
                auth_callback_data_ptr.password[0..auth_callback_data_ptr.password.len],
            );
            password_copy[auth_callback_data_ptr.password.len] = 0;

            responses[0].text = password_copy;
            responses[0].length = @intCast(auth_callback_data_ptr.password.len);
        }
    }
}
