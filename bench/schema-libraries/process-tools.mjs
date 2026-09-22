import { spawn } from "node:child_process";

export function spawnJson(executable, args, { cwd, timeoutMs = 300_000, stderr = "inherit" } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { cwd, stdio: ["ignore", "pipe", stderr] });
    const chunks = [];
    let size = 0;
    const limit = 256 * 1024 * 1024;
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.stdout.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) child.kill("SIGKILL");
      else chunks.push(chunk);
    });
    child.once("error", reject);
    child.once("close", (code, signal) => {
      clearTimeout(timer);
      if (code !== 0) return reject(new Error(`${executable} exited ${code ?? signal}`));
      if (size > limit) return reject(new Error(`${executable} exceeded ${limit} output bytes`));
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch (error) {
        reject(new Error(`${executable} did not emit one JSON document: ${error.message}`));
      }
    });
  });
}
