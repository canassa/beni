import { createHash } from "node:crypto";
import { readFile, realpath } from "node:fs/promises";
import { fileURLToPath } from "node:url";

// Refuse the easy-to-miss `npm ci`-only install: that restores registry code.
// Source builds are not evidence unless these are the files we actually load.
export async function verifySources() {
  const provenance = JSON.parse(await readFile(new URL("./provenance.json", import.meta.url), "utf8"));
  const repo = new URL("../../", import.meta.url);
  const checks = [];
  for (const [name, subject] of Object.entries(provenance.subjects)) {
    const entry = await realpath(fileURLToPath(import.meta.resolve(name)));
    const expected = await realpath(fileURLToPath(new URL(subject.runtimeEntry, repo)));
    const hash = createHash("sha256").update(await readFile(entry)).digest("hex");
    if (entry !== expected || hash !== subject.runtimeEntrySha256) {
      throw new Error(`${name}: measured source entry differs from provenance; run setup and review provenance before timing`);
    }
    checks.push({ name, entry: subject.runtimeEntry, sha256: hash, passed: true });
  }
  return checks;
}
