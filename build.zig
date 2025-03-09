const std = @import("std");
const flags = @import("src/flags.zig");

const libscrapli_version = std.SemanticVersion{
    .major = 0,
    .minor = 0,
    .patch = 1,
};

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    // .{ .cpu_arch = .aarch64, .os_tag = .linux },
    // .{ .cpu_arch = .x86_64, .os_tag = .macos },
    // .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    // .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
};

const all_examples: []const []const u8 = &.{
    "basic-driver-usage",
    "basic-netconf-usage",
};

pub fn build(b: *std.Build) !void {
    const examples = flags.parseCustomFlag("--examples", false);
    const main = flags.parseCustomFlag("--main", false);
    const skip_ffi_lib = flags.parseCustomFlag("--skip-ffi-lib", false);
    const release = flags.parseCustomFlag("--release", false);
    const default_target = b.standardTargetOptions(.{});

    const optimize = if (release) std.builtin.OptimizeMode.ReleaseSafe else std.builtin.OptimizeMode.Debug;

    for (targets) |target| {
        if (!skip_ffi_lib) {
            try buildFfiLib(b, optimize, target);
        }

        if (examples) {
            try buildExamples(b, optimize, target);
        }
    }

    try buildTests(b, optimize, default_target);

    if (main) {
        try buildMainExe(b, optimize, default_target);
    }

    buildCheck(b, optimize, default_target);
}

