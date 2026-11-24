// Replaces `child_process.spawn` with one whose child starts (the `spawn`
// event) and has a standard input that fails its first write with `code`,
// by the route Node takes for it: the stream's `error` event and then its
// `close`, as a `net.Socket` that destroys itself with the error. The
// child goes on after that, as one that closed its standard input does:
// it writes a line, exits 0 and closes. `ChildProcess.beni` asks
// `process.getBuiltinModule` for the module at each run, so it sees the
// replaced property.
import childProcess from "node:child_process";
import { EventEmitter } from "node:events";
import process from "node:process";
import { PassThrough, Writable } from "node:stream";
import { setImmediate } from "node:timers";

export const failInput = (code) => {
  childProcess.spawn = () => {
    const child = new EventEmitter();
    child.pid = 1;
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    child.kill = () => false;
    child.stdin = new Writable({
      write: (chunk, encoding, callback) => {
        const error = new Error(`write ${code}`);
        error.code = code;
        error.syscall = "write";
        callback(error);
      },
    });
    child.stdin.on("close", () => {
      child.stdout.end("after the write\n");
      child.stderr.end();
      child.emit("exit", 0, null);
      setImmediate(() => child.emit("close", 0, null));
    });
    process.nextTick(() => child.emit("spawn"));
    return child;
  };
  return null;
};
