// WASI preview 1 over a file system in memory: the host the playground runs
// beni's WebAssembly compiler on (docs/design/playground.md §3).
//
// The page's worker and the tests (`tests/wasm/beni.mjs`) load this one
// file, so the tests prove the host the page runs. It has no dependency and
// touches no API of the browser or of Node beyond `TextEncoder`,
// `TextDecoder`, `crypto.getRandomValues`, `performance.now` and `Date.now`.
//
// The rules of §3:
//   - one instance per compile: `run` makes a new instance, memory and file
//     system each time;
//   - the project directory is the first preopen, fd 3, named `.`, which
//     Zig's standard library takes as the working directory;
//   - stdin is empty; stdout and stderr are captured; a positional read or
//     write on them is `ESPIPE`, as for a pipe;
//   - every function of WASI preview 1 exists, so a module that imports one
//     more still links; one with no meaning in memory (links, sockets,
//     signals, `poll_oneoff`) returns `ENOSYS`;
//   - no `catch` in a call: a JavaScript exception in one goes out of
//     `_start`;
//   - `proc_exit` throws an `Exit`, which `run` catches by `instanceof`;
//   - a trap of the module (`WebAssembly.RuntimeError`: a safety check, an
//     overflow of its own stack) and an exhausted engine stack
//     (`isStackExhausted`) end that compile: `run` returns them as `crash`,
//     with what the compiler wrote to stderr before it, and the next compile
//     makes a new instance. Anything else is a defect of the host and goes
//     on up.

// `errno` (WASI preview 1, `wasi_snapshot_preview1.witx`).
const SUCCESS = 0;
const EBADF = 8;
const EEXIST = 20;
const EFBIG = 22;
const EINVAL = 28;
const EISDIR = 31;
const ENOENT = 44;
const ENOSYS = 52;
const ENOTDIR = 54;
const ENOTEMPTY = 55;
const ESPIPE = 70;
const ENOTCAPABLE = 76;

// `filetype`.
const CHARACTER_DEVICE = 2;
const DIRECTORY = 3;
const REGULAR_FILE = 4;

// `oflags`.
const O_CREAT = 1;
const O_DIRECTORY = 2;
const O_EXCL = 4;
const O_TRUNC = 8;

// `fdflags`.
const FDFLAG_APPEND = 1;

// `whence`.
const WHENCE_SET = 0;
const WHENCE_CUR = 1;
const WHENCE_END = 2;

// `fstflags`.
const FST_ATIM = 1;
const FST_ATIM_NOW = 2;
const FST_MTIM = 4;
const FST_MTIM_NOW = 8;

// `rights`: every file and path right (bits 0 to 28; bit 29,
// `sock_accept`, is a socket's), on every descriptor. The compiler asks for
// what it needs and the shim checks nothing against them.
const ALL_RIGHTS = 0x1fffffffn;
// A terminal's rights: no seek and no tell, which is what makes a
// descriptor a stream to Zig's standard library.
const STREAM_RIGHTS = ALL_RIGHTS & ~(0x4n | 0x20n);

const PREOPEN_FD = 3;
const PREOPEN_NAME = ".";

// The largest file in memory: a position or a size past it is `EFBIG`, so
// no request of the module can make the host allocate a typed array it
// cannot have (a `RangeError` of the host, not of the module).
const MAX_FILE = 2 ** 30;

const encoder = new TextEncoder();
// Fatal: the compiler writes UTF-8 paths, so a path that is not is a defect
// of the compiler, and its `TypeError` goes out of `_start` as one.
const decoder = new TextDecoder("utf-8", { fatal: true });

/// What `proc_exit` throws: the module asked to stop with `code`.
export class Exit {
  constructor(code) {
    this.code = code;
  }
}

/// Whether `e` is the engine's own stack running out (playground.md §8):
/// V8's and JavaScriptCore's `RangeError` "Maximum call stack size
/// exceeded", SpiderMonkey's `InternalError` "too much recursion". Any other
/// `RangeError` is not this.
export function isStackExhausted(e) {
  if (e instanceof RangeError) return /^Maximum call stack size exceeded/.test(e.message);
  return e instanceof Error && e.name === "InternalError" && /too much recursion/.test(e.message);
}

