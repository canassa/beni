// blind.mjs: a blind sweep for the border between function values and the first-order core
// (research report 113). Written by a tester who did not read the other generators of this folder.
//
//   node bench/ownership-sweeps/blind.mjs <outdir> [filter]
//
// Each program puts one list `xs` at two places, and the call or value that gets both claims, or
// could claim, that they are two cells. Then one of them is edited and the other is read (`live`),
// or nothing is read after the edit (`dead`, the safe twin). The program prints what it reads, so an
// in-place edit of a shared list changes the output.
//
// Families:
//
// - `pair`: carrier pair × route × mechanism × edit. The two carriers hold `xs` (a list, a record, a
//   tuple, a `Maybe`, a custom constructor, a list of lists, a tree, nested records and lists, a thunk,
//   a generic box). The route says how both reach the callee (two arguments, one tuple, one record,
//   one constructor, a projection, an `if` arm, a `case` arm, a tuple 2/7/8/9 levels deep, a capture
//   and an argument, a list of two). The mechanism says how the callee takes the two lists out
//   (directly, by callbacks, lambdas, a generic callee, partial application, a record or a list of
//   functions, a returned function, a composition, `List.foldl`, a hand-written fold, one more call,
//   `Maybe.map`, a local function, a recursion, a branch, a swap). The edit says where the write is
//   (the caller, a second callee, a callback, a fold after the call, a list of the two parts, a
//   record update, inside the callee, a callback inside the callee).
// - `core`: a list of lists from a function of `core/` or from a hand-written one, where two elements
//   can be one list, then an edit of one element and a read of another.
// - `tree`: a recursive tree whose leaves can be one list, walked by a hand-written fold or by a
//   function value, then a leaf is edited and another read.
import fs from 'node:fs';
import path from 'node:path';

const out = process.argv[2];
const filter = process.argv[3] ?? '';
if (!out) {
  console.error('usage: node bench/ownership-sweeps/blind.mjs <outdir> [filter]');
  process.exit(2);
}

const header = `import List
import Maybe
import Node exposing (Program)
import String


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


type Box
    = Box (List Int)
    | NoBox


type Tree
    = Leaf (List Int)
    | Fork Tree Tree


type Hold a
    = Hold a


type Two a b
    = Two a b


type alias Rec =
    { a : List Int, n : Int }


type alias Outer =
    { inner : Rec, k : Int }


getL : List Int → List Int
getL v = v


getR : Rec → List Int
getR v = v.a


getT : List Int × Int → List Int
getT v =
    case v of
        ( l, _ ) →
            l


getM : Maybe (List Int) → List Int
getM v =
    case v of
        Just l →
            l

        Nothing →
            []


getB : Box → List Int
getB v =
    case v of
        Box l →
            l

        NoBox →
            []


getN : List (List Int) → List Int
getN v =
    case v of
        [ l, …_ ] →
            l

        [] →
            []


getTr : Tree → List Int
getTr v =
    case v of
        Leaf l →
            l

        Fork a _ →
            getTr a


getTq : Tree → List Int
getTq v =
    case v of
        Leaf l →
            l

        Fork _ b →
            getTq b


getMT : Maybe (List Int × Int) → List Int
getMT v =
    case v of
        Just ( l, _ ) →
            l

        Nothing →
            []


getRN : Outer → List Int
getRN v = v.inner.a


getNN : List (List (List Int)) → List Int
getNN v =
    case v of
        [ [ l, …_ ], …_ ] →
            l

        _ →
            []


getF : (⊤ → List Int) → List Int
getF v = v ⊤


unhold : Hold a → a
unhold v =
    case v of
        Hold x →
            x


getG : Hold (List Int) → List Int
getG v = unhold v


idL : List Int → List Int
idL l = l


bump : List Int → List Int
bump l = List.set l 0 9


showAll : List (List Int) → String
showAll ls = String.join (List.map ls ints) ";"


firstOr : List (List Int) → List Int
firstOr ls = Maybe.withDefault (List.head ls) []
`;

