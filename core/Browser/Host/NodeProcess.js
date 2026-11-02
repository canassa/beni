export const writeOut = (text) => { globalThis.process.stdout.write(text); return null; };
export const writeError = (text) => { globalThis.process.stderr.write(text); return null; };
export const setExitCode = (code) => { globalThis.process.exitCode = code; return null; };
export const beforeExit = (work) => { globalThis.process.on("beforeExit", () => work(null)); return null; };
