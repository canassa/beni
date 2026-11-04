// Correctness probe for the frozen renderer ABI. Not a producer fixture or benchmark.
// Run after building RowsClient and LegacyClient (README.md).
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { GlobalWindow as Window } from '../../tests/browser/happy-dom.mjs';
const root = resolve(process.argv[2] || 'zig-out/rows-dev');
const legacyRoot = resolve(process.argv[3] || 'zig-out/rows-legacy');
const client = Object.values(await import(pathToFileURL(root+'/RowsClient.mjs')))[0];
const api = keyType => client(...Array(6).fill(keyType));
const rows = Object.fromEntries(['forKeyed','show','head','tail','restate','dispose'].map(name => [name,(keyType,...args) => api(keyType)[name](...args)]));
for (const name of ['forPosition','hide']) rows[name] = (...args) => api('core:Basics.⊤')[name](...args);
const js = await import(pathToFileURL(root+'/_core/Js.mjs'));
const NONE = Object.values(js).find(value=>value && typeof value === 'object' && Object.hasOwn(value,'$next'));
assert.ok(NONE,'compiler-emitted private optional sentinel');
const old = Object.values(await import(pathToFileURL(legacyRoot+'/LegacyClient.mjs')))[0];
const INT = 'core:Basics.Int';
const STR = 'core:Basics.String';
const FLOAT = 'core:Basics.Float';
const typedOnly = process.argv.includes("--typed-only");
const swapOnly = process.argv.includes("--swap-only");
let checked = 0;
const worlds = new WeakMap();
const instrumented = new WeakSet();
let depth = 0;
const traceNode = (node, action) => { if (!depth) worlds.get(node.ownerDocument)?.(node, action); };
function instrument(window) {
  if (instrumented.has(window.Node.prototype)) return;
  instrumented.add(window.Node.prototype);
  function wrap(prototype,name,action) {
    const original = prototype[name];
    prototype[name] = function(...args) {
      action.call(this,...args); depth++;
      try { return original.apply(this,args); } finally { depth--; }
    };
  }
  wrap(window.Node.prototype,'insertBefore',function(node,before) { traceNode(this,['insert',node,before]); });
  // rendererRemove uses removeChild; legacy uses remove. These are the same
  // removal operation, with internal DOM implementation calls counted once.
  wrap(window.Node.prototype,'removeChild',function(node) { traceNode(node,['remove']); });
  wrap(window.Element.prototype,'remove',function() { if (this.parentNode) traceNode(this,['remove']); });
  for (const prototype of [window.Node.prototype,window.Element.prototype]) {
    const descriptor = Object.getOwnPropertyDescriptor(prototype,'textContent');
    if (descriptor?.set) Object.defineProperty(prototype,'textContent',{ ...descriptor, set(value) {
      traceNode(this,['text',String(value)]); depth++;
      try { descriptor.set.call(this,value); } finally { depth--; }
    } });
  }
}
function world(typed, { marker = true, multi = false, live = false, index = false, immutable = true } = {}) {
  const window = new Window();
  const document = window.document;
  const parent = document.createElement('main');
  document.body.append(parent);
  let next = 0;
  const trace = [];
  const opsTypes = new WeakMap();
  const disposedTypes = [];
  const id = node => node ? node.__id ?? (node === parent ? 'parent' : node.nodeType === 11 ? 'fragment' : 'other') : null;
  worlds.set(document,(node, [action,...args]) => trace.push([action,id(node),...args.map(value => typeof value === 'string' ? value : id(value))]));
  instrument(window);
  const none = typed ? NONE : null;
  const end = marker ? document.createComment('end') : null;
  if (end) { end.__id = 'marker'; parent.append(end); }
  const slot = { p: parent, m: end ?? none, cx: null, i: none, u: none, r: none, l: false, w: false, v: false, j: none, k: 0, x: none, y: none, z: none, d: false };
  const label = (item, position, epoch) => `${typeof item === 'object' ? item.label : String(item)}${index ? ':' + position : ''}${epoch ? '@' + epoch : ''}`;
  function mounted(item, position, epoch) {
    const nodes = Array.from({ length: multi ? 2 : 1 }, (_, part) => {
      const node = document.createElement('span'); node.__id = ++next; node.textContent = label(item, position, epoch) + (multi ? '/' + part : ''); return node;
    });
    if (multi) { const fragment = document.createDocumentFragment(); for (const node of nodes) fragment.append(node); }
    return { s: nodes[0], e: nodes.at(-1), q: none, l: live, x: item, y: position, k: none, kv: 0, rs: 0, n: none, kc: none, kt: none };
  }
  function patched(row, item, position, epoch) {
    let node = row.s;
    for (let part = 0; node; part++) {
      const text = label(item, position, epoch) + (multi ? '/' + part : '');
      if (node.textContent !== text) node.textContent = text;
      if (node === row.e) break;
      node = node.nextSibling;
    }
    return row;
  }
  const protocol = {
    none: null, first: value => value.s, last: value => value.e, live: value => value.l,
    parentOf: location => location.p === NONE ? location.m.parentNode : location.p,
    put(parent, value, before) {
      for (let node = value.s;;) { const next = node.nextSibling; parent.insertBefore(node, before === NONE ? null : before); if (node === value.e) break; node = next; }
    },
    drop(value) { for (let node = value.s;;) { const next = node.nextSibling; node.remove(); if (node === value.e) break; node = next; } },
    swap(previous, value) { protocol.put(previous.s.parentNode, value, previous.s); protocol.drop(previous); },
    unit(block) { const value = mounted(block.v, 0, block.epoch); value.kind = block.kind; return value; },
    patch(value, block) { if (value.kind !== block.kind) { const next = protocol.unit(block); protocol.swap(value, next); return next; } return patched(value, block.v, 0, block.epoch); },
    childMaybe(location, block) {
      if (block === NONE) { if (location.i !== NONE) protocol.drop(location.i); location.i = NONE; location.l = false; }
      else if (location.i === NONE) { location.i = protocol.unit(block); protocol.put(parent, location.i, location.m); location.l = live; }
      else { location.i = protocol.patch(location.i, block); location.l = live; }
    },
    makeSite: (ops, scope, data) => ({ ops, scope, data }),
    setSiteScope(site, ops, scope) { site.ops = ops; site.scope = scope; },
    siteData: site => site.data, siteScope: site => site.scope,
    siteHead: (site, location) => site.ops.head(site.scope, site.data, location),
    siteTail: (site, location) => site.ops.tail(site.scope, site.data, location),
    siteRestate: (site, location, stamp) => site.ops.restate(site.scope, site.data, location, stamp),
    siteDispose(site,location) { disposedTypes.push(opsTypes.get(site.ops)); return site.ops.dispose(site.scope,site.data,location); },
  };
  let epoch = '';
  let previousKeyType;
  const recipe = {
    m(item, key, position) { const row = mounted(item, position, epoch); row.k = key; return row; },
    p: (row, item, position) => patched(row, item, position, epoch), r() {}, view: row => row,
    item: row => row.x, sameItem: (row, item) => row.x === item, setItem(row, item) { row.x = item; },
    o: immutable, i: index, l: live, e: false, f: NONE, j: NONE,
    same: (a, b) => a === b, remember: value => value, probe: () => NONE,
  };
  const legacyRecipe = {
    m: (item, position) => mounted(item, position, epoch), p: (row, item, position) => patched(row, item, position, epoch), r() {},
    o: immutable, i: index, l: live, e: false, f: null, j: undefined,
  };
  const kind = { l: live, m: (item) => mounted(item, 0, epoch), p: (row, item) => patched(row, item, 0, epoch) };
  const keyed = (items, keyType, stamp = '') => {
    epoch = stamp; globalThis.document = document; trace.length = 0;
    recipe.j = stamp || NONE; legacyRecipe.j = stamp || undefined;
    const keyOf = item => typeof item === 'object' ? item.key : item;
    const ops = {
      head: (_, data, location) => rows.head(keyType, protocol, recipe, data, location),
      tail: (_, data, location) => rows.tail(keyType, protocol, recipe, data, location),
      restate: (_, data, location, stamp) => rows.restate(keyType, protocol, recipe, data, location, stamp),
      dispose: (_, data, location) => rows.dispose(keyType, protocol, recipe, data, location),
    };
    opsTypes.set(ops,keyType);
    const previousSite = slot.r;
    const previousData = !typed || previousSite === NONE ? null : previousSite.data;
    if (typed) {
      rows.forKeyed(keyType, protocol, slot, items, keyOf, recipe, NONE, ops, stamp);
      if (previousSite !== NONE && previousKeyType === keyType) {
        assert.equal(slot.r,previousSite,'same-key site retained');
        assert.equal(slot.r.data,previousData,'same-key state retained');
      }
      if (previousSite !== NONE && previousKeyType !== keyType) {
        assert.notEqual(slot.r,previousSite,'new key type gets a new site');
        assert.notEqual(slot.r.data,previousData,'old state is never viewed at the new key type');
        assert.equal(disposedTypes.at(-1),previousKeyType,'dispose uses OLD typed callbacks');
      }
      assert.equal(slot.r.ops,ops,'site reads current operations');
      assert.equal(slot.r.scope,stamp,'site reads current scope');
      previousKeyType = keyType;
    }
    else old.forKeyed(slot, items, keyOf, legacyRecipe, null);
    assert.equal(parent.textContent, items.map((item, position) => label(item, position, epoch) + (multi ? '/0' + label(item, position, epoch) + '/1' : '')).join(''), typed ? 'typed' : 'legacy');
    if (typed && slot.r !== NONE) {
      const first = protocol.siteHead(slot.r, slot), last = protocol.siteTail(slot.r, slot);
      assert.equal(first === NONE ? null : first, items.length ? parent.firstChild : end);
      assert.equal(last === NONE ? null : last, marker ? end : parent.lastChild);
    }
    return { html: parent.innerHTML, trace: structuredClone(trace) };
  };
  return {
    window, parent, trace, slot, protocol, recipe, keyed,
    positional(items, stamp = '') {
      epoch = stamp; globalThis.document = document; trace.length = 0; recipe.j = stamp || NONE; legacyRecipe.j = stamp || undefined;
      const ops = { head: (_, data, location) => rows.head('core:Basics.⊤', protocol, recipe, data, location), tail: (_, data, location) => rows.tail('core:Basics.⊤', protocol, recipe, data, location), restate: () => {}, dispose: (_, data, location) => rows.dispose('core:Basics.⊤', protocol, recipe, data, location) };
      if (typed) rows.forPosition(protocol, slot, items, recipe, NONE, ops, stamp); else old.forPosition(slot, items, legacyRecipe, null);
      assert.equal(parent.textContent, items.map((item, position) => label(item, position, epoch) + (multi ? '/0' + label(item, position, epoch) + '/1' : '')).join(''));
      return { html: parent.innerHTML, trace: structuredClone(trace) };
    },
    show(key, text, stamp = '', keyType = INT) {
      epoch = stamp; globalThis.document = document; trace.length = 0;
      const block = { v: text, epoch: stamp, kind: 'text', t: kind };
      const ops = { head: (_, data, location) => rows.head(keyType, protocol, recipe, data, location), tail: (_, data, location) => rows.tail(keyType, protocol, recipe, data, location), restate: () => {}, dispose: (_, data, location) => rows.dispose(keyType, protocol, recipe, data, location) };
      if (typed) rows.show(keyType, protocol, slot, key, block, stamp || NONE, ops, stamp); else old.show(slot, key, block);
      return { html: parent.innerHTML, trace: structuredClone(trace) };
    },
    hide(fallback = null) {
      globalThis.document = document; trace.length = 0;
      const block = fallback === null ? none : { v: fallback, epoch, kind: 'text', t: kind };
      if (typed) rows.hide(protocol, slot, block); else old.hide(slot, block);
      return { html: parent.innerHTML, trace: structuredClone(trace) };
    },
  };
}
function compare(a, b, operation, args, context) {
  if (typedOnly) { try { b[operation](...args); } catch(error) { console.error(context); throw error; } checked++; return; }
  let expected,actual;
  try { expected = a[operation](...args); actual = b[operation](...args); } catch(error) { console.error(context, JSON.stringify(args)); throw error; }
  assert.deepEqual(actual, expected, context);
  checked++;
}
for (const marker of (swapOnly ? [false] : [false,true])) for (const multi of (swapOnly ? [true] : process.argv.includes("--single-node") ? [false] : [false,true])) for (const live of (swapOnly ? [false] : [false,true])) for (const index of (swapOnly ? [false] : [false,true])) for (const immutable of (swapOnly ? [false] : [false,true])) {
  const options = { marker, multi, live, index, immutable };
  const a = world(false, options), b = world(true, options);
  const pool = Array.from({ length: 20 }, (_, key) => ({ key, label: `row${key}` }));
  const sequences = swapOnly ? [[0,1],[1,0]] : [[0,1,2,3], [0,1,2,3,4], [4,0,1,2,3], [4,0,2,3], [3,2,0,4], [3,0,2,4], [19,18,17], [], [1,1,2,1], [1,2,1], [2,2,1,1,1], [], [0,1,2,3]];
  for (const [step, sequence] of sequences.entries()) compare(a,b,'keyed',[sequence.map(i => pool[i]),INT],`keyed ${JSON.stringify(options)} step ${step}`);
  if (swapOnly) continue;
  // Deterministic mixed distinct and duplicate updates exercise trimmed and full passes.
  let seed = 1612;
  const random = n => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed % n; };
  for (let step = 0; step < 150; step++) {
    const items = Array.from({ length: random(18) }, () => pool[random(20)]);
    compare(a,b,'keyed',[items,INT, step > 75 ? 'new-item-type-and-environment' : ''],`random ${JSON.stringify(options)} step ${step}`);
  }
  if (typedOnly) {
    // Same JS numbers, different compiler identities: this is defensive ABI
    // coverage, since generic primitive markup keys are refused in source.
    const items = pool.slice(0,3);
    b.keyed(items,INT); checked++;
    const previousNodes = Array.from(b.parent.querySelectorAll('span'));
    b.keyed(items,FLOAT); checked++;
    for (const node of previousNodes) assert.equal(node.isConnected,false,'old key type nodes disposed');
  }
  // A raw key type change must dispose under the old callbacks then remount.
  const changed = [{ key:'a',label:'string-a' },{ key:'b',label:'string-b' }];
  const newChange = b.keyed(changed,STR);
  if (!typedOnly) {
  const oldChange = a.keyed(changed,STR);
  assert.equal(newChange.html,oldChange.html);
  // Typed disposal must precede new mounts. Legacy has no type guard.
  assert.deepEqual(newChange.trace,[...oldChange.trace.filter(x => x[0] === 'remove'),...oldChange.trace.filter(x => x[0] !== 'remove')]);
  }
  checked++;
  const c = world(false, options), d = world(true, options);
  for (const items of [[0,1], [0,1,2,3], [4,5], [], [7], [8,9,10], []]) compare(c,d,'positional',[items],`position ${JSON.stringify(options)}`);
  const e = world(false, options), f = world(true, options);
  for (const [operation,...args] of [['show',1,'one'],['show',1,'updated'],['show',1,'new scope','epoch'],['show',2,'two'],['hide','fallback'],['hide','fallback2'],['show',2,'again'],['hide'],['hide'],['show','string','new key type','',STR]]) compare(e,f,operation,args,`show ${JSON.stringify(options)} ${operation}`);
}
console.log(JSON.stringify({ checked, mode: 'correctness only', root }, null, 2));
