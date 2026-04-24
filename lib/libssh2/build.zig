const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const openssl = b.dependency(
        "openssl",
        .{
            .target = target,
            .optimize = optimize,
        },
    );

    const upstream = b.dependency(
        "libssh2",
        .{
            .target = target,
            .optimize = optimize,
        },
    );

    const ssh2_translate_c = b.addTranslateC(
        .{
            .root_source_file = b.path("include/libssh2.h"),
            .target = target,
            .optimize = optimize,
        },
    );

    ssh2_translate_c.addIncludePath(b.path("include"));

    ssh2_translate_c.defineCMacro("LIBSSH2_OPENSSL", "");
    ssh2_translate_c.defineCMacro("HAVE_UNISTD_H", "");
    ssh2_translate_c.defineCMacro("HAVE_INTTYPES_H", "");
    ssh2_translate_c.defineCMacro("HAVE_STDLIB_H", "");
    ssh2_translate_c.defineCMacro("HAVE_SYS_SELECT_H", "");
    ssh2_translate_c.defineCMacro("HAVE_SYS_UIO_H", "");
    ssh2_translate_c.defineCMacro("HAVE_SYS_SOCKET_H", "");
    ssh2_translate_c.defineCMacro("HAVE_SYS_IOCTL_H", "");
    ssh2_translate_c.defineCMacro("HAVE_SYS_TIME_H", "");
    ssh2_translate_c.defineCMacro("HAVE_SYS_UN_H", "");
    ssh2_translate_c.defineCMacro("HAVE_LONGLONG", "");
    ssh2_translate_c.defineCMacro("HAVE_GETTIMEOFDAY", "");
    ssh2_translate_c.defineCMacro("HAVE_INET_ADDR", "");
    ssh2_translate_c.defineCMacro("HAVE_POLL", "");
    ssh2_translate_c.defineCMacro("HAVE_SELECT", "");
    ssh2_translate_c.defineCMacro("HAVE_SOCKET", "");
    ssh2_translate_c.defineCMacro("HAVE_STRTOLL", "");
    ssh2_translate_c.defineCMacro("HAVE_SNPRINTF", "");
    ssh2_translate_c.defineCMacro("HAVE_O_NONBLOCK", "");

    const lib_mod = b.createModule(
        .{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        },
    );

    lib_mod.linkLibrary(openssl.artifact("ssl"));
    lib_mod.linkLibrary(openssl.artifact("crypto"));
    lib_mod.addIncludePath(upstream.path("include"));
    lib_mod.addCSourceFiles(
        .{
            .root = upstream.path(""),
            .files = &.{
                "src/agent.c",
                "src/agent_win.c",
                "src/bcrypt_pbkdf.c",
                "src/blowfish.c",
                "src/chacha.c",
                "src/channel.c",
                "src/cipher-chachapoly.c",
                "src/comp.c",
                "src/crypt.c",
                "src/crypto.c",
                "src/global.c",
                "src/hostkey.c",
                "src/keepalive.c",
                "src/kex.c",
                "src/knownhost.c",
                "src/libgcrypt.c",
                "src/mac.c",
                "src/misc.c",
                "src/openssl.c",
                "src/os400qc3.c",
                "src/packet.c",
                "src/pem.c",
                "src/poly1305.c",
                "src/publickey.c",
                "src/scp.c",
                "src/session.c",
                "src/sftp.c",
                "src/transport.c",
                "src/userauth.c",
                "src/userauth_kbd_packet.c",
                "src/version.c",
                "src/wincng.c",
            },
            .flags = &.{
                "-fPIC",
                "-DWITH_OPENSSL=ON",
                "-DBUILD_STATIC_LIBS=ON",
                "-DBUILD_SHARED_LIBS=OFF",
                "-DENABLE_CRYPT_NONE=ON",
                "-DENABLE_MAC_NONE=ON",
                "-DCRYPTO_BACKEND=OpenSSL",
                "-DBUILD_EXAMPLES=OFF",
                "-DBUILD_TESTING=OFF",
                "-DLIBSSH2_NO_DEPRECATED",
                "-DLIBSSH2DEBUG", // for enabling debug logging/trace
            },
        },
    );

    lib_mod.addCMacro("LIBSSH2_OPENSSL", "");
    lib_mod.addCMacro("HAVE_UNISTD_H", "");
    lib_mod.addCMacro("HAVE_INTTYPES_H", "");
    lib_mod.addCMacro("HAVE_STDLIB_H", "");
    lib_mod.addCMacro("HAVE_SYS_SELECT_H", "");
    lib_mod.addCMacro("HAVE_SYS_UIO_H", "");
    lib_mod.addCMacro("HAVE_SYS_SOCKET_H", "");
    lib_mod.addCMacro("HAVE_SYS_IOCTL_H", "");
    lib_mod.addCMacro("HAVE_SYS_TIME_H", "");
    lib_mod.addCMacro("HAVE_SYS_UN_H", "");
    lib_mod.addCMacro("HAVE_LONGLONG", "");
    lib_mod.addCMacro("HAVE_GETTIMEOFDAY", "");
    lib_mod.addCMacro("HAVE_INET_ADDR", "");
    lib_mod.addCMacro("HAVE_POLL", "");
    lib_mod.addCMacro("HAVE_SELECT", "");
    lib_mod.addCMacro("HAVE_SOCKET", "");
    lib_mod.addCMacro("HAVE_STRTOLL", "");
    lib_mod.addCMacro("HAVE_SNPRINTF", "");
    lib_mod.addCMacro("HAVE_O_NONBLOCK", "");

    _ = ssh2_translate_c.addModule("ssh2");

    const lib = b.addLibrary(
        .{
            .name = "ssh2",
            .linkage = .static,
            .root_module = lib_mod,
        },
    );

    lib.installHeadersDirectory(b.path("include"), ".", .{});

    b.installArtifact(lib);
}
