const n=i=>(i.s!==null?i.s:A(i.q));const w=i=>(i.e!==null?i.e:B(i.q));const A=s=>{if(s.u!==null&&s.u.length!==0)return n(s.u[0]);return s.i!==null?n(s.i):s.m};const B=s=>{if(s.m!==null)return s.m;if(s.u!==null&&s.u.length!==0)return w(s.u[s.u.length-1]);return w(s.i)};const C=(parent,i,_)=>{const W=w(i);let Q=n(i);for(;;){const X=Q.nextSibling;parent.insertBefore(Q,_);if(Q===W)return;Q=X}};const D=i=>{const W=w(i);let Q=n(i);for(;;){const X=Q.nextSibling;Q.remove();if(Q===W)return;Q=X}};const E=($,i)=>{const f=n($);C(f.parentNode,i,f);D($)};const l=(aa,U)=>{let R=null;return()=>{if(R===null){const document=globalThis.document;const t=document.createElement("template");t.innerHTML=aa;R=t.content;if(U&2)R=R.firstChild;if(U&4){if(U&2){const f=document.createDocumentFragment();while(R.firstChild!==null)f.appendChild(R.firstChild);R=f}}else R=R.firstChild}
return U&1?globalThis.document.importNode(R,true):R.cloneNode(true)}};const F=(parent,ba,cx)=>({p:parent,m:ba,cx,i:null,u:null,b:null,x:null,y:null,z:null,d:false});const G=s=>(s.p!==null?s.p:s.m.parentNode);const H=(b,cx)=>{const i=b.t.m(b.v,cx);i.t=b.t;i.b=b;return i};const I=(i,b,cx)=>{if(b===i.b)return i;if(b.t===i.t){b.t.p(i,b.v);i.b=b;return i}
const Q=H(b,cx);E(i,Q);return Q};const J=(s,b)=>{if(s.i===null){const i=H(b,s.cx);C(G(s),i,s.m);s.i=i}else s.i=I(s.i,b,s.cx)};let K=[];let L=false;let M=null;const N=()=>{L=false;const da=K;K=[];for(const Y of da)Y();M?.()};const O=T=>{const document=globalThis.document;for(const m of T){const S=m.n===null?document.body:document.getElementById(m.n);if(S===null||S.$$root!==undefined)throw new Error(S===null?`no element has the id "${m.n}" to mount a program at`:`${m.n===null?"the page's body":`the element "${m.n}"`} already holds a program`);P(m.h?m.h(S,N,f=>(M=f,L)):m.a,S)}};const P=(T,S)=>{const s=F(S,null,null);let V=T.init;let Z=false;const Y=()=>{Z=false;J(s,T.view(V))};S.$$root=ca=>{if(!Z){Z=true;K.push(Y);if(!L){L=true;queueMicrotask(()=>{if(L)N()})}}
V=T.update(ca,V)};J(s,T.view(V))};
let b=c=>[{a:c,n:null}];
const a=l("<!>",0),
c={m:(b,d)=>{const e=a();return{s:e,q:null,e:e}},p:(f,g)=>{}},
d={t:c,v:null},
e=(a)=>d,
f=b({init:{},update:(a,c)=>c,view:e});
O(f);
export{N as flush};
