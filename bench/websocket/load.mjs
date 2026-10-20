// Load for the arena server (docs/design/boundary.md §9.11 (m)): `players`
// WebSocket clients (Node's own `WebSocket`) join, each sends an input 5
// times a second, and every state the server ticks is counted, for
// `seconds`. Prints, as JSON: the ticks, the messages each client got, the
// server's CPU time and instructions over the window (`perf stat -p`), and
// how far apart the first and the last client got one tick.
//
//   beni build --release --allow-debug --platform=node --out=<build> bench/websocket/server
//   node bench/websocket/load.mjs <perf> <build>/_main.mjs [players] [seconds]
import { spawn, execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const [perf, entry, playersArg = "100", secondsArg = "10"] = process.argv.slice(2);
const players = Number(playersArg);
const seconds = Number(secondsArg);
const server = spawn(process.execPath, [entry], { stdio: ["ignore", "pipe", "inherit"] });
const port = await new Promise((resolve) => {
  let text = "";
  server.stdout.on("data", (chunk) => {
    text += chunk;
    const m = text.match(/port: (\d+)/);
    if (m) resolve(Number(m[1]));
  });
});
const cpu = () => {
  const fields = readFileSync(`/proc/${server.pid}/stat`, "utf8").split(") ")[1].split(" ");
  return (Number(fields[11]) + Number(fields[12])) * 10; // utime + stime, in ms (100 Hz ticks)
};

const arrivals = new Map(); // tick -> [first, last, count]
let received = 0;
const clients = [];
for (let i = 0; i < players; i++) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/arena`);
  await new Promise((resolve) => ws.addEventListener("open", resolve, { once: true }));
  ws.addEventListener("message", (event) => {
    received += 1;
    const now = performance.now();
    const n = Number(event.data.slice(5, event.data.indexOf(" ", 5)));
    const a = arrivals.get(n);
    if (a === undefined) arrivals.set(n, [now, now, 1]);
    else {
      a[1] = now;
      a[2] += 1;
    }
  });
  clients.push(ws);
}
const inputs = setInterval(() => {
  for (const ws of clients) ws.send(Math.random() < 0.5 ? "left" : "right");
}, 200);
await new Promise((resolve) => setTimeout(resolve, 1000));
received = 0;
arrivals.clear();
const cpuStart = cpu();
const counter = spawn(perf, ["stat", "-x,", "-e", "instructions:u", "-p", String(server.pid), "--", "sleep", String(seconds)], { stdio: ["ignore", "ignore", "pipe"] });
let perfText = "";
counter.stderr.on("data", (chunk) => (perfText += chunk));
await new Promise((resolve) => counter.on("close", resolve));
const cpuMs = cpu() - cpuStart;
clearInterval(inputs);
const instructions = Number(perfText.split("\n").find((l) => l.includes("instructions")).split(",")[0]);
const full = [...arrivals.values()].filter((a) => a[2] === players);
const spreads = full.map((a) => a[1] - a[0]).sort((x, y) => x - y);
const pct = (p) => spreads[Math.min(spreads.length - 1, Math.floor((p / 100) * spreads.length))];
const sent = received;
console.log(
  JSON.stringify({
    players,
    seconds,
    ticksPerSecond: Math.round((full.length / seconds) * 10) / 10,
    messagesPerSecond: Math.round(sent / seconds),
    inputsPerSecond: players * 5,
    serverCpuPercent: Math.round((cpuMs / (seconds * 1000)) * 1000) / 10,
    serverMicrosPerMessage: Math.round(((cpuMs * 1000) / (sent + players * 5 * seconds)) * 10) / 10,
    serverInstructionsPerMessage: Math.round(instructions / (sent + players * 5 * seconds)),
    tickSpreadMsP50: Math.round(pct(50) * 100) / 100,
    tickSpreadMsP99: Math.round(pct(99) * 100) / 100,
  }),
);
for (const ws of clients) ws.close(1000);
server.kill("SIGTERM");
process.exit(0);
