const std = @import("std");
const Build = std.Build;

fn project_root(comptime path: []const u8) []const u8 {
    const root = std.fs.path.dirname(@src().file) orelse unreachable;
    return std.fmt.comptimePrint("{s}/{s}", .{ root, path });
}

fn define_from_bool(val: bool) ?u1 {
    return if (val) 1 else null;
}

pub fn build(b: *Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const system_libudev = b.option(
        bool,
        "system-libudev",
        "link with system libudev on linux",
    ) orelse false;

    const android_ndk_home = std.process.getEnvVarOwned(b.allocator, "ANDROID_NDK_HOME") catch "";
    defer b.allocator.free(android_ndk_home);
    const android_ndk_path: []const u8 = b.option([]const u8, "android_ndk_path", "specify path to android ndk") orelse android_ndk_home;
    const android_api_level: []const u8 = b.option([]const u8, "android_api_level", "specify android api level") orelse "35";

    const libusb = try create_libusb(b, target, optimize, system_libudev, android_ndk_path, android_api_level);
    b.installArtifact(libusb);

    const build_all = b.step("all", "build libusb for all targets");
    for (targets(b)) |t| {
        const lib = try create_libusb(b, t, optimize, system_libudev, android_ndk_path, android_api_level);
        build_all.dependOn(&lib.step);
    }
}

