// run.mjs: build each generated program two times, run both, and compare.
//
//   node bench/ownership-sweeps/run.mjs --beni=<beni> --checker=v3 [--jobs=N] [--tmp=<dir>] [--tag=<name>] <outdir>
//
// <outdir> is a directory that a generator of this folder wrote (it has a LIST). The oracle is a plain
// build: no list is edited in place. The second build has `--ownership=<checker> --ownership-everywhere
// --sanitize-lists`. Each program gets one verdict: SAME (accepted, same output), REFUSED (with its
// first code and position), LIMIT, TRAP (the checked build throws: a stale read), DIFF (another output),
// CRASH (the compiler fails), PLAINFAIL (the generated program does not build), BOTHFAIL. The results
// go to <outdir>.<checker>.txt, one line for each program (<outdir>.<tag>.txt with `--tag`, to keep the
// results of two compilers apart). A rerun skips the programs that have a line.
// Last, a tally by verdict and by the program's last name part (`live`, `kept`, `dead`, …): a dead
// twin reads nothing after the write, so a refusal of it is a precision loss, and a TRAP or DIFF of any
// program is a soundness hole.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const opt = Object.fromEntries(process.argv.slice(2).filter((a) => a.startsWith('--')).map((a) => {
  const [k, v] = a.slice(2).split('=');
  return [k, v ?? 'true'];
}));
const dir = process.argv.slice(2).find((a) => !a.startsWith('--'));
if (!dir || !opt.beni || !opt.checker) {
  console.error('usage: node bench/ownership-sweeps/run.mjs --beni=<beni> --checker=v2|v3 [--jobs=N] [--tmp=<dir>] <outdir>');
  process.exit(2);
}
const beni = path.resolve(opt.beni);
const jobs = Number(opt.jobs ?? Math.max(1, os.cpus().length >> 1));
const tmpRoot = path.resolve(opt.tmp ?? os.tmpdir());
const results = `${path.resolve(dir)}.${opt.tag ?? opt.checker}.txt`;

function run(cmd, args, cwd, timeoutMs) {
  return new Promise((resolve) => {
    const p = spawn(cmd, args, { cwd, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { out += d; });
    const t = setTimeout(() => p.kill('SIGKILL'), timeoutMs);
    p.on('close', (code, signal) => { clearTimeout(t); resolve({ code: signal ? -1 : code, out }); });
  });
}

async function judge(prog) {
  const tmp = fs.mkdtempSync(path.join(tmpRoot, 'sweep-'));
  try {
    const files = fs.readdirSync(prog).filter((f) => f.endsWith('.beni'));
    const build = (extra, out, ms) =>
      run(beni, ['build', '--no-cache', '--jobs=1', '--platform=node', ...extra, `--out=${path.join(tmp, out)}`, ...files], prog, ms);
    const plain = await build([], 'p', 60_000);
    if (plain.code !== 0) {
      return plain.code === 1 && !plain.out.includes('panic:') ? `PLAINFAIL` : `CRASH plain ${plain.code}`;
    }
    const plainRun = await run('node', [path.join(tmp, 'p', '_main.mjs')], prog, 20_000);
    const flags = [`--ownership=${opt.checker}`, '--ownership-everywhere', '--sanitize-lists'];
    const checked = await build(flags, 's', 120_000);
    if (checked.code !== 0) {
      if (checked.code !== 1 || checked.out.includes('panic:')) return `CRASH ${checked.code}`;
      if (checked.out.includes('ownership_summary_size')) return 'LIMIT';
      const code = checked.out.match(/refused: ([a-z_-]+)/)?.[1] ?? '';
      const where = checked.out.match(/^-- [A-Z ]+ -+ (\S+:\d+:\d+)/m)?.[1] ?? '';
      return `REFUSED ${code} ${where}`.trim();
    }
    const checkedRun = await run('node', [path.join(tmp, 's', '_main.mjs')], prog, 20_000);
    if (checkedRun.code !== 0 && plainRun.code !== 0) return 'BOTHFAIL';
    if (checkedRun.code !== 0) return `TRAP ${checkedRun.out.split('\n').find((l) => /stale|sanit|Error/.test(l))?.slice(0, 100) ?? ''}`.trim();
    return checkedRun.out === plainRun.out ? 'SAME' : 'DIFF';
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

const list = fs.readFileSync(path.join(dir, 'LIST'), 'utf8').split('\n').filter(Boolean).map((p) => path.resolve(p));
const done = new Set(fs.existsSync(results)
  ? fs.readFileSync(results, 'utf8').split('\n').filter(Boolean).map((l) => l.split(' ')[0]) : []);
const todo = list.filter((p) => !done.has(p));
fs.mkdirSync(tmpRoot, { recursive: true });
let next = 0;
await Promise.all(Array.from({ length: jobs }, async () => {
  while (next < todo.length) {
    const prog = todo[next++];
    fs.appendFileSync(results, `${prog} ${await judge(prog)}\n`);
  }
}));

const tally = new Map();
for (const line of fs.readFileSync(results, 'utf8').split('\n').filter(Boolean)) {
  const [prog, verdict] = line.split(' ');
  const twin = path.basename(prog).split('.').pop();
  const key = `${verdict.padEnd(9)} ${twin}`;
  tally.set(key, (tally.get(key) ?? 0) + 1);
}
console.log(`${results}`);
for (const [k, n] of [...tally].sort()) console.log(`${String(n).padStart(7)}  ${k}`);