let nextIno = 1n;
const now = () => BigInt(Date.now()) * 1_000_000n;

/// A regular file: its bytes are `data.subarray(0, size)`.
export class File {
  constructor(bytes = new Uint8Array(0)) {
    this.data = bytes;
    this.size = bytes.length;
    this.ino = nextIno++;
    this.mtim = now();
    this.atim = this.mtim;
  }

  bytes() {
    return this.data.slice(0, this.size);
  }

  /// Make room for `size` bytes, at least doubling, and zero what grows.
  reserve(size) {
    if (size <= this.data.length) return;
    const grown = new Uint8Array(Math.max(size, Math.min(this.data.length * 2, MAX_FILE), 256));
    grown.set(this.data.subarray(0, this.size));
    this.data = grown;
  }

  truncate(size) {
    if (size > this.size) this.reserve(size);
    else this.data.fill(0, size, this.size);
    this.size = size;
    this.mtim = now();
  }

  writeAt(position, bytes) {
    const end = position + bytes.length;
    this.reserve(end);
    this.data.set(bytes, position);
    if (end > this.size) this.size = end;
    this.mtim = now();
  }
}

/// A directory: a name for each entry, a `File` or a `Directory`.
export class Directory {
  constructor() {
    this.entries = new Map();
    this.ino = nextIno++;
    this.mtim = now();
    this.atim = this.mtim;
  }
}

/// A `Directory` holding `files`, an object or a `Map` from a path relative
/// to it (`src/Main.beni`) to the file's bytes or text.
export function directoryOf(files) {
  const root = new Directory();
  const entries = files instanceof Map ? files.entries() : Object.entries(files);
  for (const [path, contents] of entries) {
    const names = path.split("/");
    let dir = root;
    for (const name of names.slice(0, -1)) {
      let next = dir.entries.get(name);
      if (next === undefined) {
        next = new Directory();
        dir.entries.set(name, next);
      }
      dir = next;
    }
    const bytes = typeof contents === "string" ? encoder.encode(contents) : contents;
    dir.entries.set(names[names.length - 1], new File(bytes));
  }
  return root;
}

/// Every regular file under `dir`, as a `Map` from its path relative to
/// `dir` to its bytes, in sorted path order.
export function filesOf(dir, prefix = "", into = new Map()) {
  for (const name of [...dir.entries.keys()].sort()) {
    const node = dir.entries.get(name);
    const path = prefix + name;
    if (node instanceof Directory) filesOf(node, `${path}/`, into);
    else into.set(path, node.bytes());
  }
  return into;
}

/// One open descriptor.
class Descriptor {
  constructor(node, { append = false, stream = null } = {}) {
    this.node = node;
    this.position = 0;
    this.append = append;
    // `"stdin"`, `"stdout"` or `"stderr"` for the three streams.
    this.stream = stream;
  }
}

/// One run of a WASI command: its arguments, its file system, and what it
/// wrote to its two streams.
export class Wasi {
  constructor({ args, root, env = {} }) {
    this.args = args.map((a) => encoder.encode(`${a}\0`));
    this.env = Object.entries(env).map(([k, v]) => encoder.encode(`${k}=${v}\0`));
    this.root = root;
    this.stdout = [];
    this.stderr = [];
    this.memory = null;
    this.fds = new Map([
      [0, new Descriptor(null, { stream: "stdin" })],
      [1, new Descriptor(null, { stream: "stdout" })],
      [2, new Descriptor(null, { stream: "stderr" })],
      [PREOPEN_FD, new Descriptor(root)],
    ]);
    this.nextFd = PREOPEN_FD + 1;
    this.imports = { wasi_snapshot_preview1: this.functions() };
  }

  view() {
    return new DataView(this.memory.buffer);
  }

  bytes(pointer, length) {
    return new Uint8Array(this.memory.buffer, pointer, length);
  }

  string(pointer, length) {
    return decoder.decode(this.bytes(pointer, length));
  }

  /// The buffers of an `iovec` array, as views into memory.
  buffers(iovs, count) {
    const view = this.view();
    const out = [];
    for (let i = 0; i < count; i += 1) {
      const pointer = view.getUint32(iovs + i * 8, true);
      const length = view.getUint32(iovs + i * 8 + 4, true);
      out.push(this.bytes(pointer, length));
    }
    return out;
  }

