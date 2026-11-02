const a=b=>({next:undefined,state:b}),b=(a,c)=>{a.state=c;a.next=c;let d=a.next;return d!==undefined?d:a.state};export{a,b};
