// Replaces `fs.promises.readFile` with one that always rejects with an
// error whose `code` is `toString`: a key the table does not own, which
// `Object.hasOwn` must refuse where a plain lookup would find the
// prototype's method and answer a `FileError`. `Io.beni` asks
// `process.getBuiltinModule` for the module at each read, so it sees the
// replaced property as it is.
import fs from "node:fs/promises";

export const breakReads = (unit) => {
  fs.readFile = () => {
    const error = new Error("a rejection whose code is an inherited key");
    error.code = "toString";
    return Promise.reject(error);
  };
  return unit;
};
