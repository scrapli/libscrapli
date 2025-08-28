const std = @import("std");
const netconf = @import("netconf.zig");
const ffi_driver = @import("ffi-driver.zig");

// for forcing inclusion in the ffi.zig entrypoint we use for the ffi layer
pub const noop = true;

//
// session options
//

export fn ls_option_session_read_size(
    d_ptr: usize,
    value: u64,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.read_size = value;
        },
        .netconf => |rd| {
            rd.session.options.read_size = value;
        },
    }

    return 0;
}

export fn ls_option_session_read_min_delay_ns(
    d_ptr: usize,
    value: u64,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.min_read_delay_ns = value;
        },
        .netconf => |rd| {
            rd.session.options.min_read_delay_ns = value;
        },
    }

    return 0;
}

export fn ls_option_session_read_max_delay_ns(
    d_ptr: usize,
    value: u64,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.max_read_delay_ns = value;
        },
        .netconf => |rd| {
            rd.session.options.max_read_delay_ns = value;
        },
    }

    return 0;
}

export fn ls_option_session_return_char(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.return_char = rd.session.options.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.session.options.return_char = rd.session.options.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn ls_option_session_operation_timeout_ns(
    d_ptr: usize,
    value: u64,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.operation_timeout_ns = value;
        },
        .netconf => |rd| {
            rd.session.options.operation_timeout_ns = value;
        },
    }

    return 0;
}

export fn ls_option_session_operation_max_search_depth(
    d_ptr: usize,
    value: u64,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.operation_max_search_depth = value;
        },
        .netconf => |rd| {
            rd.session.options.operation_max_search_depth = value;
        },
    }

    return 0;
}

export fn ls_option_session_record_destination(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.record_destination = .{
                .f = rd.session.options.allocator.dupe(
                    u8,
                    std.mem.span(value),
                ) catch {
                    return 1;
                },
            };

            var out_f = std.fs.cwd().createFile(
                rd.session.options.record_destination.?.f,
                .{},
            ) catch {
                return 1;
            };

            // TODO same shit; also used to be a var and we would update .context so... gotta
            // figure out that because that is how we know to close the file. really this should
            // (session recorder things) all be fixed to just be a callback and nothing else --
            // then the rest can be handled by a user in zig or py/go
            // var w_buffer: [1024]u8 = undefined;
            // const recorder = out_f.writer(&w_buffer);
            // recorder.context = out_f;

            rd.session.recorder = &out_f;
        },
        .netconf => |rd| {
            rd.session.options.record_destination = .{
                .f = rd.session.options.allocator.dupe(
                    u8,
                    std.mem.span(value),
                ) catch {
                    return 1;
                },
            };

            // TODO see above
            var out_f = std.fs.cwd().createFile(
                rd.session.options.record_destination.?.f,
                .{},
            ) catch {
                return 1;
            };

            // var recorder = out_f.writer();
            // recorder.context = out_f;

            rd.session.recorder = &out_f;
        },
    }

    return 0;
}

//
// auth options
//

