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
let e=[];
let f=false;
let g=null;
const h=(a,b)=>{while(b!==a.length){a[b]();b+=1}},
i=()=>{f=false;const a=e;e=[];h(a,0);g?.()},
j=(a,b)=>{const c=B(b);let d=a.init;let g=false;const h=()=>{g=false;G(c,a.view(d))};b.$$root=(k)=>{if(!g){g=true;e.push(h);if(!f){f=true;queueMicrotask(()=>{if(f)i()})}}d=a.update(k,d)};G(c,a.view(d))},
k=(a)=>{const b=document,c=a.n===null?b.body:b.getElementById(a.n);if(c===null||c.$$root!==undefined){const d=a.n;throw new Error(c===null?`no element has the id "${d}" to mount a program at`:a.n===null?"the page's body already holds a program":`the element "${d}" already holds a program`)}a.h===undefined?j(a.a,c):j(a.h(c,i,(e)=>{g=e;return f}),c)},
m=(a)=>{let b=0;while(b!==a.length){const c=a[b];k(c);b+=1}};
let o=b=>[{a:b,n:null}];
const n=d(),
p={m:(a,b)=>{const c=n();return{s:c,q:null,e:c}},p:(d,e)=>{}},
q={t:p,v:null},
r=(a)=>q,
s=o({init:{},update:(a,b)=>b,view:r});
m(s);
export{i as flush};
