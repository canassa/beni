// S5: fresh pages, rotated subjects, real CDP input, 100 and 1,000 todos.
// Run direct-size.mjs and vanilla-build.mjs first. No compiler benchmark build. Vanilla commits its change on Tab; beni commits on Enter.
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadavg, cpus } from 'node:os';
import { createHash } from 'node:crypto';
import { launch, traced } from '../ui/lib/cdp.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const arg = (name, fallback) => process.argv.find(a => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const samples = Number(arg('samples', 9));
const subjects = ['browser-tea-Sandbox', 'browser-direct-Sandbox', 'browser-tea-NoEditing', 'browser-direct-NoEditing', 'vanilla-es6'];
const root = join(here, 'out/direct-effects');
const server = createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
  if (url.pathname.endsWith('.mjs')) {
    const file = resolve(root, '.' + url.pathname);
    if (!file.startsWith(root + '/')) { res.writeHead(403).end(); return; }
    res.setHeader('Content-Type', 'text/javascript');
    res.end(readFileSync(file));
    return;
  }
  const subject = url.searchParams.get('subject');
  if (!subjects.includes(subject)) { res.writeHead(404).end(); return; }
  const n = Number(url.searchParams.get('n'));
  const clear = url.searchParams.get('op') === 'clear';
  const todos = Array.from({ length: n }, (_, id) => ({ id, title: `todo ${id}`, completed: clear && id < n / 2 }));
  const seed = subject === 'vanilla-es6'
    ? `localStorage.setItem('todos-vanilla-es6', ${JSON.stringify(JSON.stringify(todos))});`
    : subject.endsWith('NoEditing') ? `localStorage.setItem('todos-beni', ${JSON.stringify(todos.map(t => (t.completed ? '1' : '0') + t.title).join('\n'))});` : '';
  const body = subject === 'vanilla-es6' ? readFileSync(join(root, subject, 'body.html'), 'utf8') : '';
  res.setHeader('Content-Type', 'text/html');
  const entry = subject === 'vanilla-es6' ? `<script src="/${subject}/_main.mjs"></script><script>window.ready=true;</script>` : `<script type="module">await import('/${subject}/_main.mjs');window.ready=true;</script>`;
  res.end(`<!doctype html><html><body>${body}<script>localStorage.clear();${seed}</script>${entry}</body></html>`);
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await launch({ chrome: arg('chrome', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome') });
const results = { started: new Date().toISOString(), chrome: browser.version, node: process.version, cpu: cpus()[0].model,
  method: 'Fresh page per sample; real CDP input; capture-to-eight-microtasks untraced interval; trace union of EventDispatch/FunctionCall/RunMicrotasks. Six toggle warmups per fresh page; preparation and two animation frames outside timing; no CSS. Beni checkbox timing ends after change, not click. Vanilla add commits on Tab/change; beni on Enter/keydown. Vanilla retains upstream JSON persistence and editing; routing beni has line persistence, no editing; sandbox has neither persistence nor routing.',
  sources: Object.fromEntries(subjects.map(s => [s, createHash('sha256').update(readFileSync(join(root, s, '_main.mjs'))).digest('hex')])), rows: [] };
const settle = `async () => { for(let i=0;i<8;i++) await Promise.resolve(); }`;
async function measure(subject, n, op, sample, mode) {
  const page = await browser.newPage(`${origin}/?subject=${subject}&n=${n}&op=${op}#/`);
  try {
    await page.waitFor('window.ready && document.querySelector(".new-todo")');
    await page.eval(`(${settle})()`);
    if (subject.endsWith('Sandbox')) {
      await page.eval(`(async () => {
        const settle=${settle}, input=document.querySelector('.new-todo');
        for(let i=0;i<${n};i++) {
          input.value='todo '+i; input.dispatchEvent(new Event('input',{bubbles:true}));
          input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true,cancelable:true}));
          await settle();
        }
        ${op === 'clear' ? `for(const input of [...document.querySelectorAll('.todo-list .toggle')].slice(0,${n / 2})){input.click();await settle();}` : ''}
      })()`);
    }
    await page.eval(`(async()=>{const settle=${settle};for(let i=0;i<6;i++){document.querySelector('.todo-list .toggle').click();await settle();}})()`);
    const initial = await page.eval(`document.querySelectorAll('.todo-list li').length`);
    if (initial !== n) throw new Error(`${subject}: initial ${initial}, expected ${n}`);
    if (op === 'add') {
      await page.eval(`(() => {const input=document.querySelector('.new-todo');input.focus();})()`);
      await page.send('Input.insertText', { text: 'added' });
      await page.eval(`(${settle})()`);
    }
    const event = op === 'add' ? subject === 'vanilla-es6' ? 'change' : 'keydown' : 'click';
    await page.eval('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))');
    const box = op === 'add' ? null : await page.locate(`document.querySelector(${JSON.stringify(op === 'toggle' ? '.todo-list .toggle' : '.clear-completed')})`);
    if (box) await page.waitFor(`document.elementFromPoint(${box.x},${box.y}) === document.querySelector(${JSON.stringify(op === 'toggle' ? '.todo-list .toggle' : '.clear-completed')})`);
    await page.eval(`(() => {window.gc?.();window.sampleTime=null;
      let start;
      addEventListener('${event}',()=>{start=performance.now();performance.mark('s5-start');}, {capture:true,once:true});
      addEventListener('${op === 'toggle' && subject !== 'vanilla-es6' ? 'change' : event}',async()=>{await (${settle})();window.sampleTime=performance.now()-start;performance.mark('s5-end');},{once:true});
    })()`);
    let events;
    const action = async () => {
      if (op === 'add') {
        const key = subject === 'vanilla-es6' ? 'Tab' : 'Enter', code = key === 'Tab' ? 9 : 13;
        await page.send('Input.dispatchKeyEvent', { type: 'keyDown', key, code: key, windowsVirtualKeyCode: code, nativeVirtualKeyCode: code });
        await page.send('Input.dispatchKeyEvent', { type: 'keyUp', key, code: key, windowsVirtualKeyCode: code, nativeVirtualKeyCode: code });
      } else await page.press(box);
      await page.waitFor('window.sampleTime !== null');
    };
    if (mode === 'traced') events = await traced(page, ['devtools.timeline', 'v8.execute', 'blink.user_timing'], action);
    else await action();
    const state = await page.eval(`({rows:document.querySelectorAll('.todo-list li').length,completed:document.querySelectorAll('.todo-list li.completed').length, time:window.sampleTime, stored:localStorage.getItem('${subject === 'vanilla-es6' ? 'todos-vanilla-es6' : 'todos-beni'}')})`);
    const expected = op === 'add' ? n + 1 : op === 'clear' ? n / 2 : n;
    if (state.rows !== expected || (op === 'toggle' && state.completed !== 1)) { const details=await page.eval(`({button:document.querySelector('.clear-completed').outerHTML,box:${JSON.stringify(box)},hit:${box ? 'document.elementFromPoint('+box.x+','+box.y+')?.outerHTML' : 'null'},body:document.body.innerHTML})`);writeFileSync(join(here,'out/failure.json'),JSON.stringify(details,null,2));throw new Error(`${subject}/${op}: ${JSON.stringify(state)}`); }
    if (!subject.endsWith('Sandbox')) {
      const stored = subject === 'vanilla-es6' ? JSON.parse(state.stored) : state.stored.split('\n').map(t => ({ completed: t[0] === '1', title: t.slice(1) }));
      if (stored.length !== expected || (op === 'toggle' && stored.filter(t => t.completed).length !== 1)) throw new Error(`${subject}/${op}: persistence did not settle`);
    }
    let script = state.time;
    if (events) {
      const starts = events.filter(e => e.ph === 'X' && e.name === 'EventDispatch' && e.args?.data?.type === event);
      if (starts.length !== 1) throw new Error(`trace ${subject}/${op}: ${starts.length} ${event} starts`);
      const first = starts[0];
      const from = events.find(e=>e.name==='s5-start')?.ts, to = events.find(e=>e.name==='s5-end')?.ts;
      if(from===undefined || to===undefined) throw new Error('trace missing timing bounds');
      const intervals = events.filter(e => e.ph === 'X' && e.pid === first.pid && e.tid === first.tid && e.ts+e.dur >= from && e.ts <= to && ['EventDispatch','FunctionCall','RunMicrotasks'].includes(e.name)).map(e=>[Math.max(from,e.ts),Math.min(to,e.ts+e.dur)]).sort((a,b)=>a[0]-b[0]);
      let total=0,end=0;
      for(const [a,b] of intervals){total+=Math.max(0,b-Math.max(end,a));end=Math.max(end,b);}
      script=total/1000;
    }
    results.rows.push({subject,n,op,sample,mode,script,load:loadavg()[0]});
  } finally { await page.close(); }
}
try {
  for (const mode of (arg('mode',null) ? [arg('mode')] : ['untraced', 'traced'])) for (const n of (arg('n',null) ? [Number(arg('n'))] : [100,1000])) for (const op of (arg('op',null) ? [arg('op')] : ['add','toggle','clear'])) {
    for (let sample=0;sample<(mode === 'traced' ? 3 : samples);sample++) {
      for(let i=0;i<subjects.length;i++) await measure(subjects[(i+sample)%subjects.length],n,op,sample,mode);
    }
    console.error(`${mode} ${n} ${op} complete`);
  }
  results.summary=[];
  for(const mode of ['untraced','traced']) for(const n of [100,1000]) for(const op of ['add','toggle','clear']) for(const subject of subjects){
    const xs=results.rows.filter(r=>r.mode===mode&&r.n===n&&r.op===op&&r.subject===subject).map(r=>r.script).sort((a,b)=>a-b);
    if(xs.length)results.summary.push({mode,n,op,subject,samples:xs.length,median:xs[Math.floor(xs.length/2)],min:xs[0],max:xs.at(-1)});
  }
  mkdirSync(join(here,'results'),{recursive:true});
  const output=resolve(here,arg('out','results/2026-10-14-s5.json'));
  writeFileSync(output,JSON.stringify(results,null,2)+'\n');
  console.log(output);
} finally { await browser.close(); await new Promise(r=>server.close(r)); }
