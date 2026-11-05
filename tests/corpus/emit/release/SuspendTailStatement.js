import{a}from"./_platform/Io.mjs";import{b,c}from"./_core/Task.mjs";const d=b=>b>0?a(b):null;function e(a){return a+1}const f=a=>{let g=d(a);if(c(g))return b(e.bind(null,a));return e(a,g)};export{f};
