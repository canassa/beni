// Three children in place of `child_process.spawn`'s. `ChildProcess.beni`
// asks `process.getBuiltinModule` for the module at each run, so it sees
// the replaced property. A child notes what somebody did to its standard
// input, and `notes` hands the notes to the program.
import childProcess from "node:child_process";
import { EventEmitter } from "node:events";
import process from "node:process";
import { PassThrough, Writable } from "node:stream";
import { setImmediate } from "node:timers";

const noted = [];

export const notes = (unit) => {
  const text = noted.length === 0 ? "nothing" : noted.join(", ");
  noted.length = 0;
  return text;
};

// A child that starts (the `spawn` event) and then writes what the caller
// asked for as its standard input, `options.stdio[0]`, exits 0 and closes.
//
// Asked for a pipe, the child has a standard input that fails its first
// write with `code`, by the route Node takes for it: the stream's `error`
// event and then its `close`, as a `net.Socket` that destroys itself with
// the error. The child goes on after that `close`, as one that closed its
// standard input does. Asked for anything else, it has no `stdin`, as a
// child of Node's with `"ignore"`, and goes on at once.
export const failInput = (code) => {
  childProcess.spawn = (file, args, options) => {
    const child = new EventEmitter();
    child.pid = 1;
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    child.kill = () => false;
    const goOn = () => {
      child.stdout.end(`standard input: ${options.stdio[0]}\n`);
      child.stderr.end();
      child.emit("exit", 0, null);
      setImmediate(() => child.emit("close", 0, null));
    };
    if (options.stdio[0] === "pipe") {
      child.stdin = new Writable({
        write: (chunk, encoding, callback) => {
          const error = new Error(`write ${code}`);
          error.code = code;
          error.syscall = "write";
          callback(error);
        },
      });
      child.stdin.on("close", goOn);
      process.nextTick(() => child.emit("spawn"));
    } else {
      child.stdin = null;
      process.nextTick(() => {
        child.emit("spawn");
        goOn();
      });
    }
    return child;
  };
  return null;
};

// A child that does not start, as Node's after `ENOENT`: the `error` event
// and then `close`, and no `spawn` event. Node gives such a child a
// standard input all the same, a socket with no handle; this one says so
// when something writes to it or ends it.
export const failStart = (unit) => {
  childProcess.spawn = (file) => {
    const child = new EventEmitter();
    child.stdout = null;
    child.stderr = null;
    child.kill = () => false;
    child.stdin = new Writable({
      write: (chunk, encoding, callback) => {
        noted.push("a write to a child that did not start");
        callback();
      },
      final: (callback) => {
        noted.push("the end of the input of a child that did not start");
        callback();
      },
    });
    const error = new Error(`spawn ${file} ENOENT`);
    error.code = "ENOENT";
    error.syscall = `spawn ${file}`;
    process.nextTick(() => {
      child.emit("error", error);
      child.emit("close", -2, null);
    });
    return child;
  };
  return unit;
};

// A child that starts, writes 11 bytes and never reads: a write to its
// standard input never completes. A signal ends it, and at its exit its
// standard input is destroyed, as Node destroys a child's. A destroy that
// comes before the signal is somebody else's, and the child says so.
export const neverRead = (unit) => {
  childProcess.spawn = () => {
    const child = new EventEmitter();
    child.pid = 1;
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    let signalled = false;
    child.stdin = new Writable({
      write: () => {},
      destroy: (error, callback) => {
        if (!signalled) noted.push("the input pipe destroyed before the signal");
        callback(error);
      },
    });
    child.kill = (signal) => {
      if (signalled) return false;
      signalled = true;
      setImmediate(() => {
        child.stdin.destroy();
        child.stdout.destroy();
        child.stderr.destroy();
        child.emit("exit", null, signal);
        setImmediate(() => child.emit("close", null, signal));
      });
      return true;
    };
    process.nextTick(() => {
      child.emit("spawn");
      child.stdout.write("12345678901");
    });
    return child;
  };
  return unit;
};
