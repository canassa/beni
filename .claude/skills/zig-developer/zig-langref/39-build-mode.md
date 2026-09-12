# Build Mode


Zig has four build modes:

- [Debug](#Debug) (default)
- [ReleaseFast](#ReleaseFast)
- [ReleaseSafe](#ReleaseSafe)
- [ReleaseSmall](#ReleaseSmall)

To add standard build options to a `build.zig` file:

    const std = @import("std");

    pub fn build(b: *std.Build) void {
        const optimize = b.standardOptimizeOption(.{});
        const exe = b.addExecutable(.{
            .name = "example",
            .root_module = b.createModule(.{
                .root_source_file = b.path("example.zig"),
                .optimize = optimize,
            }),
        });
        b.default_step.dependOn(&exe.step);
    }

build.zig

This causes these options to be available:

-Doptimize=Debug  
Optimizations off and safety on (default)

-Doptimize=ReleaseSafe  
Optimizations on and safety on

-Doptimize=ReleaseFast  
Optimizations on and safety off

-Doptimize=ReleaseSmall  
Size optimizations on and safety off

### [Debug](#toc-Debug) [§](#Debug)

    $ zig build-exe example.zig

Shell

- Fast compilation speed
- Safety checks enabled
- Slow runtime performance
- Large binary size
- No reproducible build requirement

### [ReleaseFast](#toc-ReleaseFast) [§](#ReleaseFast)

    $ zig build-exe example.zig -O ReleaseFast

Shell

- Fast runtime performance
- Safety checks disabled
- Slow compilation speed
- Large binary size
- Reproducible build

### [ReleaseSafe](#toc-ReleaseSafe) [§](#ReleaseSafe)

    $ zig build-exe example.zig -O ReleaseSafe

Shell

- Medium runtime performance
- Safety checks enabled
- Slow compilation speed
- Large binary size
- Reproducible build

### [ReleaseSmall](#toc-ReleaseSmall) [§](#ReleaseSmall)

    $ zig build-exe example.zig -O ReleaseSmall

Shell

- Medium runtime performance
- Safety checks disabled
- Slow compilation speed
- Small binary size
- Reproducible build

See also:

- [Compile Variables](#Compile-Variables)
- [Zig Build System](#Zig-Build-System)
- [Illegal Behavior](#Illegal-Behavior)

