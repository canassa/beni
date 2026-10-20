// The cost of one WebSocket message in a page (docs/design/boundary.md
// §9.11 (m)): from the host's `message` event to `update` and the render,
// each message in a task of its own, as a game's 30 states a second
// arrive, and each a new state of about 1 KiB, so the render writes it.
// Beside it, the same work written by hand in JavaScript on the same DOM,
// and a click's message on the beni page. happy-dom in Node, as §9.8.11's
// commands are measured.
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

// A state of about 1 KiB, a new string for every tick, as a server sends.
// The strings are made before the clock starts, so making them is not
// counted.
const states = Array.from({ length: n }, (_, tick) => `{"tick":${tick},"players":[${Array.from({ length: 20 }, (_, i) => `{"id":${i},"x":${(tick + i * 3) % 64},"y":${i * 5},"dir":"up","score":${i * 10}}`).join(",")}]}`);
let next = 0;
const nextState = () => {
  next = (next + 1) % n;
  return states[next];
};
const dispatch = (target) => {
  const event = new Event("message");
  Object.defineProperty(event, "data", { value: nextState() });
  target.dispatchEvent(event);
};
const message = () => dispatch(socket);
// The same page by hand: a listener that keeps the state and a count, and
// writes the two texts that changed, as the beni view does.
const handSocket = new EventTarget();
const hand = document.createElement("section");
const handState = document.createElement("p");
const handCount = document.createElement("p");
hand.append(handState, handCount);
document.body.append(hand);
let handModel = { state: "", count: 0 };
handSocket.addEventListener("message", (event) => {
  handModel = { state: event.data, count: handModel.count + 1 };
  queueMicrotask(() => {
    if (handState.textContent !== handModel.state) handState.textContent = handModel.state;
    handCount.textContent = String(handModel.count);
  });
});
const byHand = () => dispatch(handSocket);
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
for (const what of [message, byHand, click, nothing]) await time(what);
const best = async (what) => Math.min(await time(what), await time(what), await time(what));
const base = await best(nothing);
const perMessage = (await best(message)) - base;
const perHand = (await best(byHand)) - base;
const perClick = (await best(click)) - base;
const shown = document.querySelector("main").querySelectorAll("p")[1].textContent;
console.log(
  JSON.stringify({ messages: n, stateBytes: nextState().length, baseNs: Math.round(base), messageNs: Math.round(perMessage), byHandNs: Math.round(perHand), clickNs: Math.round(perClick), count: shown }),
);
process.exit(0);
