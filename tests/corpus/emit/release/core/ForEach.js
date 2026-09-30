const a=(b)=>{for(const c of b)c()},
b=(a)=>{for(const c of a){const d=c.root;d.started=true}},
c=(a,b)=>{for(const d of a)b(d)};
export{a,b,c};