// Carriers: a type that holds one `List Int`, how to make one from an expression, and its getter.
const C = {
  L: { ty: 'List Int', wrap: (e) => e, get: 'getL' },
  R: { ty: 'Rec', wrap: (e) => `{ a = ${e}, n = 1 }`, get: 'getR' },
  T: { ty: 'List Int × Int', wrap: (e) => `( ${e}, 1 )`, get: 'getT' },
  M: { ty: 'Maybe (List Int)', wrap: (e) => `Just ${e}`, get: 'getM' },
  B: { ty: 'Box', wrap: (e) => `Box ${e}`, get: 'getB' },
  N: { ty: 'List (List Int)', wrap: (e) => `[ ${e} ]`, get: 'getN' },
  Tr: { ty: 'Tree', wrap: (e) => `Fork (Fork (Leaf ${e}) (Leaf [ 0 ])) (Leaf [ 0 ])`, get: 'getTr' },
  Tq: { ty: 'Tree', wrap: (e) => `Fork (Leaf [ 0 ]) (Fork (Leaf [ 0 ]) (Leaf ${e}))`, get: 'getTq' },
  MT: { ty: 'Maybe (List Int × Int)', wrap: (e) => `Just ( ${e}, 1 )`, get: 'getMT' },
  RN: { ty: 'Outer', wrap: (e) => `{ inner = { a = ${e}, n = 1 }, k = 2 }`, get: 'getRN' },
  NN: { ty: 'List (List (List Int))', wrap: (e) => `[ [ ${e}, [ 0 ] ] ]`, get: 'getNN' },
  F: { ty: '(⊤ → List Int)', wrap: (e) => `(λ⊤ → ${e})`, get: 'getF' },
  G: { ty: 'Hold (List Int)', wrap: (e) => `Hold ${e}`, get: 'getG' },
};
const pairs = [
  ['L', 'L'], ['R', 'L'], ['T', 'M'], ['M', 'B'], ['N', 'L'], ['Tr', 'L'], ['Tr', 'Tq'], ['MT', 'R'],
  ['RN', 'NN'], ['L', 'N'], ['G', 'G'], ['B', 'T'], ['F', 'L'], ['NN', 'RN'], ['Tq', 'G'], ['R', 'R'],
];

const LL = 'List Int × List Int';

