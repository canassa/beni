globalThis.__beniWorkerFingerprint = "9c362eda0a9a938e-1c1928caf485efcb";
const report = event => {
  const cause = event.error ?? event.reason;
  globalThis.postMessage({worker: 1, kind: "Defect", payload: {
    name: typeof cause?.name === "string" ? cause.name.slice(0, 64) : null,
    message: String(cause?.message ?? event.message ?? cause ?? "Worker defect").slice(0, 4096),
    stack: String(cause?.stack ?? "").slice(0, 16384)
  }});
};
globalThis.addEventListener("error", report);
globalThis.addEventListener("unhandledrejection", report);
const pending = [];
const hold = event => {
  event.stopImmediatePropagation();
  if (pending.length === 64) {
    for (const port of event.ports ?? []) port.close();
    throw new RangeError("Worker startup message queue is full");
  }
  pending.push(event);
};
globalThis.addEventListener("message", hold);
globalThis.addEventListener("messageerror", hold);
try {
  const runtime = await import("./_platform/WorkerRuntime.mjs");
  const program = await import("./SingleWorker.mjs");
  runtime.WorkerRuntime$run(program.SingleWorker$worker);
} finally {
  globalThis.removeEventListener("message", hold);
  globalThis.removeEventListener("messageerror", hold);
}
for (const event of pending) globalThis.dispatchEvent(new MessageEvent(event.type, {
  data: event.data, origin: event.origin, lastEventId: event.lastEventId,
  source: event.source, ports: event.ports
}));
