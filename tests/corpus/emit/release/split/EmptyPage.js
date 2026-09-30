const a=(b)=>{if(b.u===null||b.u.length===0)return b.i===null?b.m:l(b.i);return l(b.u[0])},
l=(b)=>b.s===null?a(b.q):b.s,
b=(a)=>{if(a.m===null)return a.u===null||a.u.length===0?w(a.i):w(a.u[a.u.length-1]);return a.m},
w=(a)=>a.e===null?b(a.q):a.e,
z=(a,b,c)=>{let d=l(b);const e=w(b);for(;;){const f=d.nextSibling;a.insertBefore(d,c);if(d===e)return;d=f}},
A=(a)=>{let b=l(a);const c=w(a);for(;;){const d=b.nextSibling;b.remove();if(b===c)return;b=d}},
c=(a,b)=>{const d=l(a);z(d.parentNode,b,d);A(a)},
d=()=>{const a=document,b=a.createElement("template");b.innerHTML="<!>";const c=b.content;return c.firstChild},
e=()=>{let a=null;return()=>{if(a===null)a=d();return a.cloneNode(true)}},
B=(a)=>({b:null,cx:null,d:false,i:null,m:null,p:a,u:null,x:null,y:null,z:null}),
C=(a)=>a.p===null?a.m.parentNode:a.p,
D=(a,b)=>{const c=a.t.m(a.v,b);c.t=a.t;c.b=a;return c},
E=(a,b,d)=>{if(b===a.b)return a;if(b.t===a.t){b.t.p(a,b.v);a.b=b;return a}const e=D(b,d);c(a,e);return e},
F=(a,b)=>{if(a.i===null)z(C(a),b,a.m);else c(a.i,b);a.i=b},
G=(a,b)=>{if(a.i===null)F(a,D(b,a.cx));else a.i=E(a.i,b,a.cx)};
let f=[];
let g=false;
let h=null;
const i=(a,b)=>{for(;;){if(b===a.length)return;a[b]();b=b+1}},
j=()=>{g=false;const a=f;f=[];i(a,0);if(h!==null)h()},
k=(a,b)=>{const c=a.n;if(b===null)return`no element has the id "${c}" to mount a program at`;return a.n===null?"the page's body already holds a program":`the element "${c}" already holds a program`},
m=(a,b)=>{throw Error(k(a,b))},
n=(a,b)=>{const c=B(b);let d=a.init;let e=false;const h=()=>{e=false;G(c,a.view(d))};b.$$root=(i)=>{if(!e){e=true;f.push(h);if(!g){g=true;queueMicrotask(()=>{if(g)j()})}}d=a.update(i,d)};G(c,a.view(d))},
o=(a)=>{const b=document,c=a.n===null?b.body:b.getElementById(a.n);if(c===null)m(a,c);else if(c.$$root!==undefined)m(a,c);a.h===undefined?n(a.a,c):n(a.h(c,j,(d)=>{h=d;return g}),c)},
p=(a)=>{let b=0;for(;;){if(b===a.length)return;const c=a[b];o(c);b=b+1}};
let q=b=>[{a:b,n:null}];
const r=e(),
s={m:(a,b)=>{const c=r();return{s:c,q:null,e:c}},p:(d,e)=>{}},
t={t:s,v:null},
u=(a)=>t,
v=q({init:{},update:(a,b)=>b,view:u});
p(v);
export{j as flush};
