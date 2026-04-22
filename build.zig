const std = @import("std");
const builtin = @import("builtin");

const VERSION = @import("build.zig.zon").version;
const SO_VERSION: std.SemanticVersion = .{ .major = 0, .minor = 5, .patch = 0 };

const common_flags = &[_][]const u8{
    "-std=gnu11",
    "-fvisibility=hidden",
    "-pthread",
};

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const linkage = b.option(std.builtin.LinkMode, "linkage", "static vs dynamic linkage (Default: static)") orelse .static;
    const system_libudev = b.option(bool, "use-system-libudev", "link with system libudev on linux (Default: false)") orelse false;
    const windows_hotplug = b.option(bool, "windows-hotplug", "enable Windows hotplug support (Default: false)") orelse false;
    const use_rc = b.option(bool, "use-rc", "use rc version of libusb (Default: false)") orelse false;

    const android_ndk_home: []const u8 =
        if (builtin.zig_version.minor > 15)
            b.graph.environ_map.get("ANDROID_NDK_HOME") orelse b.dupe("")
        else
            std.process.getEnvVarOwned(b.allocator, "ANDROID_NDK_HOME") catch b.dupe("");

    defer b.allocator.free(android_ndk_home);
    const android_ndk_path: []const u8 = b.option([]const u8, "android-ndk-path", "specify path to android ndk (Default: ANDROID_NDK_HOME env var)") orelse android_ndk_home;
    const android_api_level: []const u8 = b.option([]const u8, "android-api-level", "specify android api level (Default: 35)") orelse "35";

    const upstream =
        if (use_rc)
            b.dependency("upstream_rc", .{})
        else
            b.dependency("upstream", .{});

    const update_config_header = b.step("update-config-header", "Update the config.h.in file");
    {
        const configure_run = b.addSystemCommand(&[_][]const u8{ "autoreconf", "-fiv" });
        configure_run.setCwd(upstream.path(""));
        const install_file = b.addInstallFileWithDir(
            upstream.path("config.h.in"),
            .{ .custom = ".." },
            "config.h.in",
        );
        install_file.step.dependOn(&configure_run.step);
        update_config_header.dependOn(&install_file.step);
    }

    const build_all = b.step("all", "Build libusb for all supported targets");
    for (targets(b)) |t| {
        const lib = try createLibUsb(b, t, optimize, linkage, system_libudev, windows_hotplug, android_ndk_path, android_api_level, upstream);
        build_all.dependOn(&lib.step);
        const triple: []const u8 = b.fmt("{s}-{s}-{s}", .{ @tagName(t.result.cpu.arch), @tagName(t.result.os.tag), @tagName(t.result.abi) });
        const dest_dir_path: []const u8 = b.pathJoin(&[_][]const u8{ "lib", triple });
        const install_artifact = b.addInstallArtifact(lib, .{
            .dest_dir = .{ .override = .{ .custom = dest_dir_path } },
            .implib_dir = if (lib.producesImplib())
                .{ .override = .{ .custom = dest_dir_path } }
            else
                .default,
        });
        build_all.dependOn(&install_artifact.step);
    }

    const libusb = try createLibUsb(b, target, optimize, linkage, system_libudev, windows_hotplug, android_ndk_path, android_api_level, upstream);
    b.installArtifact(libusb);
}

