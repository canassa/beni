// A small Chrome DevTools Protocol client over Node's built-in WebSocket:
// one long-lived headless Chrome, a fresh page target per iteration
// (research 26 §9, research 29 §1.2). Chrome is launched with the flags
// js-framework-benchmark's `webdriverCDPAccess.ts` `buildDriver` passes.

import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export const officialFlags = [
  "--js-flags=--expose-gc",
  "--enable-precise-memory-info",
  "--no-first-run",
  "--disable-background-networking",
  "--disable-background-timer-throttling",
  "--disable-cache",
  "--disable-translate",
  "--disable-sync",
  "--disable-extensions",
  "--disable-default-apps",
  "--window-size=1280,800",
  "--headless=new",
  "--disable-gpu",
  "--no-sandbox",
];

export async function launch({ chrome = process.env.CHROME ?? "chromium", taskset = null } = {}) {
  const profile = mkdtempSync(join(tmpdir(), "bench-ui-chrome-"));
  const args = [...officialFlags, `--user-data-dir=${profile}`, "--remote-debugging-port=0", "about:blank"];
  const child = taskset === null ? spawn(chrome, args, { stdio: "ignore" }) : spawn("taskset", ["-c", taskset, chrome, ...args], { stdio: "ignore" });
  const portFile = join(profile, "DevToolsActivePort");
  for (let i = 0; i < 300 && !existsSync(portFile); i++) await sleep(50);
  let text = "";
  for (let i = 0; i < 100; i++) {
    text = existsSync(portFile) ? readFileSync(portFile, "utf8") : "";
    if (text.includes("\n")) break;
    await sleep(50);
  }
  const [port, path] = text.trim().split("\n");
  if (!port) throw new Error("Chrome did not start");
  const ws = new WebSocket(`ws://127.0.0.1:${port}${path}`);
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = reject;
  });
  const browser = new Browser(ws, child, profile);
  const version = await browser.send("Browser.getVersion");
  browser.version = version.product;
  return browser;
}

class Browser {
  constructor(ws, child, profile) {
    this.ws = ws;
    this.child = child;
    this.profile = profile;
    this.id = 0;
    this.pending = new Map();
    this.listeners = new Set();
    ws.onmessage = (event) => {
      const msg = JSON.parse(event.data);
      if (msg.id !== undefined) {
        const p = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) p.reject(new Error(`${p.method}: ${msg.error.message}`));
        else p.resolve(msg.result);
      } else for (const l of this.listeners) l(msg);
    };
  }

  send(method, params = {}, sessionId = undefined) {
    const id = ++this.id;
    const msg = { id, method, params };
    if (sessionId !== undefined) msg.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, method });
      this.ws.send(JSON.stringify(msg));
    });
  }

  on(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  async newPage(url) {
    const { targetId } = await this.send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await this.send("Target.attachToTarget", { targetId, flatten: true });
    const page = new Page(this, targetId, sessionId);
    await page.send("Page.enable");
    await page.send("Runtime.enable");
    const loaded = page.once("Page.loadEventFired");
    await page.send("Page.navigate", { url });
    await loaded;
    return page;
  }

  async close() {
    try {
      await this.send("Browser.close");
    } catch {}
    this.child.kill();
    await sleep(200);
    rmSync(this.profile, { recursive: true, force: true });
  }
}

class Page {
  constructor(browser, targetId, sessionId) {
    this.browser = browser;
    this.targetId = targetId;
    this.sessionId = sessionId;
  }

  send(method, params = {}) {
    return this.browser.send(method, params, this.sessionId);
  }

  once(method) {
    return new Promise((resolve) => {
      const off = this.browser.on((msg) => {
        if (msg.sessionId === this.sessionId && msg.method === method) {
          off();
          resolve(msg.params);
        }
      });
    });
  }

  async eval(expression) {
    const r = await this.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(`page: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
    return r.result.value;
  }

  async waitFor(expression, timeout = 20000) {
    const start = Date.now();
    for (;;) {
      if (await this.eval(expression)) return;
      if (Date.now() - start > timeout) throw new Error(`timed out waiting for ${expression}`);
      await sleep(10);
    }
  }

  // A real click at the element's centre, so the trace carries an
  // `EventDispatch` of type `click` (research 29 §1.2).
  async click(finder) {
    await this.press(await this.locate(finder));
  }

  // The element's centre, scrolled into view; done before a trace starts,
  // so the trace holds the click and not the scroll.
  async locate(finder) {
    const box = await this.eval(`(() => { const el = ${finder}; if (!el) return null; el.scrollIntoView({ block: "center" }); const r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()`);
    if (box === null) throw new Error(`no element for ${finder}`);
    return box;
  }

  async press(box) {
    const base = { x: box.x, y: box.y, button: "left", clickCount: 1 };
    await this.send("Input.dispatchMouseEvent", { type: "mousePressed", ...base });
    await this.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...base });
  }

  async close() {
    await this.browser.send("Target.closeTarget", { targetId: this.targetId });
  }
}

// Collect a trace of the given categories while `body` runs.
export async function traced(page, categories, body) {
  const events = [];
  const off = page.browser.on((msg) => {
    if (msg.sessionId === page.sessionId && msg.method === "Tracing.dataCollected") events.push(...msg.params.value);
  });
  await page.send("Tracing.start", { traceConfig: { includedCategories: categories }, transferMode: "ReportEvents" });
  try {
    await body();
  } finally {
    const done = page.once("Tracing.tracingComplete");
    await page.send("Tracing.end");
    await done;
    off();
  }
  return events;
}