  /// `path`, relative to the directory of `fd`, as `{ parent, name, node }`:
  /// the directory it is in, its last name, and what is there (undefined
  /// when nothing is). A number is an `errno`. `.` and `..` move within the
  /// tree of `fd`; a path that leaves it, or an absolute one, is
  /// `ENOTCAPABLE`, as WASI's capability rule says.
  resolve(fd, path) {
    const base = this.fds.get(fd);
    if (base === undefined) return EBADF;
    if (!(base.node instanceof Directory)) return ENOTDIR;
    if (path.startsWith("/")) return ENOTCAPABLE;
    // `name/` names a directory.
    const directory = path.endsWith("/");
    const names = path.split("/").filter((n) => n !== "" && n !== ".");
    const stack = [base.node];
    for (const name of names.slice(0, -1)) {
      if (name === "..") {
        if (stack.length === 1) return ENOTCAPABLE;
        stack.pop();
        continue;
      }
      const next = stack[stack.length - 1].entries.get(name);
      if (next === undefined) return ENOENT;
      if (!(next instanceof Directory)) return ENOTDIR;
      stack.push(next);
    }
    const last = names.length === 0 ? "." : names[names.length - 1];
    if (last === "..") {
      if (stack.length === 1) return ENOTCAPABLE;
      stack.pop();
    }
    if (last === "." || last === "..") return { parent: null, name: null, node: stack[stack.length - 1] };
    const parent = stack[stack.length - 1];
    const node = parent.entries.get(last);
    if (directory && node instanceof File) return ENOTDIR;
    return { parent, name: last, node };
  }

  open(node, options) {
    const fd = this.nextFd;
    this.nextFd += 1;
    this.fds.set(fd, new Descriptor(node, options));
    return fd;
  }

  writeFilestat(pointer, node) {
    const view = this.view();
    const isDir = node instanceof Directory;
    view.setBigUint64(pointer, 0n, true); // dev
    view.setBigUint64(pointer + 8, node === null ? 0n : node.ino, true);
    view.setUint8(pointer + 16, node === null ? CHARACTER_DEVICE : isDir ? DIRECTORY : REGULAR_FILE);
    for (let i = 17; i < 24; i += 1) view.setUint8(pointer + i, 0);
    view.setBigUint64(pointer + 24, 1n, true); // nlink
    view.setBigUint64(pointer + 32, node instanceof File ? BigInt(node.size) : 0n, true);
    view.setBigUint64(pointer + 40, node === null ? 0n : node.atim, true);
    view.setBigUint64(pointer + 48, node === null ? 0n : node.mtim, true);
    view.setBigUint64(pointer + 56, node === null ? 0n : node.mtim, true); // ctim
  }

  /// Write `chunks` to the stream or file of `d` at `position`, or at its
  /// cursor when `position` is null; the number of bytes written.
  write(d, chunks, position) {
    let total = 0;
    if (d.stream !== null) {
      const sink = d.stream === "stdout" ? this.stdout : d.stream === "stderr" ? this.stderr : null;
      for (const chunk of chunks) {
        if (sink !== null) sink.push(chunk.slice());
        total += chunk.length;
      }
      return total;
    }
    let at = position ?? (d.append ? d.node.size : d.position);
    if (at + chunks.reduce((sum, c) => sum + c.length, 0) > MAX_FILE) return null;
    for (const chunk of chunks) {
      d.node.writeAt(at, chunk);
      at += chunk.length;
      total += chunk.length;
    }
    if (position === null) d.position = at;
    return total;
  }

  /// Read into `buffers` from the file of `d` at `position`, or at its
  /// cursor when `position` is null; the number of bytes read.
  read(d, buffers, position) {
    if (d.stream !== null) return 0; // stdin is empty
    let at = position ?? d.position;
    let total = 0;
    for (const buffer of buffers) {
      const n = Math.max(0, Math.min(buffer.length, d.node.size - at));
      buffer.set(d.node.data.subarray(at, at + n));
      at += n;
      total += n;
      if (n < buffer.length) break;
    }
    if (position === null) d.position = at;
    d.node.atim = now();
    return total;
  }

