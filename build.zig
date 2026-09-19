const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("ultracdc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "ultracdc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ultracdc", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addArgs(b.args orelse &.{});

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const bench_find = b.addExecutable(.{
        .name = "benchmark_find",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark_find.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "ultracdc", .module = mod },
            },
        }),
    });
    b.installArtifact(bench_find);

    const bench_find_step = b.step("bench-find", "Run find() benchmark");
    const bench_find_cmd = b.addRunArtifact(bench_find);
    bench_find_step.dependOn(&bench_find_cmd.step);
    bench_find_cmd.step.dependOn(b.getInstallStep());
}
