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

    const gen_models_exe = b.addExecutable(.{
        .name = "gen_models",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_models.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    const gen_models_run = b.addRunArtifact(gen_models_exe);
    gen_models_run.setCwd(b.path("."));
    gen_models_run.addArg("data/models.json");
    gen_models_run.addArg("src/providers/models/table.zig");
    gen_models_run.addFileInput(b.path("data/models.json"));

    const gen_models_step = b.step("gen-models", "Regenerate src/providers/models/table.zig from data/models.json");
    gen_models_step.dependOn(&gen_models_run.step);

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
    exe.step.dependOn(&gen_models_run.step);

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
            .link_libc = true,
        }),
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.setEnvironmentVariable("OMFX_HEADLESS", "1");

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "omfx", .module = mod },
            },
        }),
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.setEnvironmentVariable("OMFX_HEADLESS", "1");

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
    fmt_step.dependOn(&b.addFmt(.{ .paths = &.{ "src", "tools", "build.zig" }, .check = true }).step);

    const e2e_offline = b.addSystemCommand(&.{
        "bash", "-c", "OMFX_E2E_OFFLINE=1 python3 scripts/e2e.py",
    });
    e2e_offline.setCwd(b.path("."));
    e2e_offline.step.dependOn(b.getInstallStep());
    const e2e_offline_step = b.step("e2e-offline", "Run offline end-to-end harness");
    e2e_offline_step.dependOn(&e2e_offline.step);
}
