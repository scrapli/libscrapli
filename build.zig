const std = @import("std");

const flags = @import("src/flags.zig");

const version = std.SemanticVersion{
    .major = 0,
    .minor = 0,
    .patch = 1,
    .pre = "beta.13",
};

const ffi_targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
};

const examples: []const []const u8 = &.{
    "basic-cli-usage",
    "basic-netconf-usage",
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scrapli = try buildScrapli(b, target, optimize);

    try buildCheck(b, scrapli);
    try buildTests(b, scrapli);
    try buildMain(b, target, optimize, scrapli);
    try buildExamples(b, target, optimize, scrapli);
    try buildFFI(b, target, optimize);
}

fn getPcre2Dep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Dependency {
    return b.dependency(
        "pcre2",
        .{
            .target = target,
            .optimize = optimize,
        },
    );
}

fn getLibssh2Dep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Dependency {
    return b.dependency(
        "libssh2",
        .{
            .target = target,
            .optimize = optimize,
        },
    );
}

fn getZigYamlDep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Dependency {
    return b.dependency(
        "yaml",
        .{
            .target = target,
            .optimize = optimize,
        },
    );
}

fn getZigXmlDep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Dependency {
    return b.dependency(
        "xml",
        .{
            .target = target,
            .optimize = optimize,
        },
    );
}

fn buildScrapli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Module {
    const pcre2 = getPcre2Dep(b, target, optimize);
    const libssh2 = getLibssh2Dep(b, target, optimize);
    const yaml = getZigYamlDep(b, target, optimize);
    const xml = getZigXmlDep(b, target, optimize);

    const scrapli = b.addModule(
        "scrapli",
        .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "yaml",
                    .module = yaml.module("yaml"),
                },
                .{
                    .name = "xml",
                    .module = xml.module("xml"),
                },
            },
        },
    );

    scrapli.linkLibrary(pcre2.artifact("pcre2-8"));
    scrapli.linkLibrary(libssh2.artifact("ssh2"));

    return scrapli;
}

fn buildCheck(
    b: *std.Build,
    scrapli: *std.Build.Module,
) !void {
    const check = b.step("check", "Check if scrapli compiles");
    const scrapli_check = b.addLibrary(
        .{
            .name = "scrapli",
            .root_module = scrapli,
        },
    );

    check.dependOn(&scrapli_check.step);
}

fn buildTests(
    b: *std.Build,
    scrapli: *std.Build.Module,
) !void {
    const test_step = b.step("test", "Run the tests");
    const tests = b.addTest(
        .{
            .test_runner = std.Build.Step.Compile.TestRunner{
                .mode = .simple,
                .path = b.path("src/test-runner.zig"),
            },
            .root_module = scrapli,
        },
    );

    tests.root_module.addImport("scrapli", scrapli);

    const unit_test_flag = flags.parseCustomFlag("--unit", true);
    const integration_test_flag = flags.parseCustomFlag("--integration", false);
    const functional_test_flag = flags.parseCustomFlag("--functional", false);
    const record_flag = flags.parseCustomFlag("--record", false);
    const update_flag = flags.parseCustomFlag("--update", false);
    const coverage_flag = flags.parseCustomFlag("--coverage", false);
    const is_ci_flag = flags.parseCustomFlag("--ci", false);

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

        const run_coverage = b.addSystemCommand(
            &.{
                "kcov",
                "--clean",
                exclude,
                "--include-pattern=src/",
                // exclude "vendored" deps
                "--exclude-pattern=lib/",
                b.pathJoin(&.{ b.install_path, "cover" }),
            },
        );

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

        if (is_ci_flag) {
            run_coverage.addArg("--ci");
        }

        test_step.dependOn(&run_coverage.step);
    } else {
        const tests_run = b.addRunArtifact(tests);

        if (!unit_test_flag) {
            tests_run.addArg("--unit");
        }

        if (integration_test_flag) {
            tests_run.addArg("--integration");
        }

        if (record_flag) {
            tests_run.addArg("--record");
        }

        if (functional_test_flag) {
            tests_run.addArg("--functional");
        }

        if (update_flag) {
            tests_run.addArg("--update");
        }

        if (is_ci_flag) {
            tests_run.addArg("--ci");
        }

        test_step.dependOn(&tests_run.step);
    }
}

fn buildMain(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    scrapli: *std.Build.Module,
) !void {
    const main = b.step("main", "Build main.zig executable");
    const exe_mod = b.createModule(
        .{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        },
    );

    const main_exe = b.addExecutable(
        .{
            .name = "scrapli",
            .root_module = exe_mod,
        },
    );

    main_exe.root_module.addImport("scrapli", scrapli);

    const exe_target_output = b.addInstallArtifact(main_exe, .{});

    main.dependOn(&exe_target_output.step);
}