// Mechanisms: top-level definitions, and the call that takes the two lists out of `u : C1`, `v : C2`.
function mechanisms(c1, c2) {
  const a = C[c1];
  const b = C[c2];
  const same = c1 === c2;
  const ms = {
    direct: {
      defs: `k : ${a.ty}, ${b.ty} → ${LL}\nk u v = ( ${a.get} u, ${b.get} v )\n`,
      call: (u, v) => `k ${u} ${v}`,
    },
    cb: {
      defs: `k : (${a.ty} → List Int), (${b.ty} → List Int), ${a.ty}, ${b.ty} → ${LL}\nk g h u v = ( g u, h v )\n`,
      call: (u, v) => `k ${a.get} ${b.get} ${u} ${v}`,
    },
    lam: {
      defs: `k : (${a.ty} → List Int), (${b.ty} → List Int), ${a.ty}, ${b.ty} → ${LL}\nk g h u v = ( g u, h v )\n`,
      call: (u, v) => `k (λw1 → ${a.get} w1) (λw2 → ${b.get} w2) ${u} ${v}`,
    },
    gen: {
      defs: `k : (a → List Int), (b → List Int), a, b → ${LL}\nk g h u v = ( g u, h v )\n`,
      call: (u, v) => `k ${a.get} ${b.get} ${u} ${v}`,
    },
    gen2: {
      defs: `k : (a → c), (b → c), a, b → c × c\nk g h u v = ( g u, h v )\n`,
      call: (u, v) => `k ${a.get} ${b.get} ${u} ${v}`,
    },
    partial: {
      defs: `sel1 : Int, ${a.ty} → List Int\nsel1 _ v = ${a.get} v\n\n\nsel2 : ${b.ty}, Int → List Int\nsel2 v _ = ${b.get} v\n\n\nk : (${a.ty} → List Int), (${b.ty} → List Int), ${a.ty}, ${b.ty} → ${LL}\nk g h u v = ( g u, h v )\n`,
      call: (u, v) => `k (sel1 0 _) (sel2 _ 0) ${u} ${v}`,
    },
    recfn: {
      defs: `k : { g : ${a.ty} → List Int, h : ${b.ty} → List Int }, ${a.ty}, ${b.ty} → ${LL}\nk fs u v = ( fs.g u, fs.h v )\n`,
      call: (u, v) => `k { g = ${a.get}, h = ${b.get} } ${u} ${v}`,
    },
    ret: {
      defs: `getter1 : Int → (${a.ty} → List Int)\ngetter1 _ = ${a.get}\n\n\ngetter2 : Int → (${b.ty} → List Int)\ngetter2 _ = ${b.get}\n\n\nk : (${a.ty} → List Int), (${b.ty} → List Int), ${a.ty}, ${b.ty} → ${LL}\nk g h u v = ( g u, h v )\n`,
      call: (u, v) => `k (getter1 0) (getter2 0) ${u} ${v}`,
    },
    comp: {
      defs: `comp : (a → b), (b → c) → (a → c)\ncomp f g = λx → g (f x)\n\n\nk : (${a.ty} → List Int), (${b.ty} → List Int), ${a.ty}, ${b.ty} → ${LL}\nk g h u v = ( g u, h v )\n`,
      call: (u, v) => `k (comp ${a.get} idL) (comp ${b.get} idL) ${u} ${v}`,
    },
    fold: {
      defs: `k : ${a.ty}, ${b.ty} → ${LL}\nk u v =\n    r = List.foldl [ ${a.get} u, ${b.get} v ] [] λl acc → [ …acc, l ]\n    case r of\n        [ x, y ] →\n            ( x, y )\n\n        _ →\n            ( [], [] )\n`,
      call: (u, v) => `k ${u} ${v}`,
    },
    foldfn: {
      defs: `k : (${a.ty} → List Int), ${a.ty}, ${b.ty} → ${LL}\nk g u v =\n    r = List.foldl [ 1, 2 ] ( [], ${b.get} v ) λ_ acc →\n        case acc of\n            ( _, y ) →\n                ( g u, y )\n    r\n`,
      call: (u, v) => `k ${a.get} ${u} ${v}`,
    },
    hfold: {
      defs: `myFold : List a, b, (a, b → b) → b\nmyFold xs acc f =\n    case xs of\n        [ x, …rest ] →\n            myFold rest (f x acc) f\n\n        [] →\n            acc\n\n\nk : ${a.ty}, ${b.ty} → ${LL}\nk u v =\n    r = myFold [ ${a.get} u, ${b.get} v ] [] λl acc → [ …acc, l ]\n    case r of\n        [ x, y ] →\n            ( x, y )\n\n        _ →\n            ( [], [] )\n`,
      call: (u, v) => `k ${u} ${v}`,
    },
    fwd: {
      defs: `k0 : ${a.ty}, ${b.ty} → ${LL}\nk0 u v = ( ${a.get} u, ${b.get} v )\n\n\nk : ${a.ty}, ${b.ty} → ${LL}\nk u v = k0 u v\n`,
      call: (u, v) => `k ${u} ${v}`,
    },
    apply: {
      defs: `k0 : ${a.ty}, ${b.ty} → ${LL}\nk0 u v = ( ${a.get} u, ${b.get} v )\n\n\nk : a, b, (a, b → c) → c\nk u v f = f u v\n`,
      call: (u, v) => `k ${u} ${v} k0`,
    },
    maybe: {
      defs: `k : ${a.ty}, ${b.ty} → ${LL}\nk u v =\n    case Maybe.map (Just u) ${a.get} of\n        Just l →\n            ( l, ${b.get} v )\n\n        Nothing →\n            ( [], ${b.get} v )\n`,
      call: (u, v) => `k ${u} ${v}`,
    },
    local: {
      defs: `k : ${a.ty}, ${b.ty} → ${LL}\nk u v =\n    pick w = ${a.get} w\n    ( pick u, ${b.get} v )\n`,
      call: (u, v) => `k ${u} ${v}`,
    },
    rec: {
      defs: `k : Int, ${a.ty}, ${b.ty} → ${LL}\nk n u v =\n    if n == 0 then\n        ( ${a.get} u, ${b.get} v )\n    else\n        k (n - 1) u v\n`,
      call: (u, v) => `k 3 ${u} ${v}`,
    },
    branch: {
      defs: `k : ${a.ty}, ${b.ty} → ${LL}\nk u v =\n    l = ${b.get} v\n    if List.length l > 0 then\n        ( ${a.get} u, l )\n    else\n        ( [ 0 ], [ 0 ] )\n`,
      call: (u, v) => `k ${u} ${v}`,
    },
    swap: {
      defs: `k0 : ${a.ty}, ${b.ty} → ${LL}\nk0 u v = ( ${a.get} u, ${b.get} v )\n\n\nk : ${a.ty}, ${b.ty} → ${LL}\nk u v =\n    case k0 u v of\n        ( x, y ) →\n            ( y, x )\n`,
      call: (u, v) => `k ${u} ${v}`,
    },
    tuplefn: {
      defs: `k : (${a.ty} → List Int) × (${b.ty} → List Int), ${a.ty}, ${b.ty} → ${LL}\nk fs u v =\n    case fs of\n        ( g, h ) →\n            ( g u, h v )\n`,
      call: (u, v) => `k ( ${a.get}, ${b.get} ) ${u} ${v}`,
    },
    maybefn: {
      defs: `k : Maybe (${a.ty} → List Int), ${a.ty}, ${b.ty} → ${LL}\nk mg u v =\n    case mg of\n        Just g →\n            ( g u, ${b.get} v )\n\n        Nothing →\n            ( [], ${b.get} v )\n`,
      call: (u, v) => `k (Just ${a.get}) ${u} ${v}`,
    },
  };
  if (same) {
    ms.listfn = {
      defs: `k : List (${a.ty} → List Int), ${a.ty}, ${a.ty} → ${LL}\nk fs u v =\n    case fs of\n        [ g, h, …_ ] →\n            ( g u, h v )\n\n        _ →\n            ( [], [] )\n`,
      call: (u, v) => `k [ ${a.get}, ${a.get} ] ${u} ${v}`,
    };
    ms.once = {
      defs: `k : (${a.ty} → List Int), ${a.ty}, ${a.ty} → ${LL}\nk g u v = ( g u, g v )\n`,
      call: (u, v) => `k ${a.get} ${u} ${v}`,
    };
    ms.map = {
      defs: `k : ${a.ty}, ${a.ty} → ${LL}\nk u v =\n    case List.map [ u, v ] ${a.get} of\n        [ x, y ] →\n            ( x, y )\n\n        _ →\n            ( [], [] )\n`,
      call: (u, v) => `k ${u} ${v}`,
    };
  }
  return ms;
}

