const std = @import("std");

const frameworks = [_][]const u8{ "AppKit", "WebKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "CoreFoundation", "Foundation", "ImageIO", "UniformTypeIdentifiers", "CoreVideo", "ApplicationServices" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options_step = b.addOptions();
    options_step.addOption([]const u8, "version", "0.1.0");
    options_step.addOption(bool, "portable", false);

    // Import nanoui module from nanoui-src
    const nanoui_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "/Users/martinfan/devv/nanoui-src/src/nanoui.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nanoui_mod.addOptions("build_options", options_step);

    for (frameworks) |f| {
        nanoui_mod.linkFramework(f, .{});
    }
    nanoui_mod.linkSystemLibrary("objc", .{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "popzlip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "nanoui", .module = nanoui_mod },
            },
        }),
    });
    for (frameworks) |f| {
        exe.root_module.linkFramework(f, .{});
    }
    exe.root_module.linkSystemLibrary("objc", .{});

    b.installArtifact(exe);

    // Shared library for XCTest and C callers
    const lib = b.addLibrary(.{
        .name = "zigpopclip",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(lib);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run PopClip Zig");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/actions.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
