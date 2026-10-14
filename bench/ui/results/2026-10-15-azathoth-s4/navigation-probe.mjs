// Diagnostic only, not a timing. Reproduce Chrome's navigation fuzz failure
// while logging the action and the current document's dispatch hooks.
// node navigation-probe.mjs --beni=<binary> --chrome=<Chrome> [--out=<dir>] [--first=tea|direct]
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "../../lib/cdp.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const repo = fileURLToPath(new URL("../../../../", import.meta.url));
const beni = arg("beni", join(repo, "zig-out/bin/beni"));
const out = arg("out", fileURLToPath(new URL("./", import.meta.url)));
const first = arg("first", "tea");
if (!["tea", "direct"].includes(first)) throw new Error("--first must be tea or direct");
const scratch = mkdtempSync(join(tmpdir(), "beni-navigation-probe-"));
mkdirSync(out, { recursive: true });
for (const file of ["driver.mjs", "fuzz.mjs", "compile-cache.mjs"]) copyFileSync(join(repo, "tests/browser", file), join(scratch, file));
const source = readFileSync(join(scratch, "fuzz.mjs"), "utf8");
const oldSend = "fault = await p.run(inPage(fuzzSend), action.message);";
const oldRoot = 'const pagesRoot = fileURLToPath(new URL("../../zig-out/browser-fuzz-pages", import.meta.url));';
if (!source.includes(oldSend) || !source.includes(oldRoot)) throw new Error("fuzz diagnostic patch no longer matches");
writeFileSync(join(scratch, "fuzz.mjs"), source.replace(oldRoot, `const pagesRoot = ${JSON.stringify(join(scratch, "pages"))};`).replace(oldSend, `
            process.stderr.write(JSON.stringify({ entry, action: action.line, message: action.message, hooks: await p.run(inPage(function hookState() { return { url: location.href, tea: typeof globalThis.__beniFuzzMounts, direct: typeof globalThis.__beniFuzz }; })) }) + "\\n");
            ${oldSend}`));
const run = (args, stdoutFile = null) => {
  const r = spawnSync(beni, args, { cwd: repo, encoding: "utf8" });
  if (r.status !== 0) throw new Error(r.stderr || `beni exited ${r.status}`);
  if (stdoutFile !== null) writeFileSync(stdoutFile, r.stdout);
};
const browser = await launch({ chrome: arg("chrome", undefined) });
writeFileSync(join(out, `${first}-probe-machine.json`), JSON.stringify({ chrome: browser.version, platform: process.platform, node: process.version, at: new Date().toISOString(), first }, null, 2) + "\n");
try {
  for (const name of ["NavigateCommands", "Router"]) {
    const src = `tests/corpus/browser/direct/${name}.beni`;
    const tea = join(scratch, `${name}-tea`);
    const direct = join(scratch, `${name}-direct`);
    const types = join(scratch, `${name}-types.jsonl`);
    run(["build", "--platform=browser-tea", "--fuzz", "--no-cache", `--out=${tea}`, src]);
    run(["build", "--platform=browser-direct", "--fuzz", "--no-cache", `--out=${direct}`, src]);
    run(["dump", "--stage=writes", "--platform=browser-tea", "--msg-types", src], types);
    const spec = join(scratch, `${name}-spec.json`);
    const result = join(out, `${name}-${first}-probe.json`);
    writeFileSync(spec, JSON.stringify({ a: join(first === "tea" ? tea : direct, "_main.mjs"), b: join(first === "tea" ? direct : tea, "_main.mjs"), labelA: `browser-${first}`, labelB: first === "tea" ? "browser-direct" : "browser-tea", types, values: true, script: join(repo, `tests/corpus/browser/direct/${name}.steps`), ignore: ["^console\\.log: "], crash: "same", seeds: [1], steps: 30, shrink: true, replay: true }));
    const r = spawnSync(process.execPath, [join(scratch, "driver.mjs"), `--chrome=${browser.ws.url}`, `--fuzz=${spec}@${result}`], { cwd: repo, encoding: "utf8" });
    writeFileSync(join(out, `${name}-${first}-probe.log`), r.stdout + "\n" + r.stderr + `\ndriver exit ${r.status}\n`);
    console.log(`${name}: ${readFileSync(result, "utf8")}`);
  }
} finally {
  await browser.close();
}
