// Replaces `fs.promises.readFile` with one that always rejects with an
// `EIO` error, and pushes the change to the ESM binding `Io.js` imports.
import fs from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";

export const breakReads = (unit) => {
  fs.readFile = () => {
    const error = new Error("EIO: i/o error, read");
    error.code = "EIO";
    error.errno = -5;
    error.syscall = "read";
    return Promise.reject(error);
  };
  syncBuiltinESMExports();
  return unit;
};
