const n=i=>(i.s!==null?i.s:A(i.q));const w=i=>(i.e!==null?i.e:B(i.q));const A=s=>{if(s.u!==null&&s.u.length!==0)return n(s.u[0]);return s.i!==null?n(s.i):s.m};const B=s=>{if(s.m!==null)return s.m;if(s.u!==null&&s.u.length!==0)return w(s.u[s.u.length-1]);return w(s.i)};const C=(parent,i,aa)=>{const X=w(i);let R=n(i);for(;;){const Y=R.nextSibling;parent.insertBefore(R,aa);if(R===X)return;R=Y}};const D=i=>{const X=w(i);let R=n(i);for(;;){const Y=R.nextSibling;R.remove();if(R===X)return;R=Y}};const E=(_,i)=>{const f=n(_);C(f.parentNode,i,f);D(_)};const l=(ba,V)=>{let S=null;return()=>{if(S===null){const document=globalThis.document;const t=document.createElement("template");t.innerHTML=ba;S=t.content;if(V&2)S=S.firstChild;if(V&4){if(V&2){const f=document.createDocumentFragment();while(S.firstChild!==null)f.appendChild(S.firstChild);S=f}}else S=S.firstChild}
return V&1?globalThis.document.importNode(S,true):S.cloneNode(true)}};const F=(parent,ca,cx)=>({p:parent,m:ca,cx,i:null,u:null,b:null,x:null,y:null,z:null,d:false});const G=s=>(s.p!==null?s.p:s.m.parentNode);const H=(b,cx)=>{const i=b.t.m(b.v,cx);i.t=b.t;i.b=b;return i};const I=(i,b,cx)=>{if(b===i.b)return i;if(b.t===i.t){b.t.p(i,b.v);i.b=b;return i}
const R=H(b,cx);E(i,R);return R};const J=(s,i)=>{if(s.i!==null)E(s.i,i);else C(G(s),i,s.m);s.i=i};const K=(s,b)=>{if(s.i===null)J(s,H(b,s.cx));else s.i=I(s.i,b,s.cx)};let L=[];let M=false;let N=null;const O=()=>{M=false;const ea=L;L=[];for(const Z of ea)Z();N?.()};const P=U=>{const document=globalThis.document;for(const m of U){const T=m.n===null?document.body:document.getElementById(m.n);if(T===null||T.$$root!==undefined)throw new Error(T===null?`no element has the id "${m.n}" to mount a program at`:`${m.n===null?"the page's body":`the element "${m.n}"`} already holds a program`);Q(m.h?m.h(T,O,f=>(N=f,M)):m.a,T)}};const Q=(U,T)=>{const s=F(T,null,null);let W=U.init;let $=false;const Z=()=>{$=false;K(s,U.view(W))};T.$$root=da=>{if(!$){$=true;L.push(Z);if(!M){M=true;queueMicrotask(()=>{if(M)O()})}}
W=U.update(da,W)};K(s,U.view(W))};
let b=c=>[{a:c,n:null}];
const a=l("<!>",0),
c={m:(b,d)=>{const e=a();return{s:e,q:null,e:e}},p:(f,g)=>{}},
d={t:c,v:null},
e=(a)=>d,
f=b({init:{},update:(a,c)=>c,view:e});
P(f);
export{O as flush};