fn createLibUsb(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    system_libudev: bool,
    windows_hotplug: bool,
    android_ndk_path: []const u8,
    android_api_level: []const u8,
    upstream: *std.Build.Dependency,
) !*std.Build.Step.Compile {
    const is_posix: bool =
        target.result.os.tag.isBSD() or
        target.result.os.tag == .linux;

    const lib = b.addLibrary(.{
        .name = "usb-1.0",
        .linkage = linkage,
        .version = SO_VERSION,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    if (linkage == .dynamic) {
        lib.root_module.pic = true;
        lib.root_module.addCMacro("PIC", "");
    }

    if (builtin.zig_version.minor > 15) {
        const translate_c = b.addTranslateC(.{
            .root_source_file = b.addWriteFiles().add("translate_c.h", "#include <libusb.h>"),
            .target = target,
            .optimize = optimize,
        });
        translate_c.addIncludePath(upstream.path("libusb"));
        _ = translate_c.addModule("libusb");
    }

    addCSourceFilesFromDep(lib.root_module, upstream, src);

    if (is_posix) {
        addCSourceFilesFromDep(lib.root_module, upstream, posix_platform_src);
    }

    if (target.result.os.tag.isDarwin()) {
        // TODO2: update xcode_frameworks to include IOKit/usb/IOUSBLib.h to enable crosscompiling
        if (b.lazyDependency("xcode_frameworks", .{})) |dep| {
            lib.root_module.addSystemFrameworkPath(dep.path("Frameworks"));
            lib.root_module.addSystemIncludePath(dep.path("include"));
            lib.root_module.addLibraryPath(dep.path("lib"));
        }
        addCSourceFilesFromDep(lib.root_module, upstream, darwin_src);
        lib.root_module.linkFramework("CoreFoundation", .{});
        lib.root_module.linkFramework("IOKit", .{});
        lib.root_module.linkFramework("Security", .{});
    } else if (target.result.abi.isAndroid()) {
        try setupAndroid(b, lib, target, android_ndk_path, android_api_level);
        addCSourceFilesFromDep(lib.root_module, upstream, android_src);
    } else if (target.result.os.tag == .linux) {
        addCSourceFilesFromDep(lib.root_module, upstream, linux_src);
        if (system_libudev) {
            addCSourceFilesFromDep(lib.root_module, upstream, linux_udev_src);
            lib.root_module.linkSystemLibrary("udev", .{});
        }
    } else if (target.result.os.tag == .illumos) {
        addCSourceFilesFromDep(lib.root_module, upstream, sunos_src);
    } else if (target.result.os.tag == .windows) {
        addCSourceFilesFromDep(lib.root_module, upstream, windows_src);
        if (windows_hotplug) {
            addCSourceFilesFromDep(lib.root_module, upstream, windows_hotplug_src);
        }
    } else if (target.result.os.tag == .netbsd) {
        addCSourceFilesFromDep(lib.root_module, upstream, netbsd_src);
    } else if (target.result.os.tag == .openbsd) {
        addCSourceFilesFromDep(lib.root_module, upstream, openbsd_src);
    } else if (target.result.os.tag == .haiku) {
        addCSourceFilesFromDep(lib.root_module, upstream, haiku_src);
    } else return error.UnsupportedOS;

    lib.root_module.addIncludePath(upstream.path("libusb"));
    lib.installHeader(upstream.path("libusb/libusb.h"), "libusb.h");

    // config header
    if (target.result.os.tag.isDarwin()) {
        lib.root_module.addIncludePath(upstream.path("Xcode"));
    } else if (target.result.abi == .msvc) {
        lib.root_module.addIncludePath(upstream.path("msvc"));
    } else if (target.result.abi.isAndroid()) {
        lib.root_module.addIncludePath(upstream.path("android"));
    } else {
        const config_h = b.addConfigHeader(.{
            .style = .{
                .autoconf_undef = b.path("config.h.in"),
            },
        }, .{
            .DEFAULT_VISIBILITY = .@"__attribute__ ((visibility (\"default\")))",
            .ENABLE_DEBUG_LOGGING = defineFromBool(optimize == .Debug),
            .ENABLE_LOGGING = 1,
            .HAVE_ASM_TYPES_H = defineFromBool(target.result.os.tag == .linux),
            .HAVE_CLOCK_GETTIME = defineFromBool(!(target.result.os.tag == .windows)),
            .HAVE_DECL_EFD_CLOEXEC = null,
            .HAVE_DECL_EFD_NONBLOCK = null,
            .HAVE_DECL_TFD_CLOEXEC = null,
            .HAVE_DECL_TFD_NONBLOCK = null,
            .HAVE_DLFCN_H = null,
            .HAVE_EVENTFD = defineFromBool(target.result.os.tag == .linux),
            .HAVE_INTTYPES_H = null,
            .HAVE_IOKIT_USB_IOUSBHOSTFAMILYDEFINITIONS_H = defineFromBool(target.result.os.tag.isDarwin()),
            .HAVE_LIBUDEV = defineFromBool(system_libudev),
            .HAVE_NFDS_T = defineFromBool(is_posix),
            .HAVE_PIPE2 = defineFromBool(target.result.os.tag == .linux),
            .HAVE_PTHREAD_CONDATTR_SETCLOCK = null,
            .HAVE_PTHREAD_SETNAME_NP = null,
            .HAVE_PTHREAD_THREADID_NP = null,
            .HAVE_STDINT_H = 1,
            .HAVE_STDIO_H = 1,
            .HAVE_STDLIB_H = 1,
            .HAVE_STRINGS_H = 1,
            .HAVE_STRING_H = 1,
            .HAVE_STRUCT_TIMESPEC = 1,
            .HAVE_SYSLOG = defineFromBool(is_posix),
            .HAVE_SYS_STAT_H = 1,
            .HAVE_SYS_TIME_H = 1,
            .HAVE_SYS_TYPES_H = 1,
            .HAVE_TIMERFD = defineFromBool(target.result.os.tag == .linux),
            .HAVE_UNISTD_H = 1,
            .LIBUSB_WINDOWS_HOTPLUG = defineFromBool(windows_hotplug),
            .LT_OBJDIR = null,
            .PACKAGE = "libusb-1.0",
            .PACKAGE_BUGREPORT = "libusb-devel@lists.sourceforge.net",
            .PACKAGE_NAME = "libusb-1.0",
            .PACKAGE_STRING = "libusb-1.0 " ++ VERSION,
            .PACKAGE_TARNAME = "libusb-1.0",
            .PACKAGE_URL = "http://libusb.info",
            .PACKAGE_VERSION = VERSION,
            .PLATFORM_POSIX = defineFromBool(is_posix),
            .PLATFORM_WINDOWS = defineFromBool(target.result.os.tag == .windows),
            // TODO1: Figure out how to remove the space between "PRINTF_FORMAT" and "(a, b)", then we could just use the next line instead modifying the file beforehand
            // .PRINTF_FORMAT = .@"(a, b) __attribute__ ((__format__ (__printf__, a, b)))",
            .STDC_HEADERS = 1,
            .UMOCKDEV_HOTPLUG = null,
            .USE_SYSTEM_LOGGING_FACILITY = defineFromBool(is_posix),
            .VERSION = VERSION,
            ._GNU_SOURCE = 1,
            ._WIN32_WINNT = null,
            .@"inline" = null,
        });
        lib.root_module.addConfigHeader(config_h);
    }

    return lib;
}

fn defineFromBool(val: bool) ?u1 {
    return if (val) 1 else null;
}

fn addCSourceFilesFromDep(module: *std.Build.Module, dep: *std.Build.Dependency, files: []const []const u8) void {
    for (files) |file_path| {
        module.addCSourceFile(.{
            .file = dep.path(file_path),
            .flags = common_flags,
        });
    }
}

fn setupAndroid(b: *std.Build, lib: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, android_ndk_path: []const u8, android_api_level: []const u8) !void {
    //these are the only tag options per https://developer.android.com/ndk/guides/other_build_systems
    const host_tuple = switch (builtin.target.os.tag) {
        .linux => "linux-x86_64",
        .windows => "windows-x86_64",
        .macos => "darwin-x86_64",
        else => {
            @panic("unsupported host OS");
        },
    };

    const android_triple = switch (target.result.cpu.arch) {
        .x86_64 => "x86_64-linux-android",
        .x86 => "i686-linux-android",
        .riscv64 => "riscv64-linux-android",
        .aarch64 => "aarch64-linux-android",
        .arm => "arm-linux-androideabi",
        else => {
            @panic("unsupported target CPU");
        },
    };

    const android_sysroot: []const u8 = b.pathJoin(&.{ android_ndk_path, "/toolchains/llvm/prebuilt/", host_tuple, "/sysroot" });

    const android_lib_path: []const u8 = b.pathJoin(&.{ android_sysroot, "/usr/lib/", android_triple });
    const android_lib_path_api_specific: []const u8 = b.pathJoin(&.{ android_lib_path, android_api_level });
    const android_include_path: []const u8 = b.pathJoin(&.{ android_sysroot, "/usr/include" });
    const android_include_path_arch_specific: []const u8 = b.pathJoin(&.{ android_include_path, android_triple });
    const android_asm_path: []const u8 = b.pathJoin(&.{ android_include_path, "/asm-generic" });
    const android_glue_path: []const u8 = b.pathJoin(&.{ android_ndk_path, "/sources/android/native_app_glue" });
    const android_native_app_glue_file: []const u8 = b.pathJoin(&.{ android_glue_path, "/android_native_app_glue.c" });

    lib.root_module.addLibraryPath(.{ .cwd_relative = android_lib_path });
    lib.root_module.addLibraryPath(.{ .cwd_relative = android_lib_path_api_specific });
    lib.root_module.addSystemIncludePath(.{ .cwd_relative = android_include_path });
    lib.root_module.addSystemIncludePath(.{ .cwd_relative = android_include_path_arch_specific });
    lib.root_module.addSystemIncludePath(.{ .cwd_relative = android_asm_path });
    lib.root_module.addSystemIncludePath(.{ .cwd_relative = android_glue_path });

    lib.root_module.addCSourceFile(.{
        .file = .{ .cwd_relative = android_native_app_glue_file },
        .flags = common_flags,
    });

    var allocating_writer: std.Io.Writer.Allocating = .init(b.allocator);
    defer allocating_writer.deinit();
    const libc_installation: std.zig.LibCInstallation = .{
        .include_dir = android_include_path,
        .sys_include_dir = android_include_path,
        .crt_dir = android_lib_path_api_specific,
    };
    try libc_installation.render(&allocating_writer.writer);
    const libc_file: std.Build.LazyPath = b.addWriteFiles().add("android-libc.txt", allocating_writer.written());
    lib.setLibCFile(libc_file);
}

// zig fmt: off
fn targets(b: *std.Build) [19]std.Build.ResolvedTarget {
    return [_]std.Build.ResolvedTarget{
        b.resolveTargetQuery(.{}),
        b.resolveTargetQuery(.{ .cpu_arch = .x86_64,  .os_tag = .linux,    .abi = .musl       }),
        b.resolveTargetQuery(.{ .cpu_arch = .x86_64,  .os_tag = .linux,    .abi = .gnu        }),
        b.resolveTargetQuery(.{ .cpu_arch = .x86,     .os_tag = .linux,    .abi = .musl       }),
        b.resolveTargetQuery(.{ .cpu_arch = .x86,     .os_tag = .linux,    .abi = .gnu        }),
        b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux,    .abi = .musl       }),
        b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux,    .abi = .gnu        }),
        b.resolveTargetQuery(.{ .cpu_arch = .arm,     .os_tag = .linux,    .abi = .musleabi   }),
        b.resolveTargetQuery(.{ .cpu_arch = .arm,     .os_tag = .linux,    .abi = .musleabihf }),
        b.resolveTargetQuery(.{ .cpu_arch = .arm,     .os_tag = .linux,    .abi = .gnueabi    }),
        b.resolveTargetQuery(.{ .cpu_arch = .arm,     .os_tag = .linux,    .abi = .gnueabihf  }),

        // b.resolveTargetQuery(.{ .cpu_arch = .x86_64,  .os_tag = .macos,                       }), // TODO2: update xcode_frameworks to include IOKit/usb/IOUSBLib.h to enable crosscompiling
        // b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos,                       }), // TODO2: update xcode_frameworks to include IOKit/usb/IOUSBLib.h to enable crosscompiling

        b.resolveTargetQuery(.{ .cpu_arch = .x86_64,  .os_tag = .windows,                     }),
        b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .windows,                     }),

        b.resolveTargetQuery(.{ .cpu_arch = .x86_64,  .os_tag = .netbsd,                      }),
        // b.resolveTargetQuery(.{ .cpu_arch = .x86_64,  .os_tag = .openbsd,                     }), // LibC missing for crosscompiling https://codeberg.org/ziglang/zig/issues/30003
        // b.resolveTargetQuery(.{ .cpu_arch = .x86_64,  .os_tag = .haiku,                       }), // LibC missing for crosscompiling https://codeberg.org/ziglang/zig/issues/30003
        // b.resolveTargetQuery(.{ .cpu_arch = .x86_64,  .os_tag = .solaris,                     }), // LibC missing for crosscompiling https://codeberg.org/ziglang/zig/issues/30003

        b.resolveTargetQuery(.{ .cpu_arch = .x86_64,  .os_tag = .linux,   .abi = .android     }),
        b.resolveTargetQuery(.{ .cpu_arch = .x86,     .os_tag = .linux,   .abi = .android     }),
        b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .linux,   .abi = .android     }),
        b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux,   .abi = .android     }),
        b.resolveTargetQuery(.{ .cpu_arch = .arm,     .os_tag = .linux,   .abi = .androideabi }),
    };
}
// zig fmt: on

