// Differential page transcripts; deletion ablations are intentionally never run.
import fs from 'node:fs';
import {execFileSync} from 'node:child_process';
import {gunzipSync} from 'node:zlib';
import {createHash} from 'node:crypto';
const root='bench/direct-bytes/results',out='zig-out/direct-bytes/verify';fs.mkdirSync(out,{recursive:true});
const trials=['baseline','trim-mask-zeroes','short-path-ids','paths-and-zeroes','short-protocol-fields','u32-masks','literal-plan','inline-group-records'];
const summary=[];
for(const app of ['conduit','todomvc','table']){
 const scripts=app==='conduit'?['Reader','Editor','Tour'].map(n=>`tests/corpus/browser/direct/Conduit${n}/_expected.steps`):[`${out}/${app}.steps`];
 if(app==='todomvc')fs.writeFileSync(scripts[0],`input #new-todo "first"\nkey #new-todo Enter\ninput #new-todo "second"\nkey #new-todo Enter\nclick .todo-list>li:nth-child(1)>div>input\nclick .filters>li:nth-child(2)>a\nclick .filters>li:nth-child(1)>a\ndblclick .todo-list>li:nth-child(2)>div>label\ninput #edit "edited"\nkey #edit Enter\nclick #toggle-all\nclick #clear-completed\n`);
 // The corpus driver seeds crypto, so the table labels compare exactly.
 if(app==='table')fs.writeFileSync(scripts[0],`click #run\nclick tbody>tr:nth-child(2)>td:nth-child(2)>a\nclick #swaprows\nclick #update\nclick tbody>tr:nth-child(4)>td:nth-child(3)>a\nclick #add\nclick #clear\n`);
 let expected=[];
 for(const trial of trials){
  const file=`${out}/${app}-${trial}.mjs`;fs.writeFileSync(file,gunzipSync(fs.readFileSync(`${root}/${app}-direct-${trial}.mjs.gz`)));
  for(const [i,script]of scripts.entries()){
   let transcript=execFileSync('node',['tests/browser/driver.mjs','--dom=tests/browser/happy-dom.mjs','--no-comments',file,script],{encoding:'utf8',maxBuffer:64<<20});
   if(trial==='baseline')expected[i]=transcript;else if(transcript!==expected[i]){fs.writeFileSync(`${out}/expected.txt`,expected[i]);fs.writeFileSync(`${out}/actual.txt`,transcript);throw Error(`${app}/${trial}/${script} differs`)}
   summary.push({app,trial,script,transcriptSha256:createHash('sha256').update(transcript).digest('hex')});
  }
 }
}
fs.writeFileSync(`${root}/verification.json`,JSON.stringify(summary,null,2)+'\n');console.log(`${summary.length} page transcripts agree`);
