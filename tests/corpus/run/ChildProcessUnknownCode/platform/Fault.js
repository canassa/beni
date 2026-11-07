// Replaces `child_process.spawn` with one that fails with `code` by the
// route Node takes for it (`ChildProcess.prototype.spawn`): EACCES,
// EAGAIN, EMFILE, ENFILE and ENOENT as the child's `error` event and then
// `close`, with no pipes, as Node does for EMFILE; every other code thrown
// from the call. `ChildProcess.beni` asks `process.getBuiltinModule` for
// the module at each run, so it sees the replaced property.
import childProcess from "node:child_process";
import { EventEmitter } from "node:events";
import process from "node:process";

const asEvent = new Set(["EACCES", "EAGAIN", "EMFILE", "ENFILE", "ENOENT"]);

export const failSpawns = (code) => {
  childProcess.spawn = (file) => {
    const error = new Error(`spawn ${file} ${code}`);
    error.code = code;
    error.syscall = asEvent.has(code) ? `spawn ${file}` : "spawn";
    if (!asEvent.has(code)) throw error;
    const child = new EventEmitter();
    child.stdout = null;
    child.stderr = null;
    child.kill = () => false;
    process.nextTick(() => {
      child.emit("error", error);
      child.emit("close", -1, null);
    });
    return child;
  };
  return null;
};
