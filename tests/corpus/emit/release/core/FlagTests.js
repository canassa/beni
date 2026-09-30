const a=(b,c)=>b&2&&!(b&4)?c.firstChild:b&1?c:null,
b=(a)=>a&8?"wide":"narrow",
c=(a)=>(a&8)!==0;
export{a,b,c};
