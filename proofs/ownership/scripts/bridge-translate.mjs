// Typed ANF → beni. No compiler internals and no host-language evaluation.
export class Skip extends Error { constructor(reason) { super(reason); this.reason = reason; } }
const fail = reason => { throw new Skip(reason); };
const walk = (e, f) => {
  f(e);
  if (e[0] === 'let') { walk(e[2], f); walk(e[3], f); }
  if (e[0] === 'branch') { walk(e[2], f); walk(e[3], f); }
  if (e[0] === 'focus') walk(e[4], f);
  if (e[0] === 'traverse') walk(e[7], f);
};
const atomVars = a => a[0] === 'var' ? [a[1]] : a[0] === 'field' ? atomVars(a[1]) : [];
const atoms = e => {
  switch(e[0]) {
    case 'atom': case 'branch': return [e[1]];
    case 'prim': case 'closure': return e[2];
    case 'app': return [e[1], ...e[2]];
    case 'recur': return e[1];
    case 'focus': return [e[1],e[2]];
    case 'traverse': return [e[2],e[3]];
    default: return [];
  }
};
const uses = (e, n) => { let yes = false; walk(e, x => { if (atoms(x).flatMap(atomVars).includes(n)) yes = true; }); return yes; };
export function constructs(ds, main) {
  const counts = {}, seen = new Set();
  const scan = e => {
    walk(e, x => {
      const tag = x[0] === 'prim' ? x[1][0] : x[0] === 'traverse' ? `traverse-${x[1]}` : x[0];
      counts[tag] = (counts[tag] ?? 0) + 1;
      if (x[0] === 'closure' && !seen.has(x[1])) { seen.add(x[1]); scan(ds[x[1]][4]); }
    });
  };
  scan(main); return counts;
}
export function translate(ds, main) {
  let serial = 0;
  const sites = [], defs = new Map(), building = new Set(), hoisted = new Set(), globals = [];
  const bindings = new Map();
  for (let e = main; e[0] === 'let'; e = e[3]) bindings.set(e[1], e[2]);
  function hoistAtom(a) {
    if (a[0] === 'int') return;
    if (a[0] !== 'var') fail('shared-field-root');
    const n = a[1]; if (hoisted.has(n)) return;
    const e = bindings.get(n); if (!e) fail('dynamic-shared-root');
    hoisted.add(n);
    if (e[0] === 'atom') hoistAtom(e[1]);
    else if (e[0] === 'prim' && ['literal', 'record', 'shared'].includes(e[1][0])) e[2].forEach(hoistAtom);
    else if (e[0] === 'closure') fail('shared-function-observation');
    else fail('shared-depends-on-computation');
  }
  let computationSeen = false;
  const publications = new Set();
  for (let e=main;;) {
    const rhs=e[0]==='let'?e[2]:e;
    if(rhs[0]==='prim' && rhs[1][0]==='shared' && computationSeen) fail('late-shared-publication');
    if(rhs[0]==='prim' && rhs[1][0]==='shared') publications.add(rhs);
    if(!['atom','closure'].includes(rhs[0]) && !(rhs[0]==='prim' && ['literal','record','shared'].includes(rhs[1][0]))) computationSeen=true;
    if(e[0]!=='let')break;
    e=e[3];
  }
  walk(main, e => {
    if (e[0] === 'prim' && e[1][0] === 'shared') {
      if (!publications.has(e)) fail('conditional-shared-publication');
      hoistAtom(e[2][0]);
    }
  });
  const name = (env, n) => { if (!env.has(n)) throw Error(`unbound translation variable ${n}`); return env.get(n); };
  const atom = (a, env) => {
    if (a[0] === 'int') {
      if (!Number.isSafeInteger(Number(a[1]))) fail('integer-out-of-range');
      return a[1].startsWith('-') ? `(${a[1]})` : a[1];
    }
    if (a[0] === 'var') return name(env, a[1]);
    if (a[0] === 'field') return `${atom(a[1], env)}.f${a[2]}`;
    throw Error(`unknown atom ${a[0]}`);
  };
  const mark = (key, text) => { sites.push(key); return `-- bridge ${key}\n${text}`; };
  const ind = (s, n = 4) => s.split('\n').map(x => ' '.repeat(n) + x).join('\n');
  function closure(id, caps, env, key) {
    const d = ds[id];
    if (d[5] === 'identity-map') fail('identity-preserving-close');
    if (d[5]) return `List.${d[5]}`;
    if (!caps.length) {
      if (!building.has(id) && !defs.has(id)) {
        building.add(id);
        const params = d[1].map((_, i) => `p${id}v${i}`);
        const denv = new Map(params.map((p, i) => [i, p]));
        const body = emit(d[4], denv, `d${id}`, { id, caps: [], env: denv });
        defs.set(id, `d${id} ${params.join(' ') || '⊤'} =\n${ind(body)}`);
        building.delete(id);
      }
      return `d${id}`;
    }
    const prefix = `c${serial++}v`, ps = d[1].map((_, i) => prefix + i);
    const denv = new Map(ps.map((p, i) => [i, p]));
    caps.forEach((a, i) => denv.set(ps.length + i, atom(a, env)));
    // Local named functions are needed only for recursive closures.
    let recursive = false; walk(d[4], e => { if (e[0] === 'recur') recursive = true; });
    const local = `rec${serial++}`;
    const body = emit(d[4], denv, `d${id}`, { id, local, caps, env: denv });
    return recursive ? `(\n${ind(`${local} ${ps.join(' ') || '⊤'} =\n${ind(body)}\n${local}`)}\n)`
      : `(λ${ps.join(' ') || '⊤'} →\n${ind(body)}\n)`;
  }
  function emit(e, env, key, self = null) {
    const a = x => atom(x, env), args = xs => xs.map(x => `(${a(x)})`).join(' ');
    switch (e[0]) {
      case 'atom': return a(e[1]);
      case 'let': {
        const next = new Map(env), n = `b${serial++}v${e[1]}`;
        next.set(e[1], hoisted.has(e[1]) && bindings.get(e[1]) === e[2] ? `g${e[1]}` : n);
        if (hoisted.has(e[1]) && bindings.get(e[1]) === e[2]) {
          globals.push(`pub g${e[1]} =\n${ind(emit(e[2], env, key + '/0', self))}`);
          return emit(e[3], next, key + '/1', self);
        }
        return `${n} =\n${ind(emit(e[2], env, key + '/0', self))}\n${emit(e[3], next, key + '/1', self)}`;
      }
      case 'prim': {
        const op = e[1][0], xs = e[2], aa = xs.map(a);
        let text;
        if (['add', 'sub'].includes(op)) text = `(${aa[0]} ${op === 'add' ? '+' : '-'} ${aa[1]})`;
        else if (['eq', 'lt'].includes(op)) text = `if ${aa[0]} ${op === 'eq' ? '==' : '<'} ${aa[1]} then 1 else 0`;
        else if (op === 'literal') text = `[ ${aa.join(', ')} ]`;
        else if (op === 'record') {
          if (!aa.length) fail('empty-record-representation');
          text = `{ ${aa.map((x, i) => `f${i} = ${x}`).join(', ')} }`;
        }
        else if (op === 'prepend') text = `[ ${aa[0]}, …${aa[1]} ]`;
        else if (op === 'shared') {
          if (key.startsWith('d')) fail('dynamic-shared-root');
          if (xs[0][0] !== 'var' || !hoisted.has(xs[0][1])) fail('dynamic-shared-root');
          text = aa[0];
        } else if (['length', 'copy', 'push', 'set'].includes(op)) text = `List.${op} ${args(xs)}`;
        else if (op === 'at') text = `case List.get (${aa[0]}) (${aa[1]}) of\n    Just found${serial} →\n        found${serial++}\n    Nothing →\n        ${aa[2]}`;
        else fail(({builder:'private-builder', put:'private-put', close:'private-close',
          events:'abstract-event-boundary', owned:'abstract-owned-boundary'})[op] ?? `primitive-${op}`);
        if (["length", "at"].includes(op)) text = `bridgeRead (\n${ind(text)}\n)`;
        return mark(key, text);
      }
      case 'closure': return mark(key, closure(e[1], e[2], env, key));
      case 'app': return mark(key, `${a(e[1])} ${args(e[2]) || '⊤'}`);
      case 'recur':
        if (!self) fail('recursion-outside-declaration');
        return mark(key, `${self.local ?? `d${self.id}`} ${args(e[1]) || '⊤'}`);
      case 'branch': return `if ${a(e[1])} == 0 then\n${ind(emit(e[2], env, key + '/0', self))}\nelse\n${ind(emit(e[3], env, key + '/1', self))}`;
      case 'focus': {
        const local = `focus${serial++}`, next = new Map(env); next.set(e[3], local);
        return mark(key, `List.update (${a(e[1])}) (${a(e[2])}) (λ${local} →\n${ind(emit(e[4], next, key + '/body', self))}\n)`);
      }
      case 'traverse': {
        if (e[1] === 'model') fail('model-entry-protocol');
        if (e[1] === 'list' && uses(e[7], e[4])) fail('list-traversal-index');
        const index = `index${serial++}`, item = `item${serial++}`, acc = `acc${serial++}`, next = new Map(env);
        next.set(e[4], index); next.set(e[5], e[1] === 'range' ? index : item); next.set(e[6], acc);
        const src = e[1] === 'list' ? a(e[2]) : `(List.range 0 (${a(e[2])} - 1))`;
        return mark(key, `List.foldl (${src}) (${a(e[3])}) (λ${e[1] === 'list' ? item : index} ${acc} →\n${ind(emit(e[7], next, key + '/body', self))}\n)`);
      }
      default: throw Error(`unknown expression ${e[0]}`);
    }
  }
  const body = emit(main, new Map(), 'main');
  const source = ['pub bridgeRead value = value', ...globals, ...defs.values(), `pub run ⊤ =\n${ind(body)}`].join('\n\n\n') + '\n';
  // Each marker belongs to its following expression. Keep its enclosing range
  // for call/update obligations whose token is stamped on an argument.
  const lines = source.split('\n'), markers = [];
  for (let i = 0; i < lines.length; ++i) {
    const m = lines[i].match(/^( *)-- bridge (.+)$/);
    if (m) markers.push({ key: m[2], line: i + 2, indent: m[1].length });
  }
  return { source, markers };
}
export function siteAt(markers, row) {
  return markers.filter(m => m.line <= row).at(-1)?.key ?? null;
}