fn create_libusb(
    b: *Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    system_libudev: bool,
    android_ndk_path: []const u8,
    android_api_level: []const u8,
) !*Build.Step.Compile {
    const is_posix =
        target.result.os.tag.isDarwin() or
        target.result.os.tag == .linux or
        target.result.os.tag == .openbsd;

    const lib = b.addLibrary(.{
        .name = "usb",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .static,
    });
    lib.root_module.addCSourceFiles(.{ .files = src });

    if (target.result.abi.isAndroid())
        try setupAndroid(b, lib, target, android_ndk_path, android_api_level);

    if (is_posix)
        lib.root_module.addCSourceFiles(.{ .files = posix_platform_src });

    if (target.result.os.tag.isDarwin()) {
        lib.root_module.addCSourceFiles(.{ .files = darwin_src });
        lib.root_module.linkFramework("CoreFoundation", .{});
        lib.root_module.linkFramework("IOKit", .{});
        lib.root_module.linkFramework("Security", .{});
        // TODO: update xcode_frameworks to include IOKit/usb/IOUSBLib.h
        // Include xcode_frameworks for cross compilation
        if (b.lazyDependency("xcode_frameworks", .{})) |dep| {
            lib.root_module.addSystemFrameworkPath(dep.path("Frameworks"));
            lib.root_module.addSystemIncludePath(dep.path("include"));
            lib.root_module.addLibraryPath(dep.path("lib"));
        }
    } else if (target.result.abi.isAndroid()) {
        lib.root_module.addCSourceFiles(.{ .files = android_src });
    } else if (target.result.os.tag == .linux) {
        lib.root_module.addCSourceFiles(.{ .files = linux_src });
        if (system_libudev) {
            lib.root_module.addCSourceFiles(.{ .files = linux_udev_src });
            lib.root_module.linkSystemLibrary("udev", .{});
        }
    } else if (target.result.os.tag == .windows) {
        lib.root_module.addCSourceFiles(.{ .files = windows_src });
        lib.root_module.addCSourceFiles(.{ .files = windows_platform_src });
    } else if (target.result.os.tag == .netbsd) {
        lib.root_module.addCSourceFiles(.{ .files = netbsd_src });
    } else if (target.result.os.tag == .openbsd) {
        lib.root_module.addCSourceFiles(.{ .files = openbsd_src });
    } else if (target.result.os.tag == .haiku) {
        lib.root_module.addCSourceFiles(.{ .files = haiku_src });
    } else if (target.result.os.tag == .solaris) {
        lib.root_module.addCSourceFiles(.{ .files = sunos_src });
    } else unreachable;

    lib.root_module.addIncludePath(b.path("libusb"));
    lib.installHeader(b.path("libusb/libusb.h"), "libusb.h");

    // config header
    if (target.result.os.tag.isDarwin()) {
        lib.root_module.addIncludePath(b.path("Xcode"));
    } else if (target.result.abi == .msvc) {
        lib.root_module.addIncludePath(b.path("msvc"));
    } else if (target.result.abi.isAndroid()) {
        lib.root_module.addIncludePath(b.path("android"));
    } else {
        const config_h = b.addConfigHeader(.{ .style = .{
            .autoconf_undef = b.path("config.h.in"),
        } }, .{
            .DEFAULT_VISIBILITY = .@"__attribute__ ((visibility (\"default\")))",
            .ENABLE_DEBUG_LOGGING = define_from_bool(optimize == .Debug),
            .ENABLE_LOGGING = 1,
            .HAVE_ASM_TYPES_H = null,
            .HAVE_CLOCK_GETTIME = define_from_bool(!(target.result.os.tag == .windows)),
            .HAVE_DECL_EFD_CLOEXEC = null,
            .HAVE_DECL_EFD_NONBLOCK = null,
            .HAVE_DECL_TFD_CLOEXEC = null,
            .HAVE_DECL_TFD_NONBLOCK = null,
            .HAVE_DLFCN_H = null,
            .HAVE_EVENTFD = null,
            .HAVE_INTTYPES_H = null,
            .HAVE_IOKIT_USB_IOUSBHOSTFAMILYDEFINITIONS_H = define_from_bool(target.result.os.tag.isDarwin()),
            .HAVE_LIBUDEV = define_from_bool(system_libudev),
            .HAVE_NFDS_T = null,
            .HAVE_PIPE2 = null,
            .HAVE_PTHREAD_CONDATTR_SETCLOCK = null,
            .HAVE_PTHREAD_SETNAME_NP = null,
            .HAVE_PTHREAD_THREADID_NP = null,
            .HAVE_STDINT_H = 1,
            .HAVE_STDIO_H = 1,
            .HAVE_STDLIB_H = 1,
            .HAVE_STRINGS_H = 1,
            .HAVE_STRING_H = 1,
            .HAVE_STRUCT_TIMESPEC = 1,
            .HAVE_SYSLOG = define_from_bool(is_posix),
            .HAVE_SYS_STAT_H = 1,
            .HAVE_SYS_TIME_H = 1,
            .HAVE_SYS_TYPES_H = 1,
            .HAVE_TIMERFD = null,
            .HAVE_UNISTD_H = 1,
            .LT_OBJDIR = null,
            .PACKAGE = "libusb-1.0",
            .PACKAGE_BUGREPORT = "libusb-devel@lists.sourceforge.net",
            .PACKAGE_NAME = "libusb-1.0",
            .PACKAGE_STRING = "libusb-1.0 1.0.29",
            .PACKAGE_TARNAME = "libusb-1.0",
            .PACKAGE_URL = "http://libusb.info",
            .PACKAGE_VERSION = "1.0.29",
            .PLATFORM_POSIX = define_from_bool(is_posix),
            .PLATFORM_WINDOWS = define_from_bool(target.result.os.tag == .windows),
            .STDC_HEADERS = 1,
            .UMOCKDEV_HOTPLUG = null,
            .USE_SYSTEM_LOGGING_FACILITY = null,
            .VERSION = "1.0.29",
            ._GNU_SOURCE = 1,
            ._WIN32_WINNT = null,
            .@"inline" = null,
        });
        lib.root_module.addConfigHeader(config_h);
    }

    return lib;
}

