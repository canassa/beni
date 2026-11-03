export const run = (main) => {
  console.log(main.b);
  const original = globalThis.Worker;
  let mode = "normal";
  let unknown;
  let latest;
  const reason = new Error("original reason");
  class ProbeWorker extends globalThis.EventTarget {
    constructor(url, options) {
      super();
      if (mode === "syntax") throw new DOMException("invalid", "SyntaxError");
      if (mode === "security") throw new DOMException("blocked", "SecurityError");
      if (mode === "type") throw new TypeError("trusted URL required");
      if (mode === "unknown constructor" || mode === "named security") throw unknown;
      this.url = url;
      this.options = options;
      this.posts = 0;
      this.terminated = false;
      latest = this;
    }
    postMessage(data) {
      if (mode === "clone") throw new DOMException("not clonable", "DataCloneError");
      if (mode === "unknown post" || mode === "named clone") throw unknown;
      this.posts++;
      if (mode === "metadata") {
        const event = new globalThis.Event("error");
        Object.defineProperty(event, "error", { value: reason });
        this.dispatchEvent(event);
      } else {
        this.dispatchEvent(new globalThis.MessageEvent("message", { data }));
      }
    }
    terminate() { this.terminated = true; }
  }
  const unchanged = (label, phase, name) => {
    mode = label;
    unknown = new Error(label);
    if (name) unknown.name = name;
    let caught = false;
    try { main.a(phase); } catch (error) { if (error !== unknown) throw error; caught = true; }
    if (!caught) throw new Error(`${label} was swallowed`);
    console.log(`${label} unchanged`);
  };
  try {
    globalThis.Worker = undefined;
    console.log(`unsupported: ${main.a(-1)}`);
    globalThis.Worker = ProbeWorker;
    for (const name of ["syntax", "security", "type"]) {
      mode = name;
      console.log(`${name}: ${main.a(0)}`);
    }
    unchanged("unknown constructor", 0);
    unchanged("named security", 0, "SecurityError");
    mode = "clone";
    console.log(`clone: ${main.a(1)}`);
    unchanged("unknown post", 1);
    unchanged("named clone", 1, "DataCloneError");
    mode = "normal";
    console.log(`callbacks: ${main.a(2)}`);
    if (latest.posts !== 2 || !latest.terminated || latest.url !== "worker.js" || JSON.stringify(latest.options) !== JSON.stringify({ type: "module", name: "named", credentials: "same-origin" })) throw new Error("native options or lifecycle changed");
    console.log("native identity and options preserved");
    mode = "metadata";
    console.log(`error callbacks: ${main.a(3)}`);
    if (JSON.stringify(reason.abandonedWorkers) !== '["gone"]') throw new Error("native reason metadata missing");
    console.log("native reason preserved");
    console.log("fixed groups: " + main.a(4));
    console.log("created metadata: " + main.a(5));
    let raised;
    try { main.a(6); } catch (error) { raised = error; }
    if (!(raised instanceof Error) || raised.name !== "MyError2" || raised.message !== "retained message" || raised.code !== "TEST") throw new Error("created error changed");
    console.log("created native reason raised");
    console.log("ordinary event: " + main.c(new globalThis.Event("other")));
    const originalErrorEvent = globalThis.ErrorEvent;
    try {
      globalThis.ErrorEvent = class extends globalThis.Event { constructor(message) { super("error"); this.message = message; } };
      console.log("empty error message: " + JSON.stringify(main.c(new globalThis.ErrorEvent(""))));
      console.log("error message: " + main.c(new globalThis.ErrorEvent("MyError2: message")));
    } finally { globalThis.ErrorEvent = originalErrorEvent; }
    const originalWindow = globalThis.window;
    try { globalThis.window = {}; console.log("page groups: " + main.a(4)); }
    finally { if (originalWindow === undefined) delete globalThis.window; else globalThis.window = originalWindow; }
  } finally {
    globalThis.Worker = original;
  }
};
