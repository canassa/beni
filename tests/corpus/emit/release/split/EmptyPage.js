const a=(b)=>b.u===null||b.u.length===0?b.i===null?b.m:l(b.i):l(b.u[0]),
l=(b)=>b.s===null?a(b.q):b.s,
b=(a)=>a.m===null?a.u===null||a.u.length===0?w(a.i):w(a.u[a.u.length-1]):a.m,
w=(a)=>a.e===null?b(a.q):a.e,
z=(a,b,c)=>{let d=l(b);const e=w(b);for(;;){const f=d.nextSibling;a.insertBefore(d,c);if(d===e)return;d=f}},
A=(a)=>{let b=l(a);const c=w(a);for(;;){const d=b.nextSibling;b.remove();if(b===c)return;b=d}},
c=(a,b)=>{const d=l(a);z(d.parentNode,b,d);A(a)},
d=()=>{let a=null;return()=>{if(a===null){const b=document,c=b.createElement("template");c.innerHTML="<!>";a=c.content;a=a.firstChild}return a.cloneNode(true)}},
B=(a)=>({b:null,cx:null,d:false,i:null,m:null,p:a,u:null,x:null,y:null,z:null}),
C=(a)=>a.p===null?a.m.parentNode:a.p,
D=(a,b)=>{const c=a.t.m(a.v,b);c.t=a.t;c.b=a;return c},
E=(a,b,d)=>{if(b===a.b)return a;if(b.t===a.t){b.t.p(a,b.v);a.b=b;return a}const e=D(b,d);c(a,e);return e},
F=(a,b)=>{if(a.i===null)z(C(a),b,a.m);else c(a.i,b);a.i=b},
G=(a,b)=>{if(a.i===null)F(a,D(b,a.cx));else a.i=E(a.i,b,a.cx)};
let e=[],
f=false,
g=null;
const h=()=>{f=false;const a=e;e=[];for(const b of a)b();g?.()},
i=(a,b)=>{const c=B(b);let d=a.init,g=false;const j=()=>{g=false;G(c,a.view(d))};b.$$root=(k)=>{if(!g){g=true;e.push(j);if(!f){f=true;queueMicrotask(()=>{if(f)h()})}}d=a.update(k,d)};G(c,a.view(d))},
j=(a)=>{for(const b of a){const c=document,d=b.n===null?c.body:c.getElementById(b.n);if(d===null||d.$$root!==undefined){const e=b.n;throw new Error(d===null?`no element has the id "${e}" to mount a program at`:b.n===null?"the page's body already holds a program":`the element "${e}" already holds a program`)}if(b.h===undefined)i(b.a,d);else i(b.h(d,h,(k)=>{g=k;return f}),d)}};
let o=b=>[{a:b,n:null}];
const k=d(),
m={m:(a,b)=>{const c=k();return{s:c,q:null,e:c}},p:(d,e)=>{}},
n={t:m,v:null},
p=(a)=>n,
q=o({init:{},update:(a,b)=>b,view:p});
j(q);
export{h as flush};
