import{a}from"./_core/List.mjs";const b=a=>({mount:c=>a+c+1,patch:c=>a+c+2}),c=a=>a>0?a+2+(d=>d*3+d*4)(5):a-3+(a-4),d=b=>a(b,b=>{let c=b*10;return{get:b=>c+b}});export{b,c,d};
