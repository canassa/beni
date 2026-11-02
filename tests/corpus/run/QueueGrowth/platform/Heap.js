import process from "node:process";
import { setFlagsFromString } from "node:v8";
import { runInNewContext } from "node:vm";

// Keep GC access in this test platform. The ordinary corpus Node invocation
// needs no extra flags, and the runtime exposes no queue inspection hook.
setFlagsFromString("--expose_gc");
const collect = runInNewContext("gc");
let baseline = 0;
export const begin = (_) => {
  collect();
  baseline = process.memoryUsage().heapUsed;
  return null;
};
export const check = (_) => {
  collect();
  const retained = process.memoryUsage().heapUsed - baseline;
  if (retained > 2 * 1024 * 1024) {
    throw new Error(`busy run queue retained ${retained} bytes (budget 2097152)`);
  }
  return null;
};
