const a=(b)=>b.u===null||b.u.length===0?b.i===null?b.m:d(b.i):d(b.u[0]),
d=(b)=>b.s===null?a(b.q):b.s,
b=(a)=>a.m===null?a.u===null||a.u.length===0?e(a.i):e(a.u[a.u.length-1]):a.m,
e=(a)=>a.e===null?b(a.q):a.e,
l=(a,b,c)=>{let f=d(b);const g=e(b);for(;;){const h=f.nextSibling;a.insertBefore(f,c);if(f===g)return;f=h}},
q=(a)=>{let b=d(a);const c=e(a);for(;;){const f=b.nextSibling;b.remove();if(b===c)return;b=f}},
c=(a,b)=>{const e=d(a);l(e.parentNode,b,e);q(a)},
f=()=>{let a=null;return()=>{if(a===null){const b=document,c=b.createElement("template");c.innerHTML="<!>";a=c.content;a=a.firstChild}return a.cloneNode(true)}},
g=(a)=>({cx:null,i:null,m:null,p:a}),
v=(a)=>a.p===null?a.m.parentNode:a.p,
w=(a,b)=>{const c=a.t.m(a.v,b);c.t=a.t;c.b=a;return c},
z=(a,b,d)=>{if(b===a.b)return a;if(b.t===a.t){b.t.p(a,b.v);a.b=b;return a}const e=w(b,d);c(a,e);return e},
A=(a,b)=>{if(a.i===null)l(v(a),b,a.m);else c(a.i,b);a.i=b},
h=(a,b)=>{if(a.i===null)A(a,w(b,a.cx));else a.i=z(a.i,b,a.cx)};
let i=[],
j=false;
const k=()=>{j=false;const a=i;i=[];for(const b of a)b()},
m=(a,b)=>{const c=g(b);let d=a.init,e=false;const f=()=>{e=false;h(c,a.view(d))};b.$$root=(l)=>{if(!e){e=true;i.push(f);if(!j){j=true;queueMicrotask(()=>{if(j)k()})}}d=a.update(l,d)};h(c,a.view(d))},
n=(a)=>{for(const b of a){const c=document,d=b.n===null?c.body:c.getElementById(b.n);if(d===null||d.$$root!==undefined){const e=b.n;throw new Error(d===null?`no element has the id "${e}" to mount a program at`:b.n===null?"the page's body already holds a program":`the element "${e}" already holds a program`)}m(b.a,d)}};
const o=(a)=>[{a:a,n:null}];
const p=f(),
r={m:(a,b)=>{const c=p();return{s:c,q:null,e:c}},p:(d,e)=>{}},
s={t:r,v:null},
t=(a)=>s,
u=o({init:{},update:(a,b)=>b,view:t});
n(u);
export{k as flush};
