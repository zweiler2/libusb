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
    // .linkage = .static,          // Default is .static
    // .use-system-libudev = false, // Default is false
    // .android-api-level = "35",   // Default is "35"
    // .android-ndk-path = "",      // Default is the ANDROID_NDK_HOME environment variable
});
exe.root_module.linkLibrary(libusb.artifact("usb-1.0"));
```

3. Additionally you need to add one of the following lines:

- With Zig 0.15.2 :

```zig
exe.root_module.addIncludePath(libusb.path("include"));
```

- With Zig 0.16.0:

```zig
exe.root_module.addImport("libusb", libusb.module("libusb"));
```

4. And then use it in your code like this:

- With Zig 0.15.2 :

```zig
const libusb = @cImport({
    @cInclude("libusb.h");
});
```

- With Zig 0.16.0:

```zig
const libusb = @import("libusb");
```
