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

    const ssl = openssl.artifact("ssl");
    const crypto = openssl.artifact("crypto");

    // openssl deliberately calls through mismatched fn pointers (lhash/doall etc.),
    // which UBSan's function check traps on; nuke sanitizers. honestly fabio (fable) helped
    // figure this out as im not 100% i understand, but i *do* understand that we hit traps related
    // to ubsan w/out this unless in ReleaseFast which skipped some checks, now we can be in
    // ReleaseSafe and w/ these flags we are gucci.
    ssl.root_module.sanitize_c = .off;
    crypto.root_module.sanitize_c = .off;

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

    // Windows: add libscrapli's windows-compat stub headers (sys/uio.h etc.)
    // Absolute paths because .cwd_relative resolves against the MAIN build
    // root, not this sub-project's directory.
    if (@import("builtin").target.os.tag == .windows) {
        ssh2_translate_c.addIncludePath(.{
            .cwd_relative = "D:\\ai\\ref\\libscrapli\\src\\windows-compat",
        });
    }

    ssh2_translate_c.defineCMacro("LIBSSH2_OPENSSL", "");

    // POSIX header detection macros. On Windows, skip the sys/* ones —
    // letting libssh2.h include <sys/select.h> etc. drags mingw-w64's
    // x86 intrinsic headers through zig translate-c which chokes on
    // __builtin_elementwise_* builtins (44 AVX-512 errors). The stub
    // sys/uio.h + sys/socket.h in windows-compat cover what libssh2.h
    // unconditionally needs.
    const is_windows_target = @import("builtin").target.os.tag == .windows;
    if (!is_windows_target) {
        ssh2_translate_c.defineCMacro("HAVE_UNISTD_H", "");
        ssh2_translate_c.defineCMacro("HAVE_SYS_SELECT_H", "");
        ssh2_translate_c.defineCMacro("HAVE_SYS_UIO_H", "");
        ssh2_translate_c.defineCMacro("HAVE_SYS_SOCKET_H", "");
        ssh2_translate_c.defineCMacro("HAVE_SYS_IOCTL_H", "");
        ssh2_translate_c.defineCMacro("HAVE_SYS_TIME_H", "");
        ssh2_translate_c.defineCMacro("HAVE_SYS_UN_H", "");
        ssh2_translate_c.defineCMacro("HAVE_POLL", "");
        ssh2_translate_c.defineCMacro("HAVE_SELECT", "");
        ssh2_translate_c.defineCMacro("HAVE_SOCKET", "");
    }
    // Safe on all platforms:
    ssh2_translate_c.defineCMacro("HAVE_INTTYPES_H", "");
    ssh2_translate_c.defineCMacro("HAVE_STDLIB_H", "");
    ssh2_translate_c.defineCMacro("HAVE_LONGLONG", "");
    ssh2_translate_c.defineCMacro("HAVE_GETTIMEOFDAY", "");
    ssh2_translate_c.defineCMacro("HAVE_INET_ADDR", "");
    ssh2_translate_c.defineCMacro("HAVE_STRTOLL", "");
    ssh2_translate_c.defineCMacro("HAVE_SNPRINTF", "");
    ssh2_translate_c.defineCMacro("HAVE_O_NONBLOCK", "");

    if (is_windows_target) {
        // Workaround: zig translate-c chokes on its bundled mingw-w64
        // AVX-512/XOP intrinsic headers (__builtin_elementwise_* builtins
        // unknown). All of those sub-headers are guarded by __IMMINTRIN_H /
        // __X86INTRIN_H, so pre-defining these two guards turns the whole
        // SIMD chain into no-op includes.
        ssh2_translate_c.defineCMacro("__IMMINTRIN_H", "");
        ssh2_translate_c.defineCMacro("__X86INTRIN_H", "");
        // Suppress mingw secure-template inline functions (wcscat_s etc.)
        // which translate-c converts into unused top-level constants
        // (compile error under zig 0.17-dev).
        ssh2_translate_c.defineCMacro("__CRT__NO_INLINE", "1");
        ssh2_translate_c.defineCMacro("__STDC_WANT_SECURE_LIB__", "0");
        // Kill BOS fortify overload bodies (see main build.zig rationale).
        ssh2_translate_c.defineCMacro("__MINGW_FORTIFY_LEVEL", "0");
    }

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
    // POSIX feature detection. Windows (zig mingw headers) lacks poll.h,
    // sys/un.h, sys/select.h, sys/time.h — libssh2 falls back to select()
    // via winsock when HAVE_POLL/HAVE_SYS_* are absent, which is exactly
    // how its official Win32 builds are configured.
    if (!is_windows_target) {
        lib_mod.addCMacro("HAVE_UNISTD_H", "");
        lib_mod.addCMacro("HAVE_SYS_SELECT_H", "");
        lib_mod.addCMacro("HAVE_SYS_UIO_H", "");
        lib_mod.addCMacro("HAVE_SYS_SOCKET_H", "");
        lib_mod.addCMacro("HAVE_SYS_IOCTL_H", "");
        lib_mod.addCMacro("HAVE_SYS_TIME_H", "");
        lib_mod.addCMacro("HAVE_SYS_UN_H", "");
        lib_mod.addCMacro("HAVE_POLL", "");
        lib_mod.addCMacro("HAVE_SELECT", "");
        lib_mod.addCMacro("HAVE_SOCKET", "");
        // POSIX non-blocking via fcntl(O_NONBLOCK)
        lib_mod.addCMacro("HAVE_O_NONBLOCK", "");
    } else {
        // Windows: keep only what MinGW actually provides.
        lib_mod.addCMacro("HAVE_SELECT", "");   // winsock select()
        lib_mod.addCMacro("HAVE_SOCKET", "");   // winsock socket()
        lib_mod.addCMacro("HAVE_IOCTLSOCKET", ""); // ioctlsocket(FIONBIO)
        // NOTE: HAVE_O_NONBLOCK deliberately omitted — it selects the
        // fcntl() branch in session.c which doesn't exist on Windows.
    }
    // Safe on all platforms:
    lib_mod.addCMacro("HAVE_UNISTD_H", "");
    lib_mod.addCMacro("HAVE_INTTYPES_H", "");
    lib_mod.addCMacro("HAVE_STDLIB_H", "");
    lib_mod.addCMacro("HAVE_LONGLONG", "");
    lib_mod.addCMacro("HAVE_GETTIMEOFDAY", "");
    lib_mod.addCMacro("HAVE_INET_ADDR", "");
    lib_mod.addCMacro("HAVE_STRTOLL", "");
    lib_mod.addCMacro("HAVE_SNPRINTF", "");

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
