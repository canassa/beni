// Price a Solid-like encoding of one view, executable: the feed's article
// preview (Feed.viewPreview and the helpers it calls) in the tea bundle,
// rewritten by hand as one template whose nodes live in closure locals and
// whose patch is one guard per hole, keeping the TEA protocol the runtime
// expects (a kind {m, p}, an instance with s/q/e) and every behaviour: the
// same DOM (comment markers included), the same hrefs through Route.href and
// safeUrl, the same messages on the same nodes with the map context, the
// favorite button remounted when its branch changes (two kinds, backend.md
// §15.2), the tags through the runtime's positional list.
//
// What it drops, and why that is allowed:
//  - the instance record of kept values with NaN/undefined initialisers: the
//    kept values are closure locals, which start as a sentinel no value is;
//  - the group-then-hole double test: one test per hole, on its input path,
//    and the derived value written without a second test (a write of an equal
//    value is a no-op for these properties);
//  - restates and liveness: nothing under this preview can be live (no
//    stateful attribute, no every-render value), which the compiler knows;
//  - blocks and kinds of the helpers it calls with constant or input-only
//    arguments: their markup is inlined into the one template (research 39
//    §6.3 option 2, which backend.md §15.4 leaves as later work).
//   node bench/app-code-size/proto-preview.mjs [results dir]
import fs from 'node:fs';
import * as acorn from '../output-size/node_modules/acorn/dist/acorn.mjs';
import {size, readGz, writeGz} from '../output-size/lib.mjs';
import {units} from '../output-size/units.mjs';

const dir = process.argv[2] ?? 'bench/app-code-size/results';
const src = readGz(`${dir}/beni-tea.mjs.gz`), map = JSON.parse(readGz(`${dir}/beni-tea.mjs.map.gz`));
const {units: us} = units(src, map);
// Resolve every name the hand code uses from its beni origin, so the prototype
// survives a rename of the bundle.
const by = (owner, orig) => { const u = us.find(x => x.owner === owner && x.orig === orig); if (!u) throw Error(`${owner}.${orig}`); return u.js; };
const N = {
  template: by('platforms/browser/Rt', 'template'), slot: by('platforms/browser/Rt', 'slot'),
  forPosition: by('platforms/browser/Rt', 'forPosition'), safeUrl: by('platforms/browser/Rt', 'safeUrl'),
  href: by('app/Route', 'href'), profile: by('app/Author', 'profile'), username: by('app/Author', 'username'),
  avatarSrc: by('app/Author', 'avatarSrc'), fromInt: by('core/String', 'fromInt'),
  tagRowTemplate: by('app/Article', 't536'), kind: by('app/Feed', 'k272'),
};
const dead = [['app/Feed', 'p272'], ['app/Feed', 't272'], ['app/Feed', 'k224'], ['app/Feed', 'p224'], ['app/Feed', 't224'],
  ['app/Feed', 'b265'], ['app/Feed', 'k265'], ['app/Feed', 't265'],
  ['app/Article', 'link'], ['app/Article', 'k599'], ['app/Article', 'p599'], ['app/Article', 't599']].map(([o, n]) => by(o, n));