const src = &.{
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

const windows_platform_src: []const []const u8 = &.{
    "libusb/os/events_windows.c",
    "libusb/os/threads_windows.c",
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

// zig fmt: off
pub fn targets(b: *Build) [17]std.Build.ResolvedTarget {
    return [_]std.Build.ResolvedTarget{
        b.resolveTargetQuery(.{}),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .x86_64,  .abi = .musl       }),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .x86_64,  .abi = .gnu        }),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .aarch64, .abi = .musl       }),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .aarch64, .abi = .gnu        }),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .arm,     .abi = .musleabi   }),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .arm,     .abi = .musleabihf }),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .arm,     .abi = .gnueabi    }),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .arm,     .abi = .gnueabihf  }),
        b.resolveTargetQuery(.{ .os_tag = .macos,   .cpu_arch = .aarch64                     }),
        b.resolveTargetQuery(.{ .os_tag = .macos,   .cpu_arch = .x86_64                      }),
        b.resolveTargetQuery(.{ .os_tag = .windows, .cpu_arch = .aarch64                     }),
        b.resolveTargetQuery(.{ .os_tag = .windows, .cpu_arch = .x86_64                      }),
        b.resolveTargetQuery(.{ .os_tag = .netbsd,  .cpu_arch = .x86_64                      }),
        b.resolveTargetQuery(.{ .os_tag = .openbsd, .cpu_arch = .x86_64                      }),
        b.resolveTargetQuery(.{ .os_tag = .haiku,   .cpu_arch = .x86_64                      }),
        b.resolveTargetQuery(.{ .os_tag = .solaris, .cpu_arch = .x86_64                      }),
    };
}
// zig fmt: on

fn setupAndroid(b: *Build, lib: *Build.Step.Compile, target: std.Build.ResolvedTarget, android_ndk_path: []const u8, android_api_level: []const u8) !void {
    //these are the only tag options per https://developer.android.com/ndk/guides/other_build_systems
    const host_tuple = switch (@import("builtin").target.os.tag) {
        .linux => "linux-x86_64",
        .windows => "windows-x86_64",
        .macos => "darwin-x86_64",
        else => {
            @panic("unsupported host OS");
        },
    };

    const android_triple: []u8 = try target.result.linuxTriple(b.allocator);

    const android_sysroot: []u8 = try std.fs.path.join(b.allocator, &.{ android_ndk_path, "/toolchains/llvm/prebuilt/", host_tuple, "/sysroot" });
    const android_lib_path: []u8 = try std.fs.path.join(b.allocator, &.{ android_sysroot, "/usr/lib/", android_triple });
    const android_api_specific_path: []u8 = try std.fs.path.join(b.allocator, &.{ android_lib_path, android_api_level });
    const android_include_path: []u8 = try std.fs.path.join(b.allocator, &.{ android_sysroot, "/usr/include" });
    const android_arch_include_path: []u8 = try std.fs.path.join(b.allocator, &.{ android_include_path, android_triple });
    const android_asm_path: []u8 = try std.fs.path.join(b.allocator, &.{ android_include_path, "/asm-generic" });
    const android_glue_path: []u8 = try std.fs.path.join(b.allocator, &.{ android_ndk_path, "/sources/android/native_app_glue" });
    const android_native_app_glue_file = try std.fs.path.join(b.allocator, &.{ android_glue_path, "/android_native_app_glue.c" });

    lib.root_module.addLibraryPath(.{ .cwd_relative = android_api_specific_path });
    lib.root_module.addLibraryPath(.{ .cwd_relative = android_lib_path });
    lib.root_module.addSystemIncludePath(.{ .cwd_relative = android_include_path });
    lib.root_module.addSystemIncludePath(.{ .cwd_relative = android_arch_include_path });
    lib.root_module.addSystemIncludePath(.{ .cwd_relative = android_asm_path });
    lib.root_module.addSystemIncludePath(.{ .cwd_relative = android_glue_path });

    lib.root_module.addCSourceFile(.{
        .file = std.Build.LazyPath{ .cwd_relative = android_native_app_glue_file },
    });

    var allocating_writer: std.io.Writer.Allocating = .init(b.allocator);
    defer allocating_writer.deinit();
    try (std.zig.LibCInstallation{
        .include_dir = android_include_path,
        .sys_include_dir = android_include_path,
        .crt_dir = android_api_specific_path,
    }).render(&allocating_writer.writer);
    const libc_data: []u8 = try allocating_writer.toOwnedSlice();
    defer b.allocator.free(libc_data);
    const libcFile: Build.LazyPath = b.addWriteFiles().add("android-libc.txt", libc_data);
    lib.setLibCFile(libcFile);
}
