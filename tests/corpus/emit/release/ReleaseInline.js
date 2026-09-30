import{a}from"./_platform/Node.mjs";
const b=(a,c)=>{const d=a.a<c.a?"LT":a.a>c.a?"GT":"EQ";if(d!=="EQ")return d;return a.b<c.b?"LT":a.b>c.b?"GT":"EQ"},
c=(a,b)=>a.a===b.a&&a.b===b.b,
d=(a)=>a.a+a.b,
e=(a)=>({$:"Pair",a:a.b,b:a.a}),
f=(a)=>{const b=a.a;return b*b},
g=(a)=>{const b=d(a);return b+1},
h=a([]);
export{b,c,h,d,e,f,g};
