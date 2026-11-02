import process from "node:process";
export const count = Number(process.argv[2]);
let baseline = 0;
export const begin = (_) => {
  globalThis.gc();
  baseline = process.memoryUsage().heapUsed;
  globalThis.console.log("FIBER_COST_BEGIN");
  return null;
};
export const mark = (label) => {
  const allocated = process.memoryUsage().heapUsed - baseline;
  globalThis.console.log("FIBER_COST_END " + JSON.stringify({label, count, allocated}));
  globalThis.gc();
  globalThis.console.log("FIBER_COST_RETAINED " + JSON.stringify({label, count, retained: process.memoryUsage().heapUsed - baseline}));
  return null;
};
