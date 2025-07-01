const std = @import("std");
const auth = @import("auth.zig");
const logging = @import("logging.zig");
const errors = @import("errors.zig");
const transport_waiter = @import("transport-waiter.zig");

const c = @cImport({
    @cDefine("_XOPEN_SOURCE", "500");
    @cInclude("sys/socket.h");
    @cInclude("stdlib.h");
});

const ssh2 = @cImport({
    @cInclude("libssh2.h");
});

const open_eagain_delay_ns: u64 = 100_000;

var ssh2_initialized = false;

fn libssh2InitializeOnce() c_int {
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

fn libssh2ChannelOpenProxySession(
    session: ?*ssh2.LIBSSH2_SESSION,
    host: [:0]u8,
) ?*ssh2.LIBSSH2_CHANNEL {
    return ssh2.libssh2_channel_direct_tcpip_ex(
        session,
        host,
        22, // TODO obv add to the options
        "127.0.0.1",
        0,
    );
}

// another untranslatable macro one
fn libssh2ChannelRequestPty(channel: ?*ssh2.LIBSSH2_CHANNEL) c_int {
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

const ProxyLoop = struct {
    allocator: std.mem.Allocator,
    channel: ?*ssh2.LIBSSH2_CHANNEL = null,
    remote_fd: c_int = 0,
    stop_flag: std.atomic.Value(bool),
    pipe_to_channel_thread: ?std.Thread = null,
    channel_to_pipe_thread: ?std.Thread = null,

    pub fn init(
        allocator: std.mem.Allocator,
    ) !*ProxyLoop {
        const pl = try allocator.create(ProxyLoop);

        pl.* = ProxyLoop{
            .allocator = allocator,
            .stop_flag = std.atomic.Value(bool).init(false),
        };

        return pl;
    }

    pub fn deinit(self: *ProxyLoop) void {
        self.allocator.destroy(self);
    }

    pub fn start(self: *ProxyLoop, channel: *ssh2.LIBSSH2_CHANNEL, remote_fd: c_int) !void {
        self.channel = channel;
        self.remote_fd = remote_fd;

        self.stop_flag.store(false, std.builtin.AtomicOrder.unordered);

        self.pipe_to_channel_thread = try std.Thread.spawn(
            .{},
            ProxyLoop.copy_pipe_to_channel,
            .{
                self,
            },
        );
        self.channel_to_pipe_thread = try std.Thread.spawn(
            .{},
            ProxyLoop.copy_channel_to_pipe,
            .{
                self,
            },
        );
    }

    pub fn stop(self: *ProxyLoop) void {
        std.posix.close(self.remote_fd);

        self.stop_flag.store(true, std.builtin.AtomicOrder.unordered);

        if (self.pipe_to_channel_thread) |t| t.join();
        if (self.channel_to_pipe_thread) |t| t.join();

        self.pipe_to_channel_thread = null;
        self.channel_to_pipe_thread = null;
    }

    fn copy_pipe_to_channel(
        self: *ProxyLoop,
    ) !void {
        var buf: [4096]u8 = undefined;
        while (!self.stop_flag.load(std.builtin.AtomicOrder.unordered)) {
            // TODO i assume this is a blockign read which... is not good
            const n = std.posix.read(self.remote_fd, &buf) catch |err| {
                switch (err) {
                    error.NotOpenForReading => {
                        return;
                    },
                    else => {
                        return err;
                    },
                }
            };
            if (n == 0) break;

            const rc = ssh2.libssh2_channel_write_ex(self.channel, 0, buf[0..n].ptr, n);

            // TODO gotta figure out what happens if these fail -- maybe the "normal" read method
            // should check for the state of the proxy loop if in proxy jump setup?
            if (rc < 0) {
                return error.WriteFailed;
            }
        }
    }

    fn copy_channel_to_pipe(
        self: *ProxyLoop,
    ) !void {
        var buf: [4096]u8 = undefined;
        while (!self.stop_flag.load(std.builtin.AtomicOrder.unordered)) {
            const n = ssh2.libssh2_channel_read(self.channel, buf[0..].ptr, 4096);
            if (n == 0) break;
            if (n < 0) continue;
            _ = try std.posix.write(self.remote_fd, buf[0..@intCast(n)]);
        }
    }
};

const AuthCallbackData = struct {
    password: [:0]u8,
};

pub const ProxyJumpTarget = struct {
    host: []const u8,
    username: []const u8,
    password: []const u8,
};

pub const OptionsInputs = struct {
    known_hosts_path: ?[]const u8 = null,
    libssh2_trace: bool = false,
    netconf: bool = false,
    proxy_jump_target: ?ProxyJumpTarget = null,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    known_hosts_path: ?[]const u8,
    libssh2_trace: bool,
    netconf: bool,
    proxy_jump_target: ?ProxyJumpTarget,

    pub fn init(allocator: std.mem.Allocator, opts: OptionsInputs) !*Options {
        const o = try allocator.create(Options);
        errdefer allocator.destroy(o);

        o.* = Options{
            .allocator = allocator,
            .known_hosts_path = opts.known_hosts_path,
            .libssh2_trace = opts.libssh2_trace,
            .netconf = opts.netconf,
            .proxy_jump_target = opts.proxy_jump_target,
        };

        return o;
    }

    pub fn deinit(self: *Options) void {
        self.allocator.destroy(self);
    }
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    log: logging.Logger,

    options: *Options,

    auth_callback_data: *AuthCallbackData,
    proxy_auth_callback_data: *AuthCallbackData,

    session_lock: std.Thread.Mutex,

    // may be to the actual host or to the jumphost
    socket: ?std.posix.socket_t = null,

    // the session/channel to the host in normal operation, or to the "initial" host in proxy jump
    // operations
    initial_session: ?*ssh2.struct__LIBSSH2_SESSION = null,
    initial_channel: ?*ssh2.struct__LIBSSH2_CHANNEL = null,

    // the "outer" (or original) session/channel (to the jumphost basically)
    proxy_session: ?*ssh2.struct__LIBSSH2_SESSION = null,
    proxy_channel: ?*ssh2.struct__LIBSSH2_CHANNEL = null,
    proxy_loop: *ProxyLoop,

    pub fn init(
        allocator: std.mem.Allocator,
        log: logging.Logger,
        options: *Options,
    ) !*Transport {
        const rc = libssh2InitializeOnce();
        if (rc != 0) {
            log.critical("failed initializing ssh2", .{});

            return errors.ScrapliError.OpenFailed;
        }

        const t = try allocator.create(Transport);
        const a = try allocator.create(AuthCallbackData);

        a.* = AuthCallbackData{
            // SAFETY: used in C callback, so think this is expected/fine
            .password = undefined,
        };

        const pa = try allocator.create(AuthCallbackData);

        pa.* = AuthCallbackData{
            // SAFETY: used in C callback, so think this is expected/fine
            .password = undefined,
        };

        t.* = Transport{
            .allocator = allocator,
            .log = log,
            .options = options,
            .auth_callback_data = a,
            .proxy_auth_callback_data = pa,
            .proxy_loop = try ProxyLoop.init(allocator),
            .session_lock = std.Thread.Mutex{},
        };

        return t;
    }

    pub fn deinit(self: *Transport) void {
        if (self.initial_session != null) {
            while (true) {
                // TODO proxy session too if applicable
                const rc = ssh2.libssh2_session_free(self.initial_session);

                if (rc == 0) {
                    break;
                } else if (rc == ssh2.LIBSSH2_ERROR_EAGAIN) {
                    std.time.sleep(open_eagain_delay_ns);

                    continue;
                } else {
                    self.log.critical("failed freeing ssh2 session", .{});

                    break;
                }
            }
        }

        self.allocator.destroy(self.auth_callback_data);
        self.allocator.destroy(self.proxy_auth_callback_data);
        self.proxy_loop.deinit();
        self.allocator.destroy(self);
    }

    pub fn open(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        host: []const u8,
        port: u16,
        auth_options: *auth.Options,
    ) !void {
        try self.initSocket(host, port);
        try self.initSession(timer, cancel, operation_timeout_ns);
        try self.initKnownHost(host, port);

        try self.authenticate(
            timer,
            cancel,
            operation_timeout_ns,
            self.initial_session.?,
            auth_options,
        );

        self.log.info("authentication complete", .{});

        var channel: ?*ssh2.struct__LIBSSH2_CHANNEL = null;

        if (self.options.proxy_jump_target == null) {
            // no proxy jump, normal flow
            self.initial_channel = try self.openChannel(
                timer,
                cancel,
                operation_timeout_ns,
                self.initial_session.?,
            );

            channel = self.initial_channel;
        } else {
            try self.openProxyChannel(timer, cancel, operation_timeout_ns);

            self.proxy_channel = try self.openChannel(
                timer,
                cancel,
                operation_timeout_ns,
                self.proxy_session.?,
            );

            channel = self.proxy_channel;
        }

        if (!self.options.netconf) {
            // no pty for netconf, it causes inputs to be echoed (which we normally want, but
            // not in netconf), and disabling them via term mode only makes it echo once
            // not twice :p
            try self.requestPty(
                timer,
                cancel,
                operation_timeout_ns,
                channel.?,
            );
        }

        try self.requestShell(
            timer,
            cancel,
            operation_timeout_ns,
            channel.?,
        );

        // all the open things are sequential/single-threaded, any read/write operation past
        // this point must acquire the lock to operate against the session!
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
            self.log.critical(
                "failed initializing resolved addresses, err: {}",
                .{err},
            );

            return errors.ScrapliError.OpenFailed;
        };
        defer resolved_addresses.deinit();

        if (resolved_addresses.addrs.len == 0) {
            self.log.critical("failed resolving any address for host '{s}'", .{host});

            return errors.ScrapliError.OpenFailed;
        }

        for (resolved_addresses.addrs) |addr| {
            const sock = std.posix.socket(
                addr.un.family,
                std.posix.SOCK.STREAM,
                std.posix.IPPROTO.TCP,
            ) catch |err| {
                self.log.warn(
                    "failed initializing socket for addr {any}, err: {}",
                    .{ addr, err },
                );

                continue;
            };

            std.posix.connect(
                sock,
                @ptrCast(&addr),
                addr.getOsSockLen(),
            ) catch |err| {
                self.log.warn("failed connecting socket, err: {}", .{err});

                std.posix.close(sock);

                continue;
            };

            self.socket = sock;

            return;
        }

        if (self.socket == null) {
            self.log.critical(
                "failed initializing socket, all resolved addresses failed",
                .{},
            );

            return errors.ScrapliError.OpenFailed;
        }
    }

    fn initSession(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
    ) !void {
        self.initial_session = ssh2.libssh2_session_init_ex(
            null,
            null,
            null,
            self.auth_callback_data,
        );
        if (self.initial_session == null) {
            self.log.critical("failed creating libssh2 session", .{});

            return errors.ScrapliError.OpenFailed;
        }

        // set blocking status (0 non-block, 1 block)
        ssh2.libssh2_session_set_blocking(self.initial_session, 0);

        if (self.options.libssh2_trace) {
            // best effort, but probably wont fail anyway :p
            _ = ssh2.libssh2_trace(
                self.initial_session,
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

                return errors.ScrapliError.Cancelled;
            }

            const elapsed_time = timer.read();

            if (operation_timeout_ns != 0 and elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return errors.ScrapliError.TimeoutExceeded;
            }

            const rc = ssh2.libssh2_session_handshake(
                self.initial_session,
                self.socket.?,
            );

            if (rc == 0) {
                break;
            } else if (rc == ssh2.LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            }

            self.log.critical("failed session handshake", .{});

            return errors.ScrapliError.OpenFailed;
        }
    }

    fn initKnownHost(
        self: *Transport,
        host: []const u8,
        port: u16,
    ) !void {
        if (self.options.known_hosts_path == null) {
            return;
        }

        const _host = self.allocator.dupeZ(u8, host) catch |err| {
            self.log.critical("failed casting host to c string, err: {}", .{err});

            return errors.ScrapliError.OpenFailed;
        };
        defer self.allocator.free(_host);

        const _known_hosts_path = self.allocator.dupeZ(
            u8,
            self.options.known_hosts_path.?,
        ) catch |err| {
            self.log.critical(
                "failed casting known hosts path to c string, err: {}",
                .{err},
            );

            return errors.ScrapliError.OpenFailed;
        };
        defer self.allocator.free(_known_hosts_path);

        const nh = ssh2.libssh2_knownhost_init(self.initial_session.?);
        if (nh == null) {
            self.log.critical("failed libssh2 known hosts init", .{});

            return errors.ScrapliError.OpenFailed;
        }
        defer ssh2.libssh2_knownhost_free(nh);

        const read_rc = ssh2.libssh2_knownhost_readfile(
            nh,
            _known_hosts_path,
            ssh2.LIBSSH2_KNOWNHOST_FILE_OPENSSH,
        );
        if (read_rc < 0) {
            self.log.critical("failed to read known hosts file", .{});

            return errors.ScrapliError.OpenFailed;
        }

        var len: usize = 0;
        var key_type: c_int = 0;

        const host_fingerprint = ssh2.libssh2_session_hostkey(
            self.initial_session.?,
            &len,
            &key_type,
        );
        if (host_fingerprint == null) {
            self.log.critical("failed to fingerprint target host", .{});

            return errors.ScrapliError.OpenFailed;
        }

        var known_host: ?*ssh2.libssh2_knownhost = null;

        const check_rc = ssh2.libssh2_knownhost_checkp(
            nh,
            _host,
            port,
            host_fingerprint,
            len,
            ssh2.LIBSSH2_KNOWNHOST_TYPE_PLAIN | ssh2.LIBSSH2_KNOWNHOST_KEYENC_RAW,
            &known_host,
        );

        switch (check_rc) {
            ssh2.LIBSSH2_KNOWNHOST_CHECK_MATCH => {
                return;
            },
            ssh2.LIBSSH2_KNOWNHOST_CHECK_MISMATCH => {
                self.log.critical("known host check mismatch", .{});

                return errors.ScrapliError.OpenFailed;
            },
            ssh2.LIBSSH2_KNOWNHOST_CHECK_NOTFOUND => {
                self.log.critical("known host check not found", .{});

                return errors.ScrapliError.OpenFailed;
            },
            ssh2.LIBSSH2_KNOWNHOST_CHECK_FAILURE => {
                self.log.critical("known host check failure", .{});

                return errors.ScrapliError.OpenFailed;
            },
            else => {
                self.log.critical("known host unknown error", .{});

                return errors.ScrapliError.OpenFailed;
            },
        }
    }

    fn authenticate(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        session: *ssh2.struct__LIBSSH2_SESSION,
        auth_options: *auth.Options,
    ) !void {
        const _username = self.allocator.dupeZ(u8, auth_options.username.?) catch |err| {
            self.log.critical("failed casting username to c string, err: {}", .{err});

            return errors.ScrapliError.OpenFailed;
        };
        defer self.allocator.free(_username);

        if (auth_options.private_key_path != null) {
            self.handlePrivateKeyAuth(
                timer,
                cancel,
                operation_timeout_ns,
                session,
                _username,
                auth_options.private_key_path,
                auth_options.private_key_passphrase,
            ) catch blk: {
                // we can still try to auth with a password if the user provided it, so we continue
                break :blk;
            };

            if (try self.isAuthenticated(
                timer,
                cancel,
                operation_timeout_ns,
                session,
            )) {
                return;
            }
        }

        if (auth_options.username != null and auth_options.password != null) {
            const _password = self.allocator.dupeZ(
                u8,
                try auth_options.resolveAuthValue(
                    auth_options.password.?,
                ),
            ) catch |err| {
                self.log.critical("failed casting password to c string, err: {}", .{err});

                return errors.ScrapliError.OpenFailed;
            };
            defer self.allocator.free(_password);
            self.auth_callback_data.password = _password;

            self.handlePasswordAuth(
                timer,
                cancel,
                operation_timeout_ns,
                session,
                _username,
                _password,
            ) catch blk: {
                // password auth failed but we can still try kbdinteractive, in the future we could
                // /should check auth list before doing this but for now this is ok
                break :blk;
            };

            if (try self.isAuthenticated(
                timer,
                cancel,
                operation_timeout_ns,
                session,
            )) {
                return;
            }

            try self.handleKeyboardInteractiveAuth(
                timer,
                cancel,
                operation_timeout_ns,
                session,
                _username,
            );
            if (try self.isAuthenticated(
                timer,
                cancel,
                operation_timeout_ns,
                session,
            )) {
                return;
            }
        }

        return errors.ScrapliError.AuthenticationFailed;
    }

    fn isAuthenticated(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        session: *ssh2.struct__LIBSSH2_SESSION,
    ) !bool {
        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return errors.ScrapliError.Cancelled;
            }

            const elapsed_time = timer.read();

            if (operation_timeout_ns != 0 and elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return errors.ScrapliError.TimeoutExceeded;
            }

            const rc = ssh2.libssh2_userauth_authenticated(session);

            // 1 for auth, 0 for not, including EAGAIN just in case, but unclear if needed
            if (rc == 1) {
                return true;
            } else if (rc == ssh2.LIBSSH2_ERROR_EAGAIN) {
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
        session: *ssh2.struct__LIBSSH2_SESSION,
        username: [:0]u8,
        private_key_path: ?[]const u8,
        passphrase: ?[]const u8,
    ) !void {
        const _private_key_path = self.allocator.dupeZ(
            u8,
            private_key_path.?,
        ) catch |err| {
            self.log.critical("failed casting private key path to c string, err: {}", .{err});

            return errors.ScrapliError.OpenFailed;
        };
        defer self.allocator.free(_private_key_path);

        // SAFETY: will be set always, but this possibly saves us an allocation
        var _passphrase: [:0]u8 = undefined;

        if (passphrase != null) {
            _passphrase = try self.allocator.dupeZ(
                u8,
                passphrase.?,
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

                return errors.ScrapliError.Cancelled;
            }

            const elapsed_time = timer.read();

            if (operation_timeout_ns != 0 and elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return errors.ScrapliError.TimeoutExceeded;
            }

            // -18 rc == "failed" (key auth not supported)
            // -19 rc == "unverified" (auth failed)
            const rc = ssh2.libssh2_userauth_publickey_fromfile_ex(
                session,
                username,
                @intCast(username.len),
                null, // would be public key if not using openssl as libssh2 crypto engine
                _private_key_path,
                _passphrase,
            );

            if (rc == 0) {
                break;
            } else if (rc == ssh2.LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            }

            self.log.critical("failed private key authentication", .{});

            return errors.ScrapliError.OpenFailed;
        }
    }

    fn handleKeyboardInteractiveAuth(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        session: *ssh2.struct__LIBSSH2_SESSION,
        username: [:0]u8,
    ) !void {
        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return errors.ScrapliError.Cancelled;
            }

            const elapsed_time = timer.read();

            if (operation_timeout_ns != 0 and elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return errors.ScrapliError.TimeoutExceeded;
            }

            const rc = ssh2.libssh2_userauth_keyboard_interactive_ex(
                session,
                username,
                @intCast(username.len),
                kbdInteractiveCallback,
            );

            if (rc == 0) {
                break;
            } else if (rc == ssh2.LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            }

            self.log.critical("failed keyboard interactive authentication", .{});

            return errors.ScrapliError.OpenFailed;
        }
    }

    fn handlePasswordAuth(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        session: *ssh2.struct__LIBSSH2_SESSION,
        username: [:0]u8,
        password: [:0]u8,
    ) !void {
        // note: calling the converted c func instead of zig style due to typing issue similar
        // to -> https://github.com/ziglang/zig/issues/18824
        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return errors.ScrapliError.Cancelled;
            }

            const elapsed_time = timer.read();

            if (operation_timeout_ns != 0 and elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return errors.ScrapliError.TimeoutExceeded;
            }

            const rc = ssh2.libssh2_userauth_password_ex(
                session,
                username,
                @intCast(username.len),
                password,
                @intCast(password.len),
                null,
            );

            if (rc == 0) {
                break;
            } else if (rc == ssh2.LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            }

            self.log.warn("failed password authentication, will try keyboard interactive", .{});

            return errors.ScrapliError.OpenFailed;
        }
    }

    fn openChannel(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        session: *ssh2.struct__LIBSSH2_SESSION,
    ) !?*ssh2.struct__LIBSSH2_CHANNEL {
        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return errors.ScrapliError.Cancelled;
            }

            const elapsed_time = timer.read();

            if (operation_timeout_ns != 0 and elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return errors.ScrapliError.TimeoutExceeded;
            }

            const channel = libssh2ChannelOpenSession(session);

            if (channel != null) {
                return channel;
            }

            const rc = ssh2.libssh2_session_last_errno(session);

            if (rc == ssh2.LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            }

            self.log.critical("failed opening session channel", .{});

            return errors.ScrapliError.OpenFailed;
        }
    }

    fn openProxyChannel(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
    ) !void {
        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return errors.ScrapliError.Cancelled;
            }

            const elapsed_time = timer.read();

            if (operation_timeout_ns != 0 and elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return errors.ScrapliError.TimeoutExceeded;
            }

            const _host = self.allocator.dupeZ(
                u8,
                self.options.proxy_jump_target.?.host,
            ) catch |err| {
                self.log.critical(
                    "failed casting proxy target host to c string, err: {}",
                    .{err},
                );

                return errors.ScrapliError.OpenFailed;
            };
            defer self.allocator.free(_host);

            self.initial_channel = libssh2ChannelOpenProxySession(
                self.initial_session,
                _host,
            );

            if (self.initial_channel != null) {
                break;
            }

            const rc = ssh2.libssh2_session_last_errno(self.initial_session.?);

            if (rc == ssh2.LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            }

            self.log.critical("failed opening session (initial direct tcpip) channel {d}", .{rc});

            return errors.ScrapliError.OpenFailed;
        }

        const _password = self.allocator.dupeZ(
            u8,
            self.options.proxy_jump_target.?.password,
        ) catch |err| {
            self.log.critical("failed casting password to c string, err: {}", .{err});

            return errors.ScrapliError.OpenFailed;
        };
        defer self.allocator.free(_password);

        self.proxy_auth_callback_data.password = _password;

        const _username = self.allocator.dupeZ(
            u8,
            self.options.proxy_jump_target.?.username,
        ) catch |err| {
            self.log.critical("failed casting username to c string, err: {}", .{err});

            return errors.ScrapliError.OpenFailed;
        };
        defer self.allocator.free(_username);

        self.proxy_session = ssh2.libssh2_session_init_ex(
            null,
            null,
            null,
            self.proxy_auth_callback_data,
        );
        if (self.proxy_session == null) {
            self.log.critical("failed creating libssh2 session", .{});

            return errors.ScrapliError.OpenFailed;
        }

        // TODO option to enable trace for the "inner" session
        // _ = ssh2.libssh2_trace(
        //     final_session.?,
        //     ssh2.LIBSSH2_TRACE_PUBLICKEY |
        //         ssh2.LIBSSH2_TRACE_CONN |
        //         ssh2.LIBSSH2_TRACE_ERROR |
        //         ssh2.LIBSSH2_TRACE_SOCKET |
        //         ssh2.LIBSSH2_TRACE_TRANS |
        //         ssh2.LIBSSH2_TRACE_KEX |
        //         ssh2.LIBSSH2_TRACE_AUTH,
        // );

        // we have to create a socket pair/pipe so we can give libssh2 a real socket -- we then
        // run this little proxy loop around it to read/write to/from the pipe and then to the
        // final (proxy-jump-d) session.
        var fds: [2]c_int = undefined;
        const sockrc = c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds);
        if (sockrc != 0) {
            // TODO use scrapli error
            return error.ErrorCreatingSocketPair;
        }

        const local_fd = fds[0];
        const remote_fd = fds[1];

        try self.proxy_loop.start(self.initial_channel.?, remote_fd);

        const handshake_rc = ssh2.libssh2_session_handshake(self.proxy_session, local_fd);
        if (handshake_rc != 0) {
            return errors.ScrapliError.OpenFailed;
        }

        ssh2.libssh2_session_set_blocking(self.proxy_session, 0);

        var handshake_attempts: u32 = 0;
        while (true) {
            handshake_attempts += 1;

            const rc = ssh2.libssh2_userauth_password_ex(
                self.proxy_session.?,
                _username,
                @intCast(self.options.proxy_jump_target.?.username.len),
                _password,
                @intCast(self.options.proxy_jump_target.?.password.len),
                null,
            );

            if (rc == 0) {
                break;
            } else if (rc == ssh2.LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(std.time.ns_per_ms * 500);
                continue;
            }

            std.time.sleep(std.time.ns_per_ms * 500);
        }
    }

    fn requestPty(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        channel: *ssh2.struct__LIBSSH2_CHANNEL,
    ) !void {
        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return errors.ScrapliError.Cancelled;
            }

            const elapsed_time = timer.read();

            if (operation_timeout_ns != 0 and elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return errors.ScrapliError.TimeoutExceeded;
            }

            const rc = libssh2ChannelRequestPty(channel);

            if (rc == 0) {
                break;
            } else if (rc == ssh2.LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            }

            self.log.critical("failed requesting pty", .{});

            return errors.ScrapliError.OpenFailed;
        }
    }

    fn requestShell(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        channel: *ssh2.struct__LIBSSH2_CHANNEL,
    ) !void {
        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return errors.ScrapliError.Cancelled;
            }

            const elapsed_time = timer.read();

            if (operation_timeout_ns != 0 and elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return errors.ScrapliError.TimeoutExceeded;
            }

            const rc = libssh2ChannelProcessStartup(
                channel,
                self.options.netconf,
            );

            if (rc == 0) {
                break;
            } else if (rc == ssh2.LIBSSH2_ERROR_EAGAIN) {
                std.time.sleep(open_eagain_delay_ns);

                continue;
            }

            self.log.critical("failed requesting shell", .{});

            return errors.ScrapliError.OpenFailed;
        }
    }

    pub fn close(self: *Transport) void {
        self.session_lock.lock();
        defer self.session_lock.unlock();

        // TODO proxy session shit too
        if (self.initial_session != null) {
            const rc = ssh2.libssh2_session_disconnect(self.initial_session, "deinit");
            if (rc != 0) {
                self.log.critical("failed disconnecting ssh2 session", .{});
            }
        }

        self.proxy_loop.stop();
    }

    pub fn write(self: *Transport, w: transport_waiter.Waiter, buf: []const u8) !void {
        self.session_lock.lock();
        defer self.session_lock.unlock();

        var channel: ?*ssh2.struct__LIBSSH2_CHANNEL = null;
        if (self.options.proxy_jump_target == null) {
            channel = self.initial_channel.?;
        } else {
            std.debug.print("WRITE TO PROXY CHAN?\n", .{});
            channel = self.proxy_channel.?;
        }

        const n = ssh2.libssh2_channel_write_ex(channel, 0, buf.ptr, buf.len);

        if (n == ssh2.LIBSSH2_ERROR_EAGAIN) {
            // would block
            return self.write(w, buf);
        }

        if (n < 0) {
            return errors.ScrapliError.WriteFailed;
        }

        if (n != buf.len) {
            self.log.critical("wrote {d} bytes, expected to write {d}", .{ n, buf.len });

            return errors.ScrapliError.WriteFailed;
        }
    }

    pub fn read(self: *Transport, w: transport_waiter.Waiter, buf: []u8) !usize {
        self.session_lock.lock();

        var channel: ?*ssh2.struct__LIBSSH2_CHANNEL = null;
        var wait_fd: ?std.posix.fd_t = null;

        if (self.options.proxy_jump_target == null) {
            channel = self.initial_channel.?;
            wait_fd = self.socket.?;
        } else {
            channel = self.proxy_channel.?;
            wait_fd = self.proxy_loop.remote_fd;
        }

        // because nonblock we will just eagain forever (really until the timeout catches us)
        // if we dont check explicitly for eof, so do that
        if (ssh2.libssh2_channel_eof(channel) == 1) {
            self.session_lock.unlock();

            return errors.ScrapliError.EOF;
        }

        // only locked around the actual read (and eof check), not waiting on kqueue/epoll stuff
        const n = ssh2.libssh2_channel_read_ex(
            channel,
            @as(c_int, 0),
            &buf[0],
            @intCast(buf.len),
        );

        self.session_lock.unlock();

        if (n == ssh2.LIBSSH2_ERROR_EAGAIN) {
            // TODO have to wait on a diff socket if we are proxied i think
            // _ = w;
            try w.wait(wait_fd.?);
            // std.debug.print("w", .{});
            // try w.wait(self.socket.?);

            return 0;
        }

        if (n < 0) {
            return errors.ScrapliError.ReadFailed;
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

            const password_copy: [*c]u8 = @ptrCast(c.malloc(auth_callback_data_ptr.password.len + 1));

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
