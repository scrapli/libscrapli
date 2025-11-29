const std = @import("std");

const version = std.SemanticVersion{
    // set on release in ci
    .major = 0,
    .minor = 0,
    .patch = 0,
    .pre = null,
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

    const dependency_linkage = b.option(
        std.builtin.LinkMode,
        "dependency-linkage",
        "static/dynamic linkage for libssh2/pcre2",
    ) orelse .static;

    const scrapli = try buildScrapli(
        b,
        target,
        optimize,
        dependency_linkage,
        false,
    );

    try buildCheck(b, scrapli);
    // try buildZlinter(b);
    try buildTests(b, scrapli);
    try buildMain(b, target, optimize, scrapli);
    try buildExamples(b, target, optimize, scrapli);
    try buildFFI(b, target, optimize, dependency_linkage);
}

fn buildScrapli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dependency_linkage: std.builtin.LinkMode,
    is_ffi: bool,
) !*std.Build.Module {
    const root_source_file = if (is_ffi) "src/ffi-root.zig" else "src/root.zig";

    const scrapli = b.addModule(
        "scrapli",
        .{
            .root_source_file = b.path(root_source_file),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "yaml",
                    .module = b.dependency(
                        "yaml",
                        .{
                            .target = target,
                            .optimize = optimize,
                        },
                    ).module("yaml"),
                },
                .{
                    .name = "xml",
                    .module = b.dependency(
                        "xml",
                        .{
                            .target = target,
                            .optimize = optimize,
                        },
                    ).module("xml"),
                },
            },
            .link_libc = true,
        },
    );

    switch (dependency_linkage) {
        .static => {
            scrapli.linkLibrary(
                b.dependency(
                    "pcre2",
                    .{
                        .target = target,
                        .optimize = optimize,
                    },
                ).artifact("pcre2-8"),
            );
            scrapli.linkLibrary(
                b.dependency(
                    "libssh2",
                    .{
                        .target = target,
                        .optimize = optimize,
                    },
                ).artifact("ssh2"),
            );
        },
        else => {
            // always include our patched libssh2 header first, this fixes a translate-c issue
            // that resulted in a struct having the same field twice which caused the linker to
            // fail in very confusing ways!
            scrapli.addIncludePath(
                .{
                    .cwd_relative = "./lib/libssh2/include",
                },
            );

            if (target.result.os.tag == .macos) {
                if (target.result.cpu.arch == .aarch64) {
                    // arm homebrew paths
                    scrapli.addIncludePath(
                        .{
                            .cwd_relative = "/opt/homebrew/include",
                        },
                    );
                    scrapli.addLibraryPath(
                        .{
                            .cwd_relative = "/opt/homebrew/lib",
                        },
                    );
                } else if (target.result.cpu.arch == .x86_64) {
                    scrapli.addIncludePath(
                        .{
                            .cwd_relative = "/usr/local/include",
                        },
                    );
                    scrapli.addLibraryPath(
                        .{
                            .cwd_relative = "/usr/local/lib",
                        },
                    );
                }
            }

            scrapli.linkSystemLibrary("pcre2-8", .{});
            scrapli.linkSystemLibrary("ssh2", .{});
        },
    }

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

fn buildZlinter(
    b: *std.Build,
) !void {
    const zlinter = @import("zlinter");
    const lint_cmd = b.step("lint", "Lint source code.");

    lint_cmd.dependOn(
        step: {
            var builder = zlinter.builder(b, .{});

            builder.addPaths(
                .{
                    .exclude = &.{
                        b.path(".private/"),
                        b.path("main.zig"),
                        b.path("lib/"),
                    },
                },
            );

            inline for (@typeInfo(zlinter.BuiltinLintRule).@"enum".fields) |f| {
                const rule: zlinter.BuiltinLintRule = @enumFromInt(f.value);

                switch (rule) {
                    .function_naming => {
                        builder.addRule(
                            .{
                                .builtin = .function_naming,
                            },
                            .{
                                .exclude_export = true,
                            },
                        );
                    },
                    else => {
                        builder.addRule(
                            .{
                                .builtin = @enumFromInt(f.value),
                            },
                            .{},
                        );
                    },
                }
            }

            break :step builder.build();
        },
    );
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

    const unit_tests = b.option(
        bool,
        "unit-tests",
        "true/false execute unit tests",
    ) orelse true;

    const integration_tests = b.option(
        bool,
        "integration-tests",
        "true/false execute integration tests",
    ) orelse false;

    const functional_tests = b.option(
        bool,
        "functional-tests",
        "true/false execute functional tests",
    ) orelse false;

    const record_test_fixtures = b.option(
        bool,
        "record-test-fixtures",
        "true/false record (integration/functional) test fixture data",
    ) orelse false;

    const update_test_golden = b.option(
        bool,
        "update-test-golden",
        "true/false update test golden data",
    ) orelse false;

    const test_coverage = b.option(
        bool,
        "test-coverage",
        "true/false record test coverage",
    ) orelse false;

    const ci_functional_tests = b.option(
        bool,
        "ci-functional-tests",
        "true/false only execute functional tests available in ci",
    ) orelse false;

    if (test_coverage) {
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

        if (!unit_tests) {
            run_coverage.addArg("--unit");
        }

        if (integration_tests) {
            run_coverage.addArg("--integration");
        }

        if (record_test_fixtures) {
            run_coverage.addArg("--record");
        }

        if (functional_tests) {
            run_coverage.addArg("--functional");
        }

        if (update_test_golden) {
            run_coverage.addArg("--update");
        }

        if (ci_functional_tests) {
            run_coverage.addArg("--ci");
        }

        test_step.dependOn(&run_coverage.step);
    } else {
        const tests_run = b.addRunArtifact(tests);

        if (!unit_tests) {
            tests_run.addArg("--unit");
        }

        if (integration_tests) {
            tests_run.addArg("--integration");
        }

        if (record_test_fixtures) {
            tests_run.addArg("--record");
        }

        if (functional_tests) {
            tests_run.addArg("--functional");
        }

        if (update_test_golden) {
            tests_run.addArg("--update");
        }

        if (ci_functional_tests) {
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
            .link_libc = true,
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
                .link_libc = true,
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

fn buildFFI(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dependency_linkage: std.builtin.LinkMode,
) !void {
    const ffi = b.step("ffi", "Build libscrapli ffi objects");

    const all_targets = b.option(
        bool,
        "all-targets",
        "true/false build all targets",
    ) orelse false;

    if (!all_targets) {
        try buildFFITarget(b, ffi, target, optimize, dependency_linkage);

        return;
    }

    for (ffi_targets) |ffi_target| {
        try buildFFITarget(b, ffi, b.resolveTargetQuery(ffi_target), optimize, dependency_linkage);
    }
}

fn buildFFITarget(
    b: *std.Build,
    ffi: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dependency_linkage: std.builtin.LinkMode,
) !void {
    const libscrapli = b.addLibrary(
        .{
            .name = "scrapli",
            .root_module = try buildScrapli(
                b,
                target,
                optimize,
                dependency_linkage,
                true,
            ),
            // *our* output is always a dynamic library that ctypes/purego can load, our *deps*
            // may be static or dynamically linked though
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