fn buildExamples(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    scrapli: *std.Build.Module,
) !void {
    const example = b.step("examples", "Build example binaries");

    for (examples) |ex| {
        const ex_mod = b.createModule(
            .{
                .root_source_file = b.path(
                    b.pathJoin(&[_][]const u8{ "examples", ex, "main.zig" }),
                ),
                .target = target,
                .optimize = optimize,
            },
        );

        const ex_exe = b.addExecutable(
            .{
                .name = ex,
                .root_module = ex_mod,
            },
        );

        ex_exe.root_module.addImport("scrapli", scrapli);

        const exe_target_output = b.addInstallArtifact(
            ex_exe,
            .{
                .dest_dir = .{
                    .override = .{
                        .custom = "examples",
                    },
                },
            },
        );

        example.dependOn(&exe_target_output.step);
    }
}

fn buildScrapliFFI(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Module {
    const pcre2 = getPcre2Dep(b, target, optimize);
    const libssh2 = getLibssh2Dep(b, target, optimize);
    const yaml = getZigYamlDep(b, target, optimize);
    const xml = getZigXmlDep(b, target, optimize);

    const scrapli = b.addModule(
        "scrapli",
        .{
            .root_source_file = b.path("src/ffi-root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "yaml",
                    .module = yaml.module("yaml"),
                },
                .{
                    .name = "xml",
                    .module = xml.module("xml"),
                },
            },
        },
    );

    scrapli.linkLibrary(pcre2.artifact("pcre2-8"));
    scrapli.linkLibrary(libssh2.artifact("ssh2"));

    return scrapli;
}

fn genFfiLibOutputDir(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
) ![]const u8 {
    const target = lib.rootModuleTarget();

    switch (target.os.tag) {
        .macos => {
            return std.fmt.allocPrint(
                b.allocator,
                "{s}-{s}",
                .{
                    @tagName(target.cpu.arch),
                    @tagName(target.os.tag),
                },
            );
        },
        else => {
            return std.fmt.allocPrint(
                b.allocator,
                "{s}-{s}-{s}",
                .{
                    @tagName(target.cpu.arch),
                    @tagName(target.os.tag),
                    @tagName(target.abi),
                },
            );
        },
    }
}

fn genFfiLibOutputName(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
) ![]const u8 {
    switch (lib.rootModuleTarget().os.tag) {
        .macos => {
            const base_name = try std.fmt.allocPrint(
                b.allocator,
                "libscrapli.{d}.{d}.{d}",
                .{
                    version.major,
                    version.minor,
                    version.patch,
                },
            );
            defer b.allocator.free(base_name);

            if (version.pre) |pre| {
                return std.fmt.allocPrint(
                    b.allocator,
                    "{s}-{s}.dylib",
                    .{
                        base_name,
                        pre,
                    },
                );
            }

            return std.fmt.allocPrint(
                b.allocator,
                "{s}.dylib",
                .{
                    base_name,
                },
            );
        },
        else => {
            const base_name = try std.fmt.allocPrint(
                b.allocator,
                "libscrapli.so.{d}.{d}.{d}",
                .{
                    version.major,
                    version.minor,
                    version.patch,
                },
            );

            if (version.pre) |pre| {
                defer b.allocator.free(base_name);

                return std.fmt.allocPrint(
                    b.allocator,
                    "{s}-{s}",
                    .{
                        base_name,
                        pre,
                    },
                );
            }

            return base_name;
        },
    }
}

fn buildFFI(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const ffi = b.step("ffi", "Build libscrapli ffi objects");

    const all_targets = flags.parseCustomFlag("--all-targets", false);

    if (!all_targets) {
        try buildFFITarget(b, ffi, target, optimize);

        return;
    }

    for (ffi_targets) |ffi_target| {
        try buildFFITarget(b, ffi, b.resolveTargetQuery(ffi_target), optimize);
    }
}

fn buildFFITarget(
    b: *std.Build,
    ffi: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const libscrapli = b.addLibrary(
        .{
            .name = "scrapli",
            .root_module = try buildScrapliFFI(b, target, optimize),
            .linkage = .dynamic,
        },
    );

    const ffi_obj = b.addInstallArtifact(
        libscrapli,
        .{
            .dest_dir = .{
                .override = .{
                    .custom = try genFfiLibOutputDir(b, libscrapli),
                },
            },
            .dest_sub_path = try genFfiLibOutputName(b, libscrapli),
            .dylib_symlinks = false,
        },
    );

    ffi.dependOn(&ffi_obj.step);
}
