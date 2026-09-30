const a=(b,c)=>{if(b&2&&!(b&4))return c.firstChild;return b&1?c:null;},
b=(a)=>a&8?"wide":"narrow",
c=(a)=>(a&8)!==0;
export{a,b,c};
