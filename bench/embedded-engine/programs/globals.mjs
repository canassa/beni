// The global names a raw context offers, minus the host prelude's.
const prelude = new Set(["console", "setTimeout", "clearTimeout", "setImmediate", "queueMicrotask", "process", "__write", "__exitCode", "__tick", "__beforeExit", "__pending"]);
console.log(Object.getOwnPropertyNames(globalThis).filter((n) => !prelude.has(n)).sort().join(" "));
