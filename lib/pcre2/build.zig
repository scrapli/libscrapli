const std = @import("std");

pub const CodeUnitWidth = enum {
    @"8",
    @"16",
    @"32",
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // super janky, but lets us be decoupled from upstream (because even if we used upstream as
    // a dep and then tried to tweak it we would still be hosed if/until they update zig versions
    // and stuff).
    const proc = std.process.Child.run(
        .{
            .cwd = b.build_root.path orelse ".",
            .argv = &[_][]const u8{"./generate.sh"},
            .allocator = b.allocator,
        },
    ) catch {
        return std.Build.RunError.ExitCodeFailure;
    };

    if (proc.term.Exited != 0) {
        return std.Build.RunError.ExitCodeFailure;
    }

    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "whether to statically or dynamically link the library",
    ) orelse @as(std.builtin.LinkMode, if (target.result.isGnuLibC()) .dynamic else .static);
    const codeUnitWidth = b.option(
        CodeUnitWidth,
        "code-unit-width",
        "Sets the code unit width",
    ) orelse .@"8";

    const pcre2_header_dir = b.addWriteFiles();
    const pcre2_header = pcre2_header_dir.addCopyFile(
        b.path("pcre2/src/pcre2.h.generic"),
        "pcre2.h",
    );

    const config_header = b.addConfigHeader(
        .{
            .style = .{ .cmake = b.path("pcre2/config-cmake.h.in") },
            .include_path = "config.h",
        },
        .{
            .HAVE_ASSERT_H = true,
            .HAVE_UNISTD_H = (target.result.os.tag != .windows),
            .HAVE_WINDOWS_H = (target.result.os.tag == .windows),

            .HAVE_MEMMOVE = true,
            .HAVE_STRERROR = true,

            .SUPPORT_PCRE2_8 = codeUnitWidth == CodeUnitWidth.@"8",
            .SUPPORT_PCRE2_16 = codeUnitWidth == CodeUnitWidth.@"16",
            .SUPPORT_PCRE2_32 = codeUnitWidth == CodeUnitWidth.@"32",
            .SUPPORT_UNICODE = true,

            .PCRE2_EXPORT = null,
            .PCRE2_LINK_SIZE = 2,
            .PCRE2_HEAP_LIMIT = 20000000,
            .PCRE2_MATCH_LIMIT = 10000000,
            .PCRE2_MATCH_LIMIT_DEPTH = "MATCH_LIMIT",
            .PCRE2_MAX_VARLOOKBEHIND = 255,
            .NEWLINE_DEFAULT = 2,
            .PCRE2_PARENS_NEST_LIMIT = 250,

            .PCRE2GREP_BUFSIZE = 20480,
            .PCRE2GREP_MAX_BUFSIZE = 1048576,
        },
    );

    // pcre2-8/16/32.so

    const lib = b.addStaticLibrary(
        .{
            .name = b.fmt("pcre2-{s}", .{@tagName(codeUnitWidth)}),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        },
    );

    lib.root_module.addCMacro("HAVE_CONFIG_H", "");
    lib.root_module.addCMacro("PCRE2_CODE_UNIT_WIDTH", @tagName(codeUnitWidth));
    if (linkage == .static) {
        lib.root_module.addCMacro("PCRE2_STATIC", "");
    }

    lib.addConfigHeader(config_header);
    lib.addIncludePath(pcre2_header_dir.getDirectory());
    lib.addIncludePath(b.path("pcre2/src"));

    lib.addCSourceFile(.{
        .file = b.addWriteFiles().addCopyFile(
            b.path("pcre2/src/pcre2_chartables.c.dist"),
            "pcre2_chartables.c",
        ),
    });

    lib.addCSourceFiles(
        .{
            .flags = &.{
                "-fPIC",
            },
            .files = &.{
                "pcre2/src/pcre2_auto_possess.c",
                "pcre2/src/pcre2_chkdint.c",
                "pcre2/src/pcre2_compile.c",
                "pcre2/src/pcre2_compile_class.c",
                "pcre2/src/pcre2_config.c",
                "pcre2/src/pcre2_context.c",
                "pcre2/src/pcre2_convert.c",
                "pcre2/src/pcre2_dfa_match.c",
                "pcre2/src/pcre2_error.c",
                "pcre2/src/pcre2_extuni.c",
                "pcre2/src/pcre2_find_bracket.c",
                "pcre2/src/pcre2_jit_compile.c",
                "pcre2/src/pcre2_maketables.c",
                "pcre2/src/pcre2_match.c",
                "pcre2/src/pcre2_match_data.c",
                "pcre2/src/pcre2_newline.c",
                "pcre2/src/pcre2_ord2utf.c",
                "pcre2/src/pcre2_pattern_info.c",
                "pcre2/src/pcre2_script_run.c",
                "pcre2/src/pcre2_serialize.c",
                "pcre2/src/pcre2_string_utils.c",
                "pcre2/src/pcre2_study.c",
                "pcre2/src/pcre2_substitute.c",
                "pcre2/src/pcre2_substring.c",
                "pcre2/src/pcre2_tables.c",
                "pcre2/src/pcre2_ucd.c",
                "pcre2/src/pcre2_valid_utf.c",
                "pcre2/src/pcre2_xclass.c",
            },
        },
    );

    lib.installHeader(pcre2_header, "pcre2.h");
    b.installArtifact(lib);
}
