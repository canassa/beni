const a=(b,c)=>{while(b.firstChild!==null)c.appendChild(b.firstChild)},
b=(a,c)=>{while(c!==a.length){a[c]();c+=1}},
c=(a,b)=>{while(a[b]!==null)b+=2;return b},
d=(a,b)=>{for(;;){const c=a.nextSibling;a.remove();if(a===b)return;a=c}};
export{a,b,c,d};