// The hand-written preview. v = [article, maybeCred], as viewPreview builds it.
const T = 'Bt', B1 = 'Ct', B2 = 'Dt', R = 'Et';
const hand = {
  [T]: `${N.template}("<div class=article-preview><div class=article-meta><a><img class></a><div class=info><a class=author> </a><!><span class=date> </span><!></div><!></div><a class=preview-link><h1> </h1><p> </p><span>Read more...</span><ul class=tag-list></ul><!></a>",0)`,
  [B1]: `${N.template}('<button class="btn btn-primary btn-sm pull-xs-right"><i class=ion-heart></i> </button>',0)`,
  [B2]: `${N.template}('<button class="btn btn-outline-primary btn-sm pull-xs-right"><i class=ion-heart></i> </button>',0)`,
  [R]: `{m:()=>{let d=${N.tagRowTemplate}();return{s:d,q:null,e:d,w1:d.firstChild,a0:undefined,x:undefined}},p:(a,b)=>{if(b!==a.a0){a.a0=b;a.w1.data=b}},w:true}`,
  [N.kind]: `{m:(v,x)=>{let r=${T}(),m=r.firstChild,p=m.firstChild,g=p.firstChild,i=p.nextSibling,u=i.firstChild,n=u.firstChild,t=u.nextSibling.nextSibling.firstChild,o=i.nextSibling,l=m.nextSibling,h=l.firstChild,d=h.nextSibling,s=${N.slot}(d.nextSibling.nextSibling,null,x),A,C,D,E,G,H,K,M,S,c,f,j,k=-1,q,w=v=>{let e=v[0],y=v[1];` +
    `if(e.j!==A){A=e.j;let z=${N.profile}(A),Z=${N.username}(A);p.setAttribute("href",${N.safeUrl}(${N.href}({$:7,a:z.username})));g.setAttribute("src",${N.safeUrl}(${N.avatarSrc}(z.E)));u.setAttribute("href",${N.safeUrl}(${N.href}({$:7,a:Z})));n.data=Z}` +
    `if(e.N!==C){C=e.N;t.data=C}` +
    `if(e.title!==D){D=e.title;h.firstChild.data=D}` +
    `if(e.D!==E){E=e.D;d.firstChild.data=E}` +
    `if(e.A!==G){G=e.A;l.setAttribute("href",${N.safeUrl}(${N.href}({$:6,a:G})))}` +
    `if(e.B!==H){H=e.B;${N.forPosition}(s,H,${R},null)}` +
    `let b=y.$===0?e.da?1:2:0;if(b!==k){k=b;let F=b===0?document.createComment(""):(b===1?${B1}:${B2})();o.replaceWith(F);o=F;f=b?F.firstChild.nextSibling:null;if(b&&x!==null)F.$$cx=x;K=M=S=undefined}` +
    // b is 1 on a favorited article, whose button sends ClickedUnfavorite ($:2),
    // and 2 on another, whose button sends ClickedFavorite ($:1): the tag is 3 - b.
    // The kept count is reset with the branch, so a remade button gets its text.
    `if(b&&(y!==K||e!==M)){K=y;M=e;o.$$click={$:3-b,a:y.a,b:e.A};if(e.S!==S){S=e.S;f.data=\` \${${N.fromInt}(S)}\`}}};` +
    `w(v);return{s:r,q:null,e:r,u:w}},p:(a,v)=>a.u(v)}`,
};
if (!hand[N.kind].includes('o.$$click=') || !hand[N.kind].includes('F.$$cx=')) throw Error('lost a $$ property');

// Edit the bundle: replace the kind's initialiser, delete what only it used,
// and add the hand declarations next to it.
const ast = acorn.parse(src, {ecmaVersion: 'latest', sourceType: 'module'});
const edits = [];
for (const s of ast.body) if (s.type === 'VariableDeclaration') s.declarations.forEach((d, k) => {
  const name = d.id.name;
  if (name === N.kind) edits.push({start: d.start, end: d.end, text: Object.entries(hand).map(([n, v]) => `${n}=${v}`).join(',')});
  else if (dead.includes(name)) {
    const ds = s.declarations;
    if (ds.length === 1) throw Error(`lone declarator ${name}`);
    edits.push(k < ds.length - 1 ? {start: d.start, end: ds[k + 1].start, text: ''} : {start: ds[k - 1].end, end: d.end, text: ''});
  }
});
for (const n of [T, B1, B2, R]) if (new RegExp(`(?<![\\w$.])${n}(?![\\w$])`).test(src)) throw Error(`name ${n} is taken`);
let out = src;
for (const e of edits.sort((a, b) => b.start - a.start)) out = out.slice(0, e.start) + e.text + out.slice(e.end);
acorn.parse(out, {ecmaVersion: 'latest', sourceType: 'module'});
fs.mkdirSync('zig-out/app-code-size', {recursive: true});
fs.writeFileSync('zig-out/app-code-size/proto-preview-tea.mjs', out);
writeGz(`${dir}/proto-preview-tea.mjs.gz`, out);
const before = size(src), after = size(out);
const handRaw = Object.entries(hand).reduce((n, [k, v]) => n + Buffer.byteLength(`${k}=${v},`), 0);
const result = {before, after, saved: before.brotli - after.brotli, handRaw, removedUnits: [N.kind, ...dead]};
console.log(JSON.stringify(result));
fs.writeFileSync(`${dir}/proto-preview.json`, JSON.stringify(result, null, 2) + '\n');
