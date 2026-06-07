const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("openssl", .{});

    const generate = std.Build.Step.Run.create(b, "Generate openssl files");
    generate.has_side_effects = true;
    generate.addArg("sh");
    generate.addFileArg(b.path("generate.sh"));
    generate.addFileArg(upstream.path(""));
    generate.expectExitCode(0);
    generate.addCheck(
        .{ .expect_stdout_match = "Files were successfully generated\n" },
    );

    const header_path = generate.addOutputFileArg("include");

    const crypto = try libcrypto(b, target, optimize);
    crypto.installHeadersDirectory(
        header_path.path(b, "crypto"),
        "crypto",
        .{},
    );
    crypto.installHeadersDirectory(
        header_path.path(b, "internal"),
        "internal",
        .{},
    );
    b.installArtifact(crypto);

    const ssl = try libssl(b, target, optimize);
    ssl.installHeadersDirectory(
        header_path.path(b, "openssl"),
        "openssl",
        .{},
    );
    b.installArtifact(ssl);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn collectSources(
    b: *std.Build,
    base: []const u8,
    path: []const u8,
    ignores: []const []const u8,
) ![][]const u8 {
    const dir = try b.build_root.handle.openDir(
        b.graph.io,
        path,
        .{
            .iterate = true,
        },
    );
    defer dir.close(b.graph.io);

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(b.allocator);

    errdefer {
        for (files.items) |file| b.allocator.free(file);
    }

    while (try walker.next(b.graph.io)) |entry| {
        if (entry.kind != .file) continue;

        if (!std.mem.endsWith(u8, entry.path, ".c")) continue;

        var should_ignore: bool = false;

        for (ignores) |ignore| {
            if (std.mem.eql(u8, entry.path, ignore)) {
                should_ignore = true;
                break;
            }
        }

        if (should_ignore) continue;

        try files.append(
            b.allocator,
            try std.fmt.allocPrint(
                b.allocator,
                "{s}/{s}",
                .{ base, entry.path },
            ),
        );
    }

    std.sort.block([]const u8, files.items, {}, lessThan);

    return files.toOwnedSlice(b.allocator);
}

fn libssl(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const upstream = b.dependency("openssl", .{});

    const collect_path = try std.fmt.allocPrint(
        b.allocator,
        "{s}/ssl",
        .{
            upstream.builder.build_root.path.?,
        },
    );
    defer b.allocator.free(collect_path);

    const sources = try collectSources(
        b,
        "ssl",
        collect_path,
        &[_][]const u8{"record/methods/ktls_meth.c"},
    );
    defer {
        for (sources) |source| b.allocator.free(source);
        b.allocator.free(sources);
    }

    const lib_mod = b.createModule(
        .{
            .root_source_file = null,
            .strip = true,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        },
    );
    lib_mod.addIncludePath(upstream.path("."));
    lib_mod.addIncludePath(upstream.path("include"));

    lib_mod.addCSourceFiles(
        .{
            .root = upstream.path(""),
            .files = sources,
        },
    );

    // Disable CommonCrypto random when cross-compiling TO macOS FROM non-macOS
    // because CommonCrypto headers not available when cross-compiling
    if (target.result.os.tag == .macos and b.graph.host.result.os.tag != .macos) {
        lib_mod.addCMacro("OPENSSL_NO_APPLE_CRYPTO_RANDOM", "1");
    }

    const lib = b.addLibrary(
        .{
            .name = "ssl",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            }),
            .linkage = .static,
        },
    );
    lib.bundle_ubsan_rt = true;
    lib.bundle_compiler_rt = true;
    lib.pie = true;
    lib.root_module.strip = true;
    lib.root_module.link_libc = true;
    lib.root_module.addIncludePath(upstream.path("."));
    lib.root_module.addIncludePath(upstream.path("include"));

    // Disable CommonCrypto random when cross-compiling TO macOS FROM non-macOS
    // because CommonCrypto headers not available when cross-compiling
    if (target.result.os.tag == .macos and b.graph.host.result.os.tag != .macos) {
        lib.root_module.addCMacro("OPENSSL_NO_APPLE_CRYPTO_RANDOM", "1");
    }

    lib.root_module.addCSourceFiles(
        .{
            .root = upstream.path(""),
            .files = sources,
        },
    );

    return lib;
}

