// Replaces `child_process.spawn` with one whose child starts (the `spawn`
// event) and then writes what the caller asked for as its standard input,
// `options.stdio[0]`, exits 0 and closes.
//
// Asked for a pipe, the child has a standard input that fails its first
// write with `code`, by the route Node takes for it: the stream's `error`
// event and then its `close`, as a `net.Socket` that destroys itself with
// the error. The child goes on after that `close`, as one that closed its
// standard input does. Asked for anything else, it has no `stdin`, as a
// child of Node's with `"ignore"`, and goes on at once.
//
// `ChildProcess.beni` asks `process.getBuiltinModule` for the module at
// each run, so it sees the replaced property.
import childProcess from "node:child_process";
import { EventEmitter } from "node:events";
import process from "node:process";
import { PassThrough, Writable } from "node:stream";
import { setImmediate } from "node:timers";

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