function nestTy(ty, d) {
  let t = ty;
  for (let i = 0; i < d; i++) t = `(${t}) × Int`;
  return t;
}
function nestVal(e, d) {
  let t = e;
  for (let i = 0; i < d; i++) t = `( ${t}, ${i} )`;
  return t;
}
function nestPat(name, d) {
  let t = name;
  for (let i = 0; i < d; i++) t = `( ${t}, _ )`;
  return t;
}

// Routes: definitions and main-body lines that end in an expression of type `List Int × List Int`.
// `xs` is bound before them.
function routes(c1, c2, call) {
  const a = C[c1];
  const b = C[c2];
  const rs = {
    two: { defs: '', lines: [], expr: call(`(${a.wrap('xs')})`, `(${b.wrap('xs')})`) },
    tup: {
      defs: `via : (${a.ty}) × (${b.ty}) → ${LL}\nvia pp =\n    case pp of\n        ( u, v ) →\n            ${call('u', 'v')}\n`,
      lines: [], expr: `via ( ${a.wrap('xs')}, ${b.wrap('xs')} )`,
    },
    tupl: { defs: '', lines: [`pv = ( ${a.wrap('xs')}, ${b.wrap('xs')} )`, `( u0, v0 ) = pv`], expr: call('u0', 'v0') },
    rec: {
      defs: `via : { p : ${a.ty}, q : ${b.ty} } → ${LL}\nvia r = ${call('r.p', 'r.q')}\n`,
      lines: [], expr: `via { p = ${a.wrap('xs')}, q = ${b.wrap('xs')} }`,
    },
    ctor: {
      defs: `via : Two (${a.ty}) (${b.ty}) → ${LL}\nvia t =\n    case t of\n        Two u v →\n            ${call('u', 'v')}\n`,
      lines: [], expr: `via (Two (${a.wrap('xs')}) (${b.wrap('xs')}))`,
    },
    proj: { defs: '', lines: [`u0 = ${a.wrap('xs')}`], expr: call('u0', `(${b.wrap(`(${a.get} u0)`)})`) },
    iff: {
      defs: '',
      lines: [`u0 = if List.length xs > 0 then ${a.wrap('xs')} else ${a.wrap('[ 7 ]')}`],
      expr: call('u0', `(${b.wrap('xs')})`),
    },
    casej: {
      defs: '',
      lines: [`v0 =\n        case Just xs of\n            Just l →\n                ${b.wrap('l')}\n\n            Nothing →\n                ${b.wrap('[ 7 ]')}`],
      expr: call(`(${a.wrap('xs')})`, 'v0'),
    },
    cap: {
      defs: '',
      lines: [`c0 = ${a.wrap('xs')}`, `kc = λv → ${call('c0', 'v')}`],
      expr: `kc (${b.wrap('xs')})`,
    },
    cap2: {
      defs: `mk : ${a.ty} → (${b.ty} → ${LL})\nmk c = λv → ${call('c', 'v')}\n`,
      lines: [],
      expr: `(mk (${a.wrap('xs')})) (${b.wrap('xs')})`,
    },
    hold: {
      defs: `via : Hold ((${a.ty}) × (${b.ty})) → ${LL}\nvia h =\n    case unhold h of\n        ( u, v ) →\n            ${call('u', 'v')}\n`,
      lines: [], expr: `via (Hold ( ${a.wrap('xs')}, ${b.wrap('xs')} ))`,
    },
  };
  for (const d of [2, 7, 8, 9]) {
    rs[`deep${d}`] = {
      defs: `via : ${nestTy(a.ty, d)}, ${nestTy(b.ty, d)} → ${LL}\nvia dp dq =\n    case dp of\n        ${nestPat('u', d)} →\n            case dq of\n                ${nestPat('v', d)} →\n                    ${call('u', 'v')}\n`,
      lines: [], expr: `via ${nestVal(`(${a.wrap('xs')})`, d)} ${nestVal(`(${b.wrap('xs')})`, d)}`,
    };
  }
  if (c1 === c2) {
    rs.list = {
      defs: `via : List (${a.ty}) → ${LL}\nvia ws =\n    case ws of\n        [ u, v, …_ ] →\n            ${call('u', 'v')}\n\n        _ →\n            ( [], [] )\n`,
      lines: [], expr: `via [ ${a.wrap('xs')}, ${a.wrap('xs')} ]`,
    };
    rs.alias = { defs: '', lines: [`u0 = ${a.wrap('xs')}`, `v0 = u0`], expr: call('u0', 'v0') };
  }
  return rs;
}

