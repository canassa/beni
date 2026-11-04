const a=b=>b.length,b=()=>0,c=b=>a(b?[1]:[2,3]),d=()=>{let a=[1];a.push(2);return a.length},e=()=>{let b=0;return a([(()=>{b++;return 3})()])+b};export{b,c,d,e};