  functions() {
    const wasi = this;
    const fileOf = (fd) => {
      const d = wasi.fds.get(fd);
      return d === undefined ? EBADF : d;
    };
    return {
      args_sizes_get(count, size) {
        const view = wasi.view();
        view.setUint32(count, wasi.args.length, true);
        view.setUint32(size, wasi.args.reduce((sum, a) => sum + a.length, 0), true);
        return SUCCESS;
      },
      args_get(argv, buffer) {
        return writeStrings(wasi, wasi.args, argv, buffer);
      },
      environ_sizes_get(count, size) {
        const view = wasi.view();
        view.setUint32(count, wasi.env.length, true);
        view.setUint32(size, wasi.env.reduce((sum, e) => sum + e.length, 0), true);
        return SUCCESS;
      },
      environ_get(environ, buffer) {
        return writeStrings(wasi, wasi.env, environ, buffer);
      },
      clock_res_get(id, resolution) {
        if (id < 0 || id > 3) return EINVAL;
        wasi.view().setBigUint64(resolution, id === 0 ? 1_000_000n : 1_000n, true);
        return SUCCESS;
      },
      clock_time_get(id, _precision, time) {
        if (id < 0 || id > 3) return EINVAL;
        const ns = id === 0 ? now() : BigInt(Math.round(performance.now() * 1e6));
        wasi.view().setBigUint64(time, ns, true);
        return SUCCESS;
      },
      random_get(pointer, length) {
        // `getRandomValues` fills at most 65 536 bytes a call.
        for (let at = 0; at < length; at += 65536) {
          crypto.getRandomValues(wasi.bytes(pointer + at, Math.min(65536, length - at)));
        }
        return SUCCESS;
      },
      proc_exit(code) {
        throw new Exit(code);
      },
      sched_yield() {
        return SUCCESS;
      },
      poll_oneoff() {
        return ENOSYS;
      },

      fd_prestat_get(fd, pointer) {
        if (fd !== PREOPEN_FD) return EBADF;
        const view = wasi.view();
        view.setUint8(pointer, 0); // a directory
        view.setUint32(pointer + 4, PREOPEN_NAME.length, true);
        return SUCCESS;
      },
      fd_prestat_dir_name(fd, pointer, length) {
        if (fd !== PREOPEN_FD) return EBADF;
        const name = encoder.encode(PREOPEN_NAME);
        if (length < name.length) return EINVAL;
        wasi.bytes(pointer, name.length).set(name);
        return SUCCESS;
      },
      fd_fdstat_get(fd, pointer) {
        const d = fileOf(fd);
        if (typeof d === "number") return d;
        const view = wasi.view();
        const type = d.stream !== null ? CHARACTER_DEVICE : d.node instanceof Directory ? DIRECTORY : REGULAR_FILE;
        view.setUint8(pointer, type);
        view.setUint8(pointer + 1, 0);
        view.setUint16(pointer + 2, d.append ? FDFLAG_APPEND : 0, true);
        view.setUint32(pointer + 4, 0, true);
        view.setBigUint64(pointer + 8, d.stream !== null ? STREAM_RIGHTS : ALL_RIGHTS, true);
        view.setBigUint64(pointer + 16, ALL_RIGHTS, true);
        return SUCCESS;
      },
      fd_fdstat_set_flags(fd, flags) {
        const d = fileOf(fd);
        if (typeof d === "number") return d;
        d.append = (flags & FDFLAG_APPEND) !== 0;
        return SUCCESS;
      },
      fd_close(fd) {
        if (!wasi.fds.has(fd)) return EBADF;
        wasi.fds.delete(fd);
        return SUCCESS;
      },
      fd_sync(fd) {
        return wasi.fds.has(fd) ? SUCCESS : EBADF;
      },
      fd_datasync(fd) {
        return wasi.fds.has(fd) ? SUCCESS : EBADF;
      },
      fd_filestat_get(fd, pointer) {
        const d = fileOf(fd);
        if (typeof d === "number") return d;
        wasi.writeFilestat(pointer, d.node);
        return SUCCESS;
      },
      fd_filestat_set_size(fd, size) {
        const d = fileOf(fd);
        if (typeof d === "number") return d;
        if (!(d.node instanceof File)) return EINVAL;
        if (size > BigInt(MAX_FILE)) return EFBIG;
        d.node.truncate(Number(size));
        return SUCCESS;
      },
      fd_filestat_set_times(fd, atim, mtim, flags) {
        const d = fileOf(fd);
        if (typeof d === "number") return d;
        if (d.node === null) return EINVAL;
        return setTimes(d.node, atim, mtim, flags);
      },
      fd_write(fd, iovs, count, written) {
        const d = fileOf(fd);
        if (typeof d === "number") return d;
        if (d.node instanceof Directory) return EISDIR;
        if (d.stream === "stdin") return EBADF;
        const n = wasi.write(d, wasi.buffers(iovs, count), null);
        if (n === null) return EFBIG;
        wasi.view().setUint32(written, n, true);
        return SUCCESS;
      },
      fd_pwrite(fd, iovs, count, offset, written) {
        const d = fileOf(fd);
        if (typeof d === "number") return d;
        if (d.stream !== null) return ESPIPE;
        if (d.node instanceof Directory) return EISDIR;
        if (offset < 0n || offset > BigInt(MAX_FILE)) return EFBIG;
        const n = wasi.write(d, wasi.buffers(iovs, count), Number(offset));
        if (n === null) return EFBIG;
        wasi.view().setUint32(written, n, true);
        return SUCCESS;
      },
      fd_read(fd, iovs, count, read) {
        const d = fileOf(fd);
        if (typeof d === "number") return d;
        if (d.node instanceof Directory) return EISDIR;
        if (d.stream !== null && d.stream !== "stdin") return EBADF;
        wasi.view().setUint32(read, wasi.read(d, wasi.buffers(iovs, count), null), true);
        return SUCCESS;
      },
      fd_pread(fd, iovs, count, offset, read) {
        const d = fileOf(fd);
        if (typeof d === "number") return d;
        if (d.stream !== null) return ESPIPE;
        if (d.node instanceof Directory) return EISDIR;
        if (offset < 0n) return EINVAL;
        const at = offset > BigInt(MAX_FILE) ? MAX_FILE : Number(offset);
        wasi.view().setUint32(read, wasi.read(d, wasi.buffers(iovs, count), at), true);
        return SUCCESS;
      },
      fd_seek(fd, offset, whence, result) {
        const d = fileOf(fd);
        if (typeof d === "number") return d;
        if (d.stream !== null) return ESPIPE;
        if (!(d.node instanceof File)) return EISDIR;
        const from = whence === WHENCE_SET ? 0 : whence === WHENCE_CUR ? d.position : whence === WHENCE_END ? d.node.size : null;
        if (from === null) return EINVAL;
        const position = from + Number(offset);
        if (position < 0 || position > MAX_FILE) return EINVAL;
        d.position = position;
        wasi.view().setBigUint64(result, BigInt(position), true);
        return SUCCESS;
      },
      fd_tell(fd, result) {
        const d = fileOf(fd);
        if (typeof d === "number") return d;
        if (d.stream !== null) return ESPIPE;
        wasi.view().setBigUint64(result, BigInt(d.position), true);
        return SUCCESS;
      },
      fd_readdir(fd, pointer, length, cookie, used) {
        const d = fileOf(fd);
        if (typeof d === "number") return d;
        if (!(d.node instanceof Directory)) return ENOTDIR;
        // `.` and `..`, then the entries in sorted order; the cookie of an
        // entry is the index of the one after it.
        const names = [".", "..", ...[...d.node.entries.keys()].sort()];
        const view = wasi.view();
        let at = 0;
        for (let i = Number(cookie); i < names.length && at < length; i += 1) {
          const name = encoder.encode(names[i]);
          const node = i < 2 ? d.node : d.node.entries.get(names[i]);
          const record = new Uint8Array(24 + name.length);
          const r = new DataView(record.buffer);
          r.setBigUint64(0, BigInt(i + 1), true);
          r.setBigUint64(8, node.ino, true);
          r.setUint32(16, name.length, true);
          r.setUint8(20, node instanceof Directory ? DIRECTORY : REGULAR_FILE);
          record.set(name, 24);
          // A record that does not fit is cut at the end of the buffer: a
          // full buffer tells the caller to read again from its cookie.
          const n = Math.min(record.length, length - at);
          wasi.bytes(pointer + at, n).set(record.subarray(0, n));
          at += n;
        }
        view.setUint32(used, at, true);
        return SUCCESS;
      },

      path_open(fd, _lookup, pathPointer, pathLength, oflags, rightsBase, _rightsInheriting, fdflags, opened) {
        const at = wasi.resolve(fd, wasi.string(pathPointer, pathLength));
        if (typeof at === "number") return at;
        let node = at.node;
        if (node === undefined) {
          if ((oflags & O_CREAT) === 0) return ENOENT;
          if ((oflags & O_DIRECTORY) !== 0) return EINVAL;
          node = new File();
          at.parent.entries.set(at.name, node);
          at.parent.mtim = now();
        } else if ((oflags & O_CREAT) !== 0 && (oflags & O_EXCL) !== 0) {
          return EEXIST;
        }
        if ((oflags & O_DIRECTORY) !== 0 && !(node instanceof Directory)) return ENOTDIR;
        // `fd_write`, `fd_allocate` or `fd_filestat_set_size` on a
        // directory, or a truncation of one.
        const writes = (BigInt(rightsBase) & (0x40n | 0x100n | 0x400000n)) !== 0n;
        if (node instanceof Directory && (writes || (oflags & O_TRUNC) !== 0)) return EISDIR;
        if ((oflags & O_TRUNC) !== 0) node.truncate(0);
        wasi.view().setUint32(opened, wasi.open(node, { append: (fdflags & FDFLAG_APPEND) !== 0 }), true);
        return SUCCESS;
      },
      path_filestat_get(fd, _lookup, pathPointer, pathLength, pointer) {
        const at = wasi.resolve(fd, wasi.string(pathPointer, pathLength));
        if (typeof at === "number") return at;
        if (at.node === undefined) return ENOENT;
        wasi.writeFilestat(pointer, at.node);
        return SUCCESS;
      },
      path_filestat_set_times(fd, _lookup, pathPointer, pathLength, atim, mtim, flags) {
        const at = wasi.resolve(fd, wasi.string(pathPointer, pathLength));
        if (typeof at === "number") return at;
        if (at.node === undefined) return ENOENT;
        return setTimes(at.node, atim, mtim, flags);
      },
      path_create_directory(fd, pathPointer, pathLength) {
        const at = wasi.resolve(fd, wasi.string(pathPointer, pathLength));
        if (typeof at === "number") return at;
        if (at.node !== undefined) return EEXIST;
        at.parent.entries.set(at.name, new Directory());
        at.parent.mtim = now();
        return SUCCESS;
      },
      path_unlink_file(fd, pathPointer, pathLength) {
        const at = wasi.resolve(fd, wasi.string(pathPointer, pathLength));
        if (typeof at === "number") return at;
        if (at.node === undefined) return ENOENT;
        if (at.node instanceof Directory) return EISDIR;
        at.parent.entries.delete(at.name);
        at.parent.mtim = now();
        return SUCCESS;
      },
      path_remove_directory(fd, pathPointer, pathLength) {
        const at = wasi.resolve(fd, wasi.string(pathPointer, pathLength));
        if (typeof at === "number") return at;
        if (at.node === undefined) return ENOENT;
        if (!(at.node instanceof Directory)) return ENOTDIR;
        if (at.parent === null) return EINVAL; // `.` or `..`
        if (at.node.entries.size !== 0) return ENOTEMPTY;
        at.parent.entries.delete(at.name);
        at.parent.mtim = now();
        return SUCCESS;
      },
      path_rename(fd, oldPointer, oldLength, newFd, newPointer, newLength) {
        const from = wasi.resolve(fd, wasi.string(oldPointer, oldLength));
        if (typeof from === "number") return from;
        if (from.node === undefined) return ENOENT;
        if (from.parent === null) return EINVAL;
        const to = wasi.resolve(newFd, wasi.string(newPointer, newLength));
        if (typeof to === "number") return to;
        if (to.parent === null) return EINVAL;
        if (to.node !== undefined && to.node !== from.node) {
          if (to.node instanceof Directory) {
            if (!(from.node instanceof Directory)) return EISDIR;
            if (to.node.entries.size !== 0) return ENOTEMPTY;
          } else if (from.node instanceof Directory) {
            return ENOTDIR;
          }
        }
        if (from.node instanceof Directory && contains(from.node, to.parent)) return EINVAL;
        from.parent.entries.delete(from.name);
        to.parent.entries.set(to.name, from.node);
        from.parent.mtim = now();
        to.parent.mtim = from.parent.mtim;
        return SUCCESS;
      },
      fd_advise(fd) {
        // Advice is a hint, and memory takes none.
        return wasi.fds.has(fd) ? SUCCESS : EBADF;
      },
      fd_allocate(fd, offset, length) {
        const d = fileOf(fd);
        if (typeof d === "number") return d;
        if (!(d.node instanceof File)) return EINVAL;
        const end = offset + length;
        if (end > BigInt(MAX_FILE)) return EFBIG;
        if (Number(end) > d.node.size) d.node.truncate(Number(end));
        return SUCCESS;
      },
      fd_fdstat_set_rights(fd) {
        return wasi.fds.has(fd) ? SUCCESS : EBADF;
      },
      fd_renumber(from, to) {
        const d = fileOf(from);
        if (typeof d === "number" || !wasi.fds.has(to)) return EBADF;
        wasi.fds.set(to, d);
        wasi.fds.delete(from);
        return SUCCESS;
      },
      proc_raise() {
        return ENOSYS;
      },
      // No sockets and no links in memory.
      sock_accept() {
        return ENOSYS;
      },
      sock_recv() {
        return ENOSYS;
      },
      sock_send() {
        return ENOSYS;
      },
      sock_shutdown() {
        return ENOSYS;
      },
      path_link() {
        return ENOSYS;
      },
      path_symlink() {
        return ENOSYS;
      },
      path_readlink() {
        return ENOSYS;
      },
    };
  }
}

