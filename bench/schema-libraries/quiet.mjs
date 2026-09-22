import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export async function assertNoCompetingBuilds() {
  const { stdout } = await execFileAsync("ps", ["-axo", "pid=,command="], { maxBuffer: 8 * 1024 * 1024 });
  const competitors = stdout.split("\n").map((line) => line.trim()).filter(Boolean).filter((line) => {
    const match = /^(\d+)\s+(.*)$/.exec(line);
    if (!match || Number(match[1]) === process.pid) return false;
    const command = match[2];
    return /(?:^|\s)zig\s+build(?:\s|$)|(?:^|\s)npm\s+(?:ci|install)(?:\s|$)|(?:^|\s)(?:t|tt)sc(?:\s|$)|build-sources\.sh/.test(command);
  });
  if (competitors.length > 0) throw new Error(`refusing measurement while builds are active: ${competitors.join(" | ")}`);
  return { checked: true, command: "ps -axo pid=,command=", competitors: [] };
}