// Edits: what main does with the pair `X`. Each gives the live and the dead body (lines after `xs`).
const edits = {
  set: (X) => ({
    common: [`( p, q ) = ${X}`, `p2 = List.set p 0 9`],
    live: 'Node.print "${ints p2} ${ints q}"', dead: 'Node.print "${ints p2}"',
  }),
  setx: (X) => ({
    common: [`( p, q ) = ${X}`, `p2 = List.set p 0 9`],
    live: 'Node.print "${ints p2} ${ints q} ${ints xs}"', dead: 'Node.print "${ints p2}"',
  }),
  setq: (X) => ({
    common: [`( p, q ) = ${X}`, `q2 = List.set q 0 9`],
    live: 'Node.print "${ints p} ${ints q2}"', dead: 'Node.print "${ints q2}"',
  }),
  push: (X) => ({
    common: [`( p, q ) = ${X}`, `p2 = List.push p 9`],
    live: 'Node.print "${ints p2} ${ints q}"', dead: 'Node.print "${ints p2}"',
  }),
  callee: (X) => ({
    common: [`( p, q ) = ${X}`, `p2 = bump p`],
    live: 'Node.print "${ints p2} ${ints q}"', dead: 'Node.print "${ints p2}"',
  }),
  cbafter: (X) => ({
    defs: `onFirst : ${LL}, (List Int → List Int) → ${LL}\nonFirst r f =\n    case r of\n        ( x, y ) →\n            ( f x, y )\n`,
    common: [`( p2, q ) = onFirst (${X}) λl → List.set l 0 9`],
    live: 'Node.print "${ints p2} ${ints q}"', dead: 'Node.print "${ints p2}"',
  }),
  foldafter: (X) => ({
    defs: `step : Int, ${LL} → ${LL}\nstep _ acc =\n    case acc of\n        ( x, y ) →\n            ( List.set x 0 9, y )\n`,
    common: [`( p2, q ) = List.foldl [ 1, 2 ] (${X}) step`],
    live: 'Node.print "${ints p2} ${ints q}"', dead: 'Node.print "${ints p2}"',
  }),
  elems: (X) => ({
    common: [`( p, q ) = ${X}`, `zs = List.update [ p, q ] 0 λl → List.set l 0 9`],
    live: 'Node.print "${showAll zs}"',
    dead: 'Node.print "${ints (firstOr zs)}"',
  }),
  recupd: (X) => ({
    common: [`( p, q ) = ${X}`, `r = { a = p, b = q }`, `r2 = { r | a = List.set r.a 0 9 }`],
    live: 'Node.print "${ints r2.a} ${ints r2.b}"', dead: 'Node.print "${ints r2.a}"',
  }),
};

