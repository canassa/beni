// Replaces `fs.promises.readdir` with one that always rejects with an error
// carrying `code`, and pushes the change to the ESM binding `Io.js` imports.
import fs from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";

export const failListings = (code) => {
  fs.readdir = () => {
    const error = new Error(`${code}: injected failure, scandir`);
    error.code = code;
    error.syscall = "scandir";
    return Promise.reject(error);
  };
  syncBuiltinESMExports();
  return null;
};
