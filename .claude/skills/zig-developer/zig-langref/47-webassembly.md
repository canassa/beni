# WebAssembly


Zig supports building for WebAssembly out of the box.

### [Freestanding](#toc-Freestanding) [§](#Freestanding)

For host environments like the web browser and nodejs, build as an executable using the freestanding OS target. Here's an example of running Zig code compiled to WebAssembly with nodejs.

    extern fn print(i32) void;

    export fn add(a: i32, b: i32) void {
        print(a + b);
    }

math.zig

    $ zig build-exe math.zig -target wasm32-freestanding -fno-entry --export=add

Shell

    const fs = require('fs');
    const source = fs.readFileSync("./math.wasm");
    const typedArray = new Uint8Array(source);

    WebAssembly.instantiate(typedArray, {
      env: {
        print: (result) => { console.log(`The result is ${result}`); }
      }}).then(result => {
      const add = result.instance.exports.add;
      add(1, 2);
    });

test.js

    $ node test.js
    The result is 3

Shell

### [WASI](#toc-WASI) [§](#WASI)

Zig standard library has first-class support for WebAssembly System Interface.

    const std = @import("std");

    pub fn main(init: std.process.Init) !void {
        const args = try init.minimal.args.toSlice(init.arena.allocator());
        for (0.., args) |i, arg| {
            std.debug.print("{d}: {s}\n", .{ i, arg });
        }
    }

wasi_args.zig

    $ zig build-exe wasi_args.zig -target wasm32-wasi

Shell

    $ wasmtime wasi_args.wasm 123 hello
    0: wasi_args.wasm
    1: 123
    2: hello

Shell

A more interesting example would be extracting the list of preopens from the runtime. This is now supported in the standard library via `std.fs.wasi.Preopens`:

    const std = @import("std");

    pub fn main(init: std.process.Init) void {
        for (init.preopens.map.keys(), 0..) |preopen, i| {
            std.log.info("{d}: {s}", .{ i, preopen });
        }
    }

wasi_preopens.zig

    $ zig build-exe wasi_preopens.zig -target wasm32-wasi

Shell

    $ wasmtime --dir=. wasi_preopens.wasm
    0: stdin
    1: stdout
    2: stderr
    3: .

Shell

