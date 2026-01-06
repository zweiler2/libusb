# libusb

## How to use

1. Add this repo as a dependency in your `build.zig.zon` file:

```sh
zig fetch --save git+https://github.com/zweiler2/libusb
```

2. Then add the following code to your `build.zig` file:

```zig
const libusb = b.dependency("libusb", .{
    .target = target,
    .optimize = optimize,
    // .linkage = .static, // Default is .static
    // .use-system-libudev = false, // Default is false
    // .android-api-level = "35", // Default is "35"
    // .android-ndk-path = "", // Default is the ANDROID_NDK_HOME environment variable
});
exe.root_module.addIncludePath(libusb.path("include"));
exe.root_module.linkLibrary(libusb.artifact("usb-1.0"));
exe.root_module.link_libc = true;
```