fn getPcre2Dep(
    b: *std.Build,
    target: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Dependency {
    return b.dependency(
        "pcre2",
        .{
            .target = b.resolveTargetQuery(target),
            .optimize = optimize,
        },
    );
}

fn getLibssh2Dep(
    b: *std.Build,
    target: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Dependency {
    return b.dependency(
        "libssh2",
        .{
            .target = b.resolveTargetQuery(target),
            .optimize = optimize,
        },
    );
}

fn getZigYamlDep(
    b: *std.Build,
    target: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Dependency {
    return b.dependency(
        "yaml",
        .{
            .target = b.resolveTargetQuery(target),
            .optimize = optimize,
        },
    );
}

fn getZigXmlDep(
    b: *std.Build,
    target: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Dependency {
    return b.dependency(
        "xml",
        .{
            .target = b.resolveTargetQuery(target),
            .optimize = optimize,
        },
    );
}

fn buildFfiLib(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    target: std.Target.Query,
) !void {
    const pcre2 = getPcre2Dep(b, target, optimize);
    const libssh2 = getLibssh2Dep(b, target, optimize);
    const yaml = getZigYamlDep(b, target, optimize);
    const xml = getZigXmlDep(b, target, optimize);

    const lib = b.addSharedLibrary(.{
        .name = "scrapli",
        .root_source_file = b.path("src/ffi.zig"),
        .target = b.resolveTargetQuery(target),
        .optimize = optimize,
        .version = libscrapli_version,
    });

    lib.linkLibrary(pcre2.artifact("pcre2-8"));
    lib.linkLibrary(libssh2.artifact("ssh2"));
    lib.root_module.addImport("yaml", yaml.module("yaml"));
    lib.root_module.addImport("xml", xml.module("xml"));

    const lib_target_output = b.addInstallArtifact(
        lib,
        .{
            .dest_dir = .{
                .override = .{
                    .custom = try target.zigTriple(b.allocator),
                },
            },
        },
    );

    b.getInstallStep().dependOn(&lib_target_output.step);
}

fn buildExamples(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    target: std.Target.Query,
) !void {
    const pcre2 = getPcre2Dep(b, target, optimize);
    const libssh2 = getLibssh2Dep(b, target, optimize);
    const yaml = getZigYamlDep(b, target, optimize);
    const xml = getZigXmlDep(b, target, optimize);

    const lib = b.addStaticLibrary(.{
        .name = "scrapli",
        .root_source_file = b.path("src/root.zig"),
        .target = b.resolveTargetQuery(target),
        .optimize = optimize,
        .version = libscrapli_version,
    });

    lib.linkLibrary(pcre2.artifact("pcre2-8"));
    lib.linkLibrary(libssh2.artifact("ssh2"));
    lib.root_module.addImport("yaml", yaml.module("yaml"));
    lib.root_module.addImport("xml", xml.module("xml"));

    for (all_examples) |example| {
        const exe = b.addExecutable(.{
            .name = example,
            .root_source_file = b.path(
                b.pathJoin(&[_][]const u8{ "examples", example, "main.zig" }),
            ),
            .target = b.resolveTargetQuery(target),
            .optimize = optimize,
        });
        exe.linkLibrary(lib);
        exe.root_module.addImport("scrapli", lib.root_module);

        const exe_target_output = b.addInstallArtifact(
            exe,
            .{
                .dest_dir = .{
                    .override = .{ .custom = try std.fmt.allocPrint(
                        b.allocator,
                        "{s}/examples",
                        .{try target.zigTriple(b.allocator)},
                    ) },
                },
            },
        );

        b.getInstallStep().dependOn(&exe_target_output.step);
    }
}

fn buildTests(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
) !void {
    const step = b.step("test", "Run tests");

    const pcre2 = getPcre2Dep(b, target.query, optimize);
    const libssh2 = getLibssh2Dep(b, target.query, optimize);
    const yaml = getZigYamlDep(b, target.query, optimize);
    const xml = getZigXmlDep(b, target.query, optimize);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .test_runner = std.Build.Step.Compile.TestRunner{
            .mode = .simple,
            .path = b.path("src/test-runner.zig"),
        },
    });

    tests.linkLibrary(pcre2.artifact("pcre2-8"));
    tests.linkLibrary(libssh2.artifact("ssh2"));
    tests.root_module.addImport("yaml", yaml.module("yaml"));
    tests.root_module.addImport("xml", xml.module("xml"));

    const run_tests = b.addRunArtifact(tests);

    const unit_test_flag = flags.parseCustomFlag("--unit", true);
    const integration_test_flag = flags.parseCustomFlag("--integration", false);
    const functional_test_flag = flags.parseCustomFlag("--functional", false);
    const record_flag = flags.parseCustomFlag("--record", false);
    const update_flag = flags.parseCustomFlag("--update", false);
    const coverage_flag = flags.parseCustomFlag("--coverage", false);

    if (coverage_flag) {
        const home = std.process.getEnvVarOwned(b.allocator, "HOME") catch "";
        defer b.allocator.free(home);

        const exclude = std.fmt.allocPrint(
            b.allocator,
            // exclude zig cache stuff
            "--exclude-path={s}/.zig/,{s}/.cache",
            .{ home, home },
        ) catch "";
        defer b.allocator.free(exclude);

        const run_coverage = b.addSystemCommand(&.{
            "kcov",
            "--clean",
            exclude,
            "--include-pattern=src/",
            // exclude "vendored" deps
            "--exclude-pattern=lib/",
            b.pathJoin(&.{ b.install_path, "cover" }),
        });

        run_coverage.addArtifactArg(tests);

        if (!unit_test_flag) {
            run_coverage.addArg("--unit");
        }

        if (integration_test_flag) {
            run_coverage.addArg("--integration");
        }

        if (record_flag) {
            run_coverage.addArg("--record");
        }

        if (functional_test_flag) {
            run_coverage.addArg("--functional");
        }

        if (update_flag) {
            run_coverage.addArg("--update");
        }

        step.dependOn(&run_coverage.step);
    } else {
        if (!unit_test_flag) {
            run_tests.addArg("--unit");
        }

        if (integration_test_flag) {
            run_tests.addArg("--integration");
        }

        if (record_flag) {
            run_tests.addArg("--record");
        }

        if (functional_test_flag) {
            run_tests.addArg("--functional");
        }

        if (update_flag) {
            run_tests.addArg("--update");
        }

        step.dependOn(&run_tests.step);
    }
}

fn buildMainExe(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
) !void {
    const pcre2 = getPcre2Dep(b, target.query, optimize);
    const libssh2 = getLibssh2Dep(b, target.query, optimize);
    const yaml = getZigYamlDep(b, target.query, optimize);
    const xml = getZigXmlDep(b, target.query, optimize);

    const lib = b.addStaticLibrary(.{
        .name = "scrapli",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .version = libscrapli_version,
    });

    lib.linkLibrary(pcre2.artifact("pcre2-8"));
    lib.linkLibrary(libssh2.artifact("ssh2"));
    lib.root_module.addImport("yaml", yaml.module("yaml"));
    lib.root_module.addImport("xml", xml.module("xml"));

    const exe = b.addExecutable(.{
        .name = "scrapli",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibrary(lib);
    exe.root_module.addImport("scrapli", lib.root_module);

    const exe_target_output = b.addInstallArtifact(exe, .{});

    b.getInstallStep().dependOn(&exe_target_output.step);
}

fn buildCheck(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
) void {
    const pcre2 = getPcre2Dep(b, target.query, optimize);
    const libssh2 = getLibssh2Dep(b, target.query, optimize);
    const yaml = getZigYamlDep(b, target.query, optimize);
    const xml = getZigXmlDep(b, target.query, optimize);

    const lib = b.addStaticLibrary(.{
        .name = "scrapli",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .version = libscrapli_version,
    });

    lib.linkLibrary(pcre2.artifact("pcre2-8"));
    lib.linkLibrary(libssh2.artifact("ssh2"));
    lib.root_module.addImport("yaml", yaml.module("yaml"));
    lib.root_module.addImport("xml", xml.module("xml"));

    const check = b.step("check", "complitaion check step for zls");
    check.dependOn(&lib.step);
}
