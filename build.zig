const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Product binary: ReleaseFast unless -Doptimize= is set. Tests stay Debug (GPA).
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast;
    const test_optimize: std.builtin.OptimizeMode = .Debug;

    // libc is a link-time dependency, not a source one: `tty.zig` calls
    // tcsetattr and the sandbox path uses the C errno table. On the host it is
    // linked implicitly; a cross build has to be told.
    const mod = b.addModule("omfx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "omfx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "omfx", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run omfx");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = test_optimize,
        }),
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = test_optimize,
            .imports = &.{
                .{ .name = "omfx", .module = mod },
            },
        }),
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const wasm = b.addLibrary(.{
        .name = "omfx-core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_root.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi }),
            .optimize = optimize,
        }),
    });
    const wasm_step = b.step("wasm", "Build wasm32-wasi core (no HTTP)");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);

    const fmt_step = b.step("fmt", "Check formatting");
    fmt_step.dependOn(&b.addFmt(.{ .paths = &.{ "src", "build.zig" }, .check = true }).step);
}
