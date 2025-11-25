const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("linenoise", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const keycode_exe = b.addExecutable(.{
        .name = "keycode-print",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/keycodes.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "linenoise", .module = mod },
            },
        }),
    });

    const demo_exe = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(
            .{
                .root_source_file = b.path("src/demo.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "linenoise", .module = mod },
                },
            },
        ),
    });

    b.installArtifact(keycode_exe);
    b.installArtifact(demo_exe);

    const run_keycode_print_step = b.step("keycode-print", "Run keycode printer");
    const run_keycode_print_cmd = b.addRunArtifact(keycode_exe);
    run_keycode_print_step.dependOn(&run_keycode_print_cmd.step);
    run_keycode_print_cmd.step.dependOn(b.getInstallStep());

    const run_demo_step = b.step("demo", "Run demo");
    const run_demo_cmd = b.addRunArtifact(demo_exe);
    run_demo_step.dependOn(&run_demo_cmd.step);
    run_demo_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_keycode_print_cmd.addArgs(args);
        run_demo_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
