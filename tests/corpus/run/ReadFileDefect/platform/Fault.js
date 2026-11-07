// Replaces `fs.promises.readFile` with one that always rejects with an
// `EIO` error. `Io.beni` asks `process.getBuiltinModule` for the module at
// each read, so it sees the replaced property as it is.
import fs from "node:fs/promises";

export const breakReads = (unit) => {
  fs.readFile = () => {
    const error = new Error("EIO: i/o error, read");
    error.code = "EIO";
    error.errno = -5;
    error.syscall = "read";
    return Promise.reject(error);
  };
  return unit;
};