const src: []const []const u8 = &.{
    "libusb/core.c",
    "libusb/descriptor.c",
    "libusb/hotplug.c",
    "libusb/io.c",
    "libusb/strerror.c",
    "libusb/sync.c",
};

const posix_platform_src: []const []const u8 = &.{
    "libusb/os/events_posix.c",
    "libusb/os/threads_posix.c",
};

const darwin_src: []const []const u8 = &.{
    "libusb/os/darwin_usb.c",
};

const haiku_src: []const []const u8 = &.{
    "libusb/os/haiku_pollfs.cpp",
    "libusb/os/haiku_usb_backend.cpp",
    "libusb/os/haiku_usb_raw.cpp",
};

const linux_src: []const []const u8 = &.{
    "libusb/os/linux_netlink.c",
    "libusb/os/linux_usbfs.c",
};
const linux_udev_src: []const []const u8 = &.{
    "libusb/os/linux_udev.c",
};

const android_src: []const []const u8 = &.{
    "libusb/os/linux_netlink.c",
    "libusb/os/linux_usbfs.c",
};

const netbsd_src: []const []const u8 = &.{
    "libusb/os/netbsd_usb.c",
};

const null_src: []const []const u8 = &.{
    "libusb/os/null_usb.c",
};

const openbsd_src: []const []const u8 = &.{
    "libusb/os/openbsd_usb.c",
};

// sunos isn't supported by zig
const sunos_src: []const []const u8 = &.{
    "libusb/os/sunos_usb.c",
};

const windows_src: []const []const u8 = &.{
    "libusb/os/events_windows.c",
    "libusb/os/threads_windows.c",
    "libusb/os/windows_common.c",
    "libusb/os/windows_usbdk.c",
    "libusb/os/windows_winusb.c",
};

const windows_hotplug_src: []const []const u8 = &.{
    "libusb/os/windows_hotplug.c",
};
