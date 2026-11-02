export const readUtf8 = (path, signal) => { return globalThis.process.getBuiltinModule("node:fs/promises").readFile(path, { encoding: "utf8", signal }); };
export const readDir = (path) => { return globalThis.process.getBuiltinModule("node:fs/promises").readdir(path, { withFileTypes: true }); };
