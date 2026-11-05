// Replaces `child_process.spawn` with one whose child reports an `error`
// event with code `toString`: a key the table does not own, which
// `Object.hasOwn` must refuse where a plain lookup would find the
// prototype's method and answer a `RunError`.
import childProcess from "node:child_process";
import { EventEmitter } from "node:events";
import process from "node:process";

export const breakSpawns = (unit) => {
  childProcess.spawn = (file) => {
    const error = new Error(`spawn ${file} toString`);
    error.code = "toString";
    error.syscall = `spawn ${file}`;
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
  return unit;
};