export fn ls_option_auth_username(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.username = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.username = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn ls_option_auth_password(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.password = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.password = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn ls_option_auth_private_key_path(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.private_key_path = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.private_key_path = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn ls_option_auth_private_key_passphrase(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.private_key_passphrase = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.private_key_passphrase = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn ls_option_auth_set_lookup_key_value(
    d_ptr: usize,
    key: [*c]const u8,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.extendLookupMap(
                std.mem.span(key),
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.extendLookupMap(
                std.mem.span(key),
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn ls_option_auth_force_in_session_auth(
    d_ptr: usize,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.auth_options.force_in_session_auth = true;
        },
        .netconf => |rd| {
            rd.session.auth_options.force_in_session_auth = true;
        },
    }

    return 0;
}

export fn ls_option_auth_bypass_in_session_auth(
    d_ptr: usize,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.auth_options.bypass_in_session_auth = true;
        },
        .netconf => |rd| {
            rd.session.auth_options.bypass_in_session_auth = true;
        },
    }

    return 0;
}

export fn ls_option_auth_username_pattern(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.username_pattern = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.username_pattern = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn ls_option_auth_password_pattern(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.password_pattern = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.password_pattern = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn ls_option_auth_private_key_passphrase_pattern(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.private_key_passphrase_pattern = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.private_key_passphrase_pattern = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

//
// bin transport options
//

export fn ls_option_transport_bin_bin(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.bin = rd.options.transport.bin.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.bin = rd.options.transport.bin.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn ls_option_transport_bin_extra_open_args(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.extra_open_args = rd.options.transport.bin.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.extra_open_args = rd.options.transport.bin.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn ls_option_transport_bin_override_open_args(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.override_open_args = rd.options.transport.bin.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.override_open_args = rd.options.transport.bin.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn ls_option_transport_bin_ssh_config_path(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.ssh_config_path = rd.options.transport.bin.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.ssh_config_path = rd.options.transport.bin.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn ls_option_transport_bin_known_hosts_path(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.known_hosts_path = rd.options.transport.bin.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.known_hosts_path = rd.options.transport.bin.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn ls_option_transport_bin_enable_strict_key(
    d_ptr: usize,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.enable_strict_key = true;
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.enable_strict_key = true;
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn ls_option_transport_bin_term_height(
    d_ptr: usize,
    value: u16,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.term_height = value;
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.term_height = value;
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn ls_option_transport_bin_term_width(
    d_ptr: usize,
    value: u16,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.term_width = value;
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.term_width = value;
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

//
// ssh2 transport options
//

export fn ls_option_transport_ssh2_known_hosts_path(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.known_hosts_path = rd.options.transport.ssh2.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.known_hosts_path = rd.options.transport.ssh2.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn ls_option_transport_ssh2_libssh2trace(
    d_ptr: usize,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.libssh2_trace = true;
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.libssh2_trace = true;
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn ls_option_transport_ssh2_proxy_jump_host(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    if (i.options.proxy_jump_options == null) {
                        i.options.proxy_jump_options = .{
                            .host = rd.options.transport.ssh2.allocator.dupe(
                                u8,
                                std.mem.span(value),
                            ) catch {
                                return 1;
                            },
                        };

                        return 0;
                    }

                    i.options.proxy_jump_options.?.host = rd.options.transport.ssh2.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    if (i.options.proxy_jump_options == null) {
                        i.options.proxy_jump_options = .{
                            .host = rd.options.transport.ssh2.allocator.dupe(
                                u8,
                                std.mem.span(value),
                            ) catch {
                                return 1;
                            },
                        };

                        return 0;
                    }

                    i.options.proxy_jump_options.?.host = rd.options.transport.ssh2.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn ls_option_transport_ssh2_proxy_jump_port(
    d_ptr: usize,
    value: u16,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.proxy_jump_options.?.port = value;
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.proxy_jump_options.?.port = value;
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn ls_option_transport_ssh2_proxy_jump_username(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.proxy_jump_options.?.username = rd.options.transport.ssh2.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.proxy_jump_options.?.username = rd.options.transport.ssh2.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn ls_option_transport_ssh2_proxy_jump_password(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.proxy_jump_options.?.password = rd.options.transport.ssh2.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.proxy_jump_options.?.password = rd.options.transport.ssh2.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn ls_option_transport_ssh2_proxy_jump_private_key_path(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.proxy_jump_options.?.private_key_path = rd.options.transport.ssh2.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.proxy_jump_options.?.private_key_path = rd.options.transport.ssh2.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn ls_option_transport_ssh2_proxy_jump_private_key_passphrase(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.proxy_jump_options.?.private_key_passphrase = rd.options.transport.ssh2.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.proxy_jump_options.?.private_key_passphrase = rd.options.transport.ssh2.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn ls_option_transport_ssh2_proxy_jump_libssh2trace(
    d_ptr: usize,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.proxy_jump_options.?.libssh2_trace = true;
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.proxy_jump_options.?.libssh2_trace = true;
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

//
// test transport options
//

export fn ls_option_transport_test_f(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .test_ => |i| {
                    i.options.f = rd.options.transport.test_.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .test_ => |i| {
                    i.options.f = rd.options.transport.test_.allocator.dupe(
                        u8,
                        std.mem.span(value),
                    ) catch {
                        return 1;
                    };
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

//
// netconf options
//

export fn ls_option_netconf_error_tag(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => {
            return 1;
        },
        .netconf => |rd| {
            rd.options.error_tag = rd.options.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn ls_option_netconf_preferred_version(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => {
            return 1;
        },
        .netconf => |rd| {
            const preferred_version = std.mem.span(value);

            if (std.mem.eql(
                u8,
                @tagName(netconf.Version.version_1_0),
                preferred_version,
            )) {
                rd.options.preferred_version = netconf.Version.version_1_0;
            } else if (std.mem.eql(
                u8,
                @tagName(netconf.Version.version_1_1),
                preferred_version,
            )) {
                rd.options.preferred_version = netconf.Version.version_1_1;
            } else {
                return 1;
            }
        },
    }

    return 0;
}

export fn ls_option_netconf_message_poll_interval(
    d_ptr: usize,
    value: u64,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => {
            return 1;
        },
        .netconf => |rd| {
            rd.options.message_poll_interval_ns = value;
        },
    }

    return 0;
}
