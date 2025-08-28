const std = @import("std");

const flags = @import("src/flags.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scrapli = try buildScrapli(b, target, optimize);

    try buildCheck(b, scrapli);
    try buildTests(b, scrapli);
    try buildMain(b, target, optimize, scrapli);
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
