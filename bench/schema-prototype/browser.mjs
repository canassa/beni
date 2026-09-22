import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { spawn } from "node:child_process";

const DEFAULT_CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const TIMEOUT_MS = 20000;

const deadline = (promise, ms, label) => {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms} ms`)), ms);
    }),
  ]).finally(() => clearTimeout(timer));
};

class Cdp {
  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    this.waiters = [];
    socket.addEventListener("message", (event) => this.receive(JSON.parse(event.data)));
  }

  receive(message) {
    if (message.id !== undefined) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message));
      else pending.resolve(message.result);
      return;
    }
    for (const waiter of [...this.waiters]) {
      if (waiter.method === message.method && (!waiter.sessionId || waiter.sessionId === message.sessionId)) {
        this.waiters.splice(this.waiters.indexOf(waiter), 1);
        waiter.resolve(message.params);
      }
    }
  }

  send(method, params = {}, sessionId = undefined) {
    const id = this.nextId++;
    const response = new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
    this.socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    return deadline(response, TIMEOUT_MS, `CDP ${method}`);
  }

  event(method, sessionId) {
    return deadline(
      new Promise((resolve) => this.waiters.push({ method, sessionId, resolve })),
      TIMEOUT_MS,
      `CDP event ${method}`,
    );
  }
}

async function launch(chromePath) {
  const profile = await mkdtemp(join(tmpdir(), "beni-schema-chrome-"));
  const child = spawn(
    chromePath,
    [
      "--headless=new",
      "--disable-gpu",
      "--disable-background-networking",
      "--disable-component-update",
      "--disable-default-apps",
      "--disable-extensions",
      "--disable-sync",
      "--no-first-run",
      "--no-default-browser-check",
      "--allow-file-access-from-files",
      "--remote-debugging-port=0",
      `--user-data-dir=${profile}`,
      "about:blank",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  let stderr = "";
  const endpoint = deadline(
    new Promise((resolve, reject) => {
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", (chunk) => {
        stderr += chunk;
        const found = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
        if (found) resolve(found[1]);
      });
      child.once("error", reject);
      child.once("exit", (code, signal) => reject(new Error(`Chrome exited before CDP was ready (${code ?? signal})\n${stderr}`)));
    }),
    TIMEOUT_MS,
    "Chrome startup",
  );
  try {
    return { child, profile, endpoint: await endpoint, stderr: () => stderr };
  } catch (failure) {
    child.kill("SIGKILL");
    await rm(profile, { recursive: true, force: true });
    throw failure;
  }
}

const median = (values) => {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
};

export async function measureBrowser(outDir, expected, options = {}) {
  const chromePath = options.chromePath ?? DEFAULT_CHROME;
  const launched = await launch(chromePath);
  let socket;
  try {
    socket = new WebSocket(launched.endpoint);
    await deadline(
      new Promise((resolve, reject) => {
        socket.addEventListener("open", resolve, { once: true });
        socket.addEventListener("error", () => reject(new Error("Chrome CDP WebSocket failed")), { once: true });
      }),
      TIMEOUT_MS,
      "CDP connection",
    );
    const cdp = new Cdp(socket);
    const version = await cdp.send("Browser.getVersion");
    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    const attached = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    const session = attached.sessionId;
    await cdp.send("Page.enable", {}, session);
    await cdp.send("Runtime.enable", {}, session);
    const loaded = cdp.event("Page.loadEventFired", session);
    const reported = cdp.event("Runtime.consoleAPICalled", session);
    const pageUrl = pathToFileURL(join(outDir, "browser.html"));
    pageUrl.searchParams.set("run", `${Date.now()}`);
    await cdp.send("Page.navigate", { url: pageUrl.href }, session);
    await Promise.all([loaded, reported]);

    const read = await cdp.send(
      "Runtime.evaluate",
      {
        expression: "JSON.stringify(globalThis.__schemaPrototype)",
        returnByValue: true,
      },
      session,
    );
    if (read.exceptionDetails || typeof read.result?.value !== "string") {
      throw new Error("browser did not expose globalThis.__schemaPrototype");
    }
    const result = JSON.parse(read.result.value);
    if (JSON.stringify(result) !== JSON.stringify(expected)) {
      throw new Error(`browser result differs from Node\nexpected ${JSON.stringify(expected)}\nactual   ${JSON.stringify(result)}`);
    }

    const expectedBenchmark = options.benchmarkExpected;
    if (!Number.isInteger(expectedBenchmark?.iterations) || expectedBenchmark.iterations <= 0) {
      throw new Error("benchmark expectation needs a positive integer iteration count");
    }
    const benchmark = await cdp.send(
      "Runtime.evaluate",
      {
        expression: `(async () => {
          const module = await import("./Benchmark.mjs?benchmark=" + Date.now());
          const functions = Object.values(module).filter((value) => typeof value === "function");
          if (functions.length !== 1) throw new Error("Benchmark.mjs must export exactly one function");
          const run = functions[0];
          const iterations = ${JSON.stringify(expectedBenchmark.iterations)};
          run(5);
          const samples = [];
          let checksum = null;
          for (let sample = 0; sample < 11; sample++) {
            const start = performance.now();
            const answer = run(iterations);
            samples.push(performance.now() - start);
            if (checksum === null) checksum = answer;
            else if (answer !== checksum) throw new Error("benchmark checksum changed between samples");
          }
          return { iterations, samples_ms: samples, checksum };
        })()`,
        awaitPromise: true,
        returnByValue: true,
      },
      session,
    );
    if (benchmark.exceptionDetails || !benchmark.result?.value) {
      const detail = benchmark.exceptionDetails?.exception?.description ?? "unknown browser benchmark failure";
      throw new Error(detail);
    }
    const timing = benchmark.result.value;
    if (
      !expectedBenchmark ||
      expectedBenchmark.iterations !== timing.iterations ||
      expectedBenchmark.checksum !== timing.checksum
    ) {
      throw new Error(
        `benchmark checksum differs: expected ${JSON.stringify(expectedBenchmark)}, actual ${JSON.stringify({ iterations: timing.iterations, checksum: timing.checksum })}`,
      );
    }
    timing.operation = expectedBenchmark.operation;
    timing.median_ms = median(timing.samples_ms);
    timing.median_ms_per_iteration = timing.median_ms / timing.iterations;
    return {
      engine: version.product,
      user_agent: version.userAgent,
      platform: process.platform,
      architecture: process.arch,
      parity: result,
      timing,
    };
  } finally {
    if (socket && socket.readyState < WebSocket.CLOSING) socket.close();
    launched.child.kill("SIGKILL");
    await deadline(
      new Promise((resolve) => launched.child.once("exit", resolve)),
      5000,
      "Chrome shutdown",
    ).catch(() => {});
    await rm(launched.profile, { recursive: true, force: true });
  }
}
