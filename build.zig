const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "agent version") orelse "0.0.1";
    const coverage = b.option(bool, "coverage", "Run tests through kcov") orelse false;
    const coverage_dir = b.option([]const u8, "coverage-dir", "kcov output directory") orelse "zig-out/coverage";
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);
    const runtime_module = b.createModule(.{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    const compat_module = b.createModule(.{
        .root_source_file = b.path("src/compat.zig"),
        .target = target,
        .optimize = optimize,
    });
    compat_module.addImport("runtime", runtime_module);
    const net_module = b.createModule(.{
        .root_source_file = b.path("src/net.zig"),
        .target = target,
        .optimize = optimize,
    });
    const debug_module = b.createModule(.{
        .root_source_file = b.path("src/protocol/debug.zig"),
        .target = target,
        .optimize = optimize,
    });
    const enable_crash_trace = !(target.result.os.tag == .freebsd and target.result.cpu.arch == .x86);
    const crash_trace_options = .{
        .strip = false,
        .unwind_tables = if (enable_crash_trace) std.builtin.UnwindTables.sync else std.builtin.UnwindTables.none,
        .omit_frame_pointer = !enable_crash_trace,
        .error_tracing = enable_crash_trace,
    };

    const exe = b.addExecutable(.{
        .name = "komari-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = crash_trace_options.strip,
            .unwind_tables = crash_trace_options.unwind_tables,
            .omit_frame_pointer = crash_trace_options.omit_frame_pointer,
            .error_tracing = crash_trace_options.error_tracing,
        }),
    });
    exe.root_module.addOptions("build_options", opts);
    exe.root_module.addImport("runtime", runtime_module);
    addCompatImports(exe.root_module, compat_module, net_module);
    exe.root_module.addImport("debug", debug_module);
    if (target.result.os.tag == .linux or target.result.os.tag == .freebsd or target.result.os.tag == .macos) {
        exe.root_module.linkSystemLibrary("c", .{});
    }
    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("advapi32", .{});
        exe.root_module.linkSystemLibrary("iphlpapi", .{});
    }
    const exe_idna = b.createModule(.{
        .root_source_file = b.path("src/idna.zig"),
        .target = target,
        .optimize = optimize,
        .strip = crash_trace_options.strip,
        .unwind_tables = crash_trace_options.unwind_tables,
        .omit_frame_pointer = crash_trace_options.omit_frame_pointer,
        .error_tracing = crash_trace_options.error_tracing,
    });
    const exe_dns = b.createModule(.{
        .root_source_file = b.path("src/dns.zig"),
        .target = target,
        .optimize = optimize,
        .strip = crash_trace_options.strip,
        .unwind_tables = crash_trace_options.unwind_tables,
        .omit_frame_pointer = crash_trace_options.omit_frame_pointer,
        .error_tracing = crash_trace_options.error_tracing,
    });
    addCompatImports(exe_dns, compat_module, net_module);
    exe.root_module.addImport("idna", exe_idna);
    exe.root_module.addImport("dns", exe_dns);
    const exe_report_netstatic = b.createModule(.{
        .root_source_file = b.path("src/report/netstatic.zig"),
        .target = target,
        .optimize = optimize,
        .strip = crash_trace_options.strip,
        .unwind_tables = crash_trace_options.unwind_tables,
        .omit_frame_pointer = crash_trace_options.omit_frame_pointer,
        .error_tracing = crash_trace_options.error_tracing,
    });
    addCompatImports(exe_report_netstatic, compat_module, net_module);
    exe.root_module.addImport("report_netstatic", exe_report_netstatic);
    b.installArtifact(exe);

    if (b.option(bool, "dsm-ui", "Build the DSM configuration CGI") orelse false) {
        if (target.result.os.tag != .linux) @panic("DSM UI requires a Linux target");
        const dsm = b.addExecutable(.{
            .name = "komari-dsm-api.cgi",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/dsm_cgi.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        dsm.root_module.addImport("compat", compat_module);
        dsm.root_module.addImport("runtime", runtime_module);
        const dsm_opts = b.addOptions();
        // Test paths are compile-time only; production does not accept environment overrides.
        const test_root = b.option([]const u8, "dsm-test-root", "Compile an isolated CGI test fixture (never distribute)");
        dsm_opts.addOption([]const u8, "root", test_root orelse "/var/packages/komari-agent");
        dsm_opts.addOption([]const u8, "auth", if (test_root) |p| b.fmt("{s}/authenticate", .{p}) else "/usr/syno/synoman/webman/modules/authenticate.cgi");
        dsm_opts.addOption([]const u8, "id", if (test_root) |p| b.fmt("{s}/id", .{p}) else "/usr/bin/id");
        dsm.root_module.addOptions("dsm_options", dsm_opts);
        b.installArtifact(dsm);
    }

    const version_module = b.createModule(.{
        .root_source_file = b.path("src/version.zig"),
        .target = target,
        .optimize = optimize,
    });
    version_module.addOptions("build_options", opts);

    const test_step = b.step("test", "Run unit tests");
    const test_paths = [_][]const u8{
        "test/bootstrap_test.zig",
        "test/config_test.zig",
        "test/protocol_json_test.zig",
        "src/autodiscovery_test.zig",
        "test/http_test.zig",
        "test/dns_idna_test.zig",
        "test/basic_info_flow_test.zig",
        "test/linux_basic_info_test.zig",
        "test/freebsd_basic_info_test.zig",
        "src/platform/gpu.zig",
        "test/windows_provider_test.zig",
        "test/disk_filter_test.zig",
        "test/network_filter_test.zig",
        "test/cpu_proc_test.zig",
        "test/ip_extract_test.zig",
        "test/coverage_test.zig",
        "test/v2_state_test.zig",
        "test/ws_client_test.zig",
        "test/raw_conn_test.zig",
        "test/raw_errno_test.zig",
        "test/thread_stack_test.zig",
        "test/report_interval_test.zig",
        "test/netstatic_test.zig",
    };
    for (test_paths) |test_path| {
        addTest(b, test_step, test_path, target, optimize, opts, version_module, compat_module, net_module, debug_module, coverage, coverage_dir);
    }
    addStandaloneV2Test(b, test_step, "basic_info_v2_test.zig", target, optimize, opts, compat_module, net_module, debug_module);
}

fn addCompatImports(module: *std.Build.Module, compat_module: *std.Build.Module, net_module: *std.Build.Module) void {
    module.addImport("compat", compat_module);
    module.addImport("net", net_module);
}

fn addTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    opts: *std.Build.Step.Options,
    version_module: *std.Build.Module,
    compat_module: *std.Build.Module,
    net_module: *std.Build.Module,
    debug_module: *std.Build.Module,
    coverage: bool,
    coverage_dir: []const u8,
) void {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", opts);
    addCompatImports(tests.root_module, compat_module, net_module);
    tests.root_module.addImport("debug", debug_module);
    // Match the shipped binaries, which always link libc. Without this the suite runs
    // with `builtin.link_libc == false`, where `std.posix.errno` resolves to the
    // correct `std.os.linux.errno` and whole classes of libc-dependent bugs (see
    // test/raw_errno_test.zig) become invisible to the tests.
    if (target.result.os.tag != .windows) {
        tests.root_module.link_libc = true;
    }
    const report_netstatic = b.createModule(.{
        .root_source_file = b.path("src/report/netstatic.zig"),
        .target = target,
        .optimize = optimize,
    });
    addCompatImports(report_netstatic, compat_module, net_module);
    if (target.result.os.tag == .windows) {
        tests.root_module.linkSystemLibrary("advapi32", .{});
        tests.root_module.linkSystemLibrary("iphlpapi", .{});
        const platform_provider = b.createModule(.{
            .root_source_file = b.path("src/platform/provider.zig"),
            .target = target,
            .optimize = optimize,
        });
        addCompatImports(platform_provider, compat_module, net_module);
        platform_provider.addImport("debug", debug_module);
        platform_provider.addImport("report_netstatic", report_netstatic);
        tests.root_module.addImport("platform_provider", platform_provider);
    }
    tests.root_module.addImport("version", version_module);
    tests.root_module.addImport("thread_stacks", b.createModule(.{
        .root_source_file = b.path("src/thread_stacks.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const config_module = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_module.addImport("compat", compat_module);
    tests.root_module.addImport("config", config_module);
    tests.root_module.addImport("protocol_types", b.createModule(.{
        .root_source_file = b.path("src/protocol/types.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const idna_module = b.createModule(.{
        .root_source_file = b.path("src/idna.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dns_module = b.createModule(.{
        .root_source_file = b.path("src/dns.zig"),
        .target = target,
        .optimize = optimize,
    });
    addCompatImports(dns_module, compat_module, net_module);
    const protocol_http = b.createModule(.{
        .root_source_file = b.path("src/protocol/http.zig"),
        .target = target,
        .optimize = optimize,
    });
    addCompatImports(protocol_http, compat_module, net_module);
    protocol_http.addImport("debug", debug_module);
    protocol_http.addImport("idna", idna_module);
    protocol_http.addImport("dns", dns_module);
    tests.root_module.addImport("protocol_http", protocol_http);
    const protocol_raw_conn = b.createModule(.{
        .root_source_file = b.path("src/protocol/raw_conn.zig"),
        .target = target,
        .optimize = optimize,
    });
    addCompatImports(protocol_raw_conn, compat_module, net_module);
    protocol_raw_conn.addImport("debug", debug_module);
    protocol_raw_conn.addImport("dns", dns_module);
    tests.root_module.addImport("protocol_raw_conn", protocol_raw_conn);
    tests.root_module.addImport("dns", dns_module);
    tests.root_module.addImport("idna", idna_module);
    tests.root_module.addImport("basic_info_flow", b.createModule(.{
        .root_source_file = b.path("src/basic_info_flow.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const platform_linux = b.createModule(.{
        .root_source_file = b.path("src/platform/linux.zig"),
        .target = target,
        .optimize = optimize,
    });
    addCompatImports(platform_linux, compat_module, net_module);
    platform_linux.addImport("debug", debug_module);
    platform_linux.addImport("report_netstatic", report_netstatic);
    tests.root_module.addImport("platform_linux", platform_linux);
    const platform_freebsd = b.createModule(.{
        .root_source_file = b.path("src/platform/freebsd.zig"),
        .target = target,
        .optimize = optimize,
    });
    addCompatImports(platform_freebsd, compat_module, net_module);
    platform_freebsd.addImport("debug", debug_module);
    platform_freebsd.addImport("report_netstatic", report_netstatic);
    tests.root_module.addImport("platform_freebsd", platform_freebsd);
    const protocol_ip = b.createModule(.{
        .root_source_file = b.path("src/protocol/ip.zig"),
        .target = target,
        .optimize = optimize,
    });
    addCompatImports(protocol_ip, compat_module, net_module);
    protocol_ip.addImport("debug", debug_module);
    protocol_ip.addImport("idna", idna_module);
    protocol_ip.addImport("dns", dns_module);
    tests.root_module.addImport("protocol_ip", protocol_ip);
    tests.root_module.addImport("protocol_v2_state", b.createModule(.{
        .root_source_file = b.path("src/protocol/v2_state.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const protocol_ws_client = b.createModule(.{
        .root_source_file = b.path("src/protocol/ws_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    addCompatImports(protocol_ws_client, compat_module, net_module);
    protocol_ws_client.addImport("debug", debug_module);
    protocol_ws_client.addImport("idna", idna_module);
    protocol_ws_client.addImport("dns", dns_module);
    tests.root_module.addImport("protocol_ws_client", protocol_ws_client);
    tests.root_module.addImport("protocol_report_timing", b.createModule(.{
        .root_source_file = b.path("src/protocol/report_timing.zig"),
        .target = target,
        .optimize = optimize,
    }));
    tests.root_module.addImport("report_netstatic", report_netstatic);

    const collect_coverage = coverage and isCoverageTest(path);
    if (collect_coverage) {
        tests.use_llvm = true;

        const coverage_path = coverageOutputPath(b, coverage_dir, path);
        const make_coverage_dir = b.addSystemCommand(&.{ "mkdir", "-p", coverage_path });

        const run_tests = b.addSystemCommand(&.{
            "kcov",
            "--skip-solibs",
            "--include-path=src",
            "--exclude-path=src/autodiscovery_test.zig",
            coverage_path,
        });
        run_tests.addFileArg(tests.getEmittedBin());
        run_tests.has_side_effects = true;
        run_tests.step.dependOn(&make_coverage_dir.step);
        test_step.dependOn(&run_tests.step);
        return;
    }

    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}

fn addStandaloneV2Test(
    b: *std.Build,
    test_step: *std.Build.Step,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    opts: *std.Build.Step.Options,
    compat_module: *std.Build.Module,
    net_module: *std.Build.Module,
    debug_module: *std.Build.Module,
) void {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", opts);
    addCompatImports(tests.root_module, compat_module, net_module);
    tests.root_module.addImport("debug", debug_module);
    const idna_module = b.createModule(.{
        .root_source_file = b.path("src/idna.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dns_module = b.createModule(.{
        .root_source_file = b.path("src/dns.zig"),
        .target = target,
        .optimize = optimize,
    });
    addCompatImports(dns_module, compat_module, net_module);
    tests.root_module.addImport("idna", idna_module);
    tests.root_module.addImport("dns", dns_module);
    const report_netstatic = b.createModule(.{
        .root_source_file = b.path("src/report/netstatic.zig"),
        .target = target,
        .optimize = optimize,
    });
    addCompatImports(report_netstatic, compat_module, net_module);
    tests.root_module.addImport("report_netstatic", report_netstatic);
    if (target.result.os.tag == .windows) {
        tests.root_module.linkSystemLibrary("advapi32", .{});
        tests.root_module.linkSystemLibrary("iphlpapi", .{});
    }

    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}

fn isCoverageTest(test_path: []const u8) bool {
    return std.mem.eql(u8, test_path, "test/coverage_test.zig");
}

fn coverageOutputPath(b: *std.Build, coverage_dir: []const u8, test_path: []const u8) []const u8 {
    const name = b.dupe(test_path);
    for (name) |*ch| switch (ch.*) {
        '/', '\\', '.' => ch.* = '_',
        else => {},
    };
    return b.fmt("{s}/{s}", .{ coverage_dir, name });
}
