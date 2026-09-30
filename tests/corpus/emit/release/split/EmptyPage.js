const a=(b)=>b.u===null||b.u.length===0?b.i===null?b.m:c(b.i):c(b.u[0]),
c=(b)=>b.s===null?a(b.q):b.s,
b=(a)=>a.m===null?a.u===null||a.u.length===0?d(a.i):d(a.u[a.u.length-1]):a.m,
d=(a)=>a.e===null?b(a.q):a.e,
e=(a,b,f)=>{let g=c(b);const h=d(b);for(;;){const i=g.nextSibling;a.insertBefore(g,f);if(g===h)return;g=i}},
l=(a)=>{let b=c(a);const e=d(a);for(;;){const f=b.nextSibling;b.remove();if(b===e)return;b=f}},
f=(a,b)=>{const d=c(a);e(d.parentNode,b,d);l(a)},
g=()=>{let a=null;return()=>{if(a===null){const b=document,c=b.createElement("template");c.innerHTML="<!>";a=c.content;a=a.firstChild}return a.cloneNode(true)}},
h=(a)=>({cx:null,i:null,m:null,p:a}),
q=(a)=>a.p===null?a.m.parentNode:a.p,
v=(a,b)=>{const c=a.t.m(a.v,b);c.t=a.t;c.b=a;return c},
w=(a,b,c)=>{if(b===a.b)return a;if(b.t===a.t){b.t.p(a,b.v);a.b=b;return a}const d=v(b,c);f(a,d);return d},
x=(a,b)=>{if(a.i===null)e(q(a),b,a.m);else f(a.i,b);a.i=b},
i=(a,b)=>{if(a.i===null)x(a,v(b,a.cx));else a.i=w(a.i,b,a.cx)};
let j=[],
k=false;
const m=()=>{k=false;const a=j;j=[];for(const b of a)b()},
n=(a,b)=>{const c=h(b);let d=a.init,e=false;const f=()=>{e=false;i(c,a.view(d))};b.$$root=(g)=>{if(!e){e=true;j.push(f);if(!k){k=true;queueMicrotask(()=>{if(k)m()})}}d=a.update(g,d)};i(c,a.view(d))},
o=(a)=>{for(const b of a){const c=document,d=b.n===null?c.body:c.getElementById(b.n);if(d===null||d.$$root!==undefined){const e=b.n;throw new Error(d===null?`no element has the id "${e}" to mount a program at`:b.n===null?"the page's body already holds a program":`the element "${e}" already holds a program`)}n(b.a,d)}};
const p=(a)=>[{a:a,n:null}];
const r=g(),
s={m:(a,b)=>{const c=r();return{s:c,q:null,e:c}},p:(d,e)=>{}},
t={t:s,v:null},
u=(a)=>t,
y=p({init:{},update:(a,b)=>b,view:u});
o(y);
export{m as flush};