fn libcrypto(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const upstream = b.dependency("openssl", .{});

    const crypto_collect_path = try std.fmt.allocPrint(
        b.allocator,
        "{s}/crypto",
        .{
            upstream.builder.build_root.path.?,
        },
    );
    defer b.allocator.free(crypto_collect_path);

    const crypto_sources = try collectSources(
        b,
        "crypto",
        crypto_collect_path,
        &[_][]const u8{
            "aes/aes_x86core.c",
            "armcap.c",
            "bn/asm/x86_64-gcc.c",
            "bn/bn_ppc.c",
            "bn/bn_s390x.c",
            "bn/bn_sparc.c",
            "bn/rsaz_exp_x2.c",
            "bn/rsaz_exp.c",
            "chacha/chacha_ppc.c",
            "chacha/chacha_riscv.c",
            "des/ncbc_enc.c",
            "dllmain.c",
            "ec/ecp_nistp224.c",
            "ec/ecp_nistp256.c",
            "ec/ecp_nistp384.c",
            "ec/ecp_nistp521.c",
            "ec/ecp_nistputil.c",
            "ec/ecp_nistz256_table.c",
            "ec/ecp_nistz256.c",
            "ec/ecp_ppc.c",
            "ec/ecp_s390x_nistp.c",
            "ec/ecp_sm2p256_table.c",
            "ec/ecp_sm2p256.c",
            "ec/ecx_s390x.c",
            "evp/legacy_md2.c",
            "hmac/hmac_s390x.c",
            "lms/lm_ots_params.c",
            "lms/lm_ots_verify.c",
            "lms/lms_key.c",
            "lms/lms_params.c",
            "lms/lms_pubkey_decode.c",
            "lms/lms_sig_decoder.c",
            "lms/lms_sig.c",
            "lms/lms_verify.c",
            "loongarchcap.c",
            "LPdir_nyi.c",
            "LPdir_unix.c",
            "LPdir_vms.c",
            "LPdir_win.c",
            "LPdir_win32.c",
            "LPdir_wince.c",
            "md2/md2_dgst.c",
            "md2/md2_one.c",
            "md5/md5_riscv.c",
            "poly1305/poly1305_base2_44.c",
            "poly1305/poly1305_ieee754.c",
            "poly1305/poly1305_ppc.c",
            "ppccap.c",
            "rand/rand_egd.c",
            "rc5/rc5_ecb.c",
            "rc5/rc5_enc.c",
            "rc5/rc5_skey.c",
            "rc5/rc5cfb64.c",
            "rc5/rc5ofb64.c",
            "riscvcap.c",
            "rsa/rsa_acvp_test_params.c",
            "s390xcap.c",
            "sha/sha_ppc.c",
            "sha/sha_riscv.c",
            "sm3/sm3_riscv.c",
            "sparcv9cap.c",
        },
    );
    defer {
        for (crypto_sources) |source| b.allocator.free(source);
        b.allocator.free(crypto_sources);
    }

    const providers_collect_path = try std.fmt.allocPrint(
        b.allocator,
        "{s}/providers",
        .{
            upstream.builder.build_root.path.?,
        },
    );
    defer b.allocator.free(providers_collect_path);

    const provider_sources = try collectSources(
        b,
        "providers",
        providers_collect_path,
        &[_][]const u8{
            "common/securitycheck_fips.c",
            "fips/fips_entry.c",
            "fips/fipsindicator.c",
            "fips/fipsprov.c",
            "fips/self_test_kats.c",
            "fips/self_test.c",
            "implementations/ciphers/cipher_blowfish_hw.c",
            "implementations/ciphers/cipher_blowfish.c",
            "implementations/ciphers/cipher_cast5_hw.c",
            "implementations/ciphers/cipher_cast5.c",
            "implementations/ciphers/cipher_des_hw.c",
            "implementations/ciphers/cipher_des.c",
            "implementations/ciphers/cipher_desx_hw.c",
            "implementations/ciphers/cipher_desx.c",
            "implementations/ciphers/cipher_idea_hw.c",
            "implementations/ciphers/cipher_idea.c",
            "implementations/ciphers/cipher_rc2_hw.c",
            "implementations/ciphers/cipher_rc2.c",
            "implementations/ciphers/cipher_rc4_hmac_md5_hw.c",
            "implementations/ciphers/cipher_rc4_hmac_md5.c",
            "implementations/ciphers/cipher_rc4_hw.c",
            "implementations/ciphers/cipher_rc4.c",
            "implementations/ciphers/cipher_rc5_hw.c",
            "implementations/ciphers/cipher_rc5.c",
            "implementations/ciphers/cipher_seed_hw.c",
            "implementations/ciphers/cipher_seed.c",
            "implementations/digests/md2_prov.c",
            "implementations/digests/md4_prov.c",
            "implementations/digests/mdc2_prov.c",
            "implementations/digests/wp_prov.c",
            "implementations/encode_decode/decode_lmsxdr2key.c",
            "implementations/kem/template_kem.c",
            "implementations/macs/blake2_mac_impl.c",
            "implementations/rands/seeding/rand_cpu_arm64.c",
            "implementations/rands/seeding/rand_vms.c",
            "implementations/rands/seeding/rand_vxworks.c",
            "implementations/signature/lms_signature.c",
            "legacyprov.c",
        },
    );
    defer {
        for (provider_sources) |source| b.allocator.free(source);
        b.allocator.free(provider_sources);
    }

    var all_sources: std.ArrayList([]const u8) = .empty;
    defer all_sources.deinit(b.allocator);

    try all_sources.appendSlice(b.allocator, crypto_sources);
    try all_sources.appendSlice(b.allocator, provider_sources);
    try all_sources.appendSlice(
        b.allocator,
        &[_][]const u8{
            "ssl/record/methods/ssl3_cbc.c",
            "ssl/record/methods/tls_pad.c",
        },
    );

    const lib_mod = b.createModule(
        .{
            .root_source_file = null,
            .strip = true,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        },
    );

    lib_mod.addIncludePath(upstream.path("include"));
    lib_mod.addIncludePath(upstream.path("."));
    lib_mod.addIncludePath(upstream.path("providers/common/include"));
    lib_mod.addIncludePath(upstream.path("providers/implementations/include"));
    lib_mod.addIncludePath(upstream.path("providers/fips/include"));

    lib_mod.addCMacro("OPENSSLDIR", "\"/usr/local/ssl\"");
    lib_mod.addCMacro("ENGINESDIR", "\"/usr/local/lib/engines-3\"");
    lib_mod.addCMacro("MODULESDIR", "\"/usr/local/lib/ossl-modules\"");

    // Disable CommonCrypto random when cross-compiling TO macOS FROM non-macOS
    // because CommonCrypto headers not available when cross-compiling
    if (target.result.os.tag == .macos and b.graph.host.result.os.tag != .macos) {
        lib_mod.addCMacro("OPENSSL_NO_APPLE_CRYPTO_RANDOM", "1");
    }

    lib_mod.addCSourceFiles(
        .{
            .root = upstream.path("."),
            .files = all_sources.items,
        },
    );

    const lib = b.addLibrary(
        .{
            .name = "crypto",
            .linkage = .static,
            .root_module = lib_mod,
        },
    );
    lib.bundle_ubsan_rt = true;
    lib.bundle_compiler_rt = true;
    lib.pie = true;

    return lib;
}
