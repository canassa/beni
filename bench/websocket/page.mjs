// The cost of one WebSocket message in a page (docs/design/boundary.md
// §9.11 (m)): from the host's `message` event to `update` and the render,
// each message in a task of its own, as a game's 30 states a second
// arrive; and, on the same page, a click's message, for comparison.
// happy-dom in Node, as §9.8.11's commands are measured.
//
//   beni build --release --platform=browser-tea --out=<build> bench/websocket/page
//   node bench/websocket/page.mjs tests/browser/happy-dom.mjs <build>/_main.mjs [messages]
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
import { setImmediate as turn } from "node:timers/promises";

const [domPath, entry, count = "20000"] = process.argv.slice(2);
const n = Number(count);
const { GlobalWindow } = await import(pathToFileURL(resolve(domPath)).href);
const window = new GlobalWindow({ url: "http://127.0.0.1:8000/_page.html" });
for (const [key, descriptor] of Object.entries(Object.getOwnPropertyDescriptors(window))) {
  if (["constructor", "undefined", "NaN", "global", "globalThis", "console"].includes(key)) continue;
  const own = Object.getOwnPropertyDescriptor(globalThis, key);
  if (own !== undefined && own.value !== undefined && own.value === descriptor.value) continue;
  if (descriptor.value === window) descriptor.value = globalThis;
  Object.defineProperty(globalThis, key, { ...descriptor, configurable: true });
}
for (const method of ["addEventListener", "removeEventListener", "dispatchEvent"]) globalThis[method] = window[method].bind(window);

// A socket that opens when asked and hands the page the messages it is given.
let socket = null;
globalThis.WebSocket = class extends EventTarget {
  constructor(url) {
    super();
    this.url = url;
    this.readyState = 0;
    this.protocol = "";
    this.bufferedAmount = 0;
    socket = this;
  }
  send() {}
  close() {
    this.readyState = 2;
  }
};
await import(pathToFileURL(resolve(entry)).href);
for (let i = 0; i < 5; i++) await turn();
socket.readyState = 1;
socket.dispatchEvent(new Event("open"));
for (let i = 0; i < 5; i++) await turn();

const state = `{"tick":0,"players":[${Array.from({ length: 8 }, (_, i) => `{"id":${i},"x":${i * 3},"y":${i * 5},"dir":"up","score":${i * 10}}`).join(",")}]}`;
const message = () => {
  const event = new Event("message");
  Object.defineProperty(event, "data", { value: state });
  socket.dispatchEvent(event);
};
const button = document.getElementById("b");
const click = () => button.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
const nothing = () => {};

const time = async (what) => {
  const start = process.hrtime.bigint();
  for (let i = 0; i < n; i++) {
    what();
    await turn();
  }
  return Number(process.hrtime.bigint() - start) / n;
};
// Warm up, then measure each three times and keep the fastest.
for (const what of [message, click, nothing]) await time(what);
const best = async (what) => Math.min(await time(what), await time(what), await time(what));
const base = await best(nothing);
const perMessage = (await best(message)) - base;
const perClick = (await best(click)) - base;
const shown = document.querySelectorAll("p")[1].textContent;
console.log(JSON.stringify({ messages: n, baseNs: Math.round(base), messageNs: Math.round(perMessage), clickNs: Math.round(perClick), count: shown }));
process.exit(0);
