// Round files stay verbatim; pooled files feed the unmodified upstream report.
import fs from 'node:fs';
const dir='bench/s8/results',pooled=new Map();
for(const label of ['jfb','jfb-1','jfb-2','jfb-3'])for(const file of fs.readdirSync(`${dir}/${label}/raw`).filter(f=>f.endsWith('.json'))){
 const row=JSON.parse(fs.readFileSync(`${dir}/${label}/raw/${file}`));
 if(!pooled.has(file))pooled.set(file,{...row,values:{}});
 for(const [column,data]of Object.entries(row.values))(pooled.get(file).values[column]??=[]).push(...data.values);
}
fs.mkdirSync(`${dir}/jfb-pooled/raw`,{recursive:true});
for(const [file,row]of pooled){
 row.values=Object.fromEntries(Object.entries(row.values).map(([key,values])=>{const a=values.toSorted((a,b)=>a-b),n=a.length,mean=a.reduce((a,b)=>a+b,0)/n;return [key,{min:a[0],max:a.at(-1),median:n%2?a[(n-1)/2]:(a[n/2-1]+a[n/2])/2,mean,stddev:n>1?Math.sqrt(a.reduce((s,x)=>s+(x-mean)**2,0)/(n-1)):0,values}]}));
 fs.writeFileSync(`${dir}/jfb-pooled/raw/${file}`,JSON.stringify(row)+'\n');
}
console.log('Pooled',pooled.size,'cells.');
