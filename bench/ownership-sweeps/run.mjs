// run.mjs: build each generated program two times, run both, and compare.
//
//   node bench/ownership-sweeps/run.mjs --beni=<beni> --checker=v3 [--mode=sanitize|inplace|both] [--jobs=N] [--tmp=<dir>] [--tag=<name>] <outdir>
//
// <outdir> is a directory that a generator of this folder wrote (it has a LIST). The oracle is a plain
// build: no list is edited in place. The second build has `--ownership=<checker> --ownership-everywhere
// --sanitize-lists` (`--mode=sanitize`, the default): each accepted write copies and poisons, and an
// identity compare an in-place write would change traps. `--mode=inplace` builds with `--lists-in-place`
// instead: each accepted write edits its base's own array, so the output is the in-place truth.
// `--mode=both` builds all three, and an in-place fault is IPTRAP or IPDIFF when the sanitised run passes
// (the line then ends with `ip=<verdict>`). `--mode=both` also builds the program under `--release` two times, plain
// and in place, so the release optimiser is inside the oracle (research report 141): a release in-place fault is
// RIPTRAP or RIPDIFF when every other leg passes (else the line ends with `rip=<verdict>`: PLAINRUNFAIL, a plain
// release run that fails, is a defect of the release build). Each program gets one verdict: SAME (accepted, same output), REFUSED (with its
// first code and position), LIMIT, TRAP (the checked build throws: a stale read), DIFF (another output),
// CRASH (the compiler fails), PLAINFAIL (the generated program does not build), BOTHFAIL (both runs fail, and
// what they printed agrees once the stack frames and the output directories are set aside; it differs:
// DIFF, #2605). The results
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
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const mode = opt.mode ?? 'sanitize';
if (!['sanitize', 'inplace', 'both'].includes(mode)) {
  console.error('--mode is sanitize, inplace or both');
  process.exit(2);
}
const results = `${path.resolve(dir)}.${opt.tag ?? (mode === 'sanitize' ? opt.checker : `${opt.checker}-${mode}`)}.txt`;

function run(cmd, args, cwd, timeoutMs) {
  return new Promise((resolve) => {
    const p = spawn(cmd, args, { cwd, stdio: ['ignore', 'pipe', 'pipe'] });
    // The two streams apart, then joined: their interleaving is the scheduler's, not the program's.
    // Decoded as streams: a chunk can end inside a character of several bytes, and decoding each chunk
    // alone turned it into two U+FFFD, a false DIFF.
    p.stdout.setEncoding('utf8');
    p.stderr.setEncoding('utf8');
    let out = '';
    let err = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { err += d; });
    let timedOut = false;
    const t = setTimeout(() => { timedOut = true; p.kill('SIGKILL'); }, timeoutMs);
    p.on('close', (code, signal) => { clearTimeout(t); resolve({ code: signal ? -1 : code, out: `${out}${err}`, timedOut }); });
  });
}