// Edits inside a wrapper callee that is called on the pair the mechanism returns.
const innerEdits = {
  inner: {
    defs: (call, c1, c2) => `kk : ${C[c1].ty}, ${C[c2].ty} → ${LL}\nkk u v =\n    case ${call('u', 'v')} of\n        ( x, y ) →\n            ( List.set x 0 9, y )\n`,
    call: (u, v) => `kk ${u} ${v}`,
  },
  innercb: {
    defs: (call, c1, c2) => `kk : (List Int → List Int), ${C[c1].ty}, ${C[c2].ty} → ${LL}\nkk f u v =\n    case ${call('u', 'v')} of\n        ( x, y ) →\n            ( f x, y )\n`,
    call: (u, v) => `kk (λl → List.set l 0 9) ${u} ${v}`,
  },
};

let count = 0;
const list = [];
function emit(name, defs, lines, last) {
  if (filter && !name.includes(filter)) return;
  const dir = path.join(out, name);
  fs.mkdirSync(dir, { recursive: true });
  const body = ['xs = [ 1, 2, 3 ]', ...lines, last].map((l) => `    ${l}`).join('\n');
  const src = `${header}\n\n${defs.filter(Boolean).join('\n\n')}\n\nmain : Program\nmain =\n${body}\n`;
  fs.writeFileSync(path.join(dir, 'Main.beni'), src);
  list.push(dir);
  count++;
}

// Family `pair`. Each (route, mechanism, edit) gets one carrier pair, chosen by rotation.
fs.mkdirSync(out, { recursive: true });
const routeNames = Object.keys(routes('L', 'L', (u, v) => '')).sort();
const mechNames = Object.keys(mechanisms('L', 'L')).sort();
const editNames = [...Object.keys(edits), ...Object.keys(innerEdits)];
let rot = 0;
for (const rn of routeNames) {
  for (const mn of mechNames) {
    for (const en of editNames) {
      let tries = 0;
      let made = 0;
      while (made < 1 && tries < pairs.length) {
        const [c1, c2] = pairs[(rot + tries * 5) % pairs.length];
        tries++;
        const ms = mechanisms(c1, c2);
        const m = ms[mn];
        if (!m) continue;
        let call = m.call;
        const defs = [m.defs];
        let editKey = en;
        if (innerEdits[en]) {
          defs.push(innerEdits[en].defs(m.call, c1, c2));
          call = innerEdits[en].call;
        }
        const r = routes(c1, c2, call)[rn];
        if (!r) continue;
        defs.push(r.defs);
        const live = innerEdits[en] ? null : edits[en](r.expr);
        const base = `pair.${rn}.${mn}.${editKey}.${c1}-${c2}`;
        if (live) {
          if (live.defs) defs.push(live.defs);
          emit(`${base}.live`, defs, [...r.lines, ...live.common], live.live);
          emit(`${base}.dead`, defs, [...r.lines, ...live.common], live.dead);
        } else {
          const common = [...r.lines, `( p2, q ) = ${r.expr}`];
          emit(`${base}.live`, defs, common, 'Node.print "${ints p2} ${ints q}"');
          emit(`${base}.dead`, defs, common, 'Node.print "${ints p2}"');
        }
        made++;
      }
      rot++;
    }
  }
}