/// `args_get` and `environ_get`: the pointers, then the NUL-terminated
/// strings they point at.
function writeStrings(wasi, strings, pointers, buffer) {
  const view = wasi.view();
  let at = buffer;
  strings.forEach((s, i) => {
    view.setUint32(pointers + i * 4, at, true);
    wasi.bytes(at, s.length).set(s);
    at += s.length;
  });
  return SUCCESS;
}

function setTimes(node, atim, mtim, flags) {
  if ((flags & FST_ATIM) !== 0 && (flags & FST_ATIM_NOW) !== 0) return EINVAL;
  if ((flags & FST_MTIM) !== 0 && (flags & FST_MTIM_NOW) !== 0) return EINVAL;
  if ((flags & FST_ATIM) !== 0) node.atim = BigInt(atim);
  if ((flags & FST_ATIM_NOW) !== 0) node.atim = now();
  if ((flags & FST_MTIM) !== 0) node.mtim = BigInt(mtim);
  if ((flags & FST_MTIM_NOW) !== 0) node.mtim = now();
  return SUCCESS;
}

/// Whether `dir` is `target` or holds it at any depth.
function contains(dir, target) {
  if (dir === target) return true;
  for (const node of dir.entries.values()) {
    if (node instanceof Directory && contains(node, target)) return true;
  }
  return false;
}

/// Run the command `args` (its name first) of the compiled `module` on the
/// project directory `root`, in a new instance. Returns its exit code (null
/// when it crashed), the crash (a trap or an exhausted engine stack, else
/// null), the bytes of its two streams, and `root`, which holds what it
/// wrote (playground.md §3).
export async function run(module, args, root) {
  const wasi = new Wasi({ args, root });
  const instance = await WebAssembly.instantiate(module, wasi.imports);
  wasi.memory = instance.exports.memory;
  let code = 0;
  let crash = null;
  try {
    instance.exports._start();
  } catch (e) {
    if (e instanceof Exit) code = e.code;
    else if (e instanceof WebAssembly.RuntimeError || isStackExhausted(e)) {
      code = null;
      crash = e;
    } else throw e;
  }
  return { code, crash, stdout: concat(wasi.stdout), stderr: concat(wasi.stderr), root };
}

function concat(chunks) {
  const out = new Uint8Array(chunks.reduce((sum, c) => sum + c.length, 0));
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}
