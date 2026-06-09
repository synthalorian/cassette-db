const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------
    // CLI executable
    // -----------------------------------------------------------------
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "cassette-db",
        .root_module = root_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run cassette-db");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // -----------------------------------------------------------------
    // C ABI static library
    // -----------------------------------------------------------------
    const c_abi_mod = b.createModule(.{
        .root_source_file = b.path("src/cassette_c.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "cassette",
        .root_module = c_abi_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Also ship the public C header alongside the library.
    lib.installHeader(b.path("include/cassette.h"), "cassette.h");

    // Stand-alone test target for the C ABI module (not part of the default
    // `test` step to avoid file-name collisions with the main test binary).
    const c_abi_tests = b.addTest(.{
        .root_module = c_abi_mod,
    });

    const run_c_abi_tests = b.addRunArtifact(c_abi_tests);
    const c_abi_test_step = b.step("test-c-abi", "Run C ABI unit tests");
    c_abi_test_step.dependOn(&run_c_abi_tests.step);
}