// Family `core`: a list of lists whose elements can be one list. `ys` is the producer.
const producers = {
  repeat: 'List.repeat xs 2',
  init: 'List.initialize 2 λ_ → xs',
  mapc: 'List.map [ 1, 2 ] λ_ → xs',
  concat: 'List.concat [ [ xs ], [ xs ] ]',
  append: 'List.append [ xs ] [ xs ]',
  spread: '[ …[ xs ], …[ xs ] ]',
  inter: 'List.intersperse [ xs, xs ] xs',
  push: 'List.push [ xs ] xs',
  foldp: 'List.foldl [ 1, 2 ] [] λ_ acc → List.push acc xs',
  foldr: 'List.foldr [ 1, 2 ] [] λ_ acc → [ …acc, xs ]',
  hrep: 'hrep xs 2',
  hrepf: 'hrepf (λ⊤ → xs) 2',
  pairl: 'pairToList ( xs, xs )',
  dupf: 'dupBy idL xs',
  dupg: 'dupBy (λl → l) xs',
  twicef: 'twice (λl → [ l ]) xs',
  maybe: 'withBoth (Just xs) xs',
  sorted: 'List.sortBy [ xs, xs ] List.length',
  filter: 'List.filter [ xs, xs ] λl → List.length l > 0',
  reverse: 'List.reverse [ xs, [ 0 ], xs ]',
  take: 'List.take [ xs, xs, [ 0 ] ] 2',
  drop: 'List.drop [ [ 0 ], xs, xs ] 1',
  unzip: 'firstOf (List.unzip [ ( xs, 1 ), ( xs, 2 ) ])',
  tree: 'leaves (Fork (Leaf xs) (Fork (Leaf xs) (Leaf [ 0 ])))',
  treef: 'foldTree (Fork (Leaf xs) (Leaf xs)) [] λl acc → [ …acc, l ]',
  gen: 'gpair xs',
  genf: 'gapply2 (λl → l) xs',
  closure: 'callTwice (λ⊤ → xs)',
  rec: 'recLists { a = xs, b = xs }',
  dict: 'fromMaybes [ Just xs, Nothing, Just xs ]',
};
const coreDefs = `hrep : List Int, Int → List (List Int)
hrep l n =
    if n == 0 then
        []
    else
        [ …hrep l (n - 1), l ]


hrepf : (⊤ → List Int), Int → List (List Int)
hrepf g n =
    if n == 0 then
        []
    else
        [ …hrepf g (n - 1), g ⊤ ]


pairToList : List Int × List Int → List (List Int)
pairToList p =
    case p of
        ( a, b ) →
            [ a, b ]


dupBy : (List Int → List Int), List Int → List (List Int)
dupBy f l = [ f l, f l ]


twice : (List Int → List (List Int)), List Int → List (List Int)
twice f l = List.append (f l) (f l)


withBoth : Maybe (List Int), List Int → List (List Int)
withBoth m l =
    case m of
        Just a →
            [ a, l ]

        Nothing →
            [ l ]


firstOf : a × b → a
firstOf p =
    case p of
        ( a, _ ) →
            a


leaves : Tree → List (List Int)
leaves t =
    case t of
        Leaf l →
            [ l ]

        Fork a b →
            List.append (leaves a) (leaves b)


foldTree : Tree, b, (List Int, b → b) → b
foldTree t acc f =
    case t of
        Leaf l →
            f l acc

        Fork a b →
            foldTree b (foldTree a acc f) f


gpair : a → List a
gpair x = [ x, x ]


gapply2 : (a → b), a → List b
gapply2 f x = [ f x, f x ]


callTwice : (⊤ → a) → List a
callTwice g = [ g ⊤, g ⊤ ]


recLists : { a : List Int, b : List Int } → List (List Int)
recLists r = [ r.a, r.b ]


fromMaybes : List (Maybe (List Int)) → List (List Int)
fromMaybes ms = List.filterMap ms λm → m
`;
const coreEdits = {
  update: {
    common: ['zs = List.update ys 0 λl → List.set l 0 9'],
    live: 'Node.print "${showAll zs}"',
    dead: 'Node.print "${ints (firstOr zs)}"',
  },
  updatex: {
    common: ['zs = List.update ys 0 λl → List.set l 0 9'],
    live: 'Node.print "${ints (firstOr zs)} ${ints xs}"',
    dead: 'Node.print "${ints (firstOr zs)}"',
  },
  pat: {
    common: ['( p2, q ) =\n        case ys of\n            [ a, b, …_ ] →\n                ( List.set a 0 9, b )\n\n            _ →\n                ( [], [] )'],
    live: 'Node.print "${ints p2} ${ints q}"', dead: 'Node.print "${ints p2}"',
  },
  mapw: {
    common: ['zs = List.map ys λl → List.push l 9'],
    live: 'Node.print "${showAll zs}"',
    dead: 'Node.print "${String.fromInt (List.length zs)}"',
  },
  foldw: {
    common: ['zs = List.foldl ys [] λl acc → [ …acc, List.set l 0 9 ]'],
    live: 'Node.print "${showAll zs}"',
    dead: 'Node.print "${String.fromInt (List.length zs)}"',
  },
  cbw: {
    defs: 'eachFirst : List (List Int), (List Int → List Int) → List (List Int)\neachFirst ls f =\n    case ls of\n        [ a, …rest ] →\n            [ f a, …rest ]\n\n        [] →\n            []\n',
    common: ['zs = eachFirst ys bump'],
    live: 'Node.print "${showAll zs}"',
    dead: 'Node.print "${ints (firstOr zs)}"',
  },
};
for (const [pn, pe] of Object.entries(producers)) {
  for (const [en, e] of Object.entries(coreEdits)) {
    for (const how of ['inline', 'callee']) {
      const defs = [coreDefs, e.defs];
      let lines;
      if (how === 'inline') lines = [`ys = ${pe}`, ...e.common];
      else {
        defs.push(`produce : List Int → List (List Int)\nproduce xs = ${pe}\n`);
        lines = ['ys = produce xs', ...e.common];
      }
      emit(`core.${pn}.${en}.${how}.live`, defs, lines, e.live);
      emit(`core.${pn}.${en}.${how}.dead`, defs, lines, e.dead);
    }
  }
}