async function judge(prog) {
  const tmp = fs.mkdtempSync(path.join(tmpRoot, 'sweep-'));
  try {
    const files = fs.readdirSync(prog).filter((f) => f.endsWith('.beni'));
    const pf = path.join(prog, 'PLATFORM');
    const platform = fs.existsSync(pf) ? path.join(root, fs.readFileSync(pf, 'utf8').trim()) : 'node';
    const page = fs.existsSync(path.join(prog, 'steps'));
    // A prerendering build (`corpus.mjs`'s `PRERENDER`): its output is the pages it wrote.
    const prerender = fs.existsSync(path.join(prog, 'PRERENDER'));
    const pages = (dir) => {
      const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))
        .flatMap((e) => e.isDirectory() ? walk(path.join(d, e.name)) : e.name.endsWith('.html') ? [path.join(d, e.name)] : []);
      const at = path.join(tmp, dir);
      return { code: 0, out: walk(at).map((f) => `== ${path.relative(at, f)}\n${fs.readFileSync(f, 'utf8')}`).join('\n') };
    };
    const exec = async (dir) => prerender ? pages(dir) : page
      ? run('node', [path.join(root, 'tests/browser/driver.mjs'), `--dom=${path.join(root, 'tests/browser/happy-dom.mjs')}`, path.join(tmp, dir, '_main.mjs'), path.join(prog, 'steps')], prog, 20_000)
      : run('node', [path.join(tmp, dir, '_main.mjs')], prog, 20_000);
    const build = (extra, out, ms) =>
      run(beni, ['build', '--no-cache', '--jobs=1', `--platform=${platform}`, ...extra, `--out=${path.join(tmp, out)}`, ...files], prog, ms);
    // On a platform of its own (`PLATFORM`), the plain build names the checker v3: a chain that names it
    // (`"ownership": "v3"`, `boundary.md` §5.2) writes in place what v3 accepted, and `--ownership=v3` on
    // the command line keeps the copying build, which is the oracle.
    const plainFlags = opt.checker === 'v3' && fs.existsSync(pf) ? ['--ownership=v3'] : [];
    const oracle = mode === 'inplace' ? '--lists-in-place' : '--sanitize-lists';
    const flags = [`--ownership=${opt.checker}`, '--ownership-everywhere', oracle];
    const refusal = (checked) => {
      if (checked.code !== 1 || checked.out.includes('panic:')) return `CRASH ${checked.code}`;
      // A limit of either checker: v2's `ownership_summary_size` and every `ownership_limit` line.
      if (checked.out.includes('ownership_summary_size') || checked.out.includes('OWNERSHIP CHECK TOO LARGE')) return 'LIMIT';
      const code = checked.out.match(/refused: ([a-z_-]+)/)?.[1] ?? '';
      const where = checked.out.match(/^-- [A-Z ]+ -+ (\S+:\d+:\d+)/m)?.[1] ?? '';
      return `REFUSED ${code} ${where}`.trim();
    };
    const plain = await build(plainFlags, 'p', 60_000);
    if (plain.code !== 0) {
      if (plain.code !== 1 || plain.out.includes('panic:')) return `CRASH plain ${plain.code}`;
      // The plain build of a platform v3 judges enforces it: a program v3 refuses is REFUSED.
      if (plainFlags.length > 0 && /refused: [a-z_-]+/.test(plain.out)) {
        const checked = await build(flags, 's', 120_000);
        if (checked.code !== 0) return refusal(checked);
      }
      return 'PLAINFAIL';
    }
    const plainRun = await exec('p');
    if (plainRun.timedOut) return 'TIMEOUT plain';
    const checked = await build(flags, 's', 120_000);
    if (checked.code !== 0) return refusal(checked);
    // A log line's `timestamp=` and each span's `label=Nms` are the clock's, not the program's: the two
    // fields of a `logfmt` line (`core/Log.beni`) are set aside, and nothing else of it.
    const clock = (line) => !/^timestamp=\S+ level=/.test(line) ? line
      : line.replace(/^timestamp=\S+ /, '').replace(/ ([^\s=]+)=\d+ms(?=\s|$)/g, ' $1=<ms>');
    // A run that fails prints where it failed: a location in its own build (which differs between two
    // builds), the source line there and a caret, then the stack. The output of two failing runs is
    // compared without them, and without a log line's time.
    const norm = (text) => {
      const lines = text.split('\n');
      const kept = [];
      for (let i = 0; i < lines.length; i++) {
        if (/^file:\/\/\S+:\d+$/.test(lines[i])) { i += 2; continue; }
        if (/^\s*at /.test(lines[i]) || lines[i].trim() === '') continue;
        kept.push(clock(lines[i]).split(tmp).join('<tmp>'));
      }
      return kept.join('\n');
    };
    // The error a failed run ended with: its class and message, the stack and the location set aside.
    const errorOf = (text) => text.match(/^(?:Uncaught )?([A-Za-z]*Error): (.*)$/m)?.slice(1).join(': ') ?? null;
    const verdict = async (out, oracle = plainRun) => {
      const r = await exec(out);
      if (r.timedOut) return 'TIMEOUT';
      // Both fail (a defect): what the program printed before it stopped is still judged (#2605). A
      // trap of the sanitiser is a trap; else the outputs must agree, BOTHFAIL when they do.
      if (r.code !== 0 && oracle.code !== 0) {
        // The plain build throws the same error (the program's own defect, whose stack the sanitiser
        // only happens to be on): BOTHFAIL, not a trap.
        const same = errorOf(r.out) !== null && errorOf(r.out) === errorOf(oracle.out);
        if (r.out.includes('_sanitize.mjs') && !same) return `TRAP ${r.out.split('\n').find((l) => /stale|sanit|identity|Error/.test(l))?.slice(0, 100) ?? ''}`.trim();
        return norm(r.out) === norm(oracle.out) ? 'BOTHFAIL' : 'DIFF';
      }
      if (r.code !== 0) return `TRAP ${r.out.split('\n').find((l) => /stale|sanit|identity|Error/.test(l))?.slice(0, 100) ?? ''}`.trim();
      const stamp = (text) => text.split('\n').map(clock).join('\n');
      return stamp(r.out) === stamp(oracle.out) ? 'SAME' : 'DIFF';
    };
    const first = await verdict('s');
    if (mode !== 'both') return first;
    const inPlace = await build([`--ownership=${opt.checker}`, '--ownership-everywhere', '--lists-in-place'], 'i', 120_000);
    if (inPlace.code !== 0) return `CRASH in-place ${inPlace.code}`;
    const second = await verdict('i');
    // BOTHFAIL is a pass of a leg: both runs stopped the same way, with the same output.
    const ok = (v) => v === 'SAME' || v === 'BOTHFAIL';
    if (ok(first) && !ok(second)) return `IP${second}`;
    if (!ok(first) || !ok(second)) return `${first} ip=${second.split(' ')[0]}`;
    const pass = first === 'BOTHFAIL' || second === 'BOTHFAIL' ? 'BOTHFAIL' : 'SAME';
    // The release leg: the plain release build is its oracle, the in-place release build is judged against it.
    // `--allow-debug`: a program whose instrument is `Debug.log` is built as the corpus's release pass builds it.
    const rel = ['--release', '--allow-debug'];
    const plainRel = await build([...rel, ...plainFlags], 'pr', 60_000);
    if (plainRel.code !== 0) return `${pass} ip=${second} rip=${plainRel.code === 1 && !plainRel.out.includes('panic:') ? 'PLAINFAIL' : `CRASH-${plainRel.code}`}`;
    const plainRelRun = await exec('pr');
    if (plainRelRun.timedOut) return `${pass} ip=${second} rip=TIMEOUT-plain`;
    // A plain release run that fails where the development run passed is a defect of the release build,
    // not of the checker: no oracle. Where the development run failed too (a defect), it is the oracle.
    if (plainRelRun.code !== 0 && plainRun.code === 0) return 'SAME ip=SAME rip=PLAINRUNFAIL';
    const inPlaceRel = await build([...rel, `--ownership=${opt.checker}`, '--ownership-everywhere', '--lists-in-place'], 'ir', 120_000);
    if (inPlaceRel.code !== 0) return `CRASH release-in-place ${inPlaceRel.code}`;
    const third = await verdict('ir', plainRelRun);
    if (ok(third)) return pass === 'SAME' && third === 'SAME' ? 'SAME' : 'BOTHFAIL';
    if (third === 'TIMEOUT') return `${pass} ip=${second} rip=TIMEOUT`;
    return `RIP${third}`;
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
