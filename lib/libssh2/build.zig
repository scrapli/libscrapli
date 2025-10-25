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

    const lib_mod = b.createModule(
        .{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
        },
    );
    lib_mod.linkLibrary(openssl.artifact("ssl"));
    lib_mod.linkLibrary(openssl.artifact("crypto"));

    const lib = b.addLibrary(
        .{
            .name = "ssh2",
            .linkage = .static,
            .root_module = lib_mod,
        },
    );

    lib.root_module.addCMacro("LIBSSH2_OPENSSL", "");

    lib.root_module.addCMacro("HAVE_UNISTD_H", "");
    lib.root_module.addCMacro("HAVE_INTTYPES_H", "");
    lib.root_module.addCMacro("HAVE_STDLIB_H", "");
    lib.root_module.addCMacro("HAVE_SYS_SELECT_H", "");
    lib.root_module.addCMacro("HAVE_SYS_UIO_H", "");
    lib.root_module.addCMacro("HAVE_SYS_SOCKET_H", "");
    lib.root_module.addCMacro("HAVE_SYS_IOCTL_H", "");
    lib.root_module.addCMacro("HAVE_SYS_TIME_H", "");
    lib.root_module.addCMacro("HAVE_SYS_UN_H", "");
    lib.root_module.addCMacro("HAVE_LONGLONG", "");
    lib.root_module.addCMacro("HAVE_GETTIMEOFDAY", "");
    lib.root_module.addCMacro("HAVE_INET_ADDR", "");
    lib.root_module.addCMacro("HAVE_POLL", "");
    lib.root_module.addCMacro("HAVE_SELECT", "");
    lib.root_module.addCMacro("HAVE_SOCKET", "");
    lib.root_module.addCMacro("HAVE_STRTOLL", "");
    lib.root_module.addCMacro("HAVE_SNPRINTF", "");
    lib.root_module.addCMacro("HAVE_O_NONBLOCK", "");

    lib.addIncludePath(upstream.path("include"));
    lib.addIncludePath(upstream.path("config"));

    lib.installHeadersDirectory(
        upstream.path("include"),
        ".",
        .{},
    );

    lib.addCSourceFiles(
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
                "-DLIBSSH2DEBUG", // for enabling debug logging/trace
            },
        },
    );

    b.installArtifact(lib);
}