// Family `tree`: leaves of a tree that can be one list, edited through a walk.
const treeShapes = {
  two: 'Fork (Leaf xs) (Leaf xs)',
  deep: 'Fork (Fork (Leaf xs) (Leaf [ 0 ])) (Fork (Leaf [ 0 ]) (Leaf xs))',
  shared: 'tw (Leaf xs)',
  built: 'mkTree xs 3',
};
const treeDefs = `tw : Tree → Tree
tw t = Fork t t


mkTree : List Int, Int → Tree
mkTree l n =
    if n == 0 then
        Leaf l
    else
        Fork (mkTree l (n - 1)) (Leaf [ n ])


mapFirst : Tree, (List Int → List Int) → Tree
mapFirst t f =
    case t of
        Leaf l →
            Leaf (f l)

        Fork a b →
            Fork (mapFirst a f) b


mapLeaves : Tree, (List Int → List Int) → Tree
mapLeaves t f =
    case t of
        Leaf l →
            Leaf (f l)

        Fork a b →
            Fork (mapLeaves a f) (mapLeaves b f)


setFirst : Tree → Tree
setFirst t =
    case t of
        Leaf l →
            Leaf (List.set l 0 9)

        Fork a b →
            Fork (setFirst a) b


flat : Tree → List Int
flat t =
    case t of
        Leaf l →
            l

        Fork a b →
            List.append (List.copy (flat a)) (flat b)


lastLeaf : Tree → List Int
lastLeaf t =
    case t of
        Leaf l →
            l

        Fork _ b →
            lastLeaf b
`;
const treeEdits = {
  mapFirst: 't2 = mapFirst t λl → List.set l 0 9',
  mapFirstB: 't2 = mapFirst t bump',
  mapLeaves: 't2 = mapLeaves t λl → List.push l 9',
  setFirst: 't2 = setFirst t',
};
for (const [sn, se] of Object.entries(treeShapes)) {
  for (const [en, ee] of Object.entries(treeEdits)) {
    for (const reader of ['flat', 'orig', 'last']) {
      const live = reader === 'flat' ? 'Node.print "${ints (flat t2)}"'
        : reader === 'orig' ? 'Node.print "${ints (getTr t2)} ${ints xs}"'
          : 'Node.print "${ints (getTr t2)} ${ints (lastLeaf t)}"';
      const dead = 'Node.print "${ints (getTr t2)}"';
      emit(`tree.${sn}.${en}.${reader}.live`, [treeDefs], [`t = ${se}`, ee], live);
      emit(`tree.${sn}.${en}.${reader}.dead`, [treeDefs], [`t = ${se}`, ee], dead);
    }
  }
}

fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${count} programs in ${out}`);
