# Zig issues found while building beni

Drafts for the owner to file upstream (codeberg.org/ziglang/zig). Nothing here has been filed.

## `readFileAlloc` on a file that grows after its size is read

Found 2026-09-28: beni crashed when one process read a cache entry another was rewriting.
beni now reads every file through `src/fs_read.zig`, which treats the size as a hint only.

- **0.16.0:** `Io.Writer.Allocating.sendFile` (`lib/std/Io/Writer.zig:2730`) computes
  `size - pos` from the size cached at the first `stat`. The read fills all spare capacity, so
  `pos` can pass `size` when the file grew: `panic: integer overflow`. Reproduced.
- **Master** (checked by reading the code, 2026-09-28): the read is capped at `size - pos`, so it
  no longer traps, but a file that grew comes back truncated with no error.
  `Io.Writer.Discarding.sendFile` and `Io.File.Reader.discard` still compute `size - pos`
  unchecked. No existing issue found; PR #36562 and issue #31946 are related but different.

Draft:

> **`readFileAlloc` / `Reader.allocRemaining` on a file that grows after `getSize`: integer
> overflow (0.16.0), silent truncation (master)**
>
> `File.Reader` caches the size from its first `stat`. `Writer.Allocating.sendFile` computes
> `size - pos` from that cached size. If the file grows between the stat and the reads (an editor
> saving, another process appending), 0.16.0 panics with integer overflow at
> `Io/Writer.zig:2730`, because the read fills all spare capacity and `pos` passes `size`. On
> master the read is capped to `size - pos`, so it no longer traps, but it returns only the first
> `size` bytes with no error. `Discarding.sendFile` and `File.Reader.discard` still compute
> `size - pos` unchecked.
>
> ```zig
> const std = @import("std");
> test "a file that grows after its size is known" {
>     const io = std.testing.io;
>     const gpa = std.testing.allocator;
>     var tmp = std.testing.tmpDir(.{});
>     defer tmp.cleanup();
>     try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "a" });
>     var file = try tmp.dir.openFile(io, "f", .{ .mode = .read_write });
>     defer file.close(io);
>     var reader = file.reader(io, &.{});
>     _ = try reader.getSize(); // readFileAlloc's first sendFile does this
>     try file.writePositionalAll(io, "b" ** 1000, 1); // another process appends
>     const bytes = try reader.interface.allocRemaining(gpa, .unlimited);
>     defer gpa.free(bytes);
>     try std.testing.expectEqual(@as(usize, 1001), bytes.len);
> }
> ```
>
> 0.16.0: `panic: integer overflow` in `Writer.Allocating.sendFile`. Master (by reading the code):
> `bytes.len == 1`. Expected: every read-to-end helper treats the stat size as a hint, reads until
> EOF, and never subtracts a later position from an earlier size.
